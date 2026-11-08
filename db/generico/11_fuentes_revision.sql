-- =============================================================================
-- AVIA Vigilante · Fuentes: fallos que sí cuentan y «pedir a AVIA que la revise»
-- Requiere 01 y 06 a 10. Se puede ejecutar más de una vez.
--
--   * En el vigilante.json real, AVIA marca «UNKNOWN» cuando no puede leer una fuente.
--     Desde aquí, una comprobación nueva en CRIT o en UNKNOWN cuenta como fallo seguido.
--   * vigilante.pedir_revision(codigo) → analista o administrador. La fuente vuelve a llegar
--     a Hermes como «nueva» y la revisa en su siguiente ronda, sin esperar a su frecuencia.
--     Queda en la Bitácora.
-- =============================================================================

BEGIN;

-- Sincronización (igual que en 09, contando UNKNOWN como fallo)
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

-- La Bitácora admite la acción «revision»
ALTER TABLE vigilante.source_events DROP CONSTRAINT IF EXISTS source_events_accion_check;
ALTER TABLE vigilante.source_events ADD CONSTRAINT source_events_accion_check
  CHECK (accion IN ('alta', 'editada', 'pausada', 'reactivada', 'aprobada', 'eliminada', 'recuperada', 'reconocida', 'revision'));

CREATE OR REPLACE FUNCTION vigilante.tg_bitacora_fuente()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_quien text; v_accion text; v_detalle text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  IF v_quien IS NULL THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    v_accion := 'alta'; v_detalle := NEW.url;
  ELSIF OLD.eliminada_en IS NULL AND NEW.eliminada_en IS NOT NULL THEN
    v_accion := 'eliminada';
  ELSIF OLD.eliminada_en IS NOT NULL AND NEW.eliminada_en IS NULL THEN
    v_accion := 'recuperada'; v_detalle := NEW.url;
  ELSIF NOT OLD.activa AND NEW.activa THEN
    v_accion := CASE WHEN OLD.config ? 'propuesta_avia' THEN 'aprobada' ELSE 'reactivada' END;
  ELSIF OLD.activa AND NOT NEW.activa THEN
    v_accion := 'pausada';
  ELSIF (NEW.config ->> 'revision_pedida_en') IS DISTINCT FROM (OLD.config ->> 'revision_pedida_en') AND NEW.config ? 'revision_pedida_en' THEN
    v_accion := 'revision';
  ELSIF (NEW.config ->> 'reconocida_en') IS DISTINCT FROM (OLD.config ->> 'reconocida_en') AND NEW.config ? 'reconocida_en' THEN
    v_accion := 'reconocida'; v_detalle := nullif(NEW.config ->> 'reconocida_nota', '');
  ELSIF (NEW.nombre, NEW.url, NEW.tipo, NEW.metodo, NEW.categorias, NEW.frecuencia_minutos,
         NEW.config -> 'que_buscar', NEW.config -> 'palabras_clave')
        IS DISTINCT FROM
        (OLD.nombre, OLD.url, OLD.tipo, OLD.metodo, OLD.categorias, OLD.frecuencia_minutos,
         OLD.config -> 'que_buscar', OLD.config -> 'palabras_clave') THEN
    v_accion := 'editada';
    v_detalle := concat_ws(', ',
      CASE WHEN NEW.nombre <> OLD.nombre THEN 'nombre' END,
      CASE WHEN NEW.url <> OLD.url THEN 'dirección' END,
      CASE WHEN NEW.metodo <> OLD.metodo THEN 'cómo se lee' END,
      CASE WHEN NEW.frecuencia_minutos <> OLD.frecuencia_minutos THEN 'frecuencia' END,
      CASE WHEN NEW.categorias <> OLD.categorias THEN 'canal' END,
      CASE WHEN NEW.tipo <> OLD.tipo THEN 'tipo' END,
      CASE WHEN (NEW.config -> 'que_buscar') IS DISTINCT FROM (OLD.config -> 'que_buscar') THEN 'qué buscar' END,
      CASE WHEN (NEW.config -> 'palabras_clave') IS DISTINCT FROM (OLD.config -> 'palabras_clave') THEN 'palabras clave' END);
  ELSE
    RETURN NULL;
  END IF;

  INSERT INTO vigilante.source_events (cliente_id, source_id, codigo, nombre, accion, quien, detalle)
  VALUES (NEW.cliente_id, NEW.id, NEW.codigo, NEW.nombre, v_accion, v_quien, v_detalle);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS z_bitacora_fuente ON vigilante.sources;
CREATE TRIGGER z_bitacora_fuente AFTER INSERT OR UPDATE ON vigilante.sources
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_bitacora_fuente();

-- Pedir a AVIA que revise una fuente en su siguiente ronda
CREATE OR REPLACE FUNCTION vigilante.pedir_revision(p_codigo text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede pedir una revisión'; END IF;
  UPDATE vigilante.sources SET config = config || jsonb_build_object(
           'revisar_desde', now(), 'revision_pedida_en', now(),
           'revision_pedida_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()))
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL AND activa;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % no está activa en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.pedir_revision(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.pedir_revision(text) TO authenticated;

-- La web: añade cuándo y quién pidió la última revisión
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz,
               propuesta boolean, errores_seguidos int, ultimo_exito_en timestamptz, ultimo_error text,
               reconocida_por text, reconocida_en timestamptz, reconocida_nota text,
               revision_pedida_en timestamptz, revision_pedida_por text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz,
         coalesce((config ->> 'propuesta_avia')::boolean, false), errores_seguidos, ultimo_exito_en, ultimo_error,
         config ->> 'reconocida_por', (config ->> 'reconocida_en')::timestamptz, config ->> 'reconocida_nota',
         (config ->> 'revision_pedida_en')::timestamptz, config ->> 'revision_pedida_por'
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

COMMIT;
