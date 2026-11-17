-- Prueba de 22_puntuaciones.sql: fiabilidad (base), probabilidad (solo justificada) e impacto.
-- Requiere 01 a 22 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- dos fuentes: una oficial y una de prensa
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{eventos}', 'rss' FROM ids,
  (VALUES ('p-ofi', 'Oficial de prueba', 'oficial', 'https://ofi.gob.bo'), ('p-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);

--  P-1 oficial + prensa, confirmada, con probabilidad e impacto justificados → fiabilidad 90 alta
--  P-2 solo prensa, detectada, probabilidad SIN justificación, relevancia 5   → fiabilidad 15 baja, prob «sin datos», impacto medio deducido
--  P-3 sin noticias ni nada                                                 → fiabilidad 0, todo «sin datos»
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, salida_modelo)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', 'oportunidad', 'eventos', x.est::vigilante.estado_senal, x.m::jsonb FROM ids, (VALUES
  ('P-1', 'confirmada', '{"probabilidad": {"valor": 0.8, "justificacion": "El organizador confirmó fecha y sede"}, "impacto": {"nivel": "alto", "motivo": "Feria nacional con 20 000 visitantes"}}'),
  ('P-2', 'detectada',  '{"probabilidad": {"valor": 0.9}, "relevancia": 5}'),
  ('P-3', 'detectada',  '{}')) x(cod, est, m);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
SELECT c, s.id, s.url || '/n', 'h-punt-' || s.codigo, 'Noticia ' || s.codigo FROM ids, vigilante.sources s WHERE s.codigo IN ('p-ofi', 'p-pre');
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g, vigilante.raw_items r
 WHERE (g.codigo = 'P-1' AND r.content_hash IN ('h-punt-p-ofi', 'h-punt-p-pre')) OR (g.codigo = 'P-2' AND r.content_hash = 'h-punt-p-pre');

SELECT codigo, jsonb_pretty(vigilante.puntuaciones(id)) FROM vigilante.signals WHERE codigo LIKE 'P-%' ORDER BY 1;

DO $$
DECLARE p1 jsonb; p2 jsonb; p3 jsonb;
BEGIN
  SELECT vigilante.puntuaciones(id) INTO p1 FROM vigilante.signals WHERE codigo = 'P-1';
  SELECT vigilante.puntuaciones(id) INTO p2 FROM vigilante.signals WHERE codigo = 'P-2';
  SELECT vigilante.puntuaciones(id) INTO p3 FROM vigilante.signals WHERE codigo = 'P-3';
  IF (p1 #>> '{fiabilidad,valor}')::int <> 90 OR p1 #>> '{fiabilidad,nivel}' <> 'alta' THEN RAISE EXCEPTION 'P-1 fiabilidad: %', p1 -> 'fiabilidad'; END IF;
  IF (p1 #>> '{probabilidad,valor}')::numeric <> 0.8 OR p1 #>> '{impacto,nivel}' <> 'alto' THEN RAISE EXCEPTION 'P-1 prob/impacto: %', p1; END IF;
  IF (p2 #>> '{fiabilidad,valor}')::int <> 15 OR p2 #>> '{fiabilidad,nivel}' <> 'baja' THEN RAISE EXCEPTION 'P-2 fiabilidad: %', p2 -> 'fiabilidad'; END IF;
  IF p2 #>> '{probabilidad,nivel}' <> 'sin datos' OR (p2 #> '{probabilidad,valor}') <> 'null'::jsonb THEN RAISE EXCEPTION 'P-2 sin justificación no debe tener probabilidad: %', p2 -> 'probabilidad'; END IF;
  IF p2 #>> '{impacto,nivel}' <> 'medio' OR p2 #>> '{impacto,origen}' <> 'relevancia' THEN RAISE EXCEPTION 'P-2 impacto: %', p2 -> 'impacto'; END IF;
  IF (p3 #>> '{fiabilidad,valor}')::int <> 0 OR p3 #>> '{impacto,nivel}' <> 'sin datos' THEN RAISE EXCEPTION 'P-3: %', p3; END IF;
  IF NOT EXISTS (SELECT 1 FROM ids, jsonb_array_elements(vigilante._vigilante_json(c) -> 'senales') e WHERE e ->> 'id' = 'P-1' AND e ? 'puntuaciones') THEN
    RAISE EXCEPTION 'vigilante.json no lleva puntuaciones';
  END IF;
  RAISE WARNING 'OK: tres puntuaciones separadas (P-1 %, P-2 %, P-3 %)', p1 #>> '{fiabilidad,valor}', p2 #>> '{fiabilidad,valor}', p3 #>> '{fiabilidad,valor}';
END $$;

ROLLBACK;
