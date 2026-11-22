-- Prueba de 37_fuentes_internacionales.sql: noticias de fuera que afectan a Bolivia.
-- Requiere 01 a 37 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-intl»).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-intl', 'Prueba internacional', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo, internacional)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{salud}', 'rss', x.intl FROM ids,
  (VALUES ('i-nac', 'Ministerio de Salud de prueba', 'oficial', 'https://salud.prueba.bo', false),
          ('i-ops', 'OPS de prueba', 'organismo_internacional', 'https://ops.prueba.org', true),
          ('i-bbc', 'Prensa internacional de prueba', 'medio', 'https://bbc.prueba.com', true)) x(cod, nom, tipo, url, intl);

CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text, p_titulo text, p_texto text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-intl-' || p_k, p_titulo,
           vigilante.texto_norm(p_titulo), p_texto, now()
      FROM ids i JOIN vigilante.sources s ON s.cliente_id = i.c AND s.codigo = p_fuente
    RETURNING id)
  INSERT INTO n SELECT p_k, id FROM r RETURNING id
$$;
CREATE FUNCTION pg_temp.senal(p_k text) RETURNS vigilante.signals LANGUAGE sql AS $$
  SELECT s.* FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
   WHERE sr.raw_item_id = (SELECT id FROM n WHERE k = p_k)
$$;

-- 1. Una señal nacional: dengue en Santa Cruz -------------------------------------------------
SELECT pg_temp.noticia('dengue-nac', 'i-nac', 'Brote de dengue en Santa Cruz: el Ministerio de Salud declara alerta',
                       'El Ministerio de Salud declara alerta por dengue en Santa Cruz.');
DO $$
DECLARE l jsonb := vigilante.lote_para_clasificar('prueba-intl', 10);
BEGIN
  ASSERT jsonb_array_length(l) = 1, 'la noticia nacional va al clasificador';
  ASSERT NOT (l -> 0 ? 'internacional'), 'una noticia nacional no lleva la marca internacional';
END $$;
SELECT vigilante.guardar_clasificacion('prueba-intl', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'dengue-nac'), 'relevante', true,
    'titulo', 'Santa Cruz: alerta por brote de dengue', 'resumen', 'El Ministerio de Salud declara alerta por dengue.',
    'naturaleza', 'riesgo', 'categoria', 'salud', 'prioridad', 'alta', 'departamentos', '["Santa Cruz"]')),
  'prueba', 'clasificador-1.8') AS nacional;

-- 2. La OPS alerta de dengue en la región: refuerza la señal nacional -----------------------------
SELECT pg_temp.noticia('dengue-ops', 'i-ops', 'OPS emite alerta epidemiológica por dengue en América del Sur',
                       'La OPS alerta del aumento de casos de dengue en Brasil, Paraguay y Bolivia y recomienda medidas a viajeros.');
DO $$
DECLARE l jsonb := vigilante.lote_para_clasificar('prueba-intl', 10);
BEGIN
  RAISE NOTICE 'lote internacional: %', l;
  ASSERT jsonb_array_length(l) = 1, 'solo la noticia de la OPS';
  ASSERT (l -> 0 ->> 'internacional')::boolean, 'lleva la marca internacional';
  ASSERT l #> '{0,senales_nacionales}' @> jsonb_build_array(jsonb_build_object('codigo', (pg_temp.senal('dengue-nac')).codigo)),
         'el clasificador recibe la señal nacional del dengue para decir si la refuerza';
END $$;
SELECT vigilante.guardar_clasificacion('prueba-intl', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'dengue-ops'), 'relevante', true,
    'titulo', 'OPS: alerta por dengue en América del Sur, con casos en Bolivia', 'resumen', 'Aumento de casos en Brasil, Paraguay y Bolivia.',
    -- sin departamentos: la alerta es regional; si nombrara Santa Cruz, el 43 la uniría a la señal nacional (mismo hecho)
    'naturaleza', 'riesgo', 'categoria', 'salud', 'prioridad', 'alta',
    'impacto_bolivia', jsonb_build_object('hay_impacto', true, 'ambitos', '["salud","turismo"]',
                                          'via', 'Brote regional con casos en Bolivia; afecta a viajeros que llegan desde Brasil y Paraguay',
                                          'nivel', 'alto', 'plazo', 'inmediato',
                                          'refuerza', jsonb_build_array((pg_temp.senal('dengue-nac')).codigo, 'NO-EXISTE')))),
  'prueba', 'clasificador-1.8') AS ops;
DO $$
DECLARE s vigilante.signals := pg_temp.senal('dengue-ops'); nac vigilante.signals := pg_temp.senal('dengue-nac'); j jsonb;
BEGIN
  ASSERT s.impacto_bolivia ->> 'nivel' = 'alto' AND s.impacto_bolivia ->> 'plazo' = 'inmediato', 'guarda el impacto en Bolivia';
  j := vigilante._internacional_json((SELECT c FROM ids));
  RAISE NOTICE 'panel: %', j;
  ASSERT jsonb_array_length(j -> 'fuentes') = 2, 'el panel ve las dos fuentes internacionales';
  ASSERT j -> 'senales' @> jsonb_build_array(jsonb_build_object('codigo', s.codigo)), 'el panel ve la señal con impacto en Bolivia';
  IF s.id = nac.id THEN
    -- con el 43, la base puede ver que es el MISMO hecho que la señal nacional y sumar la noticia como otra fuente
    ASSERT NOT s.internacional, 'unida a la nacional: sigue siendo nacional, con el impacto que vio la OPS';
    RAISE NOTICE 'La alerta de la OPS se unió a la señal nacional % (mismo hecho, 43)', s.codigo;
  ELSE
    ASSERT s.internacional, 'la señal de la OPS es internacional';
    ASSERT s.refuerza = ARRAY[nac.id], 'refuerza solo la señal nacional que existe';
    ASSERT NOT nac.internacional, 'la nacional sigue siendo nacional';
    ASSERT j -> 'contexto' -> nac.codigo -> 0 ->> 'codigo' = s.codigo, 'la señal nacional recibe el contexto internacional';
  END IF;
END $$;

-- 2b. Una alerta regional de otro tema que da contexto a la nacional (no es el mismo hecho) ------------
SELECT pg_temp.noticia('viajeros-ops', 'i-ops', 'OPS recomienda a los viajeros protegerse de picaduras de mosquitos en la región',
                       'Ante el aumento de enfermedades transmitidas por mosquitos (dengue, chikungunya), la OPS recomienda repelente a los viajeros.');
SELECT vigilante.lote_para_clasificar('prueba-intl', 10) IS NOT NULL AS lote_viajeros;
SELECT vigilante.guardar_clasificacion('prueba-intl', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'viajeros-ops'), 'relevante', true,
    'titulo', 'OPS: recomendaciones a viajeros por enfermedades transmitidas por mosquitos', 'resumen', 'Repelente y ropa larga.',
    'naturaleza', 'riesgo', 'categoria', 'salud', 'prioridad', 'media',
    'impacto_bolivia', jsonb_build_object('hay_impacto', true, 'ambitos', '["salud","turismo"]',
                                          'via', 'Viajeros hacia las tierras bajas de Bolivia', 'nivel', 'medio', 'plazo', 'semanas',
                                          'refuerza', jsonb_build_array((pg_temp.senal('dengue-nac')).codigo, 'NO-EXISTE')))),
  'prueba', 'clasificador-1.10') AS viajeros;
DO $$
DECLARE s vigilante.signals := pg_temp.senal('viajeros-ops'); nac vigilante.signals := pg_temp.senal('dengue-nac'); j jsonb;
BEGIN
  IF s.id = nac.id THEN
    RAISE NOTICE 'También se unió a la nacional: no se puede probar «refuerza» con este texto';
  ELSE
    ASSERT s.internacional, 'la recomendación de la OPS es internacional';
    ASSERT s.refuerza = ARRAY[nac.id], 'refuerza solo la señal nacional que existe (el código inventado no)';
    j := vigilante._internacional_json((SELECT c FROM ids));
    ASSERT j -> 'contexto' -> nac.codigo @> jsonb_build_array(jsonb_build_object('codigo', s.codigo)),
           'la señal nacional recibe el contexto internacional';
  END IF;
END $$;

-- 3. Un medio boliviano cuenta lo mismo que la BBC: la señal deja de ser solo internacional ----------
SELECT pg_temp.noticia('lluvias-bbc', 'i-bbc', 'Lluvias torrenciales en los Andes afectan a Perú y Bolivia',
                       'Las lluvias en la región andina cortan carreteras en Perú y Bolivia.');
SELECT vigilante.lote_para_clasificar('prueba-intl', 10) IS NOT NULL AS lote_bbc;
SELECT vigilante.guardar_clasificacion('prueba-intl', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'lluvias-bbc'), 'relevante', true,
    'titulo', 'Lluvias en los Andes cortan carreteras en Perú y Bolivia', 'resumen', 'Cortes de carreteras por lluvias.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'media',
    'impacto_bolivia', jsonb_build_object('hay_impacto', true, 'ambitos', '["clima","infraestructura"]',
                                          'via', 'Cortes de ruta en el lado boliviano', 'nivel', 'medio', 'plazo', 'inmediato'))),
  'prueba', 'clasificador-1.8') AS bbc;
DO $$ BEGIN
  ASSERT (pg_temp.senal('lluvias-bbc')).internacional, 'de momento solo la cuenta la BBC';
END $$;
-- la misma noticia en un medio nacional (mismo título): se une a la misma señal
SELECT pg_temp.noticia('lluvias-nac', 'i-nac', 'Lluvias torrenciales en los Andes afectan a Perú y Bolivia',
                       'Cortes de carreteras en La Paz por las lluvias.');
SELECT vigilante.lote_para_clasificar('prueba-intl', 10) IS NOT NULL AS lote_nac;
SELECT vigilante.guardar_clasificacion('prueba-intl', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'lluvias-nac'), 'relevante', true,
    'titulo', 'Lluvias cortan carreteras en La Paz', 'resumen', 'Cortes en La Paz.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'media', 'departamentos', '["La Paz"]')),
  'prueba', 'clasificador-1.8') AS nac;
DO $$ BEGIN
  ASSERT (pg_temp.senal('lluvias-nac')).id = (pg_temp.senal('lluvias-bbc')).id, 'es la misma señal';
  ASSERT NOT (pg_temp.senal('lluvias-nac')).internacional, 'con una noticia nacional, la señal es nacional';
  ASSERT (pg_temp.senal('lluvias-nac')).impacto_bolivia IS NOT NULL, 'pero conserva el impacto que vio la BBC';
END $$;

\echo 'Prueba 37 (fuentes internacionales): todo correcto'
ROLLBACK;
