-- Prueba de 23_trazabilidad.sql: fuente, enlace, publicación, recogida, detección y última verificación.
-- Requiere 01 a 23 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{eventos}', 'rss' FROM ids,
  (VALUES ('t-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.gob.bo'), ('t-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);
UPDATE vigilante.sources SET ultima_consulta_en = now() - interval '20 minutes' WHERE codigo = 't-ofi';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol, telegram_chat_id)
SELECT c, '50000000-0000-0000-0000-00000000000a', 'Ana Analista', 'analista', 777 FROM ids;

--  T-1: noticia oficial (publicada hace 1 día) + prensa (sin fecha de publicación); una persona la confirma
--  T-2: señal antigua sin noticias enlazadas, con enlaces copiados de vigilante.json
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, created_at, salida_modelo)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', 'riesgo', 'eventos', 'detectada', now() - interval '3 hours', x.m::jsonb FROM ids, (VALUES
  ('T-1', '{}'), ('T-2', '{"enlaces": [{"nombre": "Diario", "url": "https://diario.bo/a", "fecha": "2026-11-10"}]}')) x(cod, m);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, publicado_en)
SELECT c, s.id, s.url || '/aviso', 'h-traz-' || s.codigo, 'Noticia ' || s.codigo,
       CASE WHEN s.codigo = 't-ofi' THEN now() - interval '1 day' END
  FROM ids, vigilante.sources s WHERE s.codigo IN ('t-ofi', 't-pre');
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g, vigilante.raw_items r WHERE g.codigo = 'T-1' AND r.content_hash LIKE 'h-traz-%';
-- la persona la mueve (el actor es su id de Supabase Auth)
SELECT set_config('vigilante.actor', '50000000-0000-0000-0000-00000000000a', true);
UPDATE vigilante.signals SET estado = 'en_analisis' WHERE codigo = 'T-1';
UPDATE vigilante.signals SET estado = 'confirmada' WHERE codigo = 'T-1';
SELECT set_config('vigilante.actor', '', true);

SELECT codigo, jsonb_pretty(vigilante.trazabilidad(id)) FROM vigilante.signals WHERE codigo IN ('T-1', 'T-2') ORDER BY 1;

DO $$
DECLARE t1 jsonb; t2 jsonb;
BEGIN
  SELECT vigilante.trazabilidad(id) INTO t1 FROM vigilante.signals WHERE codigo = 'T-1';
  SELECT vigilante.trazabilidad(id) INTO t2 FROM vigilante.signals WHERE codigo = 'T-2';
  IF jsonb_array_length(t1 -> 'fuentes') <> 2 THEN RAISE EXCEPTION 'T-1 debe tener 2 fuentes: %', t1 -> 'fuentes'; END IF;
  IF NOT (t1 #>> '{fuentes,0,oficial}')::boolean OR t1 #>> '{fuentes,0,nombre}' <> 'SENAMHI de prueba' THEN RAISE EXCEPTION 'la oficial va primero'; END IF;
  IF t1 #> '{fuentes,0,publicada}' IS NULL OR t1 #> '{fuentes,0,recogida}' IS NULL THEN RAISE EXCEPTION 'faltan fechas de publicación/recogida'; END IF;
  IF t1 #> '{fuentes,1}' ? 'publicada' THEN RAISE EXCEPTION 'la prensa sin fecha no debe inventar publicación'; END IF;
  IF t1 ->> 'detectada' IS NULL OR t1 ->> 'fuente_comprobada' IS NULL THEN RAISE EXCEPTION 'falta detectada o fuente_comprobada'; END IF;
  IF t1 #>> '{ultima_verificacion,quien}' <> 'Ana Analista' OR t1 #>> '{ultima_verificacion,estado}' <> 'confirmada' THEN
    RAISE EXCEPTION 'última verificación: %', t1 -> 'ultima_verificacion'; END IF;
  IF t2 -> 'ultima_verificacion' <> 'null'::jsonb OR t2 #>> '{fuentes,0,nota}' NOT LIKE 'fecha sin distinguir%' THEN
    RAISE EXCEPTION 'T-2: %', t2; END IF;
  IF NOT EXISTS (SELECT 1 FROM ids, jsonb_array_elements(vigilante._vigilante_json(c) -> 'senales') e WHERE e ->> 'id' = 'T-1' AND e ? 'trazabilidad') THEN
    RAISE EXCEPTION 'vigilante.json no lleva trazabilidad';
  END IF;
  RAISE WARNING 'OK: trazabilidad (T-1 verificada por %, T-2 con fecha sin distinguir)', t1 #>> '{ultima_verificacion,quien}';
END $$;

ROLLBACK;
