-- Prueba de 33_probabilidad_senales.sql: cálculo base al confirmar, recálculo con noticias nuevas,
-- reserva para AVIA, ajuste acotado y borrado al volver atrás.
-- Requiere 01 a 33 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-prob»).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-prob', 'Prueba de probabilidad', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{clima}', 'rss' FROM ids,
  (VALUES ('f-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.prob.bo'),
          ('f-pre', 'Prensa de prueba', 'medio', 'https://prensa.prob.bo'),
          ('f-red', 'Página de Facebook', 'no_oficial', 'https://facebook.prob.bo')) x(cod, nom, tipo, url);

CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-prob-' || p_k, 'Noticia ' || p_k,
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

-- Historial de la categoría clima: 3 confirmadas (una publicada) y 1 descartada → tasa 0,75
SELECT pg_temp.noticia('h' || i, 'f-pre') FROM generate_series(1, 4) i;
SELECT pg_temp.senal('H-' || i, ARRAY['h' || i]) FROM generate_series(1, 4) i;
SELECT pg_temp.mover('H-1', 'en_analisis', 'confirmada');
SELECT pg_temp.mover('H-2', 'en_analisis', 'confirmada', 'publicada');
SELECT pg_temp.mover('H-3', 'en_analisis', 'confirmada');
SELECT pg_temp.mover('H-4', 'descartada');

SELECT pg_temp.noticia(k, f) FROM (VALUES ('ofi1', 'f-ofi'), ('pre1', 'f-pre'), ('red2', 'f-red'), ('pre2', 'f-pre'),
                                          ('pre3', 'f-pre')) x(k, f);
--  Q-1 oficial + prensa, detectada → se confirma a mano   → 5/5·0,5 + 2/4·0,3 + 0,75·0,2 = 0,80
--  Q-2 prensa, se queda en detectada                      → sin probabilidad
--  Q-4 solo Facebook, se confirma después                → 1/5·0,5 + 1/4·0,3 + (4/5)·0,2 = 0,335 → 0,34
--      (Q-1 ya cuenta en el historial: 4 confirmadas y 1 descartada)
SELECT pg_temp.senal('Q-1', ARRAY['ofi1', 'pre1']);
SELECT pg_temp.senal('Q-2', ARRAY['pre3']);
SELECT pg_temp.senal('Q-4', ARRAY['red2']);
SELECT pg_temp.mover('Q-1', 'en_analisis', 'confirmada');
SELECT pg_temp.mover('Q-4', 'en_analisis', 'confirmada');

-- 1. Cálculo base al confirmar ------------------------------------------------------------------
DO $$
DECLARE q1 vigilante.signals := pg_temp.s('Q-1'); q2 vigilante.signals := pg_temp.s('Q-2'); q4 vigilante.signals := pg_temp.s('Q-4');
BEGIN
  ASSERT q1.prob_ocurrencia = 0.80 AND q1.prob_base = 0.80 AND q1.prob_origen = 'base',
    'Q-1 base 0,80, salió ' || q1.prob_ocurrencia || ' ' || coalesce(q1.prob_razon, '');
  ASSERT q1.prob_razon LIKE 'Cálculo base: fuente oficial (SENAMHI de prueba), 2 fuentes distintas y 75 % de las señales de clima%',
    'razón de Q-1: ' || q1.prob_razon;
  ASSERT (q1.prob_factores ->> 'peso')::int = 5 AND (q1.prob_factores ->> 'fuentes')::int = 2 AND (q1.prob_factores ->> 'tasa')::numeric = 0.75,
    'factores de Q-1: ' || q1.prob_factores::text;
  ASSERT q2.prob_ocurrencia IS NULL, 'Q-2 no está confirmada: sin probabilidad';
  ASSERT q4.prob_ocurrencia = 0.34, 'Q-4 base 0,34, salió ' || q4.prob_ocurrencia;
  ASSERT (vigilante.puntuaciones(q1.id) #>> '{probabilidad,origen}') = 'base', 'puntuaciones lleva la probabilidad del 33';
  ASSERT (vigilante.puntuaciones(q2.id) #>> '{probabilidad,nivel}') = 'sin datos', 'Q-2 sigue «sin datos»';
END $$;

-- 2. Una noticia nueva en una confirmada sin ajustar recalcula la base, sin tocar updated_at --------
CREATE TEMP TABLE antes AS SELECT updated_at FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'Q-4';
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id) SELECT (pg_temp.s('Q-4')).id, id FROM n WHERE k = 'pre2';
DO $$
DECLARE q4 vigilante.signals := pg_temp.s('Q-4');
BEGIN
  -- 3/5·0,5 + 2/4·0,3 + 0,16 = 0,61
  ASSERT q4.prob_ocurrencia = 0.61, 'Q-4 con prensa: 0,61, salió ' || q4.prob_ocurrencia;
  ASSERT q4.updated_at = (SELECT updated_at FROM antes), 'recalcular la probabilidad no cuenta como actualizar la señal';
END $$;

-- 3. Una oficial que entra sola en Confirmadas (29) también la lleva --------------------------------
SELECT pg_temp.noticia('ofi3', 'f-ofi');
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, source_id, raw_item_id, enlace_oficial)
SELECT c, 'Q-3', 'Señal Q-3', 'Resumen Q-3', 'riesgo', 'clima', (SELECT id FROM vigilante.sources WHERE cliente_id = c AND codigo = 'f-ofi'),
       (SELECT id FROM n WHERE k = 'ofi3'), 'https://senamhi.prob.bo/ofi3' FROM ids;
DO $$
DECLARE q3 vigilante.signals := pg_temp.s('Q-3');
BEGIN
  IF q3.estado = 'confirmada' THEN
    -- 5/5·0,5 + 1/4·0,3 + (5/6)·0,2 = 0,741 → 0,74
    ASSERT q3.prob_ocurrencia = 0.74, 'Q-3 oficial directa: 0,74, salió ' || coalesce(q3.prob_ocurrencia::text, 'nada');
  ELSE
    ASSERT q3.prob_ocurrencia IS NULL, 'Q-3 no confirmada no lleva probabilidad';
  END IF;
END $$;

-- 4. Para AVIA: pendientes, entrada mínima y reserva ------------------------------------------------
DO $$
DECLARE v_n int := vigilante.probabilidades_pendientes_hermes('prueba-prob'); l jsonb; e jsonb;
BEGIN
  -- Q-1, Q-4, Q-3 (si entró confirmada) y las H confirmadas o publicadas (H-1, H-2, H-3)
  ASSERT v_n >= 5, 'pendientes: ' || v_n;
  l := vigilante.probabilidades_por_ajustar('prueba-prob', 10);
  ASSERT jsonb_array_length(l) = v_n, 'devuelve todas';
  SELECT x INTO e FROM jsonb_array_elements(l) x WHERE x ->> 'codigo' = 'Q-1';
  ASSERT (e ->> 'base')::numeric = 0.80 AND e #>> '{factores,peso_fuente}' = '5', 'entrada de Q-1: ' || e::text;
  ASSERT jsonb_array_length(e -> 'contexto') = 3, 'tres líneas de contexto';
  ASSERT e #>> '{contexto,1}' = 'Zona: La Paz', 'zona: ' || (e #>> '{contexto,1}');
  ASSERT e #>> '{contexto,2}' LIKE 'Historial 90 días en clima: confirmadas 3, descartadas 1; en esta zona 6 señales, 4 confirmadas', 'historial: ' || (e #>> '{contexto,2}');
  ASSERT length(e::text) < 900, 'la entrada debe ser corta (ahorro de tokens): ' || length(e::text);
  ASSERT vigilante.probabilidades_pendientes_hermes('prueba-prob') = 0, 'reservadas: ya no salen como pendientes';
END $$;

-- 5. Guardar en lote: acotado a ±0,20 de la base y a 5-95 %; errores sin romper el lote ---------------
DO $$
DECLARE r jsonb := vigilante.guardar_probabilidades('prueba-prob', '[
  {"codigo": "Q-1", "prob": 0.99, "razon": "Aviso oficial con fecha y zonas; en noviembre llueve casi a diario en Los Yungas."},
  {"codigo": "Q-4", "prob": 0.1,  "razon": "Solo prensa y redes."},
  {"codigo": "Q-2", "prob": 0.5,  "razon": "No está confirmada."},
  {"codigo": "H-1", "prob": "mucho", "razon": "x"},
  {"codigo": "H-3", "prob": 0.6,  "razon": ""}]'::jsonb, 'deepseek-prueba');
BEGIN
  ASSERT jsonb_array_length(r -> 'guardadas') = 2 AND jsonb_array_length(r -> 'errores') = 3, 'resultado: ' || r::text;
  ASSERT (pg_temp.s('Q-1')).prob_ocurrencia = 0.95 AND (pg_temp.s('Q-1')).prob_origen = 'avia', 'Q-1 tope 95 %';
  ASSERT (pg_temp.s('Q-4')).prob_ocurrencia = 0.41, 'Q-4 no baja más de 0,20 de su base (0,61)';
  ASSERT (pg_temp.s('Q-1')).prob_razon LIKE 'Aviso oficial%', 'razón de AVIA guardada';
  ASSERT (vigilante.puntuaciones((pg_temp.s('Q-1')).id) #>> '{probabilidad,origen}') = 'avia', 'puntuaciones: origen avia';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.prob_reservas WHERE signal_id = (pg_temp.s('Q-1')).id), 'reserva liberada';
  -- una ajustada por AVIA no se recalcula con noticias nuevas
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id) SELECT (pg_temp.s('Q-4')).id, id FROM n WHERE k = 'pre3';
  ASSERT (pg_temp.s('Q-4')).prob_ocurrencia = 0.41, 'el ajuste de AVIA se respeta';
END $$;

-- 6. Publicar y retirar la conserva; volver a Detectadas la borra; reconfirmar recalcula -------------
SELECT pg_temp.mover('Q-1', 'publicada', 'confirmada');
DO $$ BEGIN
  ASSERT (pg_temp.s('Q-1')).prob_ocurrencia = 0.95 AND (pg_temp.s('Q-1')).prob_origen = 'avia', 'publicar y retirar la conserva';
END $$;
SELECT pg_temp.mover('Q-1', 'en_analisis');
DO $$ BEGIN
  ASSERT (pg_temp.s('Q-1')).prob_ocurrencia IS NULL AND (pg_temp.s('Q-1')).prob_razon IS NULL, 'de vuelta en Detectadas: sin probabilidad';
END $$;
SELECT pg_temp.mover('Q-1', 'confirmada');
DO $$ BEGIN
  ASSERT (pg_temp.s('Q-1')).prob_origen = 'base' AND (pg_temp.s('Q-1')).prob_ocurrencia IS NOT NULL, 'reconfirmada: base de nuevo';
END $$;

-- 7. vigilante.json / vigilante_bd() la llevan en «puntuaciones» --------------------------------------
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM ids, jsonb_array_elements(vigilante._vigilante_json(c) -> 'senales') e
                  WHERE e ->> 'id' = 'Q-4' AND (e #>> '{puntuaciones,probabilidad,valor}')::numeric = 0.41), 'vigilante.json lleva la probabilidad';
END $$;

SELECT 'OK: probabilidad de ocurrencia en señales confirmadas' AS resultado;
ROLLBACK;
