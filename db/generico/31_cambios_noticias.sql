-- =============================================================================
-- 31. Cambios en noticias ya recogidas: «viene un ciclón» → «el ciclón se desvió»
-- =============================================================================
-- Qué faltaba: cuando llegaba una noticia nueva sobre un hecho que ya era señal, la señal se
-- actualizaba en silencio (o, desde el 30, se le sumaba la noticia como evidencia y conservaba su
-- título viejo). Si el evento cambiaba de fecha, se cancelaba o el ciclón se desviaba, nadie se
-- enteraba hasta abrir la ficha.
--
-- Ahora cada CAMBIO queda registrado (CAM-0001…) y el panel lo avisa con sonido y ventana:
--
--   1. LA BASE DETECTA LO OBJETIVO (sin IA). Disparador en signals: si el clasificador o Hermes
--      cambian la fecha del evento, el plazo, la naturaleza (riesgo ↔ oportunidad) o la prioridad
--      (sube a alta o deja de serlo) de una señal que ya existía, se registra el cambio con el
--      antes y el ahora. Lo que mueve una persona en el panel NO cuenta (ya lo sabe).
--
--   2. EL CLASIFICADOR DETECTA LO SEMÁNTICO. lote_para_clasificar manda ahora, con cada noticia,
--      las señales abiertas que hablan de lo mismo (senales_relacionadas). Si la noticia modifica o
--      contradice una de ellas (cancelación, desvío, nueva fecha, desmentido, se resolvió…), el
--      clasificador devuelve «cambio» con el antes y el ahora (prompt clasificador-1.7). Un disparador
--      sobre vigilante.analisis lo registra. Sirve también cuando la noticia nueva acabó en OTRA señal.
--
--   3. HERMES INTERPRETA (el cerebro). Con la skill «interpretar-cambios»: confirma que es un cambio
--      real (o lo descarta), dice qué significa, a quién afecta y qué hacer ahora. Puede registrar
--      cambios que encuentre investigando (registrar_cambio). La alerta NO espera a Hermes
--      (cambios_espera_hermes_min = 0): sale en cuanto se detecta, y la interpretación se añade después.
--
--   4. EL PANEL AVISA: cambios_recientes() → ventana flotante con sonido para cada cambio sin ver y
--      un indicador «Cambios N» junto al botón de Eventos que se queda hasta que la persona lo mira.
--
-- Si la señal que cambia forma parte de un evento compuesto abierto (28), el evento vuelve a Hermes
-- para que actualice su interpretación (sin volver a sacar su alerta).
--
-- Esto es INTERNO (panel del equipo). Nada sale a la web pública ni a Telegram.
--
-- Necesita del 01 al 30 (usa vigilante.parecido del 30; el 28 es opcional).
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run. Se puede ejecutar más de una vez.
-- Comprobar: SELECT codigo, tipo, antes, ahora, importancia, estado FROM vigilante.cambios_senal ORDER BY id DESC;
-- Prueba: 99_prueba_cambios.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante.parecido(text,text)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 30 (sin_duplicados): ejecútalo antes que este';
  END IF;
END $$;

-- 0. Parámetros (cada cliente puede sobrescribirlos) ---------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'cambios_alerta_desde', '"baja"', 'Importancia mínima de un cambio para que salga la ventana con sonido: baja (todos), media o alta'),
  (NULL, 'cambios_espera_hermes_min', '0', 'Minutos que la alerta de un cambio espera la interpretación de Hermes (0 = sale al momento)'),
  (NULL, 'cambios_dias_panel', '3', 'Días que un cambio sigue en la lista «Cambios» del panel'),
  (NULL, 'cambios_repetido_horas', '24', 'Un cambio del mismo tipo en la misma señal dentro de estas horas se junta con el anterior (no vuelve a sonar)'),
  (NULL, 'cambios_parecido_min', '0.25', 'Parecido de títulos (0 a 1) para mandar una señal abierta al clasificador como posible relacionada'),
  (NULL, 'cambios_buscar_dias', '30', 'Días hacia atrás en que se buscan señales abiertas relacionadas con una noticia nueva')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Tablas -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.cambios_senal (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id       uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  codigo           text NOT NULL,                                     -- CAM-0001
  signal_id        bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,   -- la señal que cambia
  signal_nueva_id  bigint REFERENCES vigilante.signals(id) ON DELETE SET NULL,           -- si la noticia nueva acabó en otra señal
  tipo             text NOT NULL CHECK (tipo IN ('fecha', 'plazo', 'cancelado', 'desviado', 'resuelto', 'agravado',
                                                 'atenuado', 'lugar', 'desmentido', 'confirmado', 'naturaleza',
                                                 'prioridad', 'otro')),
  antes            text,                                              -- «Llega el jueves 20 a Santa Cruz»
  ahora            text NOT NULL,                                     -- «Se desvió hacia Paraguay; no tocará Bolivia»
  campos           jsonb NOT NULL DEFAULT '{}',                       -- datos que cambiaron: {"fecha_evento_inicio": {"antes": "2026-11-20", "ahora": "2026-11-27"}}
  importancia      vigilante.prioridad NOT NULL DEFAULT 'media',
  noticias         bigint[] NOT NULL DEFAULT '{}',                    -- las noticias que traen el cambio
  origen           text NOT NULL CHECK (origen IN ('datos', 'clasificador', 'hermes')),
  detectado_por    text,
  txid             bigint NOT NULL DEFAULT txid_current(),            -- para juntar lo que detectan datos y clasificador a la vez
  -- ciclo de vida (como los eventos del 28)
  estado           text NOT NULL DEFAULT 'por_interpretar'
                     CHECK (estado IN ('por_interpretar', 'interpretando', 'interpretado', 'descartado')),
  titular          text,
  interpretacion   jsonb,
  interpretado_por text,
  interpretado_en  timestamptz,
  tomado_en        timestamptz,
  descartado_por   text,
  motivo_descarte  text,
  repeticiones     integer NOT NULL DEFAULT 0,                        -- otras noticias que trajeron el mismo cambio después
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, codigo)
);
CREATE INDEX IF NOT EXISTS cambios_senal_signal_idx ON vigilante.cambios_senal (signal_id, created_at DESC);
CREATE INDEX IF NOT EXISTS cambios_senal_abiertos_idx ON vigilante.cambios_senal (cliente_id, created_at DESC) WHERE estado <> 'descartado';
DROP TRIGGER IF EXISTS b_updated_at ON vigilante.cambios_senal;
CREATE TRIGGER b_updated_at BEFORE UPDATE ON vigilante.cambios_senal
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
ALTER TABLE vigilante.cambios_senal ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
COMMENT ON TABLE vigilante.cambios_senal IS
  'Cambios en señales ya existentes (31): nueva fecha, cancelación, desvío, desmentido… La base y el clasificador los detectan, Hermes los interpreta, el panel avisa';

CREATE TABLE IF NOT EXISTS vigilante.cambios_vistos (
  cambio_id  bigint NOT NULL REFERENCES vigilante.cambios_senal(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES vigilante.users(id) ON DELETE CASCADE,
  visto_en   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cambio_id, user_id)
);
ALTER TABLE vigilante.cambios_vistos ENABLE ROW LEVEL SECURITY;

-- 2. Utilidades ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._nivel(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'alta' THEN 3 WHEN 'media' THEN 2 WHEN 'baja' THEN 1 ELSE 0 END
$$;

-- Fecha de una señal en texto (fechas sin hora se guardan a medianoche UTC: se muestra el día tal cual)
CREATE OR REPLACE FUNCTION vigilante._dia(p timestamptz) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p IS NULL THEN NULL ELSE to_char(p AT TIME ZONE 'UTC', 'YYYY-MM-DD') END
$$;

-- Ficha corta de una señal (para el clasificador, Hermes y el panel)
CREATE OR REPLACE FUNCTION vigilante._senal_corta(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'codigo', s.codigo, 'titulo', s.titulo, 'resumen', left(s.resumen, 240),
           'naturaleza', s.naturaleza, 'categoria', s.categoria, 'prioridad', s.prioridad, 'estado', s.estado,
           'evento_inicio', vigilante._dia(s.fecha_evento_inicio), 'evento_fin', vigilante._dia(s.fecha_evento_fin),
           'plazo_hasta', vigilante._dia(s.plazo_hasta),
           'departamentos', (SELECT jsonb_agg(t.nombre ORDER BY t.nombre) FROM vigilante.signal_territorios st
                               JOIN vigilante.territorios t ON t.id = st.territorio_id WHERE st.signal_id = s.id)))
    FROM vigilante.signals s WHERE s.id = p_id
$$;
REVOKE ALL ON FUNCTION vigilante._senal_corta(bigint) FROM public, anon, authenticated;

-- Señales abiertas que pueden hablar del mismo hecho que una noticia (para el clasificador).
-- Más flojo que el 30 (que decide si UNIR): aquí solo se pregunta al clasificador si la noticia las cambia.
CREATE OR REPLACE FUNCTION vigilante.senales_relacionadas(p_cliente uuid, p_titulo text, p_territorios integer[] DEFAULT '{}',
                                                          p_excluir bigint[] DEFAULT '{}', p_limite int DEFAULT 2)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH p AS (
    SELECT coalesce((vigilante.param(p_cliente, 'cambios_parecido_min') #>> '{}')::real, 0.25) AS minimo,
           coalesce((vigilante.param(p_cliente, 'cambios_buscar_dias') #>> '{}')::int, 30) AS dias
  ), c AS (
    SELECT s.id, vigilante.parecido(vigilante.texto_norm(p_titulo), vigilante.texto_norm(s.titulo)) AS par
      FROM vigilante.signals s, p
     WHERE s.cliente_id = p_cliente AND s.duplicado_de IS NULL
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND greatest(s.created_at, s.updated_at) > now() - make_interval(days => p.dias)
       AND NOT (s.id = ANY (coalesce(p_excluir, '{}')))
       -- territorios distintos: hechos distintos (si los dos los tienen)
       AND (cardinality(coalesce(p_territorios, '{}')) = 0
            OR NOT EXISTS (SELECT 1 FROM vigilante.signal_territorios st WHERE st.signal_id = s.id)
            OR EXISTS (SELECT 1 FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id
                        WHERE st.signal_id = s.id AND (t.id = ANY (p_territorios) OR t.padre_id = ANY (p_territorios)
                                                       OR t.nivel = 'pais')))
  )
  SELECT coalesce(jsonb_agg(vigilante._senal_corta(c.id) ORDER BY c.par DESC), '[]')
    FROM (SELECT c.* FROM c, p WHERE c.par >= p.minimo ORDER BY c.par DESC, c.id DESC
           LIMIT greatest(least(coalesce(p_limite, 2), 4), 1)) c
$$;
REVOKE ALL ON FUNCTION vigilante.senales_relacionadas(uuid, text, integer[], bigint[], int) FROM public, anon, authenticated;

-- 3. Registrar un cambio (lo usan los disparadores y Hermes) ---------------------------------
-- Junta lo que llega en la misma transacción (datos + clasificador) y lo que repite un cambio
-- reciente del mismo tipo (otro medio que cuenta lo mismo): eso no vuelve a sonar.
CREATE OR REPLACE FUNCTION vigilante._registrar_cambio(p_signal bigint, p_tipo text, p_antes text, p_ahora text,
                                                       p_campos jsonb DEFAULT '{}', p_importancia text DEFAULT NULL,
                                                       p_noticias bigint[] DEFAULT '{}', p_origen text DEFAULT 'datos',
                                                       p_nueva bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; v vigilante.cambios_senal; v_imp text; v_codigo text; v_horas int;
  v_tipo text := CASE WHEN p_tipo IN ('fecha', 'plazo', 'cancelado', 'desviado', 'resuelto', 'agravado', 'atenuado', 'lugar',
                                      'desmentido', 'confirmado', 'naturaleza', 'prioridad', 'otro') THEN p_tipo ELSE 'otro' END;
  v_actor text := coalesce(nullif(current_setting('vigilante.actor', true), ''), p_origen);
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF s.id IS NULL OR coalesce(trim(p_ahora), '') = '' THEN RETURN NULL; END IF;
  IF p_nueva = p_signal THEN p_nueva := NULL; END IF;

  -- importancia: la que dan (clasificador o Hermes) o la de la señal; un giro fuerte en una señal alta es alto
  v_imp := CASE WHEN p_importancia IN ('alta', 'media', 'baja') THEN p_importancia ELSE s.prioridad::text END;
  IF s.prioridad = 'alta' AND v_tipo IN ('fecha', 'cancelado', 'desviado', 'resuelto', 'agravado', 'desmentido', 'lugar') THEN
    v_imp := 'alta';
  END IF;

  -- (a) misma transacción y misma señal: es el mismo cambio visto por dos lados (datos y clasificador)
  SELECT * INTO v FROM vigilante.cambios_senal
   WHERE signal_id = p_signal AND txid = txid_current() ORDER BY id DESC LIMIT 1;
  IF v.id IS NOT NULL THEN
    UPDATE vigilante.cambios_senal SET
      -- el texto del clasificador explica mejor que el de los datos; el tipo de los datos es más exacto si es fecha o plazo
      tipo = CASE WHEN v.origen = 'datos' AND p_origen <> 'datos' AND v.tipo NOT IN ('fecha', 'plazo') THEN v_tipo ELSE v.tipo END,
      antes = CASE WHEN v.origen = 'datos' AND p_origen <> 'datos' THEN coalesce(nullif(trim(p_antes), ''), v.antes) ELSE coalesce(v.antes, p_antes) END,
      ahora = CASE WHEN v.origen = 'datos' AND p_origen <> 'datos' THEN left(trim(p_ahora), 400) ELSE v.ahora END,
      origen = CASE WHEN v.origen = 'datos' AND p_origen <> 'datos' THEN p_origen ELSE v.origen END,
      campos = v.campos || coalesce(p_campos, '{}'),
      importancia = CASE WHEN vigilante._nivel(v_imp) > vigilante._nivel(v.importancia::text) THEN v_imp::vigilante.prioridad ELSE v.importancia END,
      noticias = ARRAY(SELECT DISTINCT x FROM unnest(v.noticias || coalesce(p_noticias, '{}')) x ORDER BY x),
      signal_nueva_id = coalesce(v.signal_nueva_id, p_nueva)
     WHERE id = v.id;
    RETURN v.id;
  END IF;

  -- (b) el mismo cambio ya registrado hace poco (otro medio lo cuenta igual): se suma, sin nueva alerta
  v_horas := coalesce((vigilante.param(s.cliente_id, 'cambios_repetido_horas') #>> '{}')::int, 24);
  SELECT * INTO v FROM vigilante.cambios_senal
   WHERE signal_id = p_signal AND tipo = v_tipo AND estado <> 'descartado'
     AND created_at > now() - make_interval(hours => v_horas)
     -- una fecha distinta de la ya avisada sí es un cambio nuevo
     AND (v_tipo NOT IN ('fecha', 'plazo') OR campos = coalesce(p_campos, '{}') OR coalesce(p_campos, '{}') = '{}')
   ORDER BY id DESC LIMIT 1;
  IF v.id IS NOT NULL THEN
    UPDATE vigilante.cambios_senal SET
      noticias = ARRAY(SELECT DISTINCT x FROM unnest(v.noticias || coalesce(p_noticias, '{}')) x ORDER BY x),
      repeticiones = repeticiones + 1
     WHERE id = v.id;
    RETURN v.id;
  END IF;

  -- (c) cambio nuevo
  PERFORM pg_advisory_xact_lock(hashtext('vigilante.cambios.codigo:' || s.cliente_id));
  SELECT 'CAM-' || lpad((coalesce(max(substring(codigo FROM '^CAM-(\d+)$')::int), 0) + 1)::text, 4, '0')
    INTO v_codigo FROM vigilante.cambios_senal WHERE cliente_id = s.cliente_id;
  INSERT INTO vigilante.cambios_senal (cliente_id, codigo, signal_id, signal_nueva_id, tipo, antes, ahora, campos,
                                       importancia, noticias, origen, detectado_por)
  VALUES (s.cliente_id, v_codigo, p_signal, p_nueva, v_tipo, left(nullif(trim(p_antes), ''), 400), left(trim(p_ahora), 400),
          coalesce(p_campos, '{}'), v_imp::vigilante.prioridad,
          ARRAY(SELECT DISTINCT x FROM unnest(coalesce(p_noticias, '{}')) x ORDER BY x), p_origen, v_actor)
  RETURNING * INTO v;

  -- un evento compuesto abierto con esta señal: Hermes debe revisar su interpretación (sin volver a sacar su alerta)
  IF to_regclass('vigilante.eventos_compuestos') IS NOT NULL THEN
    UPDATE vigilante.eventos_compuestos SET estado = 'por_interpretar', tomado_en = NULL
     WHERE cliente_id = s.cliente_id AND p_signal = ANY (senal_ids) AND estado = 'interpretado';
  END IF;
  RETURN v.id;
END $$;
REVOKE ALL ON FUNCTION vigilante._registrar_cambio(bigint, text, text, text, jsonb, text, bigint[], text, bigint) FROM public, anon, authenticated;

-- 4. Disparador sobre signals: cambios objetivos de datos ------------------------------------
-- Solo cuando el cambio viene de una noticia (clasificador o Hermes), en una señal que ya existía.
CREATE OR REPLACE FUNCTION vigilante.tg_cambio_datos_senal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_actor text := coalesce(current_setting('vigilante.actor', true), '');
  v_campos jsonb := '{}'; v_antes text[] := '{}'; v_ahora text[] := '{}'; v_tipo text; v_imp text;
BEGIN
  IF NOT (v_actor LIKE 'clasificador:%' OR v_actor = 'hermes:mcp') THEN RETURN NULL; END IF;
  IF OLD.created_at >= now() THEN RETURN NULL; END IF;                -- creada en esta misma transacción: no es un cambio
  IF NEW.estado IN ('descartada', 'cerrada') OR NEW.duplicado_de IS NOT NULL THEN RETURN NULL; END IF;

  -- fechas: solo si ya había una y ahora es otra (rellenar un dato que faltaba no es un cambio)
  IF OLD.fecha_evento_inicio IS NOT NULL AND NEW.fecha_evento_inicio IS NOT NULL
     AND vigilante._dia(OLD.fecha_evento_inicio) <> vigilante._dia(NEW.fecha_evento_inicio) THEN
    v_campos := v_campos || jsonb_build_object('fecha_evento_inicio', jsonb_build_object(
                  'antes', vigilante._dia(OLD.fecha_evento_inicio), 'ahora', vigilante._dia(NEW.fecha_evento_inicio)));
    v_antes := v_antes || ('Empezaba el ' || to_char(OLD.fecha_evento_inicio AT TIME ZONE 'UTC', 'DD/MM/YYYY'));
    v_ahora := v_ahora || ('Empieza el ' || to_char(NEW.fecha_evento_inicio AT TIME ZONE 'UTC', 'DD/MM/YYYY'));
    v_tipo := 'fecha';
  END IF;
  IF OLD.fecha_evento_fin IS NOT NULL AND NEW.fecha_evento_fin IS NOT NULL
     AND vigilante._dia(OLD.fecha_evento_fin) <> vigilante._dia(NEW.fecha_evento_fin) THEN
    v_campos := v_campos || jsonb_build_object('fecha_evento_fin', jsonb_build_object(
                  'antes', vigilante._dia(OLD.fecha_evento_fin), 'ahora', vigilante._dia(NEW.fecha_evento_fin)));
    v_antes := v_antes || ('Terminaba el ' || to_char(OLD.fecha_evento_fin AT TIME ZONE 'UTC', 'DD/MM/YYYY'));
    v_ahora := v_ahora || ('Termina el ' || to_char(NEW.fecha_evento_fin AT TIME ZONE 'UTC', 'DD/MM/YYYY'));
    v_tipo := 'fecha';
  END IF;
  IF OLD.plazo_hasta IS NOT NULL AND NEW.plazo_hasta IS NOT NULL
     AND (OLD.plazo_hasta AT TIME ZONE 'America/La_Paz')::date <> (NEW.plazo_hasta AT TIME ZONE 'America/La_Paz')::date THEN
    v_campos := v_campos || jsonb_build_object('plazo_hasta', jsonb_build_object(
                  'antes', to_char(OLD.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
                  'ahora', to_char(NEW.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD')));
    v_antes := v_antes || ('Plazo hasta el ' || to_char(OLD.plazo_hasta AT TIME ZONE 'America/La_Paz', 'DD/MM/YYYY'));
    v_ahora := v_ahora || ('Plazo hasta el ' || to_char(NEW.plazo_hasta AT TIME ZONE 'America/La_Paz', 'DD/MM/YYYY'));
    v_tipo := coalesce(v_tipo, 'plazo');
  END IF;
  -- riesgo ↔ oportunidad (pasar a o desde «mixta» no se avisa)
  IF OLD.naturaleza <> NEW.naturaleza AND OLD.naturaleza <> 'mixta' AND NEW.naturaleza <> 'mixta' THEN
    v_campos := v_campos || jsonb_build_object('naturaleza', jsonb_build_object('antes', OLD.naturaleza, 'ahora', NEW.naturaleza));
    v_antes := v_antes || ('Era ' || OLD.naturaleza::text);
    v_ahora := v_ahora || ('Ahora es ' || NEW.naturaleza::text);
    v_tipo := coalesce(v_tipo, 'naturaleza');
  END IF;
  -- prioridad: solo cuando sube a alta o deja de ser alta
  IF OLD.prioridad <> NEW.prioridad AND (OLD.prioridad = 'alta' OR NEW.prioridad = 'alta') THEN
    v_campos := v_campos || jsonb_build_object('prioridad', jsonb_build_object('antes', OLD.prioridad, 'ahora', NEW.prioridad));
    v_antes := v_antes || ('Prioridad ' || OLD.prioridad::text);
    v_ahora := v_ahora || ('Prioridad ' || NEW.prioridad::text);
    v_tipo := coalesce(v_tipo, 'prioridad');
    v_imp := CASE WHEN NEW.prioridad = 'alta' THEN 'alta' END;
  END IF;

  IF v_tipo IS NULL THEN RETURN NULL; END IF;
  PERFORM vigilante._registrar_cambio(NEW.id, v_tipo, array_to_string(v_antes, ' · '), array_to_string(v_ahora, ' · '),
                                      v_campos, v_imp, '{}', 'datos');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_cambio_datos ON vigilante.signals;
CREATE TRIGGER zz_cambio_datos AFTER UPDATE OF fecha_evento_inicio, fecha_evento_fin, plazo_hasta, naturaleza, prioridad
  ON vigilante.signals FOR EACH ROW EXECUTE FUNCTION vigilante.tg_cambio_datos_senal();

-- 5. Disparador sobre analisis: lo que dice el clasificador ---------------------------------
-- guardar_clasificacion guarda la salida del modelo y después le pone la señal (signal_id).
-- Si la salida trae «cambio» válido, se registra. Y si en esta transacción ya hay un cambio de datos
-- para esa señal, se le añade la noticia que lo trajo.
CREATE OR REPLACE FUNCTION vigilante.tg_cambio_clasificador()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  c jsonb := NEW.salida -> 'cambio'; v_obj bigint; v_ids bigint[]; v_creada timestamptz; v_doc vigilante.raw_items;
BEGIN
  IF NEW.signal_id IS NULL OR NEW.tipo <> 'clasificacion' THEN RETURN NULL; END IF;
  SELECT * INTO v_doc FROM vigilante.raw_items WHERE id = NEW.raw_item_id;
  -- la noticia y sus copias del grupo (misma noticia en otras fuentes)
  v_ids := ARRAY(SELECT sr.raw_item_id FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                  WHERE sr.signal_id = NEW.signal_id
                    AND (r.id = NEW.raw_item_id
                         -- copias del mismo lote (sin análisis propio), no noticias viejas con el mismo título
                         OR (r.titulo_norm = v_doc.titulo_norm AND r.recolectado_en > v_doc.recolectado_en - interval '12 hours'
                             AND NOT EXISTS (SELECT 1 FROM vigilante.analisis a WHERE a.raw_item_id = r.id AND a.id <> NEW.id))));
  IF cardinality(v_ids) = 0 THEN v_ids := ARRAY[NEW.raw_item_id]; END IF;

  IF jsonb_typeof(c) = 'object' AND coalesce(trim(c ->> 'ahora'), '') <> '' THEN
    -- la señal que cambia: la que nombra el clasificador (de las que se le mandaron) o, si no nombra ninguna, la suya
    IF nullif(trim(c ->> 'senal'), '') IS NOT NULL THEN
      SELECT id INTO v_obj FROM vigilante.signals
       WHERE cliente_id = NEW.cliente_id AND codigo = trim(c ->> 'senal') AND duplicado_de IS NULL;
    END IF;
    IF v_obj IS NULL THEN
      SELECT created_at INTO v_creada FROM vigilante.signals WHERE id = NEW.signal_id;
      IF v_creada < now() THEN v_obj := NEW.signal_id; END IF;      -- solo si ya existía antes de esta noticia
    END IF;
    IF v_obj IS NOT NULL THEN
      PERFORM vigilante._registrar_cambio(v_obj, c ->> 'tipo', c ->> 'antes', c ->> 'ahora', '{}',
                                          c ->> 'importancia', v_ids, 'clasificador',
                                          CASE WHEN v_obj <> NEW.signal_id THEN NEW.signal_id END);
      RETURN NULL;
    END IF;
  END IF;

  -- sin «cambio» del clasificador: la noticia se suma al cambio de datos de esta transacción, si lo hay
  UPDATE vigilante.cambios_senal
     SET noticias = ARRAY(SELECT DISTINCT x FROM unnest(noticias || v_ids) x ORDER BY x)
   WHERE signal_id = NEW.signal_id AND txid = txid_current();
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_cambio_clasificador ON vigilante.analisis;
CREATE TRIGGER zz_cambio_clasificador AFTER UPDATE OF signal_id ON vigilante.analisis
  FOR EACH ROW WHEN (NEW.signal_id IS NOT NULL AND OLD.signal_id IS DISTINCT FROM NEW.signal_id)
  EXECUTE FUNCTION vigilante.tg_cambio_clasificador();

-- 6. El clasificador recibe las señales relacionadas ------------------------------------------
-- lote_para_clasificar del 15 queda dentro; esta añade a cada noticia:
--   senal_existente con fechas y estado (antes solo título y resumen)
--   senales_relacionadas: señales abiertas que pueden hablar de lo mismo (máx. 2)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'vigilante' AND p.proname = 'lote_para_clasificar_15') THEN
    ALTER FUNCTION vigilante.lote_para_clasificar(text, int) RENAME TO lote_para_clasificar_15;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar_15(text, int) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.lote_para_clasificar(p_cliente text, p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_lote jsonb; x jsonb; v_out jsonb := '[]';
        r vigilante.raw_items; v_ex bigint;
BEGIN
  v_lote := vigilante.lote_para_clasificar_15(p_cliente, p_limite);
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(v_lote, '[]')) LOOP
    SELECT * INTO r FROM vigilante.raw_items WHERE id = (x ->> 'clave')::bigint;
    v_ex := NULL;
    IF x #>> '{senal_existente,codigo}' IS NOT NULL THEN
      SELECT id INTO v_ex FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = x #>> '{senal_existente,codigo}';
      x := x || jsonb_build_object('senal_existente', vigilante._senal_corta(v_ex));
    END IF;
    x := x || jsonb_build_object('senales_relacionadas',
           vigilante.senales_relacionadas(v_cliente, coalesce(r.titulo, x ->> 'titulo'), coalesce(r.territorios_detectados, '{}'),
                                          CASE WHEN v_ex IS NULL THEN '{}'::bigint[] ELSE ARRAY[v_ex] END, 2));
    v_out := v_out || jsonb_build_array(x);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar(text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.lote_para_clasificar(text, int) TO service_role;

-- 7. Ficha de un cambio (lo que ven Hermes y el panel) -----------------------------------------
CREATE OR REPLACE FUNCTION vigilante._cambio_json(p_id bigint, p_con_texto boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'codigo', c.codigo, 'tipo', c.tipo, 'antes', c.antes, 'ahora', c.ahora, 'campos', c.campos,
    'importancia', c.importancia, 'origen', c.origen, 'estado', c.estado, 'repeticiones', c.repeticiones,
    'titular', c.titular, 'interpretacion', c.interpretacion, 'interpretado_en', c.interpretado_en,
    'detectado', c.created_at, 'actualizado', c.updated_at,
    'senal', vigilante._senal_corta(c.signal_id),
    'senal_nueva', CASE WHEN c.signal_nueva_id IS NOT NULL THEN vigilante._senal_corta(c.signal_nueva_id) END,
    'publicada', (SELECT s.estado = 'publicada' FROM vigilante.signals s WHERE s.id = c.signal_id),
    'eventos', CASE WHEN to_regclass('vigilante.eventos_compuestos') IS NOT NULL THEN (
                 SELECT jsonb_agg(e.codigo ORDER BY e.codigo) FROM vigilante.eventos_compuestos e
                  WHERE e.cliente_id = c.cliente_id AND c.signal_id = ANY (e.senal_ids)
                    AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado')) END,
    'noticias', (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'id', r.id, 'titulo', r.titulo, 'url', r.url, 'fuente', coalesce(src.nombre, 'búsqueda'),
                    'fuente_tipo', coalesce(src.tipo::text, 'no_oficial'), 'publicado_en', r.publicado_en,
                    'recolectado_en', r.recolectado_en,
                    'texto', CASE WHEN p_con_texto THEN left(r.contenido, 600) END)) ORDER BY r.recolectado_en DESC), '[]')
                   FROM (SELECT * FROM vigilante.raw_items WHERE id = ANY (c.noticias) ORDER BY recolectado_en DESC LIMIT 4) r
                   LEFT JOIN vigilante.sources src ON src.id = r.source_id),
    -- para Hermes: lo que decían antes las noticias de la señal
    'noticias_anteriores', CASE WHEN p_con_texto THEN (
                 SELECT coalesce(jsonb_agg(jsonb_build_object('titulo', r.titulo, 'fuente', coalesce(src.nombre, 'búsqueda'),
                                                              'publicado_en', r.publicado_en, 'texto', left(r.contenido, 400))
                                           ORDER BY r.recolectado_en DESC), '[]')
                   FROM (SELECT r.* FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                          WHERE sr.signal_id = c.signal_id AND NOT (r.id = ANY (c.noticias))
                          ORDER BY r.recolectado_en DESC LIMIT 3) r
                   LEFT JOIN vigilante.sources src ON src.id = r.source_id) END))
    FROM vigilante.cambios_senal c WHERE c.id = p_id
$$;
REVOKE ALL ON FUNCTION vigilante._cambio_json(bigint, boolean) FROM public, anon, authenticated;

-- 8. Para Hermes (por el MCP, con la clave de servicio) ---------------------------------------
CREATE OR REPLACE FUNCTION vigilante.cambios_pendientes_hermes(p_cliente text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT count(*)::int FROM vigilante.cambios_senal
   WHERE cliente_id = vigilante.id_cliente(p_cliente)
     AND (estado = 'por_interpretar' OR (estado = 'interpretando' AND tomado_en < now() - interval '30 minutes'))
$$;

CREATE OR REPLACE FUNCTION vigilante.cambios_por_interpretar(p_cliente text, p_limite int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  UPDATE vigilante.cambios_senal SET estado = 'por_interpretar', tomado_en = NULL
   WHERE cliente_id = v_cliente AND estado = 'interpretando' AND tomado_en < now() - interval '30 minutes';
  WITH t AS (
    SELECT id FROM vigilante.cambios_senal
     WHERE cliente_id = v_cliente AND estado = 'por_interpretar'
     ORDER BY vigilante._nivel(importancia::text) DESC, created_at
     LIMIT greatest(least(coalesce(p_limite, 5), 10), 1) FOR UPDATE SKIP LOCKED
  ), u AS (
    UPDATE vigilante.cambios_senal c SET estado = 'interpretando', tomado_en = now()
      FROM t WHERE c.id = t.id RETURNING c.id, c.importancia, c.created_at
  )
  SELECT coalesce(jsonb_agg(vigilante._cambio_json(u.id, true) ORDER BY vigilante._nivel(u.importancia::text) DESC, u.created_at), '[]')
    INTO v FROM u;
  RETURN v;
END $$;

-- Hermes guarda su lectura del cambio. La base comprueba que está completa; el contenido es de Hermes.
--   p_int = {
--     "es_cambio": true,                       -- false = no cambia nada (repite lo mismo, otro hecho…): se descarta con «motivo_descarte»
--     "titular": "Santa Cruz: el ciclón se desvió y ya no llega a Bolivia",
--     "que_cambio": "Antes: … · Ahora: …",     -- 1 o 2 frases, solo hechos de las noticias
--     "significado": "Qué cambia para el turismo",
--     "a_quien_afecta": ["…"],
--     "recomendacion": {"accion": "…", "para_quien": "…", "cuando": "hoy", "verificar_con": "SENAMHI"},
--     "falta_saber": ["…"],
--     "importancia": {"nivel": "alta|media|baja", "motivo": "…"}   -- opcional
--   }
CREATE OR REPLACE FUNCTION vigilante.guardar_interpretacion_cambio(p_cliente text, p_codigo text, p_int jsonb,
                                                                  p_modelo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); c vigilante.cambios_senal; v_rec jsonb := p_int -> 'recomendacion';
  v_imp text := p_int #>> '{importancia,nivel}';
BEGIN
  SELECT * INTO c FROM vigilante.cambios_senal WHERE cliente_id = v_cliente AND codigo = p_codigo FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El cambio % no existe', p_codigo; END IF;
  IF c.estado = 'descartado' THEN RAISE EXCEPTION 'El cambio % está descartado', p_codigo; END IF;
  IF jsonb_typeof(p_int) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'La interpretación debe ser un objeto JSON'; END IF;

  IF (p_int ->> 'es_cambio') = 'false' THEN
    IF coalesce(trim(p_int ->> 'motivo_descarte'), '') = '' THEN
      RAISE EXCEPTION 'Para descartar un cambio hace falta «motivo_descarte»';
    END IF;
    UPDATE vigilante.cambios_senal
       SET estado = 'descartado', motivo_descarte = left(p_int ->> 'motivo_descarte', 500), descartado_por = 'hermes',
           interpretado_por = coalesce(p_modelo, 'hermes'), interpretado_en = now(), tomado_en = NULL
     WHERE id = c.id;
    RETURN jsonb_build_object('ok', true, 'estado', 'descartado');
  END IF;

  IF coalesce(trim(p_int ->> 'titular'), '') = '' THEN RAISE EXCEPTION 'Falta «titular»'; END IF;
  IF coalesce(trim(p_int ->> 'que_cambio'), '') = '' THEN RAISE EXCEPTION 'Falta «que_cambio» (antes y ahora)'; END IF;
  IF coalesce(trim(p_int ->> 'significado'), '') = '' THEN RAISE EXCEPTION 'Falta «significado» (qué cambia para el turismo)'; END IF;
  IF jsonb_typeof(v_rec) IS DISTINCT FROM 'object' OR coalesce(trim(v_rec ->> 'accion'), '') = '' OR coalesce(trim(v_rec ->> 'para_quien'), '') = '' THEN
    RAISE EXCEPTION 'Falta «recomendacion» con «accion» y «para_quien»';
  END IF;
  IF v_imp IS NOT NULL AND (v_imp NOT IN ('alta', 'media', 'baja') OR coalesce(trim(p_int #>> '{importancia,motivo}'), '') = '') THEN
    RAISE EXCEPTION '«importancia» necesita nivel (alta, media o baja) y motivo';
  END IF;

  UPDATE vigilante.cambios_senal SET
    titular = left(trim(p_int ->> 'titular'), 140),
    interpretacion = jsonb_strip_nulls(jsonb_build_object(
      'que_cambio', left(p_int ->> 'que_cambio', 600),
      'significado', left(p_int ->> 'significado', 1000),
      'a_quien_afecta', (SELECT jsonb_agg(left(x, 160)) FROM (SELECT jsonb_array_elements_text(
                           CASE WHEN jsonb_typeof(p_int -> 'a_quien_afecta') = 'array' THEN p_int -> 'a_quien_afecta' ELSE '[]' END) x LIMIT 6) q),
      'recomendacion', jsonb_strip_nulls(jsonb_build_object(
          'accion', left(v_rec ->> 'accion', 400), 'para_quien', left(v_rec ->> 'para_quien', 200),
          'cuando', left(v_rec ->> 'cuando', 120), 'verificar_con', left(v_rec ->> 'verificar_con', 200))),
      'falta_saber', (SELECT jsonb_agg(left(x, 200)) FROM (SELECT jsonb_array_elements_text(
                        CASE WHEN jsonb_typeof(p_int -> 'falta_saber') = 'array' THEN p_int -> 'falta_saber' ELSE '[]' END) x LIMIT 4) q),
      'importancia_motivo', CASE WHEN v_imp IS NOT NULL THEN left(p_int #>> '{importancia,motivo}', 400) END)),
    importancia = coalesce(v_imp::vigilante.prioridad, importancia),
    estado = 'interpretado', interpretado_por = coalesce(p_modelo, 'hermes'), interpretado_en = now(), tomado_en = NULL
   WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'estado', 'interpretado');
END $$;

-- Hermes registra un cambio que encontró investigando (p. ej. al resolver una tarea «contradiccion»).
-- Necesita noticias recogidas que lo prueben: no se registran cambios sin evidencia.
--   p = {"senal": "SEN-0012", "tipo": "desviado", "antes": "…", "ahora": "…", "noticias": [123, 124],
--        "importancia": "alta", "senal_nueva": "SEN-0020"}
CREATE OR REPLACE FUNCTION vigilante.registrar_cambio(p_cliente text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_sig bigint; v_nueva bigint; v_ids bigint[]; v_id bigint;
BEGIN
  PERFORM set_config('vigilante.actor', 'hermes:mcp', true);
  SELECT id INTO v_sig FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = p ->> 'senal';
  IF v_sig IS NULL THEN RAISE EXCEPTION 'La señal % no existe', p ->> 'senal'; END IF;
  IF coalesce(trim(p ->> 'ahora'), '') = '' THEN RAISE EXCEPTION 'Falta «ahora» (qué dice ahora la noticia)'; END IF;
  v_ids := ARRAY(SELECT r.id FROM vigilante.raw_items r WHERE r.cliente_id = v_cliente
                    AND r.id IN (SELECT x::bigint FROM jsonb_array_elements_text(
                                   CASE WHEN jsonb_typeof(p -> 'noticias') = 'array' THEN p -> 'noticias' ELSE '[]' END) x WHERE x ~ '^\d+$'));
  IF cardinality(v_ids) = 0 THEN
    RAISE EXCEPTION 'Un cambio necesita al menos una noticia recogida (noticias = ids de la base). Si no está, pide_busqueda primero';
  END IF;
  SELECT id INTO v_nueva FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = p ->> 'senal_nueva';
  v_id := vigilante._registrar_cambio(v_sig, p ->> 'tipo', p ->> 'antes', p ->> 'ahora', '{}', p ->> 'importancia',
                                      v_ids, 'hermes', v_nueva);
  RETURN jsonb_build_object('ok', v_id IS NOT NULL, 'codigo', (SELECT codigo FROM vigilante.cambios_senal WHERE id = v_id),
                            'nota', 'Queda por interpretar: interprétalo con guardar_interpretacion_cambio');
END $$;

-- Lectura sin reservar (chat de AVIA): cambios de los últimos días
CREATE OR REPLACE FUNCTION vigilante.cambios_abiertos(p_cliente text, p_dias int DEFAULT 3)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(vigilante._cambio_json(c.id) ORDER BY c.created_at DESC), '[]')
    FROM vigilante.cambios_senal c
   WHERE c.cliente_id = vigilante.id_cliente(p_cliente) AND c.estado <> 'descartado'
     AND c.created_at > now() - make_interval(days => greatest(least(coalesce(p_dias, 3), 30), 1))
$$;

REVOKE ALL ON FUNCTION vigilante.cambios_pendientes_hermes(text), vigilante.cambios_por_interpretar(text, int),
                       vigilante.guardar_interpretacion_cambio(text, text, jsonb, text), vigilante.registrar_cambio(text, jsonb),
                       vigilante.cambios_abiertos(text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.cambios_pendientes_hermes(text), vigilante.cambios_por_interpretar(text, int),
                          vigilante.guardar_interpretacion_cambio(text, text, jsonb, text), vigilante.registrar_cambio(text, jsonb),
                          vigilante.cambios_abiertos(text, int) TO service_role;

-- 9. Para el panel (usuario con sesión; solo analistas y administradores) ---------------------
--   alerta = importancia ≥ cambios_alerta_desde y (interpretado, o lleva cambios_espera_hermes_min sin interpretar)
--   visto  = esta persona ya pulsó «Entendido»
CREATE OR REPLACE FUNCTION vigilante.cambios_recientes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.cliente_actual(); v_user uuid := vigilante.usuario_actual();
        v_dias int; v_espera int; v_desde int;
BEGIN
  IF v_cliente IS NULL OR NOT vigilante.es_staff() THEN RETURN '[]'::jsonb; END IF;
  v_dias := coalesce((vigilante.param(v_cliente, 'cambios_dias_panel') #>> '{}')::int, 3);
  v_espera := coalesce((vigilante.param(v_cliente, 'cambios_espera_hermes_min') #>> '{}')::int, 0);
  v_desde := greatest(vigilante._nivel(vigilante.param(v_cliente, 'cambios_alerta_desde') #>> '{}'), 1);
  RETURN (
    SELECT coalesce(jsonb_agg(vigilante._cambio_json(c.id) || jsonb_build_object(
             'alerta', vigilante._nivel(c.importancia::text) >= v_desde
                       AND (c.estado = 'interpretado' OR c.created_at <= now() - make_interval(mins => v_espera)),
             'esperando_hermes', c.estado <> 'interpretado',
             'visto', EXISTS (SELECT 1 FROM vigilante.cambios_vistos v WHERE v.cambio_id = c.id AND v.user_id = v_user))
             ORDER BY c.created_at DESC), '[]')
      FROM vigilante.cambios_senal c
     WHERE c.cliente_id = v_cliente AND c.estado <> 'descartado'
       AND c.created_at > now() - make_interval(days => v_dias));
END $$;

-- p_codigo NULL = marcar todos los recientes como vistos
CREATE OR REPLACE FUNCTION vigilante.marcar_cambio_visto(p_codigo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_user uuid := vigilante.usuario_actual(); v_n int;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Hace falta iniciar sesión'; END IF;
  INSERT INTO vigilante.cambios_vistos (cambio_id, user_id)
  SELECT c.id, v_user FROM vigilante.cambios_senal c
   WHERE c.cliente_id = vigilante.cliente_actual() AND (p_codigo IS NULL OR c.codigo = p_codigo)
     AND c.created_at > now() - interval '30 days'
  ON CONFLICT (cambio_id, user_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF p_codigo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vigilante.cambios_senal WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo) THEN
    RAISE EXCEPTION 'El cambio % no existe', p_codigo;
  END IF;
  RETURN jsonb_build_object('ok', true, 'marcados', v_n);
END $$;

-- Un analista descarta un cambio que no lo es (para todo el equipo)
CREATE OR REPLACE FUNCTION vigilante.descartar_cambio(p_codigo text, p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_quien text;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede descartar cambios'; END IF;
  IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Escribe el motivo del descarte'; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  UPDATE vigilante.cambios_senal
     SET estado = 'descartado', motivo_descarte = left(p_motivo, 500), descartado_por = coalesce(v_quien, 'analista'), tomado_en = NULL
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND estado <> 'descartado';
  IF NOT FOUND THEN RAISE EXCEPTION 'El cambio % no existe o ya está descartado', p_codigo; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION vigilante.cambios_recientes(), vigilante.marcar_cambio_visto(text),
                       vigilante.descartar_cambio(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.cambios_recientes(), vigilante.marcar_cambio_visto(text),
                          vigilante.descartar_cambio(text, text) TO authenticated, service_role;

COMMIT;
