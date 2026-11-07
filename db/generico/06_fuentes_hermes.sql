-- =============================================================================
-- AVIA Vigilante · Fuentes: la web las gestiona, Hermes las lee
-- Requiere 01, 03 y 04. Se puede ejecutar más de una vez.
--
-- Circuito:
--   1. Un administrador o analista da de alta, pausa o reactiva una fuente en la web
--      → vigilante.sources (activa, config con «qué buscar» y palabras clave).
--   2. Antes de cada ronda, Hermes pide la lista con vigilante.fuentes_para_hermes(slug)
--      (herramienta hermes/herramientas/fuentes_activas.sh) y vigila SOLO esas.
--   3. Hermes publica vigilante.json usando el mismo código de fuente; la sincronización
--      (04) actualiza la última comprobación y el estado de cada fuente.
-- =============================================================================

BEGIN;

-- Lista de fuentes activas, con todo lo que Hermes necesita para vigilarlas
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
        'nueva', s.ultima_consulta_en IS NULL,
        'ultima_consulta_en', s.ultima_consulta_en,
        'alta_por', s.config ->> 'alta_por'
      ) ORDER BY s.ultima_consulta_en NULLS FIRST, s.nombre) FILTER (WHERE s.id IS NOT NULL), '[]'::jsonb)
  )
  FROM vigilante.clientes c
  LEFT JOIN vigilante.sources s ON s.cliente_id = c.id AND s.activa
  WHERE c.slug = p_cliente AND c.activo
  GROUP BY c.slug
$$;
REVOKE ALL ON FUNCTION vigilante.fuentes_para_hermes(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_para_hermes(text) TO service_role;

-- La web: fuentes de la base (incluidas las que Hermes aún no ha comprobado nunca)
CREATE OR REPLACE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por'
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

-- Alta de una fuente desde la web (analista o administrador)
CREATE OR REPLACE FUNCTION vigilante.alta_fuente(p_nombre text, p_url text, p_categoria text, p_tipo text,
                                                 p_metodo text, p_frecuencia int, p_que_buscar text,
                                                 p_palabras text[])
RETURNS text LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
DECLARE v_codigo text; v_base text; n int := 1;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede añadir fuentes'; END IF;
  IF coalesce(trim(p_nombre), '') = '' OR p_url !~* '^https?://' THEN RAISE EXCEPTION 'Faltan el nombre o una dirección web válida'; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND lower(url) = lower(trim(p_url))) THEN
    RAISE EXCEPTION 'Ya hay una fuente con esa dirección';
  END IF;
  -- código legible a partir del nombre: «Defensa Civil» → defensa_civil
  v_base := left(trim(both '_' from regexp_replace(lower(translate(p_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '_', 'g')), 40);
  v_codigo := coalesce(nullif(v_base, ''), 'fuente');
  WHILE EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND codigo = v_codigo) LOOP
    n := n + 1; v_codigo := v_base || '_' || n;
  END LOOP;
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
  VALUES (vigilante.cliente_actual(), p_categoria, p_categoria) ON CONFLICT DO NOTHING;
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

-- Pausar o reactivar (mantenimiento): Hermes deja de vigilarla mientras esté pausada
CREATE OR REPLACE FUNCTION vigilante.activar_fuente(p_codigo text, p_activa boolean)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede pausar fuentes'; END IF;
  UPDATE vigilante.sources SET activa = p_activa WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % aún no está en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.activar_fuente(text, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.activar_fuente(text, boolean) TO authenticated;

COMMIT;
