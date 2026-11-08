-- =============================================================================
-- AVIA Vigilante · Editar fuentes desde la web
-- Requiere 01, 03, 04, 06 y 07. Se puede ejecutar más de una vez.
--
--   * sources.gestionada_web = true cuando una persona dio de alta o editó la fuente en la web.
--     Desde ese momento la sincronización con vigilante.json ya no le cambia el nombre,
--     la dirección, el tipo ni el canal: Hermes solo informa del resultado de la comprobación.
--   * vigilante.editar_fuente(...) → analista o administrador.
--   * vigilante.fuentes_web() devuelve también palabras clave, alta y última edición.
-- =============================================================================

BEGIN;

ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS gestionada_web boolean NOT NULL DEFAULT false;
UPDATE vigilante.sources SET gestionada_web = true WHERE NOT gestionada_web AND config ->> 'alta_por' IS NOT NULL;

-- las altas desde la web quedan marcadas solas
CREATE OR REPLACE FUNCTION vigilante.tg_fuente_gestionada_web()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.config ->> 'alta_por' IS NOT NULL THEN NEW.gestionada_web := true; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_fuente_gestionada_web ON vigilante.sources;
CREATE TRIGGER b_fuente_gestionada_web BEFORE INSERT OR UPDATE ON vigilante.sources
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_fuente_gestionada_web();

-- Sincronización (igual que en 04, pero respetando lo que se editó en la web)
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
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias, ultima_consulta_en, notas, config)
    VALUES (v_cliente, f ->> 'id', coalesce(f ->> 'nombre', f ->> 'id'), coalesce(nullif(f ->> 'url', ''), '—'),
            v_tipo, v_metodo, CASE WHEN f ? 'canal' AND f ->> 'canal' IS NOT NULL THEN ARRAY[f ->> 'canal'] ELSE '{}' END,
            (f ->> 'ultima')::timestamptz, f ->> 'info',
            jsonb_build_object('estado', f -> 'estado', 'hist', f -> 'hist', 'items', f -> 'items'))
    ON CONFLICT (cliente_id, codigo) DO UPDATE SET
      -- lo que una persona escribió en la web manda: Hermes solo actualiza el estado de la comprobación
      nombre = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.nombre ELSE EXCLUDED.nombre END,
      url = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.url ELSE EXCLUDED.url END,
      tipo = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.tipo ELSE EXCLUDED.tipo END,
      categorias = CASE WHEN vigilante.sources.gestionada_web THEN vigilante.sources.categorias ELSE EXCLUDED.categorias END,
      ultima_consulta_en = EXCLUDED.ultima_consulta_en,
      notas = EXCLUDED.notas, config = vigilante.sources.config || EXCLUDED.config;
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

-- La web: todo lo que hace falta para ver y editar una fuente
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

-- Editar una fuente (analista o administrador)
CREATE OR REPLACE FUNCTION vigilante.editar_fuente(p_codigo text, p_nombre text, p_url text, p_categoria text, p_tipo text,
                                                   p_metodo text, p_frecuencia int, p_que_buscar text, p_palabras text[])
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede editar fuentes'; END IF;
  IF coalesce(trim(p_nombre), '') = '' OR p_url !~* '^https?://' THEN RAISE EXCEPTION 'Faltan el nombre o una dirección web válida'; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND codigo <> p_codigo
              AND lower(url) = lower(trim(p_url)) AND eliminada_en IS NULL) THEN
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
  WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % aún no está en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.editar_fuente(text, text, text, text, text, text, int, text, text[]) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.editar_fuente(text, text, text, text, text, text, int, text, text[]) TO authenticated;

COMMIT;
