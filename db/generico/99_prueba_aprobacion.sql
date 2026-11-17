-- Prueba de 18_aprobacion_analista.sql: plazo de 1 hora, nunca publicar sin aprobación,
-- aprobar / rechazar desde la web y desde Telegram, avisos a los analistas.
-- Requiere 01 a 18 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 0. Preparación: guardia todo el día (la prueba no depende de la hora), grupo de analistas,
--    canal público, token de prueba y publicar_al_vencer encendido a propósito (debe ignorarse)
CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.parametros (cliente_id, clave, valor)
SELECT c, k, v::jsonb FROM ids,
       (VALUES ('guardia_inicio', '"00:00"'), ('guardia_fin', '"23:59:59"'), ('telegram_analistas_chat', '"-100777"'),
               ('telegram_canal', '"@prueba"'), ('publicar_al_vencer', 'true'), ('panel_url', '"https://panel.ej"')) AS p(k, v)
ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;
DO $$ BEGIN
  IF to_regclass('vault.decrypted_secrets') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token') THEN
    RAISE NOTICE 'Sin token en el Vault: los avisos no se enviarán en esta prueba';
  END IF;
END $$;

INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol, telegram_chat_id)
SELECT c, x.a::uuid, x.n, x.r::vigilante.rol_usuario, x.t FROM ids, (VALUES
  ('40000000-0000-0000-0000-00000000000a', 'Lía Analista', 'analista', 555::bigint),
  ('40000000-0000-0000-0000-00000000000b', 'Vico Visor',   'visor',    666::bigint)) AS x(a, n, r, t);

--  R-A salud, oficial con enlace, hace 2 h  → plazo vencido, NO se publica
--  R-B clima, recién llegada               → aviso «por aprobar» con plazo de 1 h
--  R-C eventos, oficial                    → no pide revisión, sin aviso
--  R-D escenario                           → se aprueba pero no se publica
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad,
                               fuente_oficial, enlace_oficial, es_escenario, created_at)
SELECT c, x.codigo, x.titulo, 'Resumen ' || x.codigo, x.nat::vigilante.naturaleza_senal, x.cat, 'alta',
       x.oficial, x.enlace, x.esc, now() - x.hace
  FROM ids, (VALUES
    ('R-A', 'Alerta por dengue en Santa Cruz', 'riesgo',      'salud',   true, 'https://minsalud.gob.bo/a', false, interval '2 hours'),
    ('R-B', 'Aviso de heladas & <nieve>',      'riesgo',      'clima',   true, 'https://senamhi.gob.bo/b',  false, interval '0 minutes'),
    ('R-C', 'Feria del Alasita',               'oportunidad', 'eventos', true, 'https://ej.bo/c',           false, interval '0 minutes'),
    ('R-D', 'Escenario: más demanda en enero', 'oportunidad', 'eventos', true, 'https://ej.bo/d',           true,  interval '0 minutes')
  ) AS x(codigo, titulo, nat, cat, oficial, enlace, esc, hace);

SELECT codigo, requiere_revision, vigilante.espera_revision(s) AS espera FROM vigilante.signals s WHERE codigo LIKE 'R-%' ORDER BY 1;

-- 1. Plazo: 60 minutos por defecto
DO $$ BEGIN
  IF (vigilante.param(NULL, 'sla_revision_minutos') #>> '{}')::int <> 60 THEN RAISE EXCEPTION 'el plazo debería ser 60 min'; END IF;
END $$;

-- 2. La tarea de cada minuto: R-A vence y NO se publica; avisos a los analistas
SELECT vigilante.vencer_plazos_revision() AS revision;
DO $$ BEGIN
  IF (SELECT estado FROM vigilante.signals WHERE codigo = 'R-A') = 'publicada'
     OR EXISTS (SELECT 1 FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id WHERE s.codigo = 'R-A') THEN
    RAISE EXCEPTION 'R-A se publicó sin aprobación';
  END IF;
  IF (SELECT revision_vencida_en FROM vigilante.signals WHERE codigo = 'R-A') IS NULL THEN RAISE EXCEPTION 'R-A debería estar vencida'; END IF;
  IF (SELECT revision_vencida_en FROM vigilante.signals WHERE codigo = 'R-B') IS NOT NULL THEN RAISE EXCEPTION 'R-B aún está en plazo'; END IF;
END $$;
SELECT s.codigo, a.tipo, a.estado, a.mensaje_id FROM vigilante.avisos_revision a JOIN vigilante.signals s ON s.id = a.signal_id ORDER BY 1, 2;
SELECT vigilante.texto_aviso_revision((SELECT id FROM vigilante.signals WHERE codigo = 'R-B'), 'pendiente') AS aviso_rb;

-- 3. Web: el visor no puede; la analista aprueba R-A (se publica «Confirmada») y la cola se vacía de R-A
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-00000000000b', true);
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.aprobar_senal('R-A');
    RAISE EXCEPTION 'el visor no debería poder aprobar';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Solo un analista%' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-00000000000a', true);
SELECT codigo, vencida FROM vigilante.cola_revision() ORDER BY 1;
SELECT vigilante.aprobar_senal('R-A', 'Confirmado con el SEDES') AS aprobar_ra;
SELECT vigilante.aprobar_senal('R-A') AS aprobar_otra_vez;
SELECT vigilante.aprobar_senal('R-D') AS aprobar_escenario;
SELECT codigo FROM vigilante.cola_revision() ORDER BY 1;
SELECT quien, a, nota FROM vigilante.movimientos_senales(10) WHERE codigo = 'R-A' ORDER BY cuando, a;
RESET ROLE;

SELECT s.codigo, s.estado, s.revision_decidida_en IS NOT NULL AS decidida, u.nombre AS por,
       a.estado_verificacion, a.publicada_en IS NOT NULL AS en_web, (a.aprobada_por = u.id) AS aprobada_por_ok
  FROM vigilante.signals s LEFT JOIN vigilante.users u ON u.id = s.revision_decidida_por
  LEFT JOIN vigilante.alerts a ON a.signal_id = s.id
 WHERE s.codigo IN ('R-A', 'R-D') ORDER BY 1;

-- 4. Telegram: chat equivocado, persona desconocida, visor y por fin la analista rechaza R-B
SELECT vigilante.decidir_senal_telegram((SELECT id FROM vigilante.signals WHERE codigo = 'R-B'), 555, '-100999', false) ->> 'mensaje' AS chat_equivocado;
SELECT vigilante.decidir_senal_telegram((SELECT id FROM vigilante.signals WHERE codigo = 'R-B'), 123, '-100777', false) ->> 'mensaje' AS desconocido;
SELECT vigilante.decidir_senal_telegram((SELECT id FROM vigilante.signals WHERE codigo = 'R-B'), 666, '-100777', true) ->> 'mensaje' AS visor;
SELECT vigilante.decidir_senal_telegram((SELECT id FROM vigilante.signals WHERE codigo = 'R-B'), 555, '-100777', false) AS rechazar_rb;
SELECT estado, (SELECT nota FROM vigilante.signal_history h WHERE h.signal_id = s.id ORDER BY id DESC LIMIT 1) AS nota
  FROM vigilante.signals s WHERE codigo = 'R-B';

-- 5. Siguiente minuto: los avisos de señales decididas se cierran (el mensaje pierde los botones)
SELECT vigilante.vencer_plazos_revision() AS revision;
SELECT s.codigo, a.tipo, a.estado FROM vigilante.avisos_revision a JOIN vigilante.signals s ON s.id = a.signal_id ORDER BY 1, 2;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM vigilante.avisos_revision WHERE estado = 'enviado') THEN RAISE EXCEPTION 'quedan avisos abiertos'; END IF;
END $$;

-- 6. Panel con mover_senal: publicar a mano una señal en revisión también cuenta como decisión
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, fuente_oficial, enlace_oficial)
SELECT c, 'R-E', 'Bloqueo en la ruta a Copacabana', 'Resumen R-E', 'riesgo', 'vial', 'media', true, 'https://abc.gob.bo/e' FROM ids;
SET LOCAL ROLE authenticated;
SELECT vigilante.mover_senal('R-E', 'en_analisis');
SELECT vigilante.mover_senal('R-E', 'confirmada');
RESET ROLE;
SELECT codigo, estado, revision_decidida_en IS NOT NULL AS decidida, (SELECT nombre FROM vigilante.users WHERE id = revision_decidida_por) AS por
  FROM vigilante.signals WHERE codigo = 'R-E';

ROLLBACK;
