-- Prueba de 36_razones_avia.sql: la entrada de AVIA lleva fiabilidad e impacto, se guardan las tres
-- razones (limpias), se borran cuando dejan de valer y las confirmadas sin razones vuelven a la ronda.
-- Requiere 01 a 36 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-raz»).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-raz', 'Prueba de razones', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{clima}', 'rss' FROM ids,
  (VALUES ('f-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.raz.bo'),
          ('f-pre', 'Prensa de prueba', 'medio', 'https://prensa.raz.bo'),
          ('f-red', 'Página de Facebook', 'no_oficial', 'https://facebook.raz.bo')) x(cod, nom, tipo, url);

CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-raz-' || p_k, 'Noticia ' || p_k,
           vigilante.texto_norm('Noticia ' || p_k), 'Texto ' || p_k, now()
      FROM ids i JOIN vigilante.sources s ON s.cliente_id = i.c AND s.codigo = p_fuente
    RETURNING id)
  INSERT INTO n SELECT p_k, id FROM r RETURNING id
$$;
CREATE FUNCTION pg_temp.senal(p_cod text, p_noticias text[], p_estado text DEFAULT 'detectada') RETURNS void LANGUAGE sql AS $$
  INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, raw_item_id)
  SELECT c, p_cod, 'Señal ' || p_cod, 'Resumen ' || p_cod, 'riesgo', 'clima', p_estado::vigilante.estado_senal,
         (SELECT id FROM n WHERE k = p_noticias[1]) FROM ids;
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
  SELECT s.id, n.id FROM vigilante.signals s, n
   WHERE s.cliente_id = (SELECT c FROM ids) AND s.codigo = p_cod AND n.k = ANY (p_noticias);
  INSERT INTO vigilante.signal_territorios (signal_id, cliente_id, territorio_id)
  SELECT s.id, s.cliente_id, t.id FROM vigilante.signals s JOIN vigilante.territorios t ON t.cliente_id = s.cliente_id AND t.nombre = 'La Paz'
   WHERE s.cliente_id = (SELECT c FROM ids) AND s.codigo = p_cod;
$$;
CREATE FUNCTION pg_temp.mover(p_cod text, VARIADIC p_estados text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text;
BEGIN
  FOREACH e IN ARRAY p_estados LOOP
    UPDATE vigilante.signals SET estado = e::vigilante.estado_senal WHERE cliente_id = (SELECT c FROM ids) AND codigo = p_cod;
  END LOOP;
END $$;
CREATE FUNCTION pg_temp.s(p_cod text) RETURNS vigilante.signals LANGUAGE sql AS $$
  SELECT * FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids) AND codigo = p_cod
$$;


SELECT pg_temp.noticia(k, f) FROM (VALUES ('ofi1', 'f-ofi'), ('pre1', 'f-pre'), ('red1', 'f-red'), ('pre2', 'f-pre')) x(k, f);
SELECT pg_temp.senal('R-1', ARRAY['ofi1', 'pre1']);
SELECT pg_temp.senal('R-2', ARRAY['red1']);
SELECT pg_temp.senal('R-3', ARRAY['pre2']);
SELECT pg_temp.mover('R-1', 'en_analisis', 'confirmada');
SELECT pg_temp.mover('R-2', 'en_analisis', 'confirmada');
UPDATE vigilante.signals SET salida_modelo = '{"impacto": {"nivel": "alto", "motivo": "Corta el acceso a Coroico"}}'
 WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'R-1';

-- 1. La entrada para AVIA trae fiabilidad (con fuentes en palabras) e impacto ----------------------
DO $$
DECLARE l jsonb := vigilante.probabilidades_por_ajustar('prueba-raz', 10); e jsonb;
BEGIN
  ASSERT jsonb_array_length(l) = 2, 'solo las confirmadas: ' || l::text;
  SELECT x INTO e FROM jsonb_array_elements(l) x WHERE x ->> 'codigo' = 'R-1';
  ASSERT (e #>> '{fiabilidad,valor}')::int = 90 AND e #>> '{fiabilidad,nivel}' = 'alta', 'fiabilidad R-1: ' || (e -> 'fiabilidad')::text;
  ASSERT e #>> '{fiabilidad,fuentes,0}' = 'SENAMHI de prueba (oficial)', 'fuente de más peso primero: ' || (e -> 'fiabilidad')::text;
  ASSERT e #>> '{impacto,nivel}' = 'alto' AND e #>> '{impacto,motivo}' = 'Corta el acceso a Coroico', 'impacto: ' || (e -> 'impacto')::text;
  ASSERT NOT e ? 'ya_ajustada', 'R-1 aún no la ajustó AVIA';
  SELECT x INTO e FROM jsonb_array_elements(l) x WHERE x ->> 'codigo' = 'R-2';
  ASSERT e #>> '{fiabilidad,fuentes,0}' = 'Página de Facebook (no oficial: redes o blog)', 'R-2: ' || (e -> 'fiabilidad')::text;
  ASSERT length(e::text) < 1300, 'entrada corta: ' || length(e::text);
END $$;

-- 2. Guardar las tres razones; se limpia «porque» y el punto final; falta una → aviso, no error --------
DO $$
DECLARE r jsonb := vigilante.guardar_probabilidades('prueba-raz', '[
  {"codigo": "R-1", "prob": 0.9, "razon": "porque en noviembre llueve casi a diario en Los Yungas.",
   "razon_fiabilidad": "AVIA determina que la fiabilidad es alta porque lo avisa el SENAMHI y lo repite la prensa.",
   "razon_impacto": "corta la ruta a Coroico en plena temporada de visitas"},
  {"codigo": "R-2", "prob": 0.3, "razon": "solo lo dice una página de Facebook y la zona no suele tener estos cortes",
   "razon_impacto": "afecta a pocos visitantes"}]'::jsonb, 'prueba');
  s1 vigilante.signals := pg_temp.s('R-1'); s2 vigilante.signals := pg_temp.s('R-2'); p jsonb;
BEGIN
  ASSERT jsonb_array_length(r -> 'errores') = 0, 'sin errores: ' || r::text;
  ASSERT s1.prob_razon = 'en noviembre llueve casi a diario en Los Yungas', 'razón limpia: ' || s1.prob_razon;
  ASSERT s1.razon_fiabilidad = 'lo avisa el SENAMHI y lo repite la prensa', 'fiabilidad limpia: ' || s1.razon_fiabilidad;
  ASSERT s1.razon_impacto = 'corta la ruta a Coroico en plena temporada de visitas', 'impacto: ' || s1.razon_impacto;
  ASSERT s1.razones_en IS NOT NULL AND s2.razones_en IS NOT NULL, 'razones_en marcado (también si falta una)';
  ASSERT s2.razon_fiabilidad IS NULL, 'R-2 sin razón de fiabilidad';
  ASSERT (r #>> '{guardadas,1,aviso}') LIKE 'Faltó «razon_fiabilidad»%', 'aviso: ' || r::text;
  p := vigilante.puntuaciones(s1.id);
  ASSERT p #>> '{fiabilidad,avia}' = s1.razon_fiabilidad AND p #>> '{probabilidad,avia}' = s1.prob_razon
     AND p #>> '{impacto,avia}' = s1.razon_impacto, 'puntuaciones lleva las tres: ' || p::text;
  ASSERT vigilante.probabilidades_pendientes_hermes('prueba-raz') = 0, 'nada pendiente';
END $$;

-- 3. Noticia nueva: se borra la razón de fiabilidad y vuelve a pendientes (con ya_ajustada) -------------
CREATE TEMP TABLE antes AS SELECT updated_at FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'R-1';
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id) SELECT (pg_temp.s('R-1')).id, id FROM n WHERE k = 'pre2';
DO $$
DECLARE s1 vigilante.signals := pg_temp.s('R-1'); l jsonb;
BEGIN
  ASSERT s1.razon_fiabilidad IS NULL AND s1.razones_en IS NULL AND s1.razon_impacto IS NOT NULL, 'solo cae la de fiabilidad';
  ASSERT s1.updated_at = (SELECT updated_at FROM antes), 'borrar razones no cuenta como actualizar la señal';
  l := vigilante.probabilidades_por_ajustar('prueba-raz', 10);
  ASSERT jsonb_array_length(l) = 1 AND (l #>> '{0,ya_ajustada}')::numeric = 0.90, 'vuelve con ya_ajustada: ' || l::text;
END $$;

-- 4. Rellenar confirmadas antiguas: una ajustada por AVIA sin razones entra en la ronda ------------------
UPDATE vigilante.signals SET razon_fiabilidad = NULL, razon_impacto = NULL, razones_en = NULL
 WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'R-2';
DELETE FROM vigilante.prob_reservas WHERE signal_id = (pg_temp.s('R-2')).id;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM vigilante._prob_pendientes((SELECT c FROM ids)) WHERE signal_id = (pg_temp.s('R-2')).id),
    'R-2 (ya ajustada, sin razones) está pendiente de rellenar';
END $$;

-- 5. El analizador vuelve a valorarla: cae la razón de impacto ------------------------------------------
SELECT vigilante.guardar_probabilidades('prueba-raz', '[{"codigo": "R-2", "prob": 0.3, "razon": "x", "razon_fiabilidad": "y", "razon_impacto": "z"}]');
UPDATE vigilante.signals SET salida_modelo = '{"impacto": {"nivel": "medio", "motivo": "otro"}}'
 WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'R-2';
DO $$ BEGIN
  ASSERT (pg_temp.s('R-2')).razon_impacto IS NULL AND (pg_temp.s('R-2')).razones_en IS NULL
     AND (pg_temp.s('R-2')).razon_fiabilidad = 'y', 'nuevo impacto: su razón se rehace';
END $$;

-- 6. Volver a Detectadas borra las tres ------------------------------------------------------------
SELECT pg_temp.mover('R-1', 'en_analisis');
DO $$ BEGIN
  ASSERT (pg_temp.s('R-1')).razon_impacto IS NULL AND (pg_temp.s('R-1')).razones_en IS NULL, 'sin razones fuera de Confirmadas';
END $$;

SELECT 'OK: razones de AVIA para fiabilidad, probabilidad e impacto' AS resultado;
ROLLBACK;
