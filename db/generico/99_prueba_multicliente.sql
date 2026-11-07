-- =============================================================================
-- AVIA Vigilante · Prueba del flujo y del aislamiento entre clientes (ROLLBACK al final)
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 99_prueba_multicliente.sql
-- Requiere 01 y 02.
-- =============================================================================
BEGIN;
SET search_path = vigilante, public;
SET LOCAL vigilante.actor = 'prueba';

-- Segundo cliente creado desde la plantilla de ORBITA (mismo país: copia territorios y categorías)
SELECT 'alta desde plantilla' AS prueba,
       alta_cliente('agro-bolivia', 'Vigilante Agro Bolivia', 'agro', 'BO', 'America/La_Paz', 'orbita-bolivia') IS NOT NULL AS ok;
SELECT 'territorios copiados con jerarquía (esperado 9 con padre)' AS prueba, count(*)
  FROM territorios t JOIN clientes c ON c.id = t.cliente_id WHERE c.slug = 'agro-bolivia' AND t.padre_id IS NOT NULL;
INSERT INTO sources (cliente_id, codigo, nombre, url, tipo, metodo, rapida)
SELECT id, 'gnews_agro', 'Google News · agro', 'https://news.google.com/rss/search', 'medio', 'google_news_rss', true
  FROM clientes WHERE slug = 'agro-bolivia';

-- Usuarios de cada cliente (auth_user_id simula la cuenta de Supabase)
INSERT INTO users (id, cliente_id, auth_user_id, nombre, email, telegram_chat_id, rol)
SELECT '00000000-0000-0000-0000-00000000000a', id, '10000000-0000-0000-0000-00000000000a', 'Analista ORBITA', 'analista@orbita.bo', 1001, 'analista'
  FROM clientes WHERE slug = 'orbita-bolivia';
INSERT INTO users (id, cliente_id, auth_user_id, nombre, email, telegram_chat_id, rol)
SELECT '00000000-0000-0000-0000-00000000000b', id, '10000000-0000-0000-0000-00000000000b', 'Hotel La Paz', 'hotel@ejemplo.bo', 1002, 'visor'
  FROM clientes WHERE slug = 'orbita-bolivia';
INSERT INTO users (id, cliente_id, auth_user_id, nombre, email, telegram_chat_id, rol)
SELECT '00000000-0000-0000-0000-00000000000c', id, '10000000-0000-0000-0000-00000000000c', 'Analista Agro', 'analista@agro.bo', 1001, 'analista'
  FROM clientes WHERE slug = 'agro-bolivia';
-- La preferencia hereda el cliente del usuario
INSERT INTO user_preferences (user_id) VALUES ('00000000-0000-0000-0000-00000000000b');
INSERT INTO user_territorios (user_id, territorio_id)
SELECT '00000000-0000-0000-0000-00000000000b', t.id
  FROM territorios t JOIN clientes c ON c.id = t.cliente_id WHERE c.slug = 'orbita-bolivia' AND t.codigo = 'BO-L';

-- Un usuario no puede suscribirse a un territorio de otro cliente
DO $$ BEGIN
  INSERT INTO vigilante.user_territorios (user_id, territorio_id)
  SELECT '00000000-0000-0000-0000-00000000000b', t.id
    FROM vigilante.territorios t JOIN vigilante.clientes c ON c.id = t.cliente_id
   WHERE c.slug = 'agro-bolivia' AND t.codigo = 'BO-L';
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'OK: territorio de otro cliente bloqueado';
END $$;

-- 1. Ciclo de 30 min: dedupe por cliente (la misma noticia vale para dos clientes)
INSERT INTO raw_items (source_id, url, content_hash, titulo)
SELECT id, 'https://ejemplo.bo/n1', 'hash-1', 'Bloqueo en la carretera a Copacabana' FROM sources WHERE codigo = 'gnews_turismo';
INSERT INTO raw_items (source_id, url, content_hash, titulo)
SELECT id, 'https://ejemplo.bo/n1', 'hash-1', 'duplicado' FROM sources WHERE codigo = 'gnews_turismo'
ON CONFLICT (cliente_id, content_hash) DO NOTHING;
INSERT INTO raw_items (source_id, url, content_hash, titulo)
SELECT id, 'https://ejemplo.bo/n1', 'hash-1', 'Bloqueo en la carretera a Copacabana' FROM sources WHERE codigo = 'gnews_agro';
SELECT 'raw_items por cliente (esperado 1 y 1)' AS prueba, c.slug, count(*)
  FROM raw_items r JOIN clientes c ON c.id = r.cliente_id GROUP BY c.slug ORDER BY c.slug;

-- 2. Señal de ORBITA (cliente deducido de la fuente); fuente no oficial y categoría vial → revisión
INSERT INTO signals (raw_item_id, source_id, titulo, resumen, naturaleza, categoria, prioridad, puntaje, enlace_oficial)
SELECT r.id, r.source_id, 'Bloqueo en la ruta a Copacabana', 'Vecinos anuncian bloqueo de 48 h...', 'riesgo', 'vial', 'alta', 85,
       'https://ejemplo.bo/n1'
  FROM raw_items r JOIN sources s ON s.id = r.source_id WHERE s.codigo = 'gnews_turismo';
INSERT INTO signal_territorios (signal_id, territorio_id)
SELECT s.id, t.id FROM signals s JOIN territorios t ON t.cliente_id = s.cliente_id AND t.codigo = 'BO-L';
SELECT 'requiere_revision / motivo / cliente' AS prueba, s.requiere_revision, s.motivo_revision, c.slug
  FROM signals s JOIN clientes c ON c.id = s.cliente_id;

-- Categoría que no existe para ese cliente debe fallar
DO $$ BEGIN
  INSERT INTO vigilante.signals (source_id, titulo, resumen, naturaleza, categoria)
  SELECT id, 'x', 'x', 'riesgo', 'inexistente' FROM vigilante.sources WHERE codigo = 'gnews_agro';
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN foreign_key_violation THEN RAISE NOTICE 'OK: categoría ajena bloqueada';
END $$;

UPDATE signals SET estado = 'en_analisis';
SELECT 'revisión abierta, vence con la guardia del cliente' AS prueba, r.cliente_id IS NOT NULL AS hereda_cliente, r.vence_en > now() AS vence_futuro
  FROM solicitar_revision((SELECT id FROM signals)) r;
SELECT 'SLA 23:30 hora Bolivia → 07:15 (11:15 UTC)' AS prueba,
       calcular_vencimiento((SELECT id FROM clientes WHERE slug = 'orbita-bolivia'), '2026-11-03 03:30+00') AT TIME ZONE 'UTC' AS vence_utc;

-- 3. Alerta y aprobación: un analista de otro cliente NO puede aprobar
INSERT INTO alerts (signal_id, titulo, texto, enlace_fuente)
SELECT id, titulo, resumen, enlace_oficial FROM signals;
DO $$ BEGIN
  PERFORM vigilante.decidir_revision((SELECT id FROM vigilante.reviews), '00000000-0000-0000-0000-00000000000c', 'aprobada');
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'debió%' THEN RAISE; END IF;
  RAISE NOTICE 'OK: analista de otro cliente bloqueado (%)', SQLERRM;
END $$;
SELECT 'decisión' AS prueba, decision FROM decidir_revision((SELECT id FROM reviews), '00000000-0000-0000-0000-00000000000a', 'aprobada');
UPDATE signals SET estado = 'publicada';
UPDATE alerts SET publicada_en = now();

-- 4. Destinatarios: solo usuarios del mismo cliente
SELECT 'destinatarios telegram (esperado Hotel La Paz y Analista ORBITA)' AS prueba, nombre
  FROM destinatarios_alerta((SELECT id FROM alerts), 'telegram') ORDER BY nombre;
INSERT INTO deliveries (user_id, canal, alert_id)
VALUES ('00000000-0000-0000-0000-00000000000b', 'telegram', (SELECT id FROM alerts));
DO $$ BEGIN
  INSERT INTO vigilante.deliveries (user_id, canal, alert_id)
  VALUES ('00000000-0000-0000-0000-00000000000c', 'telegram', (SELECT id FROM vigilante.alerts));
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'OK: envío a usuario de otro cliente bloqueado';
END $$;

-- 5. Resumen diario por cliente
SELECT generar_resumen_diario(id) FROM clientes ORDER BY slug;
SELECT 'resumen por cliente (esperado agro 0 sin alertas, orbita 1)' AS prueba, c.slug, d.sin_alertas, count(i.alert_id)
  FROM daily_digests d JOIN clientes c ON c.id = d.cliente_id
  LEFT JOIN daily_digest_items i ON i.digest_id = d.id
 GROUP BY c.slug, d.sin_alertas ORDER BY c.slug;

-- 6. Vista pública por cliente
SELECT 'vista pública' AS prueba, cliente_slug, titulo, territorios FROM v_alertas_publicas;

-- 7. RLS: lo que ve cada usuario autenticado
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000c', true);
SELECT 'Analista Agro ve señales (esperado 0)' AS prueba, count(*) FROM vigilante.signals;
SELECT 'Analista Agro ve raw_items (esperado 1, el suyo)' AS prueba, count(*) FROM vigilante.raw_items;
SELECT 'Analista Agro ve usuarios (esperado 1)' AS prueba, count(*) FROM vigilante.users;
SELECT 'Analista Agro ve clientes (esperado 1)' AS prueba, count(*) FROM vigilante.clientes;

SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000a', true);
SELECT 'Analista ORBITA ve señales (esperado 1)' AS prueba, count(*) FROM vigilante.signals;
SELECT 'Analista ORBITA ve usuarios (esperado 2)' AS prueba, count(*) FROM vigilante.users;

SELECT set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-00000000000b', true);
SELECT 'Visor ve alertas publicadas (esperado 1)' AS prueba, count(*) FROM vigilante.alerts;
SELECT 'Visor ve señales internas (esperado 0)' AS prueba, count(*) FROM vigilante.signals;
SELECT 'Visor ve usuarios (esperado 1, él mismo)' AS prueba, count(*) FROM vigilante.users;
DO $$ BEGIN
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre) SELECT vigilante.cliente_actual(), 'nueva', 'Nueva';
  RAISE EXCEPTION 'debió fallar';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'OK: visor no puede crear categorías';
END $$;
RESET ROLE;

ROLLBACK;
