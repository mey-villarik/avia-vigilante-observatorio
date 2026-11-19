-- Prueba de 32_ficha_aprobacion.sql: qué señales llevan ficha, reserva, reglas de la base y lectura.
-- Requiere 01 a 32 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-fichas»).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-fichas', 'Prueba de fichas', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{clima}', 'rss' FROM ids,
  (VALUES ('f-ofi', 'SENAMHI de prueba', 'oficial', 'https://senamhi.prueba.bo'),
          ('f-pre', 'Prensa de prueba', 'medio', 'https://prensa.prueba.bo'),
          ('f-red', 'Página de Facebook', 'no_oficial', 'https://facebook.prueba.bo')) x(cod, nom, tipo, url);

CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text, p_titulo text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-fic-' || p_k, p_titulo,
           vigilante.texto_norm(p_titulo), p_titulo || '. Texto de la noticia.', now()
      FROM ids i JOIN vigilante.sources s ON s.cliente_id = i.c AND s.codigo = p_fuente
    RETURNING id)
  INSERT INTO n SELECT p_k, id FROM r RETURNING id
$$;
-- Señal con su noticia enlazada
CREATE FUNCTION pg_temp.senal(p_cod text, p_noticia text, p_nat text, p_cat text, p_pri text, p_est text,
                              p_escenario boolean DEFAULT false) RETURNS void LANGUAGE sql AS $$
  INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado, es_escenario, raw_item_id)
  SELECT c, p_cod, 'Señal ' || p_cod, 'Resumen ' || p_cod, p_nat::vigilante.naturaleza_senal, p_cat,
         p_pri::vigilante.prioridad, p_est::vigilante.estado_senal, p_escenario, (SELECT id FROM n WHERE k = p_noticia)
    FROM ids;
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
  SELECT s.id, (SELECT id FROM n WHERE k = p_noticia) FROM vigilante.signals s
   WHERE s.cliente_id = (SELECT c FROM ids) AND s.codigo = p_cod;
$$;
-- Espera un error de la base que contenga p_texto
CREATE FUNCTION pg_temp.falla(p_cod text, p_ficha jsonb, p_texto text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM vigilante.guardar_ficha_aprobacion('prueba-fichas', p_cod, p_ficha, 'prueba');
  RAISE EXCEPTION 'Se esperaba un error con «%» y la base aceptó la ficha', p_texto;
EXCEPTION WHEN raise_exception THEN
  IF position(p_texto IN SQLERRM) = 0 THEN RAISE EXCEPTION 'Error inesperado: %', SQLERRM; END IF;
END $$;

SELECT pg_temp.noticia('lluvia', 'f-ofi', 'SENAMHI: alerta naranja por lluvias en el norte de La Paz');
SELECT pg_temp.noticia('bloqueo', 'f-pre', 'Anuncian bloqueo en la ruta a Copacabana');
SELECT pg_temp.noticia('rumor', 'f-red', 'Dicen que hay dengue en Rurrenabaque');
SELECT pg_temp.noticia('feria', 'f-pre', 'Feria gastronómica en Sucre');
SELECT pg_temp.noticia('vacuna', 'f-pre', 'Campaña de vacunación gratuita para viajeros en Santa Cruz');
SELECT pg_temp.noticia('baja', 'f-pre', 'Corte de agua en un barrio de Oruro');
SELECT pg_temp.noticia('escen', 'f-pre', 'Escenario de sequía en el Chaco');
SELECT pg_temp.noticia('publi', 'f-ofi', 'Cierre del aeropuerto de Uyuni por nieve');

--               código     noticia    naturaleza     categoría   prioridad  estado
SELECT pg_temp.senal('FIC-1', 'lluvia',  'riesgo',      'clima',     'alta',  'detectada');   -- lleva ficha
SELECT pg_temp.senal('FIC-2', 'bloqueo', 'riesgo',      'vial',      'media', 'en_analisis'); -- lleva ficha
SELECT pg_temp.senal('FIC-3', 'rumor',   'riesgo',      'salud',     'media', 'detectada');   -- lleva ficha
SELECT pg_temp.senal('FIC-4', 'feria',   'oportunidad', 'eventos',   'media', 'detectada');   -- no: oportunidad
SELECT pg_temp.senal('FIC-5', 'vacuna',  'oportunidad', 'salud',     'media', 'detectada');   -- sí: categoría con revisión obligatoria
SELECT pg_temp.senal('FIC-6', 'baja',    'riesgo',      'vial',      'baja',  'detectada');   -- no: prioridad baja
SELECT pg_temp.senal('FIC-7', 'escen',   'riesgo',      'clima',     'alta',  'detectada', true); -- no: escenario
SELECT pg_temp.senal('FIC-8', 'publi',   'riesgo',      'vial',      'alta',  'detectada');
UPDATE vigilante.signals SET estado = 'en_analisis' WHERE codigo = 'FIC-8' AND cliente_id = (SELECT c FROM ids);
UPDATE vigilante.signals SET estado = 'confirmada'  WHERE codigo = 'FIC-8' AND cliente_id = (SELECT c FROM ids);
UPDATE vigilante.signals SET estado = 'publicada'   WHERE codigo = 'FIC-8' AND cliente_id = (SELECT c FROM ids);  -- no: publicada

-- 1. Qué señales llevan ficha -----------------------------------------------------------------
DO $$
DECLARE v text[] := ARRAY(SELECT s.codigo FROM vigilante._fichas_pendientes((SELECT c FROM ids)) p
                            JOIN vigilante.signals s ON s.id = p.signal_id);
BEGIN
  ASSERT (SELECT estado FROM vigilante.signals WHERE codigo = 'FIC-8' AND cliente_id = (SELECT c FROM ids)) = 'publicada', 'FIC-8 publicada';
  ASSERT v = ARRAY['FIC-1', 'FIC-2', 'FIC-3', 'FIC-5'], 'pendientes: alta primero, luego medias por antigüedad. Salió ' || v::text;
  ASSERT vigilante.fichas_pendientes_hermes('prueba-fichas') = 4, 'cuatro pendientes';
END $$;

-- 2. Reserva: devuelve la señal, sus noticias con su techo de peso, y deja de estar pendiente -----
DO $$
DECLARE l jsonb := vigilante.fichas_por_preparar('prueba-fichas', 2);
BEGIN
  ASSERT jsonb_array_length(l) = 2, 'reserva 2';
  ASSERT l -> 0 ->> 'codigo' = 'FIC-1', 'primero la de prioridad alta';
  ASSERT (l -> 0 -> 'noticias' -> 0 ->> 'peso_max')::int = 5, 'SENAMHI pesa como máximo 5';
  ASSERT (l -> 1 -> 'noticias' -> 0 ->> 'peso_max')::int = 3, 'un medio pesa como máximo 3';
  ASSERT (l -> 0 ->> 'peso_max_disponible')::int = 5, 'peso máximo disponible';
  ASSERT vigilante.fichas_pendientes_hermes('prueba-fichas') = 2, 'las reservadas ya no cuentan';
  ASSERT jsonb_array_length(vigilante.fichas_por_preparar('prueba-fichas', 5)) = 2, 'quedan FIC-3 y FIC-5';
  ASSERT vigilante.fichas_pendientes_hermes('prueba-fichas') = 0, 'todo reservado';
END $$;

-- 3. Reglas de la base ---------------------------------------------------------------------------
CREATE TEMP TABLE base AS SELECT jsonb_build_object(
  'afirmacion', 'Anuncian un bloqueo en la ruta a Copacabana',
  'evidencia', jsonb_build_object('noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'bloqueo')), 'peso', 3,
                                  'por_que', 'Un medio, sin comunicado de la ABC'),
  'falta', jsonb_build_array('Comunicado de la ABC sobre la ruta'),
  'riesgo', jsonb_build_object('nivel', 'U3', 'motivo', 'Puede dejar varados a visitantes'),
  'sugerencia', jsonb_build_object('decision', 'esperar', 'motivo', 'Falta la confirmación oficial'),
  'texto_prudente', 'Según la prensa, se anuncia un bloqueo en la ruta a Copacabana. Pendiente de confirmación de la ABC.',
  'verificar_con', 'ABC') AS f;

SELECT pg_temp.falla('FIC-2', (SELECT f FROM base) || '{"evidencia": {"noticias": [], "peso": 3, "por_que": "x"}}', 'al menos un id');
SELECT pg_temp.falla('FIC-2', jsonb_set((SELECT f FROM base), '{evidencia,noticias}', jsonb_build_array((SELECT id FROM n WHERE k = 'lluvia'))),
                     'no son de la señal');
SELECT pg_temp.falla('FIC-2', jsonb_set((SELECT f FROM base), '{evidencia,peso}', '4'), 'mayor que el de las fuentes');
SELECT pg_temp.falla('FIC-2', jsonb_set((SELECT f FROM base), '{sugerencia}', '{"decision": "publicar", "motivo": "x"}'), 'Regla de oro');
SELECT pg_temp.falla('FIC-2', (SELECT f FROM base) - 'falta', 'di en «falta»');
SELECT pg_temp.falla('FIC-2', jsonb_set((SELECT f FROM base), '{texto_prudente}', '"La ruta ya es seguro transitarla."'), 'sin fuente oficial');
SELECT pg_temp.falla('FIC-2', jsonb_set((SELECT f FROM base), '{riesgo}', '{"nivel": "U5", "motivo": "x"}'), 'U1, U2, U3 o U4');
SELECT pg_temp.falla('FIC-2', (SELECT f FROM base) - 'afirmacion', 'Falta «afirmacion»');
SELECT pg_temp.falla('FIC-3', jsonb_set(jsonb_set(jsonb_set((SELECT f FROM base),
         '{evidencia,noticias}', jsonb_build_array((SELECT id FROM n WHERE k = 'rumor'))), '{evidencia,peso}', '2'),
         '{riesgo}', '{"nivel": "U4", "motivo": "Salud"}') || '{"sugerencia": {"decision": "publicar", "motivo": "x"}}', 'mayor que el de las fuentes');
SELECT pg_temp.falla('FIC-8', (SELECT f FROM base), 'no necesita ficha');
SELECT pg_temp.falla('FIC-3', jsonb_set(jsonb_set(jsonb_set((SELECT f FROM base),
         '{evidencia,noticias}', jsonb_build_array((SELECT id FROM n WHERE k = 'rumor'))), '{evidencia,peso}', '1'),
         '{riesgo}', '{"nivel": "U1", "motivo": "Menor"}') || '{"sugerencia": {"decision": "publicar", "motivo": "x"}}', 'Un rumor');

-- Una válida (esperar) y una de fuente oficial (publicar con U4 y peso 5)
SELECT vigilante.guardar_ficha_aprobacion('prueba-fichas', 'FIC-2', (SELECT f FROM base), 'prueba') AS guardada_2;
SELECT vigilante.guardar_ficha_aprobacion('prueba-fichas', 'FIC-1', jsonb_build_object(
  'afirmacion', 'Alerta naranja por lluvias en el norte de La Paz',
  'evidencia', jsonb_build_object('noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'lluvia')), 'peso', 5,
                                  'por_que', 'Aviso del SENAMHI'),
  'riesgo', jsonb_build_object('nivel', 'U4', 'motivo', 'Riesgo para la vida en rutas de montaña'),
  'sugerencia', jsonb_build_object('decision', 'publicar', 'motivo', 'Fuente oficial'),
  'texto_prudente', 'El SENAMHI emitió alerta naranja por lluvias en el norte de La Paz.'), 'prueba') AS guardada_1;

DO $$
DECLARE f jsonb := vigilante.ficha_senal_hermes('prueba-fichas', 'FIC-1');
BEGIN
  ASSERT f ->> 'afirmacion' = 'Alerta naranja por lluvias en el norte de La Paz', 'lectura de la ficha';
  ASSERT (f #>> '{evidencia,peso}')::int = 5 AND (f #>> '{evidencia,peso_max}')::int = 5, 'peso y techo';
  ASSERT f #>> '{noticias_citadas,0,fuente}' = 'SENAMHI de prueba', 'noticia citada con su fuente';
  ASSERT (f ->> 'desactualizada')::boolean = false, 'al día';
  ASSERT (vigilante.ficha_senal_hermes('prueba-fichas', 'FIC-4') ->> 'sin_ficha')::boolean, 'una oportunidad no lleva ficha';
  ASSERT position('Ficha de AVIA' IN vigilante.texto_ficha_tg((SELECT id FROM vigilante.signals WHERE codigo = 'FIC-2'
                                                                 AND cliente_id = (SELECT c FROM ids)))) > 0, 'texto de Telegram';
  ASSERT position('esperar' IN vigilante.texto_ficha_tg((SELECT id FROM vigilante.signals WHERE codigo = 'FIC-2'
                                                           AND cliente_id = (SELECT c FROM ids)))) > 0, 'Telegram dice la sugerencia';
  ASSERT vigilante.ficha_aprobacion('FIC-1') IS NULL, 'sin sesión de analista, el panel no ve nada';
END $$;

-- 4. Llega una noticia nueva a FIC-2: la ficha queda desactualizada y vuelve a la cola ------------
SELECT pg_temp.noticia('bloqueo-2', 'f-ofi', 'La ABC confirma el bloqueo en la ruta a Copacabana');
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT s.id, (SELECT id FROM n WHERE k = 'bloqueo-2') FROM vigilante.signals s
 WHERE s.cliente_id = (SELECT c FROM ids) AND s.codigo = 'FIC-2';
DO $$
DECLARE l jsonb;
BEGIN
  ASSERT (vigilante.ficha_senal_hermes('prueba-fichas', 'FIC-2') ->> 'desactualizada')::boolean, 'marcada como desactualizada';
  ASSERT vigilante.fichas_pendientes_hermes('prueba-fichas') = 1, 'vuelve a la cola';
  l := vigilante.fichas_por_preparar('prueba-fichas', 5);
  ASSERT l -> 0 ->> 'codigo' = 'FIC-2' AND l -> 0 -> 'ficha_anterior' ->> 'afirmacion' IS NOT NULL, 'trae la ficha anterior';
  ASSERT (l -> 0 ->> 'peso_max_disponible')::int = 5, 'ahora hay fuente oficial';
  ASSERT vigilante.ficha_senal_hermes('prueba-fichas', 'FIC-2') ->> 'afirmacion' IS NOT NULL, 'la vieja se sigue viendo mientras se rehace';
  ASSERT vigilante.fichas_pendientes_hermes('prueba-fichas') = 0, 'reservada';
END $$;
SELECT vigilante.guardar_ficha_aprobacion('prueba-fichas', 'FIC-2', jsonb_set(jsonb_set(jsonb_set((SELECT f FROM base),
  '{evidencia}', jsonb_build_object('noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'bloqueo-2')), 'peso', 5, 'por_que', 'Comunicado de la ABC')),
  '{sugerencia}', '{"decision": "publicar", "motivo": "La ABC lo confirma"}'),
  '{texto_prudente}', '"La ABC confirma un bloqueo en la ruta a Copacabana."'), 'prueba') AS rehecha_2;
DO $$ BEGIN
  ASSERT (SELECT version FROM vigilante.fichas_aprobacion f JOIN vigilante.signals s ON s.id = f.signal_id
           WHERE s.codigo = 'FIC-2' AND s.cliente_id = (SELECT c FROM ids)) = 2, 'versión 2';
  ASSERT NOT (vigilante.ficha_senal_hermes('prueba-fichas', 'FIC-2') ->> 'desactualizada')::boolean, 'al día otra vez';
END $$;

-- 5. Sin token de Telegram, avisar_fichas no falla
SELECT vigilante.avisar_fichas() AS telegram;

SELECT 'OK: prueba de fichas de aprobación superada' AS resultado;
ROLLBACK;
