-- Prueba de 31_cambios_noticias.sql: cambios en señales ya existentes («viene un ciclón» → «se desvió»).
-- Requiere 01 a 31 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-cambios»).
-- Termina en ROLLBACK: no deja nada.
--
-- Toda la prueba va en UNA transacción, y el 31 junta lo que pasa en la misma transacción (txid).
-- Para simular rondas distintas del analizador, entre paso y paso se «envejece» lo anterior (txid = 0).
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-cambios', 'Prueba de cambios', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{clima}', 'rss' FROM ids,
  (VALUES ('c-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.prueba.bo'),
          ('c-pre', 'Prensa de prueba', 'medio', 'https://prensa.prueba.bo'),
          ('c-otr', 'Otro medio de prueba', 'medio', 'https://otro.prueba.bo')) x(cod, nom, tipo, url);

-- Mete una noticia como la dejaría el recolector (estado «nuevo»)
CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text, p_titulo text, p_texto text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido,
                                     territorios_detectados, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-cam-' || p_k, p_titulo,
           vigilante.texto_norm(p_titulo), p_texto,
           ARRAY(SELECT t.id FROM vigilante.territorios t WHERE t.cliente_id = i.c AND t.codigo IN ('BO-S', 'BO-L')
                   AND vigilante.contiene(vigilante.texto_norm(p_titulo), vigilante.texto_norm(t.nombre))),
           now()
      FROM ids i JOIN vigilante.sources s ON s.cliente_id = i.c AND s.codigo = p_fuente
    RETURNING id)
  INSERT INTO n SELECT p_k, id FROM r RETURNING id
$$;
-- «Pasa el tiempo»: lo de antes ya no es de esta transacción ni de esta hora
CREATE FUNCTION pg_temp.envejecer() RETURNS void LANGUAGE sql AS $$
  UPDATE vigilante.signals SET created_at = now() - interval '3 hours' WHERE cliente_id = (SELECT c FROM ids);
  UPDATE vigilante.cambios_senal SET txid = 0 WHERE cliente_id = (SELECT c FROM ids);
$$;
CREATE FUNCTION pg_temp.cod(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT s.codigo FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
   WHERE sr.raw_item_id = (SELECT id FROM n WHERE k = p_k)
$$;
CREATE FUNCTION pg_temp.fecha(p_dias int) RETURNS text LANGUAGE sql AS $$
  SELECT to_char((now() AT TIME ZONE 'America/La_Paz')::date + p_dias, 'YYYY-MM-DD')
$$;

-- 1. Ronda 1: dos hechos nuevos (sin cambios todavía) -----------------------------------
SELECT pg_temp.noticia('ciclon-1', 'c-ofi', 'Ciclón tropical llegará a Santa Cruz el jueves',
                       'El SENAMHI alerta de que un ciclón tropical llegará a Santa Cruz con lluvias y vientos fuertes.');
SELECT pg_temp.noticia('feria-1', 'c-pre', 'Feria de turismo de La Paz será en diciembre',
                       'La feria de turismo de La Paz se celebrará en diciembre con 200 expositores.');
DO $$
DECLARE l jsonb := vigilante.lote_para_clasificar('prueba-cambios', 10);
BEGIN
  ASSERT jsonb_array_length(l) = 2, 'las dos noticias van al clasificador';
  ASSERT (SELECT bool_and(x ? 'senales_relacionadas') FROM jsonb_array_elements(l) x), 'cada noticia trae senales_relacionadas';
  ASSERT (SELECT bool_and(jsonb_array_length(x -> 'senales_relacionadas') = 0) FROM jsonb_array_elements(l) x), 'aún no hay señales';
END $$;
SELECT vigilante.guardar_clasificacion('prueba-cambios', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'ciclon-1'), 'relevante', true,
    'titulo', 'Ciclón tropical llegará a Santa Cruz el jueves', 'resumen', 'Llega el jueves con lluvias y viento.',
    'naturaleza', 'riesgo', 'categoria', 'clima', 'prioridad', 'alta', 'departamentos', '["Santa Cruz"]',
    'fecha_evento_inicio', pg_temp.fecha(2)),
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'feria-1'), 'relevante', true,
    'titulo', 'Feria de turismo de La Paz en diciembre', 'resumen', 'Feria con 200 expositores.',
    'naturaleza', 'oportunidad', 'categoria', 'eventos', 'prioridad', 'media', 'departamentos', '["La Paz"]',
    'fecha_evento_inicio', pg_temp.fecha(20))), 'prueba', 'clasificador-1.7') AS ronda_1;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids)) = 0, 'una señal nueva no es un cambio';
END $$;
SELECT pg_temp.envejecer();

-- 2. Ronda 2: «el ciclón se desvió» (otra noticia, otro título) ---------------------------
SELECT pg_temp.noticia('ciclon-2', 'c-pre', 'El ciclón tropical se desvió hacia Paraguay y no llegará a Santa Cruz',
                       'El ciclón cambió de rumbo durante la noche. El SENAMHI levanta la alerta para Santa Cruz.');
DO $$
DECLARE l jsonb := vigilante.lote_para_clasificar('prueba-cambios', 10);
BEGIN
  ASSERT jsonb_array_length(l) = 1, 'solo la noticia nueva';
  RAISE NOTICE 'relacionadas: %', l -> 0 -> 'senales_relacionadas';
  ASSERT l #>> '{0,senales_relacionadas,0,codigo}' = pg_temp.cod('ciclon-1'),
         'el clasificador recibe la señal del ciclón como relacionada';
  ASSERT l #>> '{0,senales_relacionadas,0,evento_inicio}' = pg_temp.fecha(2), 'con su fecha, para poder comparar';
  ASSERT NOT (l #> '{0,senales_relacionadas}' @> jsonb_build_array(jsonb_build_object('codigo', pg_temp.cod('feria-1')))),
         'la feria de La Paz no tiene nada que ver';
END $$;
SELECT vigilante.guardar_clasificacion('prueba-cambios', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'ciclon-2'), 'relevante', true,
    'titulo', 'El ciclón se desvió hacia Paraguay: no llegará a Santa Cruz', 'resumen', 'Cambió de rumbo; se levanta la alerta.',
    'naturaleza', 'riesgo', 'categoria', 'clima', 'prioridad', 'media', 'departamentos', '["Santa Cruz"]',
    'cambio', jsonb_build_object('senal', pg_temp.cod('ciclon-1'), 'tipo', 'desviado',
                                 'antes', 'Llegaba a Santa Cruz el jueves', 'ahora', 'Se desvió hacia Paraguay; no llegará a Santa Cruz',
                                 'importancia', 'media'))), 'prueba', 'clasificador-1.7') AS ronda_2;
SELECT codigo, tipo, antes, ahora, importancia, origen, noticias FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids);
DO $$
DECLARE v vigilante.cambios_senal;
BEGIN
  SELECT * INTO v FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids);
  ASSERT v.codigo = 'CAM-0001' AND v.tipo = 'desviado' AND v.origen = 'clasificador', 'cambio registrado desde el clasificador';
  ASSERT v.signal_id = (SELECT id FROM vigilante.signals WHERE codigo = pg_temp.cod('ciclon-1') AND cliente_id = (SELECT c FROM ids)),
         'el cambio es de la señal del ciclón';
  ASSERT v.importancia = 'alta', 'un desvío en una señal de prioridad alta es importante aunque el modelo diga media';
  ASSERT (SELECT id FROM n WHERE k = 'ciclon-2') = ANY (v.noticias), 'con la noticia que lo trae';
  ASSERT v.estado = 'por_interpretar', 'queda para Hermes';
  ASSERT vigilante.cambios_pendientes_hermes('prueba-cambios') = 1, 'Hermes tiene uno pendiente';
END $$;
SELECT pg_temp.envejecer();

-- 3. Otro medio cuenta lo mismo: se suma al CAM-0001, no hay alerta nueva -------------------
SELECT pg_temp.noticia('ciclon-3', 'c-otr', 'Se desvía el ciclón: Santa Cruz se libra',
                       'El ciclón tomó rumbo a Paraguay.');
SELECT vigilante.lote_para_clasificar('prueba-cambios', 10) IS NOT NULL AS lote_3;
SELECT vigilante.guardar_clasificacion('prueba-cambios', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'ciclon-3'), 'relevante', true,
    'titulo', 'Se desvía el ciclón: Santa Cruz se libra', 'resumen', 'Rumbo a Paraguay.',
    'naturaleza', 'riesgo', 'categoria', 'clima', 'prioridad', 'media', 'departamentos', '["Santa Cruz"]',
    'cambio', jsonb_build_object('senal', pg_temp.cod('ciclon-1'), 'tipo', 'desviado', 'ahora', 'Rumbo a Paraguay'))),
  'prueba', 'clasificador-1.7') AS ronda_3;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids)) = 1, 'no se repite el aviso';
  ASSERT (SELECT repeticiones FROM vigilante.cambios_senal WHERE codigo = 'CAM-0001' AND cliente_id = (SELECT c FROM ids)) = 1,
         'cuenta que otro medio lo repitió';
END $$;
SELECT pg_temp.envejecer();

-- 4. La feria cambia de fecha (el clasificador no dice «cambio»: lo ve la base) --------------
SELECT pg_temp.noticia('feria-2', 'c-otr', 'Feria de turismo de La Paz será en diciembre',
                       'La feria de turismo de La Paz se aplaza una semana.');
SELECT vigilante.lote_para_clasificar('prueba-cambios', 10) IS NOT NULL AS lote_4;
SELECT vigilante.guardar_clasificacion('prueba-cambios', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'feria-2'), 'relevante', true,
    'titulo', 'Feria de turismo de La Paz se aplaza una semana', 'resumen', 'Se aplaza una semana.',
    'naturaleza', 'oportunidad', 'categoria', 'eventos', 'prioridad', 'media', 'departamentos', '["La Paz"]',
    'fecha_evento_inicio', pg_temp.fecha(27))), 'prueba', 'clasificador-1.7') AS ronda_4;
SELECT codigo, tipo, antes, ahora, campos, origen, noticias FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids) ORDER BY id;
DO $$
DECLARE v vigilante.cambios_senal;
BEGIN
  SELECT * INTO v FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids) AND codigo = 'CAM-0002';
  ASSERT v.tipo = 'fecha' AND v.origen = 'datos', 'la base detecta el cambio de fecha';
  ASSERT v.campos #>> '{fecha_evento_inicio,antes}' = pg_temp.fecha(20) AND v.campos #>> '{fecha_evento_inicio,ahora}' = pg_temp.fecha(27),
         'con la fecha de antes y la de ahora';
  ASSERT (SELECT id FROM n WHERE k = 'feria-2') = ANY (v.noticias), 'y la noticia que lo trajo';
END $$;
SELECT pg_temp.envejecer();

-- 5. Lo que NO es un cambio --------------------------------------------------------------
DO $$
DECLARE v_n int := (SELECT count(*) FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids));
        v_sig bigint := (SELECT id FROM vigilante.signals WHERE codigo = pg_temp.cod('feria-1') AND cliente_id = (SELECT c FROM ids));
BEGIN
  -- una persona cambia la fecha en el panel: ya lo sabe
  PERFORM set_config('vigilante.actor', '00000000-0000-0000-0000-0000000000c1', true);
  UPDATE vigilante.signals SET fecha_evento_inicio = fecha_evento_inicio + interval '1 day' WHERE id = v_sig;
  -- el clasificador rellena un dato que faltaba (fin) y cambia la prioridad de media a baja
  PERFORM set_config('vigilante.actor', 'clasificador:prueba', true);
  UPDATE vigilante.signals SET fecha_evento_fin = now() + interval '30 days', prioridad = 'baja' WHERE id = v_sig;
  PERFORM set_config('vigilante.actor', '', true);
  ASSERT (SELECT count(*) FROM vigilante.cambios_senal WHERE cliente_id = (SELECT c FROM ids)) = v_n,
         'ni lo que mueve una persona, ni rellenar un dato, ni media → baja';
END $$;

-- 6. Hermes interpreta -------------------------------------------------------------------
DO $$
DECLARE l jsonb := vigilante.cambios_por_interpretar('prueba-cambios', 5); v_err text;
BEGIN
  ASSERT jsonb_array_length(l) = 2, 'dos cambios para Hermes';
  ASSERT l #>> '{0,codigo}' = 'CAM-0001', 'primero el más importante';
  ASSERT jsonb_array_length(l #> '{0,noticias_anteriores}') >= 1, 'Hermes ve lo que decían antes las noticias';
  ASSERT vigilante.cambios_pendientes_hermes('prueba-cambios') = 0, 'quedan reservados';
  BEGIN
    PERFORM vigilante.guardar_interpretacion_cambio('prueba-cambios', 'CAM-0001', '{"titular": "x"}');
    RAISE EXCEPTION 'debió fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    ASSERT v_err LIKE 'Falta%', 'pide lo que falta: ' || v_err;
  END;
  PERFORM vigilante.guardar_interpretacion_cambio('prueba-cambios', 'CAM-0001', jsonb_build_object(
    'titular', 'Santa Cruz: el ciclón se desvió y ya no llega',
    'que_cambio', 'Antes: llegaba el jueves. Ahora: se desvió hacia Paraguay.',
    'significado', 'Las salidas suspendidas por el ciclón podrían retomarse.',
    'a_quien_afecta', jsonb_build_array('operadores de Santa Cruz'),
    'recomendacion', jsonb_build_object('accion', 'Confirmar con el SENAMHI que la alerta se levantó', 'para_quien', 'operadores', 'cuando', 'hoy')),
    'deepseek-chat');
  PERFORM vigilante.guardar_interpretacion_cambio('prueba-cambios', 'CAM-0002', '{"es_cambio": false, "motivo_descarte": "fecha mal leída"}');
  ASSERT (SELECT estado FROM vigilante.cambios_senal WHERE codigo = 'CAM-0001' AND cliente_id = (SELECT c FROM ids)) = 'interpretado', 'interpretado';
  ASSERT (SELECT estado FROM vigilante.cambios_senal WHERE codigo = 'CAM-0002' AND cliente_id = (SELECT c FROM ids)) = 'descartado', 'descartado';
END $$;

-- 7. Hermes registra un cambio que encontró investigando ------------------------------------
DO $$
DECLARE r jsonb; v_err text;
BEGIN
  BEGIN
    PERFORM vigilante.registrar_cambio('prueba-cambios', jsonb_build_object('senal', pg_temp.cod('feria-1'), 'tipo', 'cancelado', 'ahora', 'Se cancela'));
    RAISE EXCEPTION 'debió fallar';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    ASSERT v_err LIKE '%noticia%', 'sin noticias no hay cambio: ' || v_err;
  END;
  r := vigilante.registrar_cambio('prueba-cambios', jsonb_build_object('senal', pg_temp.cod('feria-1'), 'tipo', 'cancelado',
         'antes', 'Feria en diciembre', 'ahora', 'La alcaldía cancela la feria', 'noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'feria-2'))));
  ASSERT r ->> 'codigo' = 'CAM-0003', 'registrado: ' || r::text;
  PERFORM set_config('vigilante.actor', '', true);
END $$;

-- 8. El panel: alerta, visto y descarte -----------------------------------------------------
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, email, rol)
SELECT c, '00000000-0000-0000-0000-0000000000c1', 'Analista de prueba', 'analista@prueba.bo', 'analista' FROM ids;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', true);
SELECT x ->> 'codigo' AS codigo, x ->> 'tipo' AS tipo, x ->> 'alerta' AS alerta, x ->> 'visto' AS visto, x ->> 'titular' AS titular
  FROM jsonb_array_elements(vigilante.cambios_recientes()) x;
DO $$
DECLARE l jsonb := vigilante.cambios_recientes();
BEGIN
  ASSERT jsonb_array_length(l) = 2, 'el panel ve CAM-0001 y CAM-0003 (el descartado no)';
  ASSERT (SELECT bool_and((x ->> 'alerta')::boolean AND NOT (x ->> 'visto')::boolean) FROM jsonb_array_elements(l) x),
         'los dos salen como alerta sin ver (no esperan a Hermes)';
  ASSERT (SELECT x #>> '{senal,codigo}' FROM jsonb_array_elements(l) x WHERE x ->> 'codigo' = 'CAM-0001') = pg_temp.cod('ciclon-1'),
         'con la señal que cambió';
  PERFORM vigilante.marcar_cambio_visto('CAM-0001');
  ASSERT (SELECT (x ->> 'visto')::boolean FROM jsonb_array_elements(vigilante.cambios_recientes()) x WHERE x ->> 'codigo' = 'CAM-0001'),
         '«Entendido» lo marca visto';
  PERFORM vigilante.descartar_cambio('CAM-0003', 'Es otra feria');
  ASSERT jsonb_array_length(vigilante.cambios_recientes()) = 1, 'descartado por el analista: desaparece';
  PERFORM vigilante.marcar_cambio_visto(NULL);
END $$;
-- un visor no ve nada
UPDATE vigilante.users SET rol = 'visor' WHERE auth_user_id = '00000000-0000-0000-0000-0000000000c1';
DO $$ BEGIN
  ASSERT vigilante.cambios_recientes() = '[]'::jsonb, 'un visor no recibe cambios';
END $$;

\echo 'Prueba de cambios: todo bien'
ROLLBACK;
