-- =============================================================================
-- AVIA Vigilante · 51 · Fuentes de movilidad: ABC (carreteras), DGAC y NAABOL (aeropuertos)
-- =============================================================================
-- Requiere: 14, 15 y 20 (recolector con opciones por fuente) y el recolector 1.3.0 en el VPS
-- (extractor «tarjetas» para NAABOL). Se puede ejecutar varias veces.
--
-- Diagnóstico (2026-11-22, desde un navegador normal, no desde el VPS):
--   · ABC  transitabilidad.abc.gob.bo (mapa de transitabilidad): TODO el sitio pide ahora un CAPTCHA
--          («Verifica que eres humano») y /movil_conflictos_sociales da 404. No se puede leer de forma
--          automática ni se intenta saltar el CAPTCHA. Por eso la fuente quedaba en CRÍTICO.
--          El portal www.abc.gob.bo (WordPress) sí responde y publica los cortes y reaperturas como
--          «Comunicados» (p. ej. «Circulación vehicular sin restricción en Santa Cruz, Tramo La
--          Angostura – Bermejo»). Tiene RSS propio: /feed/?post_type=comunicados.
--          Ojo: /feed/ (el general) sale VACÍO, porque las notas no son «entradas» de WordPress.
--   · DGAC www.dgac.gob.bo responde y tiene RSS (/feed/). Publica sobre todo noticias institucionales
--          y normativa; los cierres de aeropuerto los publica NAABOL.
--   · NAABOL www.naabol.gob.bo (Drupal, sin RSS): /pagina-de-comunicados lista los comunicados de
--          operaciones (suspensión y reanudación de vuelos, cierres por clima o por obras de pista)
--          con fecha, título y PDF. Se lee con el extractor «tarjetas» del recolector 1.3.0.
--
-- Qué hace (cliente orbita-bolivia):
--   1. abc_comunicados  RSS de comunicados de la ABC (vial, cada 30 min). Si ya había una fuente de
--                       la ABC (el mapa de transitabilidad o el portal), se reutiliza esa fila: conserva
--                       su historial y deja de apuntar al mapa con CAPTCHA.
--   2. dgac             RSS de la DGAC (conectividad, cada 3 h).
--   3. naabol_comunicados  comunicados de NAABOL (conectividad, cada 60 min).
--   Cada una con espera de 30 s, 1 reintento y respaldo de Google News: si la web no responde desde
--   el VPS, se leen las noticias de prensa sobre esa institución y la fuente queda en AVISO, no en
--   CRÍTICO (las noticias de respaldo llevan extra.no_oficial = true y pasan por revisión).
--   Todas quedan gestionada_web = true (la sincronización con vigilante.json no las pisa) y con
--   proxima_revision_en = now() para que el recolector las lea en la siguiente ronda.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante.fuentes_para_recolector(text)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 14 (recolector). Ejecuta 14, 15 y 20 antes que este archivo';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION vigilante._alta_fuente_movilidad(p_cliente uuid, p_codigo text, p_patrones text[], p_nombre text,
                                                            p_institucion text, p_url text, p_metodo text, p_categorias text[],
                                                            p_frecuencia int, p_config jsonb, p_notas text)
RETURNS text LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
DECLARE v_id int; v_codigo text; v_url text;
BEGIN
  -- ¿ya existe? primero por código, luego por dirección (puede haber entrado con otro código o desde la web)
  SELECT id, codigo, url INTO v_id, v_codigo, v_url FROM vigilante.sources
   WHERE cliente_id = p_cliente AND eliminada_en IS NULL AND (codigo = p_codigo OR url ILIKE ANY (p_patrones))
   ORDER BY (codigo = p_codigo) DESC, activa DESC, id LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, institucion, url, tipo, metodo, categorias,
                                   frecuencia_minutos, rapida, activa, config, notas, gestionada_web)
    VALUES (p_cliente, p_codigo, p_nombre, p_institucion, p_url, 'oficial', p_metodo::vigilante.metodo_fuente,
            p_categorias, p_frecuencia, true, true, p_config, p_notas, true);
    RETURN p_codigo || ': añadida';
  END IF;
  UPDATE vigilante.sources SET
      nombre = p_nombre, institucion = p_institucion, url = p_url, tipo = 'oficial',
      metodo = p_metodo::vigilante.metodo_fuente, categorias = p_categorias, frecuencia_minutos = p_frecuencia,
      config = (config - 'apify_actor' - 'apify_input' - 'extractor' - 'tabla_filtro')
               || CASE WHEN v_url IS DISTINCT FROM p_url THEN jsonb_build_object('url_anterior', v_url) ELSE '{}' END
               || p_config,
      notas = CASE WHEN position(p_notas IN coalesce(notas, '')) > 0 THEN notas ELSE concat_ws(' · ', nullif(notas, ''), p_notas) END,
      activa = true, gestionada_web = true, errores_seguidos = 0, ultimo_error = NULL,
      proxima_revision_en = now(), updated_at = now()
   WHERE id = v_id;
  RETURN v_codigo || ': actualizada' || CASE WHEN v_url IS DISTINCT FROM p_url THEN ' (antes ' || v_url || ')' ELSE '' END;
END $$;
REVOKE ALL ON FUNCTION vigilante._alta_fuente_movilidad(uuid, text, text[], text, text, text, text, text[], int, jsonb, text)
  FROM public, anon, authenticated;

DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');
BEGIN
  IF c IS NULL THEN RAISE NOTICE 'No existe el cliente orbita-bolivia: no se añaden fuentes'; RETURN; END IF;

  -- 1) ABC: comunicados de cortes, desvíos y reaperturas (el mapa de transitabilidad pide CAPTCHA)
  RAISE NOTICE '%', vigilante._alta_fuente_movilidad(c, 'abc_comunicados',
    ARRAY['%abc.gob.bo%'],
    'ABC · comunicados de transitabilidad (cortes, desvíos, reaperturas)', 'Administradora Boliviana de Carreteras',
    'https://www.abc.gob.bo/feed/?post_type=comunicados', 'rss', '{vial}', 30,
    jsonb_build_object(
      'timeout_s', 30,
      'reintentos', 1,
      'palabras_clave', jsonb_build_array('transitable', 'transitabilidad', 'restricción', 'sin restricción', 'cierre',
        'corte', 'bloqueo', 'derrumbe', 'deslizamiento', 'mazamorra', 'inundación', 'desvío', 'tramo', 'ruta',
        'carretera', 'paso vehicular', 'habilitado', 'atención'),
      'respaldo', jsonb_build_object(
        'metodo', 'google_news_rss',
        'query', '("ABC" OR "Administradora Boliviana de Carreteras") (transitabilidad OR "no transitable" OR bloqueo OR derrumbe OR "paso restringido" OR desvío) Bolivia'),
      'reparada', '2026-11-22: el mapa transitabilidad.abc.gob.bo pide CAPTCHA; se leen los comunicados del portal (RSS)'),
    '2026-11-22 (SQL 51): RSS de comunicados del portal; el mapa de transitabilidad pide CAPTCHA');

  -- 2) DGAC: noticias y comunicados de aviación civil
  RAISE NOTICE '%', vigilante._alta_fuente_movilidad(c, 'dgac',
    ARRAY['%dgac.gob.bo%'],
    'DGAC · noticias y comunicados de aviación civil', 'Dirección General de Aeronáutica Civil',
    'https://www.dgac.gob.bo/feed/', 'rss', '{conectividad}', 180,
    jsonb_build_object(
      'timeout_s', 30,
      'reintentos', 1,
      'palabras_clave', jsonb_build_array('aeropuerto', 'cierre', 'suspensión', 'operaciones', 'NOTAM', 'vuelo', 'ruta',
        'frecuencia', 'aerolínea', 'BoA', 'EcoJet', 'Amaszonas', 'autoriza', 'cielos abiertos'),
      'respaldo', jsonb_build_object(
        'metodo', 'google_news_rss',
        'query', '"DGAC" Bolivia (aeropuerto OR vuelos OR aerolínea OR ruta OR suspensión)'),
      'reparada', '2026-11-22: la portada se leía como página; ahora RSS (/feed/)'),
    '2026-11-22 (SQL 51): RSS del portal');

  -- 3) NAABOL: comunicados de operaciones de los aeropuertos (cierres, suspensiones, reanudaciones)
  RAISE NOTICE '%', vigilante._alta_fuente_movilidad(c, 'naabol_comunicados',
    ARRAY['%naabol.gob.bo%'],
    'NAABOL · comunicados de aeropuertos (cierres, suspensiones, reanudaciones)', 'Navegación Aérea y Aeropuertos Bolivianos',
    'https://www.naabol.gob.bo/pagina-de-comunicados', 'http_html', '{conectividad}', 60,
    jsonb_build_object(
      'extractor', 'tarjetas',
      'timeout_s', 30,
      'reintentos', 1,
      'palabras_clave', jsonb_build_array('aeropuerto', 'suspensión', 'suspendidas', 'reanudación', 'operaciones aéreas',
        'cierre', 'pista', 'condiciones meteorológicas', 'vuelos', 'NOTAM', 'comunicado'),
      'respaldo', jsonb_build_object(
        'metodo', 'google_news_rss',
        'query', 'NAABOL aeropuerto (suspensión OR suspende OR cierre OR reanuda OR "operaciones aéreas")'),
      'reparada', '2026-11-22: nueva; lista de comunicados leída por tarjetas (título, fecha y PDF)'),
    '2026-11-22 (SQL 51): fuente nueva para cierres de aeropuertos');

  -- 4) Si quedó otra fila apuntando al mapa con CAPTCHA (p. ej. había dos fuentes de la ABC), se
  --    desactiva: seguiría en CRÍTICO para siempre. No se borra, conserva su historial.
  UPDATE vigilante.sources SET activa = false, gestionada_web = true, updated_at = now(),
         notas = concat_ws(' · ', nullif(notas, ''), '2026-11-22 (SQL 51): desactivada, el mapa pide CAPTCHA; la ABC se lee por abc_comunicados')
   WHERE cliente_id = c AND eliminada_en IS NULL AND activa AND url ILIKE '%transitabilidad.abc.gob.bo%';
END $$;

COMMIT;

-- Cómo quedaron
SELECT codigo, activa, tipo, metodo, url, frecuencia_minutos AS cada_min, categorias,
       config ->> 'extractor' AS extractor, config -> 'respaldo' ->> 'metodo' AS respaldo,
       config ->> 'url_anterior' AS url_anterior, errores_seguidos, proxima_revision_en
  FROM vigilante.sources
 WHERE cliente_id = (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia')
   AND eliminada_en IS NULL
   AND (url ILIKE '%abc.gob.bo%' OR url ILIKE '%dgac.gob.bo%' OR url ILIKE '%naabol.gob.bo%')
 ORDER BY codigo;
