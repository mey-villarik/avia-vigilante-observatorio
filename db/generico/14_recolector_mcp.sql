-- =============================================================================
-- AVIA Vigilante · Recolector sin IA + herramientas de AVIA (MCP propio)
-- Requiere 01 y 03 a 12. Se puede ejecutar más de una vez.
--
-- Diseño acordado con Meysel (2026-11-08):
--   * Un script en el VPS (hermes/recolector/recolector.py) lee las fuentes SIN IA y guarda aquí
--     solo lo nuevo (vigilante.raw_items). Apify solo para lo que el script no puede leer, con tope
--     de gasto al mes.
--   * Un filtro en SQL puntúa cada noticia (palabras clave, territorio, palabras de oportunidad y
--     de alerta) y descarta el ruido antes de que llegue a la IA.
--   * AVIA (motor Hermes) es la inteligencia: con el MCP propio (hermes/mcp-vigilante) toma las
--     noticias pendientes, guarda señales, pide búsquedas extra y PROPONE con qué se lee cada fuente.
--     El administrador aprueba la propuesta en la web.
--
-- Funciones para el VPS y para AVIA (solo service_role):
--   fuentes_para_recolector · guardar_comprobacion · tomar_busquedas · guardar_busqueda
--   noticias_pendientes · marcar_noticias · guardar_senal · buscar_senales · estado_fuentes
--   proponer_metodo · pedir_busqueda · metricas_oportunidades · alertas_tempranas · registrar_log
-- Funciones para la web (equipo con sesión):
--   vigilante_bd · propuestas_web · decidir_propuesta (solo administrador)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Noticias recogidas: puntaje previo, título normalizado y búsquedas pedidas por AVIA
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.busquedas (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id    uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  consulta      text NOT NULL CHECK (length(trim(consulta)) BETWEEN 2 AND 300),
  via           text NOT NULL DEFAULT 'script' CHECK (via IN ('script', 'apify')),
  parametros    jsonb NOT NULL DEFAULT '{}',          -- actor e input de Apify, días hacia atrás...
  motivo        text,
  pedido_por    text NOT NULL DEFAULT 'avia',
  estado        text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'en_curso', 'hecha', 'fallida')),
  noticias      integer,
  error         text,
  costo_usd     numeric(10,4),
  created_at    timestamptz NOT NULL DEFAULT now(),
  empezada_en   timestamptz,
  terminada_en  timestamptz
);
CREATE INDEX IF NOT EXISTS busquedas_cola_idx ON vigilante.busquedas (cliente_id, estado, created_at);

-- una noticia viene de una fuente o de una búsqueda pedida por AVIA
ALTER TABLE vigilante.raw_items ALTER COLUMN source_id DROP NOT NULL;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS busqueda_id bigint REFERENCES vigilante.busquedas(id) ON DELETE SET NULL;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS titulo_norm text;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS puntaje_previo smallint;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS motivos text[] NOT NULL DEFAULT '{}';
ALTER TABLE vigilante.raw_items DROP CONSTRAINT IF EXISTS raw_items_origen;
ALTER TABLE vigilante.raw_items ADD CONSTRAINT raw_items_origen CHECK (source_id IS NOT NULL OR busqueda_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS raw_items_titulo_norm_idx ON vigilante.raw_items (cliente_id, titulo_norm, recolectado_en DESC);
CREATE INDEX IF NOT EXISTS raw_items_pendientes_idx ON vigilante.raw_items (cliente_id, puntaje_previo DESC) WHERE estado IN ('nuevo', 'en_cola');

-- -----------------------------------------------------------------------------
-- 2. Propuestas de AVIA sobre cómo leer una fuente (las aprueba el administrador)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.source_proposals (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id        uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  source_id         integer NOT NULL REFERENCES vigilante.sources(id) ON DELETE CASCADE,
  metodo_actual     vigilante.metodo_fuente NOT NULL,
  metodo_propuesto  vigilante.metodo_fuente NOT NULL,
  config            jsonb NOT NULL DEFAULT '{}',      -- p. ej. {"apify_actor": "...", "apify_input": {...}} o {"query": "..."}
  motivo            text NOT NULL,
  propuesta_por     text NOT NULL DEFAULT 'AVIA',
  estado            text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aprobada', 'rechazada')),
  decidida_por      text,
  decidida_en       timestamptz,
  nota              text,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS source_proposals_una_pendiente ON vigilante.source_proposals (source_id) WHERE estado = 'pendiente';

-- Permisos: el equipo lee; solo se escribe con las funciones de abajo
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['busquedas', 'source_proposals'] LOOP
    EXECUTE format('ALTER TABLE vigilante.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS equipo_lee ON vigilante.%I', t);
    EXECUTE format('CREATE POLICY equipo_lee ON vigilante.%I FOR SELECT TO authenticated USING (cliente_id = vigilante.cliente_actual())', t);
    EXECUTE format('REVOKE ALL ON vigilante.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON vigilante.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON vigilante.%I TO service_role', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Parámetros (valores de la plataforma; cada cliente los puede sobrescribir)
-- -----------------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'umbral_previo', '30', 'Puntaje mínimo (0-100) para que una noticia llegue a AVIA; por debajo se descarta sin IA'),
  (NULL, 'apify_tope_usd_mes', '0', 'Gasto máximo en Apify al mes en USD. 0 = Apify desactivado'),
  (NULL, 'busquedas_max_dia', '20', 'Búsquedas extra que AVIA puede pedir al día'),
  (NULL, 'palabras_oportunidad',
   '["convocatoria", "fondo", "financiamiento", "financiación", "subvención", "licitación", "inversión", "festival", "feria", "congreso", "evento", "carnaval", "temporada", "nueva ruta", "nuevo vuelo", "inauguración", "apertura", "récord", "declaratoria", "patrimonio", "premio"]',
   'Palabras que suben el puntaje como posible oportunidad (propuesta inicial, editable)'),
  (NULL, 'palabras_alerta',
   '["alerta roja", "alerta naranja", "emergencia", "desastre", "bloqueo", "cierre", "suspensión", "suspendido", "cancelado", "epidemia", "brote", "inundación", "incendio", "deslizamiento", "huelga", "paro", "conflicto"]',
   'Palabras que suben el puntaje como posible riesgo o alerta temprana (propuesta inicial, editable)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 4. Utilidades
-- -----------------------------------------------------------------------------
-- minúsculas, sin tildes y sin signos: para comparar textos
CREATE OR REPLACE FUNCTION vigilante.texto_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(translate(lower(coalesce(p, '')), 'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'),
                             '[^a-z0-9]+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION vigilante.lista_param(p_cliente uuid, p_clave text)
RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(ARRAY(SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(
           CASE WHEN jsonb_typeof(vigilante.param(p_cliente, p_clave)) = 'array' THEN vigilante.param(p_cliente, p_clave) ELSE '[]' END) x
         WHERE vigilante.texto_norm(x) <> ''), '{}')
$$;

-- ¿aparece la palabra o frase dentro del texto normalizado? (palabra completa)
CREATE OR REPLACE FUNCTION vigilante.contiene(p_texto_norm text, p_frase_norm text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_frase_norm <> '' AND (' ' || p_texto_norm || ' ') LIKE ('% ' || p_frase_norm || ' %')
$$;

CREATE OR REPLACE FUNCTION vigilante.id_cliente(p_cliente text)
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM vigilante.clientes WHERE slug = p_cliente AND activo;
  IF v IS NULL THEN RAISE EXCEPTION 'Cliente % no existe o no está activo', p_cliente; END IF;
  RETURN v;
END $$;

-- Gasto de Apify en el mes en curso y lo que queda del tope
CREATE OR REPLACE FUNCTION vigilante.apify_disponible(p_cliente uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT greatest(coalesce((vigilante.param(p_cliente, 'apify_tope_usd_mes') #>> '{}')::numeric, 0)
         - coalesce((SELECT sum(costo_usd) FROM vigilante.system_logs
                      WHERE cliente_id = p_cliente AND proceso = 'apify'
                        AND created_at >= date_trunc('month', now())), 0), 0)
$$;

-- -----------------------------------------------------------------------------
-- 5. Guardar noticias con filtro previo (sin IA)
-- -----------------------------------------------------------------------------
-- p_items: [{"titulo": "...", "url": "...", "resumen": "...", "publicado_en": "ISO", "extra": {...}}]
CREATE OR REPLACE FUNCTION vigilante.insertar_noticias(p_cliente uuid, p_source_id integer, p_busqueda_id bigint,
                                                       p_items jsonb, p_ejecucion text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  it jsonb; v_src vigilante.sources;
  v_titulo text; v_url text; v_resumen text; v_norm text; v_texto text; v_pub timestamptz;
  v_kw text[]; v_opp text[]; v_alerta text[]; v_umbral int; v_ter record;
  v_puntaje int; v_motivos text[]; v_ters int[]; v_estado vigilante.estado_raw; v_frase text; v_id bigint;
  n_nuevas int := 0; n_desc int := 0; n_rep int := 0;
BEGIN
  IF p_source_id IS NOT NULL THEN SELECT * INTO v_src FROM vigilante.sources WHERE id = p_source_id; END IF;
  v_kw := CASE WHEN jsonb_typeof(v_src.config -> 'palabras_clave') = 'array'
               THEN ARRAY(SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_src.config -> 'palabras_clave') x
                          WHERE vigilante.texto_norm(x) <> '')
               ELSE '{}' END;
  v_opp := vigilante.lista_param(p_cliente, 'palabras_oportunidad');
  v_alerta := vigilante.lista_param(p_cliente, 'palabras_alerta');
  v_umbral := coalesce((vigilante.param(p_cliente, 'umbral_previo') #>> '{}')::int, 30);

  FOR it IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]' END) LOOP
    v_titulo := left(nullif(trim(it ->> 'titulo'), ''), 500);
    v_url := nullif(trim(it ->> 'url'), '');
    CONTINUE WHEN v_titulo IS NULL OR v_url IS NULL;
    v_resumen := left(nullif(trim(it ->> 'resumen'), ''), 4000);
    v_norm := vigilante.texto_norm(v_titulo);
    v_pub := CASE WHEN (it ->> 'publicado_en') ~ '^\d{4}-\d{2}-\d{2}' THEN (it ->> 'publicado_en')::timestamptz END;

    -- ya la tenemos (misma dirección, o mismo título de la misma fuente)
    IF EXISTS (SELECT 1 FROM vigilante.raw_items WHERE cliente_id = p_cliente AND url = v_url) THEN
      n_rep := n_rep + 1; CONTINUE;
    END IF;

    v_texto := v_norm || ' ' || vigilante.texto_norm(v_resumen);
    v_puntaje := 10; v_motivos := '{}'; v_ters := '{}';
    IF v_src.tipo IN ('oficial', 'organismo_internacional') THEN
      v_puntaje := v_puntaje + 15; v_motivos := v_motivos || 'fuente oficial'::text;
    END IF;
    FOREACH v_frase IN ARRAY v_kw LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 30; v_motivos := v_motivos || ('palabra clave: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    FOR v_ter IN SELECT id, nombre, datos FROM vigilante.territorios WHERE cliente_id = p_cliente AND nivel <> 'pais' LOOP
      IF vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.nombre))
         OR vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.datos ->> 'capital'))
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_ter.datos -> 'alias') = 'array' THEN v_ter.datos -> 'alias' ELSE '[]' END) a
                     WHERE vigilante.contiene(v_texto, vigilante.texto_norm(a))) THEN
        v_ters := v_ters || v_ter.id;
      END IF;
    END LOOP;
    IF cardinality(v_ters) > 0 THEN v_puntaje := v_puntaje + 25; v_motivos := v_motivos || 'menciona un territorio'::text; END IF;
    FOREACH v_frase IN ARRAY v_alerta LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 30; v_motivos := v_motivos || ('alerta: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    FOREACH v_frase IN ARRAY v_opp LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 20; v_motivos := v_motivos || ('oportunidad: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    -- lo que pidió AVIA en una búsqueda ya viene filtrado por su consulta
    IF p_busqueda_id IS NOT NULL THEN v_puntaje := v_puntaje + 20; v_motivos := v_motivos || 'búsqueda pedida por AVIA'::text; END IF;
    v_puntaje := least(v_puntaje, 100);
    v_estado := CASE WHEN v_puntaje >= v_umbral THEN 'nuevo' ELSE 'descartado' END;

    INSERT INTO vigilante.raw_items (cliente_id, source_id, busqueda_id, url, content_hash, titulo, contenido, publicado_en,
                                     menciona_territorio, territorios_detectados, estado, motivo_descarte, ejecucion,
                                     payload, titulo_norm, puntaje_previo, motivos)
    VALUES (p_cliente, p_source_id, p_busqueda_id, v_url,
            encode(sha256(convert_to(coalesce(p_source_id::text, 'b' || p_busqueda_id) || '|' || v_norm, 'UTF8')), 'hex'),
            v_titulo, v_resumen, v_pub, cardinality(v_ters) > 0, v_ters, v_estado,
            CASE WHEN v_estado = 'descartado' THEN format('puntaje previo %s < %s', v_puntaje, v_umbral) END,
            p_ejecucion, coalesce(it -> 'extra', '{}'), v_norm, v_puntaje, v_motivos)
    ON CONFLICT (cliente_id, content_hash) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN n_rep := n_rep + 1;
    ELSIF v_estado = 'nuevo' THEN n_nuevas := n_nuevas + 1;
    ELSE n_desc := n_desc + 1; END IF;
    v_id := NULL;
  END LOOP;
  RETURN jsonb_build_object('nuevas', n_nuevas, 'descartadas', n_desc, 'repetidas', n_rep);
END $$;

-- Lista de fuentes para el recolector: cuáles toca leer ahora y cómo
CREATE OR REPLACE FUNCTION vigilante.fuentes_para_recolector(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'generado', now(),
    'apify_disponible_usd', vigilante.apify_disponible(c.id),
    'fuentes', coalesce(jsonb_agg(jsonb_build_object(
        'codigo', s.codigo, 'nombre', s.nombre, 'url', s.url, 'tipo', s.tipo, 'metodo', s.metodo,
        'frecuencia_minutos', s.frecuencia_minutos,
        'palabras_clave', coalesce(s.config -> 'palabras_clave', '[]'::jsonb),
        'que_buscar', s.config ->> 'que_buscar',
        'query', coalesce(s.config ->> 'query', s.config ->> 'q'),
        'config', s.config - 'hist' - 'items' - 'estado',
        'apify_actor', s.config ->> 'apify_actor',
        'apify_input', s.config -> 'apify_input',
        'huella', s.config ->> 'huella',
        'nueva', s.ultima_consulta_en IS NULL OR s.ultima_consulta_en < (s.config ->> 'revisar_desde')::timestamptz,
        'toca', s.ultima_consulta_en IS NULL
                OR s.ultima_consulta_en < (s.config ->> 'revisar_desde')::timestamptz
                OR s.ultima_consulta_en <= now() - make_interval(mins => greatest(s.frecuencia_minutos - 2, 3))
      ) ORDER BY s.ultima_consulta_en NULLS FIRST) FILTER (WHERE s.id IS NOT NULL), '[]'::jsonb)
  )
  FROM vigilante.clientes c
  LEFT JOIN vigilante.sources s ON s.cliente_id = c.id AND s.activa AND s.eliminada_en IS NULL
  WHERE c.slug = p_cliente AND c.activo
  GROUP BY c.id, c.slug
$$;

-- El recolector informa de una comprobación: estado de la fuente + noticias leídas
CREATE OR REPLACE FUNCTION vigilante.guardar_comprobacion(p_cliente text, p_codigo text, p_estado text, p_info text,
                                                          p_items jsonb DEFAULT '[]', p_huella text DEFAULT NULL,
                                                          p_ejecucion text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_src vigilante.sources; v_est text := upper(coalesce(p_estado, ''));
        r jsonb; v_hist jsonb;
BEGIN
  IF v_est NOT IN ('OK', 'WARN', 'CRIT') THEN RAISE EXCEPTION 'Estado % no válido (OK, WARN o CRIT)', p_estado; END IF;
  SELECT * INTO v_src FROM vigilante.sources WHERE cliente_id = v_cliente AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % no existe', p_codigo; END IF;
  PERFORM set_config('vigilante.actor', 'recolector', true);

  r := CASE WHEN v_est = 'CRIT' THEN jsonb_build_object('nuevas', 0, 'descartadas', 0, 'repetidas', 0)
            ELSE vigilante.insertar_noticias(v_cliente, v_src.id, NULL, p_items, p_ejecucion) END;
  v_hist := (SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') FROM (
               SELECT x, o FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_src.config -> 'hist') = 'array'
                                                          THEN v_src.config -> 'hist' ELSE '[]' END) WITH ORDINALITY AS h(x, o)
               ORDER BY o DESC LIMIT 11) t) || to_jsonb(v_est);

  UPDATE vigilante.sources SET
    ultima_consulta_en = now(),
    ultimo_exito_en = CASE WHEN v_est IN ('OK', 'WARN') THEN now() ELSE ultimo_exito_en END,
    errores_seguidos = CASE WHEN v_est = 'CRIT' THEN errores_seguidos + 1 ELSE 0 END,
    ultimo_error = CASE WHEN v_est = 'CRIT' THEN p_info ELSE ultimo_error END,
    notas = p_info,
    config = config || jsonb_strip_nulls(jsonb_build_object(
               'estado', v_est, 'items', (r ->> 'nuevas')::int, 'hist', v_hist,
               'huella', p_huella, 'leida_por', 'recolector'))
  WHERE id = v_src.id;
  RETURN r;
END $$;

-- -----------------------------------------------------------------------------
-- 6. Búsquedas extra que pide AVIA (las ejecuta el recolector o Apify)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.pedir_busqueda(p_cliente text, p_consulta text, p_via text DEFAULT 'script',
                                                    p_parametros jsonb DEFAULT '{}', p_motivo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_max int; v_hoy int; v_id bigint;
BEGIN
  v_max := coalesce((vigilante.param(v_cliente, 'busquedas_max_dia') #>> '{}')::int, 20);
  SELECT count(*) INTO v_hoy FROM vigilante.busquedas WHERE cliente_id = v_cliente AND created_at >= now() - interval '24 hours';
  IF v_hoy >= v_max THEN
    RETURN jsonb_build_object('ok', false, 'motivo', format('Ya se pidieron %s búsquedas en 24 horas (máximo %s)', v_hoy, v_max));
  END IF;
  IF p_via = 'apify' AND vigilante.apify_disponible(v_cliente) <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Apify desactivado o sin saldo este mes: usa via = script');
  END IF;
  -- no repetir la misma consulta pendiente
  SELECT id INTO v_id FROM vigilante.busquedas
   WHERE cliente_id = v_cliente AND estado IN ('pendiente', 'en_curso') AND vigilante.texto_norm(consulta) = vigilante.texto_norm(p_consulta);
  IF v_id IS NOT NULL THEN RETURN jsonb_build_object('ok', true, 'id', v_id, 'motivo', 'Ya estaba en la cola'); END IF;
  INSERT INTO vigilante.busquedas (cliente_id, consulta, via, parametros, motivo)
  VALUES (v_cliente, trim(p_consulta), coalesce(p_via, 'script'), coalesce(p_parametros, '{}'), p_motivo)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION vigilante.tomar_busquedas(p_cliente text, p_limite int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  -- las que se quedaron colgadas más de 1 hora vuelven a la cola
  UPDATE vigilante.busquedas SET estado = 'pendiente'
   WHERE cliente_id = v_cliente AND estado = 'en_curso' AND empezada_en < now() - interval '1 hour';
  WITH t AS (
    SELECT id FROM vigilante.busquedas WHERE cliente_id = v_cliente AND estado = 'pendiente'
     ORDER BY created_at LIMIT greatest(p_limite, 1) FOR UPDATE SKIP LOCKED
  ), u AS (
    UPDATE vigilante.busquedas b SET estado = 'en_curso', empezada_en = now() FROM t WHERE b.id = t.id
    RETURNING b.id, b.consulta, b.via, b.parametros
  )
  SELECT coalesce(jsonb_agg(to_jsonb(u) ORDER BY id), '[]') INTO v FROM u;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION vigilante.guardar_busqueda(p_cliente text, p_id bigint, p_ok boolean, p_info text DEFAULT NULL,
                                                      p_items jsonb DEFAULT '[]', p_costo_usd numeric DEFAULT NULL,
                                                      p_ejecucion text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); r jsonb := '{"nuevas": 0}';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vigilante.busquedas WHERE id = p_id AND cliente_id = v_cliente) THEN
    RAISE EXCEPTION 'La búsqueda % no existe', p_id;
  END IF;
  IF p_ok THEN r := vigilante.insertar_noticias(v_cliente, NULL, p_id, p_items, p_ejecucion); END IF;
  UPDATE vigilante.busquedas SET estado = CASE WHEN p_ok THEN 'hecha' ELSE 'fallida' END,
         noticias = (r ->> 'nuevas')::int, error = CASE WHEN p_ok THEN NULL ELSE p_info END,
         costo_usd = p_costo_usd, terminada_en = now()
   WHERE id = p_id;
  RETURN r;
END $$;

-- Registro de lo que hace el sistema (y de lo que cuesta: Apify, tokens...)
CREATE OR REPLACE FUNCTION vigilante.registrar_log(p_cliente text, p_proceso text, p_nivel text, p_mensaje text,
                                                   p_detalle jsonb DEFAULT NULL, p_costo_usd numeric DEFAULT NULL,
                                                   p_codigo_fuente text DEFAULT NULL)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  INSERT INTO vigilante.system_logs (cliente_id, nivel, proceso, source_id, mensaje, detalle, costo_usd)
  SELECT c.id, CASE WHEN p_nivel IN ('debug', 'info', 'warn', 'error') THEN p_nivel::vigilante.nivel_log ELSE 'info' END,
         p_proceso, (SELECT id FROM vigilante.sources s WHERE s.cliente_id = c.id AND s.codigo = p_codigo_fuente),
         p_mensaje, p_detalle, p_costo_usd
    FROM vigilante.clientes c WHERE c.slug = p_cliente
$$;

-- -----------------------------------------------------------------------------
-- 7. Herramientas de AVIA: noticias pendientes, señales, fuentes, propuestas
-- -----------------------------------------------------------------------------
-- Noticias que pasaron el filtro, agrupadas por título (la misma noticia en varias fuentes = 1).
-- Las devuelve marcadas «en_cola»; si AVIA no las cierra en 2 horas, vuelven a salir.
CREATE OR REPLACE FUNCTION vigilante.noticias_pendientes(p_cliente text, p_limite int DEFAULT 15)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  WITH cand AS (
    SELECT r.*, coalesce(s.codigo, 'busqueda') AS fcod, coalesce(s.nombre, 'Búsqueda: ' || b.consulta) AS fnom,
           coalesce(s.tipo::text, 'no_oficial') AS ftipo
      FROM vigilante.raw_items r
      LEFT JOIN vigilante.sources s ON s.id = r.source_id
      LEFT JOIN vigilante.busquedas b ON b.id = r.busqueda_id
     WHERE r.cliente_id = v_cliente
       AND (r.estado = 'nuevo' OR (r.estado = 'en_cola'
                                   AND coalesce((r.payload ->> 'en_cola_desde')::timestamptz, r.recolectado_en) < now() - interval '2 hours'))
  ), grupos AS (
    SELECT titulo_norm,
           array_agg(id ORDER BY puntaje_previo DESC, id) AS ids,
           count(DISTINCT fcod) AS n_fuentes,
           array_agg(DISTINCT fnom) AS fuentes,
           max(puntaje_previo) AS puntaje,
           max(recolectado_en) AS ultima
      FROM cand GROUP BY titulo_norm
     ORDER BY max(puntaje_previo) + 10 * (count(DISTINCT fcod) - 1) DESC, max(recolectado_en) DESC
     LIMIT greatest(least(p_limite, 40), 1)
  ), marcadas AS (
    UPDATE vigilante.raw_items r SET estado = 'en_cola',
           payload = r.payload || jsonb_build_object('en_cola_desde', now())
      FROM grupos g WHERE r.id = ANY (g.ids)
    RETURNING r.id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'ids', g.ids,
           'titulo', c.titulo,
           'url', c.url,
           'resumen', left(c.contenido, 600),
           'fuente', c.fcod, 'fuente_nombre', c.fnom, 'fuente_tipo', c.ftipo,
           'fuentes_que_coinciden', g.n_fuentes, 'otras_fuentes', g.fuentes,
           'publicado_en', c.publicado_en, 'recolectado_en', c.recolectado_en,
           'puntaje_previo', g.puntaje, 'motivos', to_jsonb(c.motivos),
           'territorios', (SELECT coalesce(jsonb_agg(t.nombre), '[]') FROM vigilante.territorios t WHERE t.id = ANY (c.territorios_detectados))
         ) ORDER BY g.puntaje + 10 * (g.n_fuentes - 1) DESC), '[]')
    INTO v
    FROM grupos g JOIN cand c ON c.id = g.ids[1]
   WHERE (SELECT count(*) FROM marcadas) >= 0;
  RETURN v;
END $$;

-- AVIA cierra noticias: procesadas (ya están en una señal) o descartadas (no interesan)
CREATE OR REPLACE FUNCTION vigilante.marcar_noticias(p_cliente text, p_ids bigint[], p_estado text, p_motivo text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); n int;
BEGIN
  IF p_estado NOT IN ('procesado', 'descartado', 'nuevo') THEN RAISE EXCEPTION 'Estado % no válido', p_estado; END IF;
  UPDATE vigilante.raw_items SET estado = p_estado::vigilante.estado_raw,
         motivo_descarte = CASE WHEN p_estado = 'descartado' THEN coalesce(p_motivo, 'descartada por AVIA') ELSE motivo_descarte END
   WHERE cliente_id = v_cliente AND id = ANY (p_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- AVIA guarda una señal nueva (o actualiza una suya con "codigo"). Devuelve el código SEN-xxxx.
-- Campos: los de la skill (titulo, resumen, recomendacion, naturaleza, categoria, prioridad, motivos_prioridad,
-- departamentos, alcance_nacional, fecha_evento_inicio, fecha_evento_fin, plazo_hasta, fuente_oficial,
-- enlace_oficial, requiere_revision, es_escenario, confianza, fuente_id) + noticias (ids de noticias_pendientes),
-- contexto_vigilante y, para la web, importancia, soluciones, tipo_oportunidad, actores, destinos, relevancia, novedad.
CREATE OR REPLACE FUNCTION vigilante.guardar_senal(p_cliente text, p_senal jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); v_codigo text := nullif(trim(p_senal ->> 'codigo'), '');
  v_id bigint; v_src integer; v_cat text := coalesce(nullif(p_senal ->> 'categoria', ''), 'mercado');
  v_ids bigint[]; v_nuevo boolean := false; v_n int;
  v_ts timestamptz;
BEGIN
  IF coalesce(trim(p_senal ->> 'titulo'), '') = '' OR coalesce(trim(p_senal ->> 'resumen'), '') = '' THEN
    RAISE EXCEPTION 'La señal necesita titulo y resumen';
  END IF;
  PERFORM set_config('vigilante.actor', 'hermes:mcp', true);
  IF p_senal ? 'categoria' THEN
    INSERT INTO vigilante.categorias (cliente_id, codigo, nombre) VALUES (v_cliente, v_cat, v_cat) ON CONFLICT DO NOTHING;
  END IF;
  SELECT id INTO v_src FROM vigilante.sources
   WHERE cliente_id = v_cliente AND codigo = coalesce(vigilante.fuente_canonica(v_cliente, p_senal ->> 'fuente_id', NULL), p_senal ->> 'fuente_id');
  v_ids := CASE WHEN jsonb_typeof(p_senal -> 'noticias') = 'array'
                THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(p_senal -> 'noticias') x WHERE x ~ '^\d+$') ELSE '{}' END;
  v_ids := ARRAY(SELECT id FROM vigilante.raw_items WHERE cliente_id = v_cliente AND id = ANY (v_ids));

  IF v_codigo IS NOT NULL THEN
    SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = v_codigo;
    IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % no existe: para una nueva no mandes codigo', v_codigo; END IF;
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext('vigilante.signals.codigo:' || v_cliente));
    SELECT 'SEN-' || lpad((coalesce(max(substring(codigo FROM '^SEN-(\d+)$')::int), 0) + 1)::text, 4, '0')
      INTO v_codigo FROM vigilante.signals WHERE cliente_id = v_cliente;
    v_nuevo := true;
  END IF;

  IF v_nuevo THEN
    INSERT INTO vigilante.signals (cliente_id, codigo, source_id, raw_item_id, titulo, resumen, naturaleza, categoria, prioridad, estado)
    VALUES (v_cliente, v_codigo, v_src, v_ids[1], left(p_senal ->> 'titulo', 200), p_senal ->> 'resumen', 'mixta', v_cat, 'media', 'detectada')
    RETURNING id INTO v_id;
  END IF;

  UPDATE vigilante.signals SET
    source_id = coalesce(v_src, source_id),
    titulo = left(p_senal ->> 'titulo', 200),
    resumen = p_senal ->> 'resumen',
    recomendacion = coalesce(p_senal ->> 'recomendacion', recomendacion),
    naturaleza = CASE WHEN p_senal ->> 'naturaleza' IN ('riesgo', 'oportunidad', 'mixta') THEN (p_senal ->> 'naturaleza')::vigilante.naturaleza_senal ELSE naturaleza END,
    categoria = CASE WHEN p_senal ? 'categoria' OR v_nuevo THEN v_cat ELSE categoria END,
    prioridad = CASE WHEN p_senal ->> 'prioridad' IN ('baja', 'media', 'alta') THEN (p_senal ->> 'prioridad')::vigilante.prioridad ELSE prioridad END,
    motivos_prioridad = CASE WHEN jsonb_typeof(p_senal -> 'motivos_prioridad') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(p_senal -> 'motivos_prioridad')) ELSE motivos_prioridad END,
    puntaje = CASE WHEN (p_senal ->> 'relevancia') ~ '^\d+(\.\d+)?$' THEN least((p_senal ->> 'relevancia')::numeric * 10, 100) ELSE puntaje END,
    confianza = CASE WHEN (p_senal ->> 'confianza') ~ '^[01](\.\d+)?$' THEN least((p_senal ->> 'confianza')::numeric, 1) ELSE confianza END,
    alcance_total = coalesce((p_senal ->> 'alcance_nacional')::boolean, alcance_total),
    es_escenario = coalesce((p_senal ->> 'es_escenario')::boolean, es_escenario),
    fuente_oficial = coalesce((p_senal ->> 'fuente_oficial')::boolean, fuente_oficial),
    enlace_oficial = coalesce(nullif(p_senal ->> 'enlace_oficial', ''), enlace_oficial),
    requiere_revision = coalesce((p_senal ->> 'requiere_revision')::boolean, requiere_revision),
    fecha_evento_inicio = CASE WHEN (p_senal ->> 'fecha_evento_inicio') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_inicio')::timestamptz ELSE fecha_evento_inicio END,
    fecha_evento_fin = CASE WHEN (p_senal ->> 'fecha_evento_fin') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_fin')::timestamptz ELSE fecha_evento_fin END,
    plazo_hasta = CASE WHEN (p_senal ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}$' THEN ((p_senal ->> 'plazo_hasta') || 'T23:59:59-04:00')::timestamptz
                       WHEN (p_senal ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}T' THEN (p_senal ->> 'plazo_hasta')::timestamptz
                       ELSE plazo_hasta END,
    modelo = coalesce(p_senal ->> 'modelo', modelo),
    salida_modelo = CASE WHEN v_nuevo THEN '{}'::jsonb ELSE coalesce(salida_modelo, '{}') - 'id' END || (p_senal - 'contexto_vigilante' - 'id' - 'codigo'),
    contexto_vigilante = coalesce(p_senal -> 'contexto_vigilante', contexto_vigilante)
  WHERE id = v_id;

  -- territorios por nombre (sin tildes ni mayúsculas)
  IF jsonb_typeof(p_senal -> 'departamentos') = 'array' THEN
    INSERT INTO vigilante.signal_territorios (signal_id, cliente_id, territorio_id)
    SELECT v_id, v_cliente, t.id FROM vigilante.territorios t
     WHERE t.cliente_id = v_cliente
       AND vigilante.texto_norm(t.nombre) IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(p_senal -> 'departamentos') x)
    ON CONFLICT DO NOTHING;
  END IF;
  -- noticias de las que sale
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
  SELECT v_id, x, v_cliente FROM unnest(v_ids) x ON CONFLICT DO NOTHING;
  UPDATE vigilante.raw_items SET estado = 'procesado' WHERE id = ANY (v_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('codigo', v_codigo, 'nueva', v_nuevo, 'noticias_enlazadas', v_n,
                            'nota', 'Queda en «Detectada»: una persona la revisa y decide si se publica');
END $$;

-- Para que AVIA no repita: señales parecidas de los últimos días
CREATE OR REPLACE FUNCTION vigilante.buscar_senales(p_cliente text, p_texto text DEFAULT NULL, p_dias int DEFAULT 30,
                                                    p_naturaleza text DEFAULT NULL, p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'creada') DESC), '[]') FROM (
    SELECT jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', left(s.resumen, 300),
             'naturaleza', s.naturaleza, 'categoria', s.categoria, 'prioridad', s.prioridad, 'estado', s.estado,
             'plazo_hasta', s.plazo_hasta, 'fecha_evento_inicio', s.fecha_evento_inicio, 'creada', s.created_at) AS x
      FROM vigilante.signals s JOIN vigilante.clientes c ON c.id = s.cliente_id AND c.slug = p_cliente
     WHERE s.created_at >= now() - make_interval(days => greatest(coalesce(p_dias, 30), 1))
       AND (p_naturaleza IS NULL OR s.naturaleza::text = p_naturaleza)
       AND (coalesce(trim(p_texto), '') = ''
            OR s.busqueda @@ plainto_tsquery('spanish', p_texto)
            OR vigilante.texto_norm(s.titulo) LIKE '%' || vigilante.texto_norm(p_texto) || '%')
     ORDER BY s.created_at DESC
     LIMIT greatest(least(coalesce(p_limite, 10), 50), 1)) t
$$;

CREATE OR REPLACE FUNCTION vigilante.estado_fuentes(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'codigo', s.codigo, 'nombre', s.nombre, 'url', s.url, 'tipo', s.tipo, 'metodo', s.metodo,
           'activa', s.activa, 'frecuencia_minutos', s.frecuencia_minutos,
           'estado', s.config ->> 'estado', 'ultima_consulta_en', s.ultima_consulta_en,
           'errores_seguidos', s.errores_seguidos, 'ultimo_error', s.ultimo_error,
           'noticias_24h', (SELECT count(*) FROM vigilante.raw_items r WHERE r.source_id = s.id AND r.recolectado_en > now() - interval '24 hours'),
           'utiles_24h', (SELECT count(*) FROM vigilante.raw_items r WHERE r.source_id = s.id AND r.recolectado_en > now() - interval '24 hours' AND r.estado <> 'descartado'),
           'propuesta_pendiente', (SELECT p.metodo_propuesto FROM vigilante.source_proposals p WHERE p.source_id = s.id AND p.estado = 'pendiente')
         ) ORDER BY s.errores_seguidos DESC, s.nombre), '[]')
    FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id AND c.slug = p_cliente
   WHERE s.eliminada_en IS NULL
$$;

-- AVIA propone cambiar cómo se lee una fuente; el administrador decide en la web
CREATE OR REPLACE FUNCTION vigilante.proponer_metodo(p_cliente text, p_codigo text, p_metodo text, p_motivo text,
                                                     p_config jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_src vigilante.sources; v_id bigint;
BEGIN
  SELECT * INTO v_src FROM vigilante.sources WHERE cliente_id = v_cliente AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % no existe', p_codigo; END IF;
  IF p_metodo NOT IN ('rss', 'google_news_rss', 'gdelt', 'http_html', 'apify', 'tavily', 'api', 'mcp_vigilante', 'manual') THEN
    RAISE EXCEPTION 'Método % no válido', p_metodo;
  END IF;
  IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Explica el motivo de la propuesta'; END IF;
  IF v_src.metodo::text = p_metodo AND coalesce(p_config, '{}') = '{}' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'La fuente ya se lee así');
  END IF;
  UPDATE vigilante.source_proposals SET metodo_propuesto = p_metodo::vigilante.metodo_fuente,
         config = coalesce(p_config, '{}'), motivo = p_motivo, created_at = now()
   WHERE source_id = v_src.id AND estado = 'pendiente'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    INSERT INTO vigilante.source_proposals (cliente_id, source_id, metodo_actual, metodo_propuesto, config, motivo)
    VALUES (v_cliente, v_src.id, v_src.metodo, p_metodo::vigilante.metodo_fuente, coalesce(p_config, '{}'), p_motivo)
    RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'nota', 'Pendiente de que un administrador la apruebe en la web');
END $$;

-- -----------------------------------------------------------------------------
-- 8. Métricas de oportunidad y alertas tempranas (SQL, sin IA)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.metricas_oportunidades(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = p_cliente),
  vigentes AS (
    SELECT s.codigo, s.titulo, s.naturaleza, s.categoria, s.estado, s.prioridad, s.confianza,
           CASE WHEN s.plazo_hasta IS NOT NULL THEN ceil(extract(epoch FROM s.plazo_hasta - now()) / 86400)::int END AS dias_plazo,
           CASE WHEN s.fecha_evento_inicio IS NOT NULL THEN ceil(extract(epoch FROM s.fecha_evento_inicio - now()) / 86400)::int END AS dias_evento,
           ARRAY(SELECT t.nombre FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id
                  WHERE st.signal_id = s.id) AS territorios
      FROM vigilante.signals s, c
     WHERE s.cliente_id = c.id AND s.naturaleza IN ('oportunidad', 'mixta')
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND (s.plazo_hasta IS NULL OR s.plazo_hasta >= now())
       AND (s.fecha_evento_fin IS NULL OR s.fecha_evento_fin >= now())
       AND s.created_at >= now() - interval '90 days'
  ),
  menciones AS (
    SELECT t.nombre,
           count(*) FILTER (WHERE r.recolectado_en >= now() - interval '7 days') AS ult7,
           count(*) FILTER (WHERE r.recolectado_en < now() - interval '7 days') / 4.0 AS media_semana
      FROM vigilante.raw_items r, c, unnest(r.territorios_detectados) tid
      JOIN vigilante.territorios t ON t.id = tid
     WHERE r.cliente_id = c.id AND r.estado <> 'descartado' AND r.recolectado_en >= now() - interval '35 days'
     GROUP BY t.nombre
  ),
  coinciden AS (
    SELECT min(r.titulo) AS titulo, count(DISTINCT coalesce(r.source_id::text, 'b' || r.busqueda_id)) AS fuentes, max(r.recolectado_en) AS ultima
      FROM vigilante.raw_items r, c
     WHERE r.cliente_id = c.id AND r.recolectado_en >= now() - interval '48 hours' AND r.estado <> 'descartado'
     GROUP BY r.titulo_norm HAVING count(DISTINCT coalesce(r.source_id::text, 'b' || r.busqueda_id)) >= 2
  )
  SELECT jsonb_build_object(
    'generado', now(),
    'oportunidades_vigentes', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY least(coalesce(v.dias_plazo, 999), coalesce(v.dias_evento, 999))), '[]')
                                 FROM (SELECT * FROM vigentes LIMIT 30) v),
    'cierran_en_15_dias', (SELECT count(*) FROM vigentes WHERE dias_plazo BETWEEN 0 AND 15),
    'eventos_proximos_60_dias', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'dias', dias_evento, 'territorios', territorios) ORDER BY dias_evento), '[]')
                                   FROM vigentes WHERE dias_evento BETWEEN 0 AND 60),
    'impulso_territorios', (SELECT coalesce(jsonb_agg(jsonb_build_object('territorio', nombre, 'menciones_7d', ult7,
                                     'media_semanal_anterior', round(media_semana, 1),
                                     'impulso', CASE WHEN media_semana > 0 THEN round(ult7 / media_semana, 2) END) ORDER BY ult7 DESC), '[]')
                              FROM menciones),
    'temas_en_varias_fuentes_48h', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.fuentes DESC, x.ultima DESC), '[]')
                                      FROM (SELECT * FROM coinciden ORDER BY fuentes DESC, ultima DESC LIMIT 15) x)
  )
$$;

-- Reglas de alerta temprana. Devuelve qué merece mirar YA (lo decide una regla, no la IA)
CREATE OR REPLACE FUNCTION vigilante.alertas_tempranas(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = p_cliente),
  oficial_alerta AS (
    SELECT 'aviso_oficial' AS regla, r.titulo AS que, r.url, s.nombre AS fuente, r.recolectado_en AS cuando
      FROM vigilante.raw_items r JOIN vigilante.sources s ON s.id = r.source_id, c
     WHERE r.cliente_id = c.id AND r.recolectado_en >= now() - interval '24 hours' AND r.estado IN ('nuevo', 'en_cola')
       AND s.tipo IN ('oficial', 'organismo_internacional') AND EXISTS (SELECT 1 FROM unnest(r.motivos) m WHERE m LIKE 'alerta:%')
  ),
  varias_fuentes AS (
    SELECT 'varias_fuentes_6h', min(r.titulo), min(r.url), string_agg(DISTINCT coalesce(s.nombre, 'búsqueda'), ', '), max(r.recolectado_en)
      FROM vigilante.raw_items r LEFT JOIN vigilante.sources s ON s.id = r.source_id, c
     WHERE r.cliente_id = c.id AND r.recolectado_en >= now() - interval '6 hours' AND r.estado <> 'descartado'
     GROUP BY r.titulo_norm HAVING count(DISTINCT coalesce(r.source_id::text, 'b' || r.busqueda_id)) >= 3
  ),
  plazos AS (
    SELECT 'plazo_cerca', s.codigo || ' · ' || s.titulo, s.enlace_oficial, NULL::text, s.plazo_hasta
      FROM vigilante.signals s, c
     WHERE s.cliente_id = c.id AND s.plazo_hasta BETWEEN now() AND now() + interval '5 days'
       AND s.estado NOT IN ('descartada', 'cerrada')
  ),
  picos AS (
    SELECT 'tema_en_aumento', t.nombre || ': ' || count(*) FILTER (WHERE r.recolectado_en >= now() - interval '7 days') || ' menciones en 7 días',
           NULL::text, NULL::text, max(r.recolectado_en)
      FROM vigilante.raw_items r, c, unnest(r.territorios_detectados) tid JOIN vigilante.territorios t ON t.id = tid
     WHERE r.cliente_id = c.id AND r.estado <> 'descartado' AND r.recolectado_en >= now() - interval '35 days'
     GROUP BY t.nombre
    HAVING count(*) FILTER (WHERE r.recolectado_en >= now() - interval '7 days') >= 5
       AND count(*) FILTER (WHERE r.recolectado_en >= now() - interval '7 days')
           >= 2 * greatest(count(*) FILTER (WHERE r.recolectado_en < now() - interval '7 days') / 4.0, 1)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('regla', regla, 'que', que, 'url', url, 'fuente', fuente, 'cuando', cuando)
                            ORDER BY cuando DESC), '[]')
    FROM (SELECT * FROM oficial_alerta UNION ALL SELECT * FROM varias_fuentes
          UNION ALL SELECT * FROM plazos UNION ALL SELECT * FROM picos) a
$$;

-- Solo el VPS y AVIA (service_role)
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'vigilante.insertar_noticias(uuid, integer, bigint, jsonb, text)',
    'vigilante.fuentes_para_recolector(text)',
    'vigilante.guardar_comprobacion(text, text, text, text, jsonb, text, text)',
    'vigilante.pedir_busqueda(text, text, text, jsonb, text)',
    'vigilante.tomar_busquedas(text, int)',
    'vigilante.guardar_busqueda(text, bigint, boolean, text, jsonb, numeric, text)',
    'vigilante.registrar_log(text, text, text, text, jsonb, numeric, text)',
    'vigilante.noticias_pendientes(text, int)',
    'vigilante.marcar_noticias(text, bigint[], text, text)',
    'vigilante.guardar_senal(text, jsonb)',
    'vigilante.buscar_senales(text, text, int, text, int)',
    'vigilante.estado_fuentes(text)',
    'vigilante.proponer_metodo(text, text, text, text, jsonb)',
    'vigilante.metricas_oportunidades(text)',
    'vigilante.alertas_tempranas(text)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 9. Para la web (equipo con sesión)
-- -----------------------------------------------------------------------------
-- Lo que hay en la base con el mismo formato que vigilante.json (versión 1): la web lo mezcla con el
-- archivo y, cuando el archivo deje de existir, lo usa solo.
CREATE OR REPLACE FUNCTION vigilante.vigilante_bd()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT vigilante.cliente_actual() AS id)
  SELECT jsonb_build_object(
    'version', 1,
    'generado', now(),
    'origen', 'base',
    'noticias_revisadas', (SELECT count(*) FROM vigilante.raw_items r, c WHERE r.cliente_id = c.id AND r.recolectado_en > now() - interval '24 hours'),
    'ventana_horas', 24,
    'fuentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', s.codigo, 'nombre', s.nombre, 'canal', s.categorias[1], 'tipo', s.tipo, 'url', s.url,
                  'metodo', s.metodo, 'estado', s.config ->> 'estado', 'ultima', s.ultima_consulta_en,
                  'items', coalesce((s.config ->> 'items')::int, 0), 'hist', s.config -> 'hist', 'info', s.notas)), '[]')
                  FROM vigilante.sources s, c
                 WHERE s.cliente_id = c.id AND s.eliminada_en IS NULL AND s.config ->> 'leida_por' = 'recolector'),
    'senales', (SELECT coalesce(jsonb_agg(
                  -- las que vinieron de vigilante.json conservan su formato; las de AVIA por MCP se construyen
                  CASE WHEN s.salida_modelo ? 'id' AND s.salida_modelo ? 'titulo'
                       THEN s.salida_modelo || jsonb_build_object('id', s.codigo, 'estado', s.estado)
                       ELSE jsonb_strip_nulls(jsonb_build_object(
                         'id', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen, 'naturaleza', s.naturaleza,
                         'categoria', s.categoria, 'estado', s.estado, 'prioridad', s.prioridad,
                         'conf', s.confianza,
                         'rel', (s.salida_modelo ->> 'relevancia')::numeric, 'nov', (s.salida_modelo ->> 'novedad')::numeric,
                         'deps', (SELECT jsonb_agg(t.nombre) FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id WHERE st.signal_id = s.id),
                         'destinos', s.salida_modelo -> 'destinos',
                         'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
                         'enlaces', (SELECT jsonb_agg(jsonb_build_object('nombre', coalesce(src.nombre, 'Fuente'), 'url', r.url,
                                                                         'fecha', to_char(coalesce(r.publicado_en, r.recolectado_en), 'YYYY-MM-DD')))
                                       FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                       LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE sr.signal_id = s.id),
                         'tipoOpp', s.salida_modelo ->> 'tipo_oportunidad', 'actores', s.salida_modelo -> 'actores',
                         'importancia', coalesce(s.salida_modelo ->> 'importancia', s.recomendacion),
                         'soluciones', s.salida_modelo -> 'soluciones',
                         'revision', CASE WHEN s.requiere_revision THEN 'Requiere revisión de una persona' END,
                         'detectada', s.created_at))
                  END ORDER BY s.created_at DESC), '[]')
                  FROM (SELECT s.* FROM vigilante.signals s, c WHERE s.cliente_id = c.id AND s.created_at >= now() - interval '60 days'
                        ORDER BY s.created_at DESC LIMIT 300) s)
  )
$$;
REVOKE ALL ON FUNCTION vigilante.vigilante_bd() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.vigilante_bd() TO authenticated, service_role;

-- Propuestas de AVIA sobre cómo leer cada fuente (pendientes y las de los últimos 30 días)
CREATE OR REPLACE FUNCTION vigilante.propuestas_web()
RETURNS TABLE (id bigint, codigo text, nombre text, metodo_actual vigilante.metodo_fuente, metodo_propuesto vigilante.metodo_fuente,
               config jsonb, motivo text, estado text, propuesta_en timestamptz, decidida_por text, decidida_en timestamptz, nota text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT p.id, s.codigo, s.nombre, p.metodo_actual, p.metodo_propuesto, p.config, p.motivo, p.estado, p.created_at,
         p.decidida_por, p.decidida_en, p.nota
    FROM vigilante.source_proposals p JOIN vigilante.sources s ON s.id = p.source_id
   WHERE p.cliente_id = vigilante.cliente_actual() AND s.eliminada_en IS NULL
     AND (p.estado = 'pendiente' OR p.decidida_en > now() - interval '30 days')
   ORDER BY p.estado <> 'pendiente', p.created_at DESC
$$;
REVOKE ALL ON FUNCTION vigilante.propuestas_web() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.propuestas_web() TO authenticated;

-- El administrador aprueba o rechaza. Al aprobar, la fuente cambia de método y AVIA la revisa en la siguiente ronda.
CREATE OR REPLACE FUNCTION vigilante.decidir_propuesta(p_id bigint, p_aprobar boolean, p_nota text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v vigilante.source_proposals; v_quien text;
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede decidir sobre las propuestas de AVIA'; END IF;
  SELECT * INTO v FROM vigilante.source_proposals WHERE id = p_id AND cliente_id = vigilante.cliente_actual() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La propuesta no existe'; END IF;
  IF v.estado <> 'pendiente' THEN RAISE EXCEPTION 'Esta propuesta ya se decidió'; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  UPDATE vigilante.source_proposals SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END,
         decidida_por = coalesce(v_quien, 'administrador'), decidida_en = now(), nota = nullif(trim(p_nota), '')
   WHERE id = p_id;
  IF p_aprobar THEN
    UPDATE vigilante.sources SET metodo = v.metodo_propuesto,
           config = config || v.config || jsonb_build_object('revisar_desde', now(), 'editada_por', coalesce(v_quien, 'administrador'),
                                                             'editada_en', now(), 'huella', NULL)
     WHERE id = v.source_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.decidir_propuesta(bigint, boolean, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.decidir_propuesta(bigint, boolean, text) TO authenticated;

COMMIT;
