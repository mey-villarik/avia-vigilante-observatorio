-- =============================================================================
-- AVIA Vigilante · Llevar vigilante.json (lo que publica Hermes) a las tablas
-- y guardar las decisiones de las personas sobre las señales.
-- Requiere 01 y 03. Se puede ejecutar más de una vez.
--
--   * signals.codigo     = el código SEN-xxxx de Hermes (único por cliente)
--   * signals.estado_manual = true cuando una persona movió la señal desde la web;
--     a partir de ahí la sincronización ya no le cambia el estado.
--   * vigilante.sincronizar_vigilante(slug, json)  → la llama el VPS con service_role
--   * vigilante.mover_senal(codigo, estado, nota)  → la llama la web (analista o administrador)
-- =============================================================================

BEGIN;

ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS codigo text;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS estado_manual boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS signals_cliente_codigo_uk ON vigilante.signals (cliente_id, codigo);

-- -----------------------------------------------------------------------------
-- 1. Sincronización desde vigilante.json
-- -----------------------------------------------------------------------------
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
      nombre = EXCLUDED.nombre, url = EXCLUDED.url, tipo = EXCLUDED.tipo,
      categorias = EXCLUDED.categorias, ultima_consulta_en = EXCLUDED.ultima_consulta_en,
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

-- -----------------------------------------------------------------------------
-- 2. Una persona mueve una señal (la web). Se ejecuta con los permisos de quien llama:
--    las reglas RLS exigen analista o administrador del mismo cliente.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.mover_senal(p_codigo text, p_estado text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint; v_de vigilante.estado_senal; v_a vigilante.estado_senal;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede mover señales'; END IF;
  BEGIN v_a := p_estado::vigilante.estado_senal;
  EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION 'Estado no válido: %', p_estado; END;

  SELECT id, estado INTO v_id, v_de FROM vigilante.signals
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo FOR UPDATE;
  IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % aún no está en la base de datos', p_codigo; END IF;
  IF NOT vigilante.transicion_valida(v_de, v_a) THEN
    RAISE EXCEPTION 'No se puede pasar de % a %', v_de, v_a;
  END IF;

  UPDATE vigilante.signals SET estado = v_a, estado_manual = true WHERE id = v_id;
  UPDATE vigilante.signal_history SET nota = nullif(trim(p_nota), '')
   WHERE id = (SELECT max(id) FROM vigilante.signal_history WHERE signal_id = v_id);
  RETURN jsonb_build_object('codigo', p_codigo, 'de', v_de, 'a', v_a);
END $$;
REVOKE ALL ON FUNCTION vigilante.mover_senal(text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.mover_senal(text, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Lectura para la web: estado actual y últimos movimientos hechos por personas
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.estados_senales()
RETURNS TABLE (codigo text, estado vigilante.estado_senal, estado_manual boolean)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, estado, estado_manual FROM vigilante.signals
   WHERE cliente_id = vigilante.cliente_actual() AND codigo IS NOT NULL
$$;
GRANT EXECUTE ON FUNCTION vigilante.estados_senales() TO authenticated;

CREATE OR REPLACE FUNCTION vigilante.movimientos_senales(p_limite int DEFAULT 50)
RETURNS TABLE (cuando timestamptz, codigo text, titulo text, de vigilante.estado_senal, a vigilante.estado_senal,
               quien text, nota text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT h.created_at, s.codigo, s.titulo, h.estado_anterior, h.estado_nuevo,
         coalesce(u.nombre, 'Persona'), h.nota
    FROM vigilante.signal_history h
    JOIN vigilante.signals s ON s.id = h.signal_id
    LEFT JOIN vigilante.users u ON u.auth_user_id::text = h.actor
   WHERE h.cliente_id = vigilante.cliente_actual()
     AND vigilante.usuario_actual() IS NOT NULL
     AND h.actor NOT LIKE 'hermes:%' AND h.actor NOT IN ('postgres', 'service_role', 'supabase_admin')
     AND h.estado_anterior IS DISTINCT FROM h.estado_nuevo
   ORDER BY h.created_at DESC
   LIMIT least(greatest(p_limite, 1), 200)
$$;
REVOKE ALL ON FUNCTION vigilante.movimientos_senales(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.movimientos_senales(int) TO authenticated;

COMMIT;
