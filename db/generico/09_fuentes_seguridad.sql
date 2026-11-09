-- =============================================================================
-- AVIA Vigilante · Fuentes: seguridad y coherencia (auditoría 2026-11-08)
-- Requiere 01, 03, 04, 06, 07 y 08. Se puede ejecutar más de una vez.
--
--   1. La tabla de fuentes: solo el administrador escribe; todo el equipo (también el visor) lee.
--   2. Una fuente que AVIA publica y la base no conoce entra EN PAUSA como «propuesta de AVIA».
--   3. La sincronización guarda último éxito, fallos seguidos y último error, y no borra la hora
--      de la última comprobación si AVIA no la manda.
--   4. Cambiar la dirección o el método obliga a AVIA a revisarla de nuevo («nueva» en su lista).
--   5. Duplicados: http/https, «www.», mayúsculas y la barra final cuentan como la misma dirección.
-- =============================================================================

BEGIN;

-- 1. Permisos de la tabla (sustituye la regla general «staff_todo» de 01 solo para fuentes)
DROP POLICY IF EXISTS staff_todo ON vigilante.sources;
DROP POLICY IF EXISTS lectura_cliente ON vigilante.sources;  -- nombres de una versión provisional
DROP POLICY IF EXISTS admin_escribe ON vigilante.sources;
DROP POLICY IF EXISTS fuentes_equipo_lee ON vigilante.sources;
DROP POLICY IF EXISTS fuentes_admin_escribe ON vigilante.sources;
CREATE POLICY fuentes_equipo_lee ON vigilante.sources FOR SELECT TO authenticated
  USING (cliente_id = vigilante.cliente_actual());
CREATE POLICY fuentes_admin_escribe ON vigilante.sources FOR ALL TO authenticated
  USING (vigilante.es_admin() AND cliente_id = vigilante.cliente_actual())
  WITH CHECK (vigilante.es_admin() AND cliente_id = vigilante.cliente_actual());

-- 5. Dirección normalizada para comparar
CREATE OR REPLACE FUNCTION vigilante.url_normal(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(regexp_replace(lower(trim(coalesce(p, ''))), '^https?://(www\.)?', ''), '/+$', '')
$$;

-- 4. Lista para Hermes
CREATE OR REPLACE FUNCTION vigilante.fuentes_para_hermes(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'generado', now(),
    'fuentes', coalesce(jsonb_agg(jsonb_build_object(
        'codigo', s.codigo,
        'nombre', s.nombre,
        'url', s.url,
        'tipo', s.tipo,
        'metodo', s.metodo,
        'categorias', s.categorias,
        'frecuencia_minutos', s.frecuencia_minutos,
        'que_buscar', s.config ->> 'que_buscar',
        'palabras_clave', coalesce(s.config -> 'palabras_clave', '[]'::jsonb),
        'nueva', s.ultima_consulta_en IS NULL OR s.ultima_consulta_en < (s.config ->> 'revisar_desde')::timestamptz,
        'ultima_consulta_en', s.ultima_consulta_en,
        'alta_por', s.config ->> 'alta_por'
      ) ORDER BY s.ultima_consulta_en NULLS FIRST, s.nombre) FILTER (WHERE s.id IS NOT NULL), '[]'::jsonb)
  )
  FROM vigilante.clientes c
  LEFT JOIN vigilante.sources s ON s.cliente_id = c.id AND s.activa AND s.eliminada_en IS NULL
  WHERE c.slug = p_cliente AND c.activo
  GROUP BY c.slug
$$;
REVOKE ALL ON FUNCTION vigilante.fuentes_para_hermes(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_para_hermes(text) TO service_role;

-- 5. Alta con dirección normalizada (si era una fuente eliminada, se recupera)
CREATE OR REPLACE FUNCTION vigilante.alta_fuente(p_nombre text, p_url text, p_categoria text, p_tipo text,
                                                 p_metodo text, p_frecuencia int, p_que_buscar text,
                                                 p_palabras text[])
RETURNS text LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
DECLARE v_codigo text; v_base text; n int := 1; v_borrada text;
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede añadir fuentes'; END IF;
  IF coalesce(trim(p_nombre), '') = '' OR p_url !~* '^https?://' THEN RAISE EXCEPTION 'Faltan el nombre o una dirección web válida'; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
              AND vigilante.url_normal(url) = vigilante.url_normal(p_url) AND eliminada_en IS NULL) THEN
    RAISE EXCEPTION 'Ya hay una fuente con esa dirección';
  END IF;
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
  VALUES (vigilante.cliente_actual(), p_categoria, p_categoria) ON CONFLICT DO NOTHING;

  SELECT codigo INTO v_borrada FROM vigilante.sources
   WHERE cliente_id = vigilante.cliente_actual() AND vigilante.url_normal(url) = vigilante.url_normal(p_url) AND eliminada_en IS NOT NULL
   ORDER BY eliminada_en DESC LIMIT 1;
  IF v_borrada IS NOT NULL THEN
    UPDATE vigilante.sources SET
      eliminada_en = NULL, activa = true, nombre = trim(p_nombre),
      tipo = coalesce(p_tipo, 'no_oficial')::vigilante.tipo_fuente,
      metodo = coalesce(p_metodo, 'http_html')::vigilante.metodo_fuente,
      categorias = ARRAY[p_categoria], frecuencia_minutos = greatest(coalesce(p_frecuencia, 60), 5),
      config = (config - 'propuesta_avia') || jsonb_build_object('revisar_desde', now(), 'que_buscar', nullif(trim(p_que_buscar), ''),
                                            'palabras_clave', to_jsonb(coalesce(p_palabras, '{}')),
                                            'alta_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()))
    WHERE cliente_id = vigilante.cliente_actual() AND codigo = v_borrada;
    RETURN v_borrada;
  END IF;

  -- código legible a partir del nombre: «Defensa Civil» → defensa_civil
  v_base := left(trim(both '_' from regexp_replace(lower(translate(p_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '_', 'g')), 40);
  v_codigo := coalesce(nullif(v_base, ''), 'fuente');
  WHILE EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND codigo = v_codigo) LOOP
    n := n + 1; v_codigo := v_base || '_' || n;
  END LOOP;
  INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, config)
  VALUES (vigilante.cliente_actual(), v_codigo, trim(p_nombre), trim(p_url),
          coalesce(p_tipo, 'no_oficial')::vigilante.tipo_fuente, coalesce(p_metodo, 'http_html')::vigilante.metodo_fuente,
          ARRAY[p_categoria], greatest(coalesce(p_frecuencia, 60), 5),
          jsonb_build_object('que_buscar', nullif(trim(p_que_buscar), ''),
                             'palabras_clave', to_jsonb(coalesce(p_palabras, '{}')),
                             'alta_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()),
                             'estado', 'UNKNOWN'));
  RETURN v_codigo;
END $$;
REVOKE ALL ON FUNCTION vigilante.alta_fuente(text, text, text, text, text, int, text, text[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.alta_fuente(text, text, text, text, text, int, text, text[]) TO authenticated;

-- 4 y 5. Editar
CREATE OR REPLACE FUNCTION vigilante.editar_fuente(p_codigo text, p_nombre text, p_url text, p_categoria text, p_tipo text,
                                                   p_metodo text, p_frecuencia int, p_que_buscar text, p_palabras text[])
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede editar fuentes'; END IF;
  IF coalesce(trim(p_nombre), '') = '' OR p_url !~* '^https?://' THEN RAISE EXCEPTION 'Faltan el nombre o una dirección web válida'; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND codigo <> p_codigo
              AND vigilante.url_normal(url) = vigilante.url_normal(p_url) AND eliminada_en IS NULL) THEN
    RAISE EXCEPTION 'Ya hay una fuente con esa dirección';
  END IF;
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
  VALUES (vigilante.cliente_actual(), p_categoria, p_categoria) ON CONFLICT DO NOTHING;
  UPDATE vigilante.sources SET
    nombre = trim(p_nombre), url = trim(p_url),
    tipo = coalesce(p_tipo, tipo::text)::vigilante.tipo_fuente,
    metodo = coalesce(p_metodo, metodo::text)::vigilante.metodo_fuente,
    categorias = ARRAY[p_categoria], frecuencia_minutos = greatest(coalesce(p_frecuencia, frecuencia_minutos), 5),
    gestionada_web = true,
    config = config || jsonb_build_object('que_buscar', nullif(trim(p_que_buscar), ''),
                                          'palabras_clave', to_jsonb(coalesce(p_palabras, '{}')),
                                          'editada_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()),
                                          'editada_en', now())
             -- si cambia la dirección o la forma de leerla, AVIA la vuelve a tratar como nueva
             || CASE WHEN vigilante.url_normal(url) <> vigilante.url_normal(p_url) OR metodo::text <> coalesce(p_metodo, metodo::text)
                     THEN jsonb_build_object('revisar_desde', now()) ELSE '{}'::jsonb END
  WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % aún no está en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.editar_fuente(text, text, text, text, text, text, int, text, text[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.editar_fuente(text, text, text, text, text, text, int, text, text[]) TO authenticated;

-- 2 y 3. Sincronización desde vigilante.json
CREATE OR REPLACE FUNCTION vigilante.sincronizar_vigilante(p_cliente text, p_json jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid;
  f jsonb; s jsonb;
  v_tipo vigilante.tipo_fuente;
  v_metodo vigilante.metodo_fuente;
  v_estado vigilante.estado_senal;
  v_actual record;
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
    -- una fuente que la base no conoce entra EN PAUSA como propuesta de AVIA: la aprueba un administrador
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias, ultima_consulta_en, notas, config, activa)
    VALUES (v_cliente, f ->> 'id', coalesce(f ->> 'nombre', f ->> 'id'), coalesce(nullif(f ->> 'url', ''), '—'),
            v_tipo, v_metodo, CASE WHEN f ? 'canal' AND f ->> 'canal' IS NOT NULL THEN ARRAY[f ->> 'canal'] ELSE '{}' END,
            (f ->> 'ultima')::timestamptz, f ->> 'info',
            jsonb_build_object('estado', f -> 'estado', 'hist', f -> 'hist', 'items', f -> 'items', 'propuesta_avia', true),
            false)
    ON CONFLICT (cliente_id, codigo) DO UPDATE SET
      -- lo que una persona escribió en la web manda: Hermes solo actualiza el estado de la comprobación
      nombre = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.nombre ELSE EXCLUDED.nombre END,
      url = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.url ELSE EXCLUDED.url END,
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
                              WHEN upper(EXCLUDED.config ->> 'estado') = 'CRIT' THEN vigilante.sources.errores_seguidos + 1
                              WHEN upper(EXCLUDED.config ->> 'estado') IN ('OK', 'WARN') THEN 0
                              ELSE vigilante.sources.errores_seguidos END,
      ultimo_error = CASE WHEN EXCLUDED.ultima_consulta_en IS DISTINCT FROM vigilante.sources.ultima_consulta_en
                           AND EXCLUDED.ultima_consulta_en IS NOT NULL AND upper(EXCLUDED.config ->> 'estado') = 'CRIT' THEN EXCLUDED.notas
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

-- Aprobar o reactivar quita la marca de propuesta
CREATE OR REPLACE FUNCTION vigilante.activar_fuente(p_codigo text, p_activa boolean)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede pausar fuentes'; END IF;
  UPDATE vigilante.sources SET activa = p_activa,
         config = CASE WHEN p_activa THEN (config - 'propuesta_avia')
                       || jsonb_build_object('aprobada_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()))
                       ELSE config END
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % aún no está en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.activar_fuente(text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.activar_fuente(text, boolean) TO authenticated;

-- La web: añade propuesta, fallos seguidos, último éxito y último error
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz,
               propuesta boolean, errores_seguidos int, ultimo_exito_en timestamptz, ultimo_error text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz,
         coalesce((config ->> 'propuesta_avia')::boolean, false), errores_seguidos, ultimo_exito_en, ultimo_error
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

COMMIT;
