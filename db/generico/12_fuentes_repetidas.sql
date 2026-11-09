-- =============================================================================
-- AVIA Vigilante · Fuentes repetidas: juntar las del mismo sitio y no volver a duplicarlas
-- Requiere 01 y 06 a 11. Se puede ejecutar más de una vez.
--
-- Por qué: AVIA publicaba el mismo medio con códigos distintos (eldeber, eldeb, el_deber…)
-- y con la dirección del artículo en vez de la del sitio. Cada variante acababa como fuente nueva.
--
--   PASO 1 (solo mira, no cambia nada):
--      select * from vigilante.fuentes_repetidas();
--   PASO 2 (junta; las señales y noticias pasan a la fuente que se queda):
--      select vigilante.juntar_fuentes_repetidas();
--
-- Además, desde aquí la sincronización con vigilante.json busca primero si la fuente ya existe
-- (mismo código, misma dirección o mismo sitio web) y usa esa en vez de crear otra.
-- Los agregadores (Google News, redes sociales…) se comparan por dirección completa, no por sitio.
-- =============================================================================

BEGIN;

-- Sitio web de una dirección: «https://www.ElDeber.com.bo/economia/x» → «eldeber.com.bo»
CREATE OR REPLACE FUNCTION vigilante.dominio(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN h IS NULL OR h = '' THEN vigilante.url_normal(p)
    -- en los agregadores cada dirección es una fuente distinta
    WHEN h IN ('news.google.com', 'google.com', 'facebook.com', 'm.facebook.com', 'x.com', 'twitter.com', 'youtube.com',
               'instagram.com', 't.me', 'tiktok.com', 'linkedin.com', 'gdeltproject.org', 'api.gdeltproject.org')
      THEN vigilante.url_normal(p)
    ELSE h END
  FROM (SELECT substring(lower(trim(coalesce(p, ''))) FROM '^(?:https?://)?(?:www\.)?([^/:?#]+)') AS h) x
$$;

-- Código de la fuente que ya existe para lo que trae AVIA (o NULL si es nueva de verdad)
CREATE OR REPLACE FUNCTION vigilante.fuente_canonica(p_cliente uuid, p_codigo text, p_url text)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(
    -- 1. el mismo código, si sigue vigente
    (SELECT codigo FROM vigilante.sources WHERE cliente_id = p_cliente AND codigo = p_codigo AND eliminada_en IS NULL),
    -- 2. un código que se juntó con otro: se usa el que se quedó
    (SELECT s2.codigo FROM vigilante.sources s1 JOIN vigilante.sources s2
        ON s2.cliente_id = s1.cliente_id AND s2.codigo = s1.config ->> 'fusionada_en' AND s2.eliminada_en IS NULL
      WHERE s1.cliente_id = p_cliente AND s1.codigo = p_codigo),
    -- 3. la misma dirección
    (SELECT codigo FROM vigilante.sources WHERE cliente_id = p_cliente AND eliminada_en IS NULL
        AND coalesce(p_url, '') <> '' AND vigilante.url_normal(url) = vigilante.url_normal(p_url)
      ORDER BY gestionada_web DESC, created_at LIMIT 1),
    -- 4. el mismo sitio web
    (SELECT codigo FROM vigilante.sources WHERE cliente_id = p_cliente AND eliminada_en IS NULL
        AND coalesce(p_url, '') <> '' AND vigilante.dominio(url) = vigilante.dominio(p_url)
      ORDER BY gestionada_web DESC, activa DESC, length(url), created_at LIMIT 1))
$$;

-- PASO 1: qué se juntaría (no cambia nada)
CREATE OR REPLACE FUNCTION vigilante.fuentes_repetidas()
RETURNS TABLE (cliente text, sitio text, se_queda text, se_juntan text[], direccion_que_queda text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH g AS (
    SELECT s.*, c.slug, vigilante.dominio(s.url) AS dom,
           row_number() OVER (PARTITION BY s.cliente_id, vigilante.dominio(s.url)
                              ORDER BY s.gestionada_web DESC, s.activa DESC, length(s.url), s.created_at) AS orden,
           count(*) OVER (PARTITION BY s.cliente_id, vigilante.dominio(s.url)) AS n
      FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id
     WHERE s.eliminada_en IS NULL AND s.url <> '—'
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
  )
  SELECT k.slug, k.dom, k.codigo,
         ARRAY(SELECT o.codigo FROM g o WHERE o.cliente_id = k.cliente_id AND o.dom = k.dom AND o.orden > 1 ORDER BY o.codigo),
         CASE WHEN k.gestionada_web THEN k.url ELSE 'https://' || k.dom || '/' END
    FROM g k WHERE k.orden = 1 AND k.n > 1
   ORDER BY k.slug, k.dom
$$;
REVOKE ALL ON FUNCTION vigilante.fuentes_repetidas() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_repetidas() TO authenticated, service_role;

-- PASO 2: juntar (solo administrador desde la web; desde el SQL Editor, todas)
CREATE OR REPLACE FUNCTION vigilante.juntar_fuentes_repetidas()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v_keep vigilante.sources; v_dup vigilante.sources; v_reciente vigilante.sources;
        v_activa boolean; n_grupos int := 0; n_juntadas int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede juntar fuentes'; END IF;
  PERFORM set_config('vigilante.actor', 'limpieza:fuentes_repetidas', true);
  FOR r IN SELECT f.*, c.id AS cid FROM vigilante.fuentes_repetidas() f JOIN vigilante.clientes c ON c.slug = f.cliente LOOP
    SELECT * INTO v_keep FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = r.se_queda;
    -- la comprobación más reciente del grupo pasa a la fuente que se queda
    SELECT * INTO v_reciente FROM vigilante.sources
     WHERE cliente_id = r.cid AND (codigo = r.se_queda OR codigo = ANY (r.se_juntan))
     ORDER BY ultima_consulta_en DESC NULLS LAST LIMIT 1;
    SELECT coalesce(bool_or(activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)), false) INTO v_activa
      FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = ANY (r.se_juntan);
    FOR v_dup IN SELECT * FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = ANY (r.se_juntan) LOOP
      UPDATE vigilante.raw_items      SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.signals        SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.system_logs    SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.source_events  SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.sources SET activa = false, eliminada_en = now(),
             config = config || jsonb_build_object('fusionada_en', v_keep.codigo)
       WHERE id = v_dup.id;
      n_juntadas := n_juntadas + 1;
    END LOOP;
    UPDATE vigilante.sources SET
      url = r.direccion_que_queda,
      -- sigue vigilándose si alguna de las juntadas estaba activa (y no era solo una propuesta)
      activa = v_keep.activa OR v_activa,
      ultima_consulta_en = greatest(v_keep.ultima_consulta_en, v_reciente.ultima_consulta_en),
      config = (CASE WHEN v_keep.activa OR v_activa THEN config - 'propuesta_avia' ELSE config END)
               || jsonb_strip_nulls(jsonb_build_object('estado', v_reciente.config -> 'estado',
                                                              'hist', v_reciente.config -> 'hist',
                                                              'items', v_reciente.config -> 'items')),
      notas = coalesce(v_reciente.notas, notas)
     WHERE id = v_keep.id;
    n_grupos := n_grupos + 1;
  END LOOP;
  RETURN jsonb_build_object('sitios', n_grupos, 'fuentes_juntadas', n_juntadas);
END $$;
REVOKE ALL ON FUNCTION vigilante.juntar_fuentes_repetidas() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.juntar_fuentes_repetidas() TO authenticated, service_role;

-- Sincronización (igual que en 11, pero sin duplicar fuentes)
CREATE OR REPLACE FUNCTION vigilante.sincronizar_vigilante(p_cliente text, p_json jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid;
  f jsonb; s jsonb;
  v_tipo vigilante.tipo_fuente;
  v_metodo vigilante.metodo_fuente;
  v_estado vigilante.estado_senal;
  v_actual record;
  v_codigo text;
  n_fuentes int := 0; n_nuevas int := 0; n_act int := 0; n_estado_respetado int := 0;
BEGIN
  SELECT id INTO v_cliente FROM vigilante.clientes WHERE slug = p_cliente AND activo;
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'Cliente % no existe o no está activo', p_cliente; END IF;
  IF coalesce((p_json ->> 'version')::int, 0) <> 1 THEN RAISE EXCEPTION 'vigilante.json versión no reconocida'; END IF;
  PERFORM set_config('vigilante.actor', 'hermes:sincronizacion', true);

  -- Fuentes
  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(p_json -> 'fuentes', '[]')) LOOP
    CONTINUE WHEN coalesce(f ->> 'id', '') = '';
    v_tipo := CASE lower(coalesce(f ->> 'tipo', ''))
                WHEN 'oficial' THEN 'oficial'
                WHEN 'organismo_internacional' THEN 'organismo_internacional'
                WHEN 'internacional' THEN 'organismo_internacional'
                WHEN 'medio' THEN 'medio' WHEN 'media' THEN 'medio' WHEN 'prensa' THEN 'medio'
                ELSE 'no_oficial' END;
    v_metodo := CASE WHEN lower(coalesce(f ->> 'metodo', '')) IN
                  ('rss','google_news_rss','gdelt','http_html','apify','tavily','api','mcp_vigilante','manual')
                THEN lower(f ->> 'metodo')::vigilante.metodo_fuente ELSE 'mcp_vigilante' END;
    -- si la fuente ya existe (mismo código, misma dirección o mismo sitio web) se usa esa: no se duplica
    v_codigo := coalesce(vigilante.fuente_canonica(v_cliente, f ->> 'id', f ->> 'url'), f ->> 'id');
    -- una fuente que la base no conoce entra EN PAUSA como propuesta de AVIA: la aprueba un administrador
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias, ultima_consulta_en, notas, config, activa)
    VALUES (v_cliente, v_codigo, coalesce(f ->> 'nombre', f ->> 'id'), coalesce(nullif(f ->> 'url', ''), '—'),
            v_tipo, v_metodo, CASE WHEN f ? 'canal' AND f ->> 'canal' IS NOT NULL THEN ARRAY[f ->> 'canal'] ELSE '{}' END,
            (f ->> 'ultima')::timestamptz, f ->> 'info',
            jsonb_build_object('estado', f -> 'estado', 'hist', f -> 'hist', 'items', f -> 'items', 'propuesta_avia', true),
            false)
    ON CONFLICT (cliente_id, codigo) DO UPDATE SET
      -- lo que una persona escribió en la web manda: Hermes solo actualiza el estado de la comprobación
      -- si AVIA la trae con otro código (la encontró por dirección o sitio), se conserva el nombre de la base
      nombre = CASE WHEN vigilante.sources.gestionada_web OR v_codigo <> (f ->> 'id') THEN vigilante.sources.nombre ELSE EXCLUDED.nombre END,
      -- la dirección no cambia por cada artículo del mismo sitio
      url = CASE WHEN vigilante.sources.gestionada_web
                   OR vigilante.dominio(EXCLUDED.url) = vigilante.dominio(vigilante.sources.url)
                 THEN vigilante.sources.url ELSE EXCLUDED.url END,
      tipo = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.tipo ELSE EXCLUDED.tipo END,
      categorias = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.categorias ELSE EXCLUDED.categorias END,
      -- si AVIA no manda la hora, se conserva la anterior
      ultima_consulta_en = coalesce(EXCLUDED.ultima_consulta_en, vigilante.sources.ultima_consulta_en),
      notas = EXCLUDED.notas,
      config = vigilante.sources.config || (EXCLUDED.config - 'propuesta_avia'),
      -- registro de fallos: solo cuenta cuando llega una comprobación nueva (hora distinta)
      ultimo_exito_en = CASE WHEN EXCLUDED.ultima_consulta_en IS DISTINCT FROM vigilante.sources.ultima_consulta_en
                              AND EXCLUDED.ultima_consulta_en IS NOT NULL AND upper(EXCLUDED.config ->> 'estado') IN ('OK', 'WARN')
                             THEN EXCLUDED.ultima_consulta_en ELSE vigilante.sources.ultimo_exito_en END,
      errores_seguidos = CASE WHEN EXCLUDED.ultima_consulta_en IS NOT DISTINCT FROM vigilante.sources.ultima_consulta_en
                                OR EXCLUDED.ultima_consulta_en IS NULL THEN vigilante.sources.errores_seguidos
                              WHEN upper(EXCLUDED.config ->> 'estado') IN ('CRIT', 'UNKNOWN') THEN vigilante.sources.errores_seguidos + 1
                              WHEN upper(EXCLUDED.config ->> 'estado') IN ('OK', 'WARN') THEN 0
                              ELSE vigilante.sources.errores_seguidos END,
      ultimo_error = CASE WHEN EXCLUDED.ultima_consulta_en IS DISTINCT FROM vigilante.sources.ultima_consulta_en
                           AND EXCLUDED.ultima_consulta_en IS NOT NULL AND upper(EXCLUDED.config ->> 'estado') IN ('CRIT', 'UNKNOWN') THEN EXCLUDED.notas
                          ELSE vigilante.sources.ultimo_error END;
    n_fuentes := n_fuentes + 1;
  END LOOP;

  -- Señales
  FOR s IN SELECT * FROM jsonb_array_elements(coalesce(p_json -> 'senales', '[]')) LOOP
    CONTINUE WHEN coalesce(s ->> 'id', '') = '' OR coalesce(s ->> 'titulo', '') = '';
    -- la categoría tiene que existir en el catálogo del cliente
    INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
    VALUES (v_cliente, coalesce(nullif(s ->> 'categoria', ''), 'mercado'), coalesce(nullif(s ->> 'categoria', ''), 'mercado'))
    ON CONFLICT DO NOTHING;
    v_estado := CASE WHEN s ->> 'estado' IN ('detectada','en_analisis','en_verificacion','confirmada','publicada','cerrada','descartada')
                THEN (s ->> 'estado')::vigilante.estado_senal ELSE 'detectada' END;

    SELECT id, estado, estado_manual INTO v_actual FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = s ->> 'id';
    IF NOT FOUND THEN
      INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad,
                                     confianza, estado, plazo_hasta, enlace_oficial, salida_modelo)
      VALUES (v_cliente, s ->> 'id', s ->> 'titulo', coalesce(s ->> 'resumen', ''),
              CASE WHEN s ->> 'naturaleza' IN ('riesgo','oportunidad','mixta') THEN (s ->> 'naturaleza')::vigilante.naturaleza_senal ELSE 'mixta' END,
              coalesce(nullif(s ->> 'categoria', ''), 'mercado'),
              CASE WHEN s ->> 'prioridad' IN ('baja','media','alta') THEN (s ->> 'prioridad')::vigilante.prioridad ELSE 'media' END,
              least(greatest(coalesce((s ->> 'conf')::numeric, 0), 0), 1),
              v_estado,
              CASE WHEN s ->> 'fecha_limite' ~ '^\d{4}-\d{2}-\d{2}$' THEN ((s ->> 'fecha_limite') || 'T23:59:59-04:00')::timestamptz END,
              s #>> '{enlaces,0,url}', s);
      n_nuevas := n_nuevas + 1;
    ELSE
      UPDATE vigilante.signals SET
        titulo = s ->> 'titulo', resumen = coalesce(s ->> 'resumen', ''),
        prioridad = CASE WHEN s ->> 'prioridad' IN ('baja','media','alta') THEN (s ->> 'prioridad')::vigilante.prioridad ELSE prioridad END,
        confianza = least(greatest(coalesce((s ->> 'conf')::numeric, confianza, 0), 0), 1),
        salida_modelo = s,
        -- el estado de Hermes solo se aplica si ninguna persona lo cambió y la transición es válida
        estado = CASE WHEN NOT v_actual.estado_manual AND vigilante.transicion_valida(v_actual.estado, v_estado)
                      THEN v_estado ELSE estado END
      WHERE id = v_actual.id;
      IF v_actual.estado_manual AND v_actual.estado <> v_estado THEN n_estado_respetado := n_estado_respetado + 1; END IF;
      n_act := n_act + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('fuentes', n_fuentes, 'senales_nuevas', n_nuevas, 'senales_actualizadas', n_act,
                            'estados_de_personas_respetados', n_estado_respetado);
END $$;
REVOKE ALL ON FUNCTION vigilante.sincronizar_vigilante(text, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.sincronizar_vigilante(text, jsonb) TO service_role;

-- La web: dice con qué fuente se juntó cada código antiguo (para mostrar su estado en la buena)
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz,
               propuesta boolean, errores_seguidos int, ultimo_exito_en timestamptz, ultimo_error text,
               reconocida_por text, reconocida_en timestamptz, reconocida_nota text,
               revision_pedida_en timestamptz, revision_pedida_por text, fusionada_en text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz,
         coalesce((config ->> 'propuesta_avia')::boolean, false), errores_seguidos, ultimo_exito_en, ultimo_error,
         config ->> 'reconocida_por', (config ->> 'reconocida_en')::timestamptz, config ->> 'reconocida_nota',
         (config ->> 'revision_pedida_en')::timestamptz, config ->> 'revision_pedida_por', config ->> 'fusionada_en'
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

COMMIT;
