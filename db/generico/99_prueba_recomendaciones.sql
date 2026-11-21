-- Prueba de 25_recomendaciones_seguras.sql: qué falta saber, con quién verificar y avisos de afirmaciones sin verificar.
-- Requiere 01 a 25 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{vial}', 'rss' FROM ids,
  (VALUES ('r-abc', 'ABC de prueba', 'oficial', 'https://abc.gob.bo'), ('r-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);

--  R-1 vial, «la ruta está habilitada», solo prensa              → aviso, «Sin confirmar», falta el estado oficial
--  R-2 vial, mismo texto, la ABC lo dijo hace 2 h                → sin aviso
--  R-3 eventos, paro convocado para dentro de 3 días (prensa)    → falta si se mantiene la fecha
--  R-4 oportunidad de financiamiento sin plazo                   → falta la fecha límite
--  R-5 el modelo dio falta_saber y para_quien                    → se conservan
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, recomendacion, naturaleza, categoria, estado,
                               fecha_evento_inicio, created_at, salida_modelo)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', x.reco, x.nat::vigilante.naturaleza_senal, x.cat, 'detectada', x.ev, now() - interval '3 hours', x.m::jsonb
  FROM ids, (VALUES
  ('R-1', 'La ruta La Paz – Coroico está habilitada, se puede viajar.', 'riesgo', 'vial', NULL::timestamptz, '{}'),
  ('R-2', 'La ruta La Paz – Coroico está habilitada, se puede viajar.', 'riesgo', 'vial', NULL, '{}'),
  ('R-3', 'Avisar a operadores de La Paz y prever rutas alternativas.', 'riesgo', 'eventos', now() + interval '3 days', '{}'),
  ('R-4', 'Preparar la postulación.', 'oportunidad', 'financiamiento', NULL, '{}'),
  ('R-5', 'Avisar a operadores de Rurrenabaque.', 'riesgo', 'clima', NULL,
          '{"falta_saber": ["Si el aviso se amplía a Pando"], "para_quien": "operadores de turismo fluvial"}')) x(cod, reco, nat, cat, ev, m);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/' || g, 'h-reco-' || g, 'Noticia ' || g, now() - interval '2 hours'
  FROM ids, (VALUES ('R-1', 'r-pre'), ('R-2', 'r-abc'), ('R-3', 'r-pre'), ('R-4', 'r-pre'), ('R-5', 'r-pre')) x(g, f)
  JOIN vigilante.sources s ON s.codigo = x.f;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-reco-' || g.codigo;

SELECT codigo, vigilante.recomendacion_segura(id) FROM vigilante.signals WHERE codigo LIKE 'R-_' ORDER BY 1;

DO $$
DECLARE r1 jsonb; r2 jsonb; r3 jsonb; r4 jsonb; r5 jsonb;
BEGIN
  SELECT vigilante.recomendacion_segura(id) INTO r1 FROM vigilante.signals WHERE codigo = 'R-1';
  SELECT vigilante.recomendacion_segura(id) INTO r2 FROM vigilante.signals WHERE codigo = 'R-2';
  SELECT vigilante.recomendacion_segura(id) INTO r3 FROM vigilante.signals WHERE codigo = 'R-3';
  SELECT vigilante.recomendacion_segura(id) INTO r4 FROM vigilante.signals WHERE codigo = 'R-4';
  SELECT vigilante.recomendacion_segura(id) INTO r5 FROM vigilante.signals WHERE codigo = 'R-5';
  IF NOT (r1 ->> 'afirma_sin_verificar')::boolean OR r1 ->> 'texto' NOT LIKE 'Sin confirmar:%' OR r1 ->> 'aviso' IS NULL
     OR r1 ->> 'verificar_con' NOT LIKE '%ABC%' THEN RAISE EXCEPTION 'R-1: %', r1; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r1 -> 'falta_saber') x WHERE x LIKE 'Estado actual de la ruta%no hay dato oficial') THEN
    RAISE EXCEPTION 'R-1 debe pedir el estado oficial de la ruta: %', r1 -> 'falta_saber'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r1 -> 'falta_saber') x WHERE x LIKE 'Confirmar que el hecho es cierto%') THEN
    RAISE EXCEPTION 'R-1 (posible) debe pedir confirmar el hecho: %', r1 -> 'falta_saber'; END IF;
  IF r2 ? 'afirma_sin_verificar' AND (r2 ->> 'afirma_sin_verificar')::boolean OR r2 ->> 'texto' LIKE 'Sin confirmar%' THEN
    RAISE EXCEPTION 'R-2 tiene dato oficial reciente: %', r2; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r3 -> 'falta_saber') x WHERE x LIKE 'Si se mantiene%') THEN
    RAISE EXCEPTION 'R-3 (convocado): %', r3; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(r4 -> 'falta_saber') x WHERE x LIKE 'Fecha límite%') THEN
    RAISE EXCEPTION 'R-4: %', r4; END IF;
  IF r5 ->> 'para_quien' <> 'operadores de turismo fluvial' OR NOT (r5 -> 'falta_saber') ? 'Si el aviso se amplía a Pando' THEN
    RAISE EXCEPTION 'R-5: %', r5; END IF;
  IF NOT EXISTS (SELECT 1 FROM ids, jsonb_array_elements(vigilante._vigilante_json(c) -> 'senales') e WHERE e ->> 'id' = 'R-1' AND e ? 'recomendacion_segura') THEN
    RAISE EXCEPTION 'vigilante.json no lleva recomendacion_segura'; END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = coalesce(to_regprocedure('vigilante.guardar_clasificacion_25(text,jsonb,text,text,jsonb)'), 'vigilante.guardar_clasificacion(text,jsonb,text,text,jsonb)'::regprocedure)) NOT LIKE '%''falta_saber'', x -> ''falta_saber''%' THEN
    RAISE EXCEPTION 'guardar_clasificacion no guarda falta_saber'; END IF;
  RAISE WARNING 'OK: recomendaciones seguras (R-1 marcada sin verificar, R-2 con dato oficial reciente, faltas de convocado, plazo y modelo)';
END $$;

ROLLBACK;
