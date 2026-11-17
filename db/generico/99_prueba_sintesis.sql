-- Prueba de 26_sintesis_dia.sql: qué pasa, por qué importa y qué vigilar, armados por la base.
-- Requiere 01 a 26 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{vial}', 'rss' FROM ids,
  (VALUES ('s-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.gob.bo'), ('s-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);

--  S-1 riesgo clima, aviso oficial (confirmado), prioridad alta, impacto alto del modelo
--  S-2 riesgo vial, solo prensa (posible), prioridad alta                  → «qué vigilar»
--  S-3 paro convocado en 3 días (prensa), prioridad media                  → hecho (convocado) y «qué vigilar»
--  S-4 oportunidad, fuente oficial, cierra en 5 días                       → hecho y plazo corto
--  S-5 escenario                                                           → no sale en «qué pasa»
--  S-6 descartada                                                          → no cuenta
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, recomendacion, naturaleza, categoria, prioridad, estado, es_escenario,
                               fecha_evento_inicio, plazo_hasta, created_at, salida_modelo)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', x.reco, x.nat::vigilante.naturaleza_senal, x.cat, x.pri::vigilante.prioridad, x.est::vigilante.estado_senal,
       x.esc, x.ev, x.plazo, now() - interval '2 hours', x.m::jsonb
  FROM ids, (VALUES
  ('S-1', 'Avisar a operadores', 'riesgo', 'clima', 'alta', 'detectada', false, NULL::timestamptz, NULL::timestamptz,
         '{"impacto": {"nivel": "alto", "motivo": "Corta salidas fluviales en Rurrenabaque"}}'),
  ('S-2', 'La ruta está habilitada', 'riesgo', 'vial', 'alta', 'detectada', false, NULL, NULL, '{}'),
  ('S-3', 'Prever rutas alternativas', 'riesgo', 'eventos', 'media', 'detectada', false, now() + interval '3 days', NULL,
         '{"certeza": {"nivel": "convocado", "motivo": "La federación anunció el paro"}, "impacto": {"nivel": "medio", "motivo": "Bloqueos en accesos a La Paz"}}'),
  ('S-4', 'Preparar la postulación', 'oportunidad', 'financiamiento', 'media', 'detectada', false, NULL, now() + interval '5 days',
         '{"impacto": {"nivel": "medio", "motivo": "Fondos para operadores comunitarios"}}'),
  ('S-5', 'Escenario', 'riesgo', 'clima', 'alta', 'detectada', true, NULL, NULL, '{}'),
  ('S-6', 'Descartada', 'riesgo', 'clima', 'alta', 'descartada', false, NULL, NULL, '{}')) x(cod, reco, nat, cat, pri, est, esc, ev, plazo, m);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/' || g, 'h-sint-' || g, 'Noticia ' || g, now() - interval '1 hour'
  FROM ids, (VALUES ('S-1', 's-ofi'), ('S-2', 's-pre'), ('S-3', 's-pre'), ('S-4', 's-ofi'), ('S-5', 's-pre'), ('S-6', 's-pre')) x(g, f)
  JOIN vigilante.sources s ON s.codigo = x.f;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-sint-' || g.codigo;

SELECT jsonb_pretty(vigilante.sintesis_dia(c)) FROM ids;

DO $$
DECLARE s jsonb; v_c uuid; v_pasa text[]; v_vig text[];
BEGIN
  SELECT c INTO v_c FROM ids;
  s := vigilante.sintesis_dia(v_c);
  v_pasa := ARRAY(SELECT e ->> 'codigo' FROM jsonb_array_elements(s -> 'que_pasa') e);
  v_vig  := ARRAY(SELECT e ->> 'codigo' || ':' || (e ->> 'tipo') FROM jsonb_array_elements(s -> 'que_vigilar') e WHERE e ? 'codigo');
  IF NOT (v_pasa @> ARRAY['S-1', 'S-3', 'S-4']) OR cardinality(v_pasa) <> 3 THEN RAISE EXCEPTION 'que_pasa: %', v_pasa; END IF;
  IF v_pasa[1] <> 'S-1' THEN RAISE EXCEPTION 'S-1 (alta, impacto alto) va primero: %', v_pasa; END IF;
  IF 'S-2' = ANY (v_pasa) OR 'S-5' = ANY (v_pasa) OR 'S-6' = ANY (v_pasa) THEN RAISE EXCEPTION 'posible, escenario o descartada en que_pasa: %', v_pasa; END IF;
  IF jsonb_array_length(s -> 'por_que_importa') <> 3 OR s #>> '{por_que_importa,0,texto}' NOT LIKE 'Corta salidas%' THEN
    RAISE EXCEPTION 'por_que_importa: %', s -> 'por_que_importa'; END IF;
  IF NOT (v_vig @> ARRAY['S-2:sin_confirmar', 'S-3:convocado', 'S-4:plazo', 'S-2:recomendacion_sin_verificar']) THEN RAISE EXCEPTION 'que_vigilar: %', v_vig; END IF;
  IF s ->> 'totales' NOT LIKE '5 señales activas%' THEN RAISE EXCEPTION 'totales no cuadran con los contadores: %', s ->> 'totales'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(vigilante._vigilante_json(v_c) -> 'sintesis_dia' -> 'que_pasa') e WHERE e ->> 'codigo' = 'S-1') THEN
    RAISE EXCEPTION 'vigilante.json no lleva sintesis_dia'; END IF;
  -- sin señales: bloques vacíos, nada inventado
  DELETE FROM vigilante.signals WHERE cliente_id = v_c;
  s := vigilante.sintesis_dia(v_c);
  IF jsonb_array_length(s -> 'que_pasa') <> 0 OR jsonb_array_length(s -> 'que_vigilar') <> 0 THEN RAISE EXCEPTION 'sin señales debe quedar vacía: %', s; END IF;
  RAISE WARNING 'OK: síntesis del día (3 hechos, 5 señales activas, S-2 y S-3 a vigilar, vacía sin señales)';
END $$;

ROLLBACK;
