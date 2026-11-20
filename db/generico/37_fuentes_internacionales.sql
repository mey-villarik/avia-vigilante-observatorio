-- =============================================================================
-- AVIA Vigilante · 37 · Fuentes internacionales que afectan a Bolivia
-- =============================================================================
-- Requiere: 14, 15 y 31 (recolector, catálogo con versiones y señales relacionadas).
-- Se puede ejecutar varias veces.
--
-- Qué hace:
--   1. Marca las fuentes internacionales (sources.internacional) y da de alta tres para orbita-bolivia:
--        · ops_alertas         OPS/OMS: alertas y actualizaciones epidemiológicas de la región (RSS)
--        · cepal_comunicados   CEPAL: comunicados con proyecciones, comercio, inversión y turismo
--        · prensa_internacional BBC Mundo, Reuters y AP cuando hablan de Bolivia o de la región andina
--      Si ya había una fuente con esa dirección (p. ej. la OPS del 02), se actualiza esa, no se duplica.
--   2. El clasificador sabe qué noticias vienen de fuera (campo «internacional» en el lote) y recibe
--      las señales nacionales abiertas que pueden tener que ver (senales_nacionales). Para esas noticias
--      tiene que decir si hay impacto en Bolivia y por qué vía (prompt clasificador-1.8):
--        impacto_bolivia = {hay_impacto, ambitos[], via, nivel, plazo, refuerza[]}
--      Sin impacto en Bolivia, la noticia se descarta (lo hace el analizador antes de guardar).
--   3. Al guardar la clasificación, la señal recibe impacto_bolivia y las señales nacionales que
--      refuerza; queda marcada internacional = true solo si TODAS sus noticias vienen de fuera
--      (si un medio boliviano cuenta lo mismo, la señal es nacional con contexto internacional).
--   4. vigilante.internacional_web(): lo que ve el panel en la vista «Internacional» y el contexto
--      internacional de cada señal nacional.
--
-- Las señales internacionales son señales normales: siguen el mismo flujo (columnas, aprobación,
-- puntuaciones, eventos compuestos). Por eso también entran en los eventos compuestos cuando
-- coinciden en zona y fechas con señales nacionales, y en las oportunidades si traen una.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante.senales_relacionadas(uuid, text, integer[], bigint[], int)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 31 (cambios en noticias). Ejecuta 31 antes que este archivo';
  END IF;
END $$;

-- 1. Columnas ----------------------------------------------------------------------------------
ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS internacional boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN vigilante.sources.internacional IS
  'Fuente de fuera de Bolivia (OPS, CEPAL, prensa internacional): el clasificador evalúa el impacto en Bolivia';

ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS internacional boolean NOT NULL DEFAULT false;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS impacto_bolivia jsonb;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS refuerza bigint[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN vigilante.signals.internacional IS 'Todas sus noticias vienen de fuentes internacionales';
COMMENT ON COLUMN vigilante.signals.impacto_bolivia IS
  '{hay_impacto, ambitos[turismo|salud|economia|clima|infraestructura], via, nivel, plazo} que dio el clasificador';
COMMENT ON COLUMN vigilante.signals.refuerza IS 'Señales nacionales a las que esta señal internacional da contexto';
CREATE INDEX IF NOT EXISTS signals_internacional_idx ON vigilante.signals (cliente_id, created_at DESC) WHERE internacional;
CREATE INDEX IF NOT EXISTS signals_refuerza_idx ON vigilante.signals USING gin (refuerza);

-- 2. Las tres fuentes (cliente orbita-bolivia) ---------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._alta_fuente_internacional(p_cliente uuid, p_codigo text, p_patron text, p_nombre text,
                                                                p_institucion text, p_url text, p_tipo text, p_metodo text,
                                                                p_categorias text[], p_frecuencia int, p_config jsonb, p_notas text)
RETURNS text LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
DECLARE v_id int;
BEGIN
  -- ¿ya existe? por código o por dirección (la OPS ya venía en el 02 y pudo entrar con otro código)
  SELECT id INTO v_id FROM vigilante.sources
   WHERE cliente_id = p_cliente AND (codigo = p_codigo OR url ILIKE p_patron)
   ORDER BY (codigo = p_codigo) DESC, activa DESC, id LIMIT 1;
  IF v_id IS NULL THEN
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, institucion, url, tipo, metodo, categorias,
                                   frecuencia_minutos, rapida, activa, config, notas, internacional, gestionada_web)
    VALUES (p_cliente, p_codigo, p_nombre, p_institucion, p_url, p_tipo::vigilante.tipo_fuente, p_metodo::vigilante.metodo_fuente,
            p_categorias, p_frecuencia, false, true, p_config, p_notas, true, true);
    RETURN p_codigo || ': añadida';
  END IF;
  UPDATE vigilante.sources SET
      nombre = p_nombre, institucion = p_institucion, url = p_url, tipo = p_tipo::vigilante.tipo_fuente,
      metodo = p_metodo::vigilante.metodo_fuente, categorias = p_categorias, frecuencia_minutos = p_frecuencia,
      config = (config - 'apify_actor' - 'apify_input') || p_config,
      notas = CASE WHEN position(p_notas IN coalesce(notas, '')) > 0 THEN notas ELSE concat_ws(' · ', nullif(notas, ''), p_notas) END,
      internacional = true, activa = true, eliminada_en = NULL, gestionada_web = true,
      errores_seguidos = 0, proxima_revision_en = now(), updated_at = now()
   WHERE id = v_id;
  RETURN (SELECT codigo FROM vigilante.sources WHERE id = v_id) || ': actualizada';
END $$;
REVOKE ALL ON FUNCTION vigilante._alta_fuente_internacional(uuid, text, text, text, text, text, text, text, text[], int, jsonb, text)
  FROM public, anon, authenticated;

DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');
BEGIN
  IF c IS NULL THEN RAISE NOTICE 'No existe el cliente orbita-bolivia: no se añaden fuentes'; RETURN; END IF;

  -- 1) OPS/OMS: alertas epidemiológicas. El RSS es general: el filtro deja pasar lo que nombra
  --    Bolivia, un país vecino o una enfermedad vigilada; el clasificador decide si afecta a Bolivia.
  RAISE NOTICE '%', vigilante._alta_fuente_internacional(c, 'ops_alertas', '%paho.org%',
    'OPS/OMS · alertas epidemiológicas de la región', 'Organización Panamericana de la Salud',
    'https://www.paho.org/es/rss.xml', 'organismo_internacional', 'rss', '{salud}', 180,
    jsonb_build_object(
      'internacional', true,
      'que_buscar', 'Alertas y actualizaciones epidemiológicas que mencionen Bolivia o países vecinos (Perú, Chile, Argentina, Brasil, Paraguay); recomendaciones a viajeros',
      'palabras_clave', jsonb_build_array('Bolivia', 'Perú', 'Brasil', 'Argentina', 'Chile', 'Paraguay', 'alerta epidemiológica',
                                          'actualización epidemiológica', 'viajeros', 'dengue', 'sarampión', 'oropouche',
                                          'fiebre amarilla', 'chikungunya', 'influenza aviar'),
      'timeout_s', 40, 'reintentos', 1,
      'respaldo', jsonb_build_object('metodo', 'google_news_rss',
                    'query', '(OPS OR OMS) (alerta OR brote OR epidemia) (Bolivia OR Perú OR Brasil OR Argentina OR Chile OR Paraguay)'),
      'url_verificacion', 'verificada 2026-11-01 (página de alertas); RSS enlazado desde ella'),
    '2026-11-20: fuente internacional (37)');

  -- 2) CEPAL: comunicados de prensa (proyecciones de crecimiento, comercio, inversión, turismo).
  --    Listado web; si no responde desde el VPS, noticias de CEPAL sobre Bolivia por Google News.
  RAISE NOTICE '%', vigilante._alta_fuente_internacional(c, 'cepal_comunicados', '%cepal.org%',
    'CEPAL · comunicados sobre la región y Bolivia', 'Comisión Económica para América Latina y el Caribe',
    'https://www.cepal.org/es/listado/cepal_pr', 'organismo_internacional', 'http_html', '{mercados,financiamiento}', 720,
    jsonb_build_object(
      'internacional', true,
      'que_buscar', 'Proyecciones económicas, comercio, inversión extranjera, turismo, cooperación y financiamiento que nombren a Bolivia, América del Sur o la región andina',
      'palabras_clave', jsonb_build_array('Bolivia', 'América del Sur', 'América Latina y el Caribe', 'andina', 'turismo',
                                          'crecimiento', 'proyecciones', 'inversión extranjera', 'comercio', 'exportaciones',
                                          'litio', 'inflación', 'remesas', 'cooperación', 'financiamiento'),
      'timeout_s', 40, 'reintentos', 1,
      'urls_alternativas', jsonb_build_array('https://www.cepal.org/es/comunicados'),
      'respaldo', jsonb_build_object('metodo', 'google_news_rss',
                    'query', 'CEPAL (Bolivia OR "América del Sur" OR "América Latina") (crecimiento OR turismo OR inversión OR comercio OR proyecciones)'),
      'url_verificacion', 'encontrada_no_abierta: listado de comunicados de cepal.org; comprobar desde el VPS'),
    '2026-11-20: fuente internacional (37)');

  -- 3) Prensa internacional: BBC Mundo, Reuters y AP, solo cuando hablan de Bolivia o de la región andina.
  RAISE NOTICE '%', vigilante._alta_fuente_internacional(c, 'prensa_internacional', '%news.google.com%site%3Abbc.com%',
    'Prensa internacional · BBC Mundo, Reuters y AP sobre Bolivia', 'BBC Mundo / Reuters / AP (vía Google News)',
    -- dirección completa con la búsqueda (no la genérica de Google News, que ya usa gnews_turismo)
    'https://news.google.com/rss/search?q=%28Bolivia%20OR%20boliviano%20OR%20%22regi%C3%B3n%20andina%22%20OR%20Titicaca%20OR%20Uyuni%29%20%28site%3Abbc.com%20OR%20site%3Areuters.com%20OR%20site%3Aapnews.com%29%20when%3A1d&hl=es-419&gl=BO&ceid=BO:es-419',
    'medio', 'google_news_rss', '{clima,seguridad,mercados,conectividad}', 60,
    jsonb_build_object(
      'internacional', true,
      'query', '(Bolivia OR boliviano OR "región andina" OR Titicaca OR Uyuni) (site:bbc.com OR site:reuters.com OR site:apnews.com)',
      'hl', 'es-419', 'gl', 'BO',
      'que_buscar', 'Clima, política, economía, seguridad y conectividad en Bolivia o la región andina contados por medios internacionales',
      'palabras_clave', jsonb_build_array('Bolivia', 'boliviano', 'boliviana', 'andina', 'Andes', 'Titicaca', 'Uyuni',
                                          'Perú', 'Chile', 'Argentina', 'Brasil', 'Paraguay', 'El Niño', 'La Niña')),
    '2026-11-20: fuente internacional (37)');

  -- cualquier otra fuente con config.internacional = true (dada de alta a mano) también cuenta
  UPDATE vigilante.sources SET internacional = true
   WHERE cliente_id = c AND NOT internacional AND (config ->> 'internacional')::boolean IS TRUE;
END $$;

-- 3. El clasificador sabe qué noticias vienen de fuera ----------------------------------------
-- Señales nacionales abiertas que pueden tener que ver con una noticia internacional: las del 31
-- (título parecido) y las que comparten palabras con ella (búsqueda de texto), sin las internacionales.
CREATE OR REPLACE FUNCTION vigilante.senales_nacionales_para(p_cliente uuid, p_titulo text, p_texto text, p_limite int DEFAULT 4)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH pal AS (
    SELECT string_agg(DISTINCT w, ' or ') AS q
      FROM (SELECT w FROM regexp_split_to_table(vigilante.texto_norm(coalesce(p_titulo, '') || ' ' || left(coalesce(p_texto, ''), 300)), '\s+') w
             WHERE length(w) >= 5 LIMIT 14) x
  ), cand AS (
    SELECT s.id, ts_rank(s.busqueda, websearch_to_tsquery('spanish', pal.q)) AS r
      FROM vigilante.signals s, pal
     WHERE s.cliente_id = p_cliente AND NOT s.internacional AND s.duplicado_de IS NULL
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND greatest(s.created_at, s.updated_at) > now() - interval '30 days'
       AND pal.q IS NOT NULL AND s.busqueda @@ websearch_to_tsquery('spanish', pal.q)
  ), rel AS (
    SELECT s.id, 1.0::real AS r FROM jsonb_array_elements(vigilante.senales_relacionadas(p_cliente, p_titulo, '{}', '{}', 2)) j
      JOIN vigilante.signals s ON s.cliente_id = p_cliente AND s.codigo = j ->> 'codigo' AND NOT s.internacional
  ), todo AS (
    SELECT id, max(r) AS r FROM (SELECT * FROM rel UNION ALL SELECT * FROM cand) u GROUP BY id
  )
  SELECT coalesce(jsonb_agg(vigilante._senal_corta(t.id) ORDER BY t.r DESC), '[]')
    FROM (SELECT * FROM todo ORDER BY r DESC, id DESC LIMIT greatest(least(coalesce(p_limite, 4), 6), 1)) t
$$;
REVOKE ALL ON FUNCTION vigilante.senales_nacionales_para(uuid, text, text, int) FROM public, anon, authenticated;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'vigilante' AND p.proname = 'lote_para_clasificar_31') THEN
    ALTER FUNCTION vigilante.lote_para_clasificar(text, int) RENAME TO lote_para_clasificar_31;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar_31(text, int) FROM public, anon, authenticated;

-- lote_para_clasificar del 31 queda dentro; esta añade a cada noticia de fuente internacional:
--   internacional: true y senales_nacionales (máx. 4) para que el clasificador diga a cuáles refuerza
CREATE OR REPLACE FUNCTION vigilante.lote_para_clasificar(p_cliente text, p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; v_out jsonb := '[]'; r record;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(vigilante.lote_para_clasificar_31(p_cliente, p_limite), '[]')) LOOP
    SELECT ri.titulo, ri.contenido, coalesce(s.internacional, false) AS internacional, s.nombre
      INTO r FROM vigilante.raw_items ri LEFT JOIN vigilante.sources s ON s.id = ri.source_id
     WHERE ri.id = (x ->> 'clave')::bigint;
    IF r.internacional THEN
      x := x || jsonb_build_object('internacional', true,
                                   'senales_nacionales', vigilante.senales_nacionales_para(v_cliente, r.titulo, r.contenido, 4));
    END IF;
    v_out := v_out || jsonb_build_array(x);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar(text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.lote_para_clasificar(text, int) TO service_role;

-- 4. Al guardar la clasificación: impacto en Bolivia y señales que refuerza ---------------------
-- Disparador sobre analisis, como el del 31: guardar_clasificacion pone signal_id después de guardar.
CREATE OR REPLACE FUNCTION vigilante.tg_impacto_bolivia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE ib jsonb := NEW.salida -> 'impacto_bolivia'; v_ref bigint[]; v_intl boolean;
BEGIN
  IF NEW.tipo <> 'clasificacion' OR NEW.signal_id IS NULL THEN RETURN NULL; END IF;
  -- ¿la noticia viene de una fuente internacional?
  IF NOT EXISTS (SELECT 1 FROM vigilante.raw_items r JOIN vigilante.sources s ON s.id = r.source_id
                  WHERE r.id = NEW.raw_item_id AND s.internacional) THEN
    -- nacional: si la señal era internacional y ahora tiene noticias de aquí, deja de serlo
    UPDATE vigilante.signals SET internacional = false WHERE id = NEW.signal_id AND internacional;
    RETURN NULL;
  END IF;
  IF jsonb_typeof(ib) <> 'object' THEN RETURN NULL; END IF;

  -- solo señales nacionales que existen, del mismo cliente y abiertas
  v_ref := ARRAY(SELECT s.id FROM vigilante.signals s
                  WHERE s.cliente_id = NEW.cliente_id AND s.id <> NEW.signal_id AND NOT s.internacional
                    AND s.estado NOT IN ('descartada', 'cerrada')
                    AND s.codigo IN (SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(ib -> 'refuerza') = 'array'
                                                                         THEN ib -> 'refuerza' ELSE '[]' END)));
  -- internacional solo si TODAS sus noticias vienen de fuera
  v_intl := NOT EXISTS (SELECT 1 FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                          LEFT JOIN vigilante.sources s ON s.id = r.source_id
                         WHERE sr.signal_id = NEW.signal_id AND NOT coalesce(s.internacional, false));
  UPDATE vigilante.signals SET
      internacional = v_intl,
      impacto_bolivia = jsonb_strip_nulls(jsonb_build_object(
        'hay_impacto', true,
        'ambitos', CASE WHEN jsonb_typeof(ib -> 'ambitos') = 'array' THEN ib -> 'ambitos' END,
        'via', nullif(trim(ib ->> 'via'), ''),
        'nivel', CASE WHEN ib ->> 'nivel' IN ('alto', 'medio', 'bajo') THEN ib ->> 'nivel' END,
        'plazo', CASE WHEN ib ->> 'plazo' IN ('inmediato', 'semanas', 'meses') THEN ib ->> 'plazo' END,
        'evaluado_en', now())),
      refuerza = ARRAY(SELECT DISTINCT x FROM unnest(refuerza || v_ref) x ORDER BY x)
   WHERE id = NEW.signal_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_impacto_bolivia ON vigilante.analisis;
CREATE TRIGGER zz_impacto_bolivia AFTER UPDATE OF signal_id ON vigilante.analisis
  FOR EACH ROW WHEN (NEW.signal_id IS NOT NULL AND OLD.signal_id IS DISTINCT FROM NEW.signal_id)
  EXECUTE FUNCTION vigilante.tg_impacto_bolivia();

-- 5. Panel: vista «Internacional» y contexto de las señales nacionales --------------------------
CREATE OR REPLACE FUNCTION vigilante._internacional_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH intl AS (
    SELECT s.* FROM vigilante.signals s
     WHERE s.cliente_id = p_cliente AND s.duplicado_de IS NULL AND s.estado NOT IN ('descartada', 'cerrada')
       AND (s.internacional OR s.impacto_bolivia IS NOT NULL)
       AND greatest(s.created_at, s.updated_at) > now() - interval '30 days'
  )
  SELECT jsonb_build_object(
    'fuentes', (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                  'codigo', f.codigo, 'nombre', f.nombre, 'institucion', f.institucion, 'url', f.url, 'metodo', f.metodo,
                  'activa', f.activa, 'ultima_consulta_en', f.ultima_consulta_en, 'ultimo_exito_en', f.ultimo_exito_en,
                  'errores_seguidos', f.errores_seguidos, 'ultimo_error', f.ultimo_error,
                  'noticias_7d', (SELECT count(*) FROM vigilante.raw_items r WHERE r.source_id = f.id AND r.recolectado_en > now() - interval '7 days'),
                  'senales_30d', (SELECT count(DISTINCT sr.signal_id) FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                   WHERE r.source_id = f.id AND r.recolectado_en > now() - interval '30 days')))
                ORDER BY f.nombre), '[]')
                 FROM vigilante.sources f WHERE f.cliente_id = p_cliente AND f.internacional AND f.eliminada_en IS NULL),
    'senales', (SELECT coalesce(jsonb_agg(vigilante._senal_corta(i.id) || jsonb_strip_nulls(jsonb_build_object(
                  'internacional', i.internacional,
                  'impacto_bolivia', i.impacto_bolivia,
                  'detectada', i.created_at,
                  'fuentes', (SELECT jsonb_agg(DISTINCT f.nombre) FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                JOIN vigilante.sources f ON f.id = r.source_id WHERE sr.signal_id = i.id AND f.internacional),
                  'enlace', (SELECT r.url FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                               JOIN vigilante.sources f ON f.id = r.source_id
                              WHERE sr.signal_id = i.id AND f.internacional ORDER BY r.recolectado_en DESC LIMIT 1),
                  'refuerza', (SELECT jsonb_agg(vigilante._senal_corta(n.id) ORDER BY n.id DESC) FROM vigilante.signals n
                                WHERE n.id = ANY (i.refuerza) AND n.estado NOT IN ('descartada', 'cerrada'))))
                ORDER BY CASE i.impacto_bolivia ->> 'nivel' WHEN 'alto' THEN 0 WHEN 'medio' THEN 1 ELSE 2 END, i.created_at DESC), '[]')
                 FROM intl i),
    -- para cada señal nacional: las internacionales que le dan contexto
    'contexto', (SELECT coalesce(jsonb_object_agg(x.codigo, x.lista), '{}') FROM (
                  SELECT n.codigo, jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                           'codigo', i.codigo, 'titulo', i.titulo, 'via', i.impacto_bolivia ->> 'via',
                           'nivel', i.impacto_bolivia ->> 'nivel', 'ambitos', i.impacto_bolivia -> 'ambitos'))
                           ORDER BY i.created_at DESC) AS lista
                    FROM intl i JOIN vigilante.signals n ON n.id = ANY (i.refuerza)
                   WHERE n.estado NOT IN ('descartada', 'cerrada')
                   GROUP BY n.codigo) x)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._internacional_json(uuid) FROM public, anon, authenticated;

-- Web: cualquier usuario activo del cliente (como las oportunidades)
CREATE OR REPLACE FUNCTION vigilante.internacional_web()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN vigilante.cliente_actual() IS NULL THEN jsonb_build_object('fuentes', '[]'::jsonb, 'senales', '[]'::jsonb, 'contexto', '{}'::jsonb)
              ELSE vigilante._internacional_json(vigilante.cliente_actual()) END
$$;
REVOKE ALL ON FUNCTION vigilante.internacional_web() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.internacional_web() TO authenticated;

-- Hermes y AVIA (clave de servicio)
CREATE OR REPLACE FUNCTION vigilante.internacional(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante._internacional_json(vigilante.id_cliente(p_cliente))
$$;
REVOKE ALL ON FUNCTION vigilante.internacional(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.internacional(text) TO service_role;

COMMIT;

-- Cómo quedaron las fuentes internacionales
SELECT s.codigo, s.nombre, s.metodo, s.activa, s.frecuencia_minutos AS min
  FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id
 WHERE c.slug = 'orbita-bolivia' AND s.internacional ORDER BY s.codigo;
