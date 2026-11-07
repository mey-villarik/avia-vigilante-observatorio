-- =============================================================================
-- ORBITA · Prueba del flujo completo (se deshace al final con ROLLBACK)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 99_prueba_flujo.sql
-- =============================================================================
BEGIN;
SET search_path = orbita, public;
SET LOCAL orbita.actor = 'prueba';

-- Usuarios: una analista y dos visores
INSERT INTO users (id, nombre, email, telegram_chat_id, rol) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'Analista', 'analista@ejemplo.bo', 1001, 'analista'),
  ('00000000-0000-0000-0000-00000000000b', 'Hotel La Paz', 'hotel@ejemplo.bo', 1002, 'visor'),
  ('00000000-0000-0000-0000-00000000000c', 'Agencia Santa Cruz', 'agencia@ejemplo.bo', 1003, 'visor');
INSERT INTO user_preferences (user_id, prioridad_minima) VALUES
  ('00000000-0000-0000-0000-00000000000b', 'media'), ('00000000-0000-0000-0000-00000000000c', 'media');
INSERT INTO user_departamentos VALUES ('00000000-0000-0000-0000-00000000000b', 2), ('00000000-0000-0000-0000-00000000000c', 7);
INSERT INTO user_categorias VALUES ('00000000-0000-0000-0000-00000000000b', 'clima');

-- 1. Recolección con dedupe
INSERT INTO raw_items (source_id, url, content_hash, titulo, contenido)
SELECT id, 'https://senamhi.gob.bo/alerta/1', 'hash-1', 'Alerta naranja por lluvias en La Paz', 'Lluvias intensas en Yungas'
  FROM sources WHERE codigo = 'senamhi_alertas';
INSERT INTO raw_items (source_id, url, content_hash, titulo)
SELECT id, 'https://senamhi.gob.bo/alerta/1', 'hash-1', 'duplicado' FROM sources WHERE codigo = 'senamhi_alertas'
ON CONFLICT (content_hash) DO NOTHING;
SELECT 'raw_items tras dedupe (esperado 1)' AS prueba, count(*) FROM raw_items;

-- 2. Señal de clima: debe exigir revisión
INSERT INTO signals (raw_item_id, source_id, titulo, resumen, naturaleza, categoria, prioridad, puntaje, enlace_oficial)
SELECT r.id, r.source_id, 'Alerta naranja por lluvias en Yungas', 'SENAMHI emite alerta naranja...', 'riesgo', 'clima', 'alta', 90,
       'https://senamhi.gob.bo/alerta/1'
  FROM raw_items r;
INSERT INTO signal_departamentos SELECT id, 2 FROM signals;
SELECT 'requiere_revision / fuente_oficial / motivo' AS prueba, requiere_revision, fuente_oficial, motivo_revision FROM signals;

-- Transición inválida debe fallar
DO $$ BEGIN
  UPDATE orbita.signals SET estado = 'publicada';
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK: transición detectada → publicada bloqueada';
END $$;

UPDATE signals SET estado = 'en_analisis';
SELECT * FROM solicitar_revision((SELECT id FROM signals));
SELECT 'cola de revisión' AS prueba, review_id, titulo, minutos_restantes FROM v_cola_revision;

-- SLA: dentro y fuera de guardia (hora Bolivia = UTC-4)
SELECT 'SLA 10:00 BOT' AS prueba, calcular_vencimiento('2026-11-02 14:00+00') AS vence;   -- 10:15 BOT
SELECT 'SLA 23:30 BOT' AS prueba, calcular_vencimiento('2026-11-03 03:30+00') AS vence;   -- 07:15 BOT del día siguiente

-- 3. Alerta creada; WhatsApp sin aprobación debe fallar
INSERT INTO alerts (signal_id, titulo, texto, enlace_fuente)
SELECT id, titulo, resumen, enlace_oficial FROM signals;
DO $$ BEGIN
  INSERT INTO orbita.deliveries (canal, alert_id) SELECT 'whatsapp', id FROM orbita.alerts;
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK: WhatsApp sin aprobación bloqueado';
END $$;

-- 4. El analista aprueba
SELECT decision, decidido_en IS NOT NULL AS decidida
  FROM decidir_revision((SELECT id FROM reviews), '00000000-0000-0000-0000-00000000000a', 'aprobada', 'ok');
UPDATE signals SET estado = 'publicada';
UPDATE alerts SET publicada_en = now();
SELECT 'estado señal / aprobada' AS prueba, s.estado, a.aprobada_por IS NOT NULL AS aprobada FROM signals s JOIN alerts a ON a.signal_id = s.id;

-- 5. Destinatarios: el hotel de La Paz suscrito a clima y la analista (sin filtros); no la agencia de Santa Cruz
SELECT 'destinatarios telegram' AS prueba, nombre FROM destinatarios_alerta((SELECT id FROM alerts), 'telegram');
INSERT INTO deliveries (user_id, canal, alert_id, estado, enviado_en)
SELECT user_id, 'telegram', (SELECT id FROM alerts), 'enviado', now() FROM destinatarios_alerta((SELECT id FROM alerts), 'telegram');
SELECT 'destinatarios tras enviar (esperado 0)' AS prueba, count(*) FROM destinatarios_alerta((SELECT id FROM alerts), 'telegram');

-- Actualizar la alerta sube la versión y vuelve a habilitar el envío
UPDATE alerts SET texto = texto || ' Actualización: se extiende a Caranavi.';
SELECT 'versión' AS prueba, version FROM alerts;
SELECT 'destinatarios v2 (esperado 2)' AS prueba, count(*) FROM destinatarios_alerta((SELECT id FROM alerts), 'telegram');

-- 6. Web pública y feedback
SELECT 'web pública' AS prueba, titulo, etiqueta_verificacion, departamentos FROM v_alertas_publicas;
INSERT INTO feedback (alert_id, user_id, canal, util) SELECT id, '00000000-0000-0000-0000-00000000000b', 'telegram', true FROM alerts;

-- 7. Resumen diario (límite 7)
SELECT generar_resumen_diario() AS digest_id \gset
SELECT 'resumen' AS prueba, d.sin_alertas, count(i.*) AS items
  FROM daily_digests d LEFT JOIN daily_digest_items i ON i.digest_id = d.id
 WHERE d.id = :digest_id GROUP BY d.sin_alertas;
DO $$ BEGIN
  INSERT INTO orbita.daily_digest_items SELECT id, 8, (SELECT id FROM orbita.alerts) FROM orbita.daily_digests;
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK: no se permite una 8.ª alerta en el resumen';
END $$;

-- 8. Convocatoria con recordatorios 30/15/5
INSERT INTO signals (source_id, titulo, resumen, naturaleza, categoria, prioridad, plazo_hasta)
SELECT id, 'Fondo CAF turismo sostenible', 'Convocatoria abierta', 'oportunidad', 'financiamiento', 'media', now() + interval '40 days'
  FROM sources WHERE codigo = 'caf';
SELECT 'recordatorios (esperado 3)' AS prueba, programar_recordatorios(max(id)) FROM signals;
SELECT 'oportunidad oficial: requiere_revision (esperado f)' AS prueba, requiere_revision FROM signals WHERE categoria = 'financiamiento';

-- 9. Vencimiento de SLA
INSERT INTO signals (source_id, titulo, resumen, naturaleza, categoria, prioridad, enlace_oficial)
SELECT id, 'Brote de dengue en Beni', 'Boletín epidemiológico', 'riesgo', 'salud', 'alta', 'https://www.minsalud.gob.bo/x'
  FROM sources WHERE codigo = 'minsalud';
INSERT INTO reviews (signal_id, vence_en) SELECT max(id), now() - interval '1 minute' FROM signals;
SELECT 'vencidas' AS prueba, * FROM vencer_revisiones();

-- 10. Historial y RLS
SELECT 'historial' AS prueba, entidad, estado_anterior, estado_nuevo, actor FROM signal_history ORDER BY id LIMIT 6;

SET LOCAL ROLE anon;
SELECT 'anon ve alertas públicas' AS prueba, count(*) FROM orbita.v_alertas_publicas;
DO $$ BEGIN
  PERFORM count(*) FROM orbita.signals;
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: anon no puede leer signals';
END $$;
RESET ROLE;
SET LOCAL ROLE authenticated;   -- usuario autenticado sin ficha en users: no ve nada interno
SELECT 'autenticado sin rol ve signals (esperado 0)' AS prueba, count(*) FROM orbita.signals;
RESET ROLE;

ROLLBACK;
