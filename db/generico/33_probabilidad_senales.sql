-- =============================================================================
-- 33. Probabilidad de ocurrencia en las señales confirmadas: la base calcula, AVIA ajusta en una frase
-- =============================================================================
-- Qué faltaba: una señal confirmada decía QUÉ pasa, pero no qué tan probable es que ocurra de verdad
-- (que la lluvia llegue, que la feria se haga, que el bloqueo se cumpla) ni por qué.
--
-- Ahora, SOLO cuando una señal pasa a «Confirmada» (a mano, en bloque o sola por ser oficial):
--
--   1. La BASE calcula una probabilidad (0 a 1) sin IA, en el mismo momento:
--        base = (peso de la mejor fuente / 5) × 0,5
--             + (fuentes distintas, hasta 4) / 4 × 0,3
--             + tasa de confirmación de su categoría (últimos 90 días) × 0,2
--      Peso de la fuente (el mismo techo del 32): 5 oficial · 4 organismo internacional · 3 medio ·
--      2 búsqueda sin fuente del catálogo · 1 no oficial.
--      Tasa de la categoría = confirmadas / (confirmadas + descartadas) en 90 días; con menos de 3
--      señales decididas se usa 0,5 (neutro) y se dice. Nunca baja de 5 % ni pasa de 95 %.
--      Se guarda con su razón («Cálculo base: …»), así que la tarjeta ya muestra algo aunque AVIA no llegue.
--
--   2. AVIA (Hermes, skill «avia-probabilidad») recibe en lote la señal, la base, sus tres factores y
--      tres líneas de contexto (época del año, zona, historial) y devuelve lo mínimo:
--        {"codigo": "SEN-0012", "prob": 0.78, "razon": "una frase"}
--      La base no deja que se aleje más de ±0,20 de su cálculo (prob_ajuste_max): AVIA matiza, no inventa.
--      Coste: una llamada para hasta 10 señales, ~150 tokens de entrada por señal y ~40 de salida.
--
--   3. Se guarda en la propia señal: prob_ocurrencia (la final) y prob_razon (una frase), más
--      prob_base, prob_origen ('base' o 'avia'), prob_factores y prob_calculada_en.
--      Si la señal vuelve a Detectadas o se descarta, se borra; al volver a confirmarla se recalcula.
--      Si llegan noticias nuevas a una confirmada que aún no ajustó AVIA, la base se recalcula.
--
-- Dónde se ve: vigilante.puntuaciones() (del 22) devuelve esta probabilidad en «probabilidad» cuando
-- existe, así que llega sola a vigilante_bd(), al panel (tarjeta de Confirmadas y ficha de la señal)
-- y al chat de AVIA. Las señales no confirmadas siguen como antes.
--
-- Necesita del 01 al 32 (usa vigilante._peso_fuente y vigilante._noticias_senal del 32).
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run. Se puede ejecutar más de una vez.
-- Prueba: 99_prueba_probabilidad.sql (termina en ROLLBACK). Guía: docs/probabilidad-senales.md
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante._peso_fuente(text)') IS NULL OR to_regprocedure('vigilante._noticias_senal(bigint)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 32 (ficha_aprobacion): ejecútalo antes que este';
  END IF;
END $$;

-- 0. Parámetros (cada cliente puede sobrescribirlos) ---------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'prob_activa', 'true', 'Calcular la probabilidad de ocurrencia al confirmar una señal'),
  (NULL, 'prob_ajuste_max', '0.20', 'Cuánto puede subir o bajar AVIA la probabilidad base (0 a 0,5)'),
  (NULL, 'prob_tasa_dias', '90', 'Días de historial para la tasa de confirmación de la categoría'),
  (NULL, 'prob_horas_avia', '72', 'AVIA solo ajusta señales creadas o actualizadas en estas horas (las más viejas se quedan con la base)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Columnas en la señal y reserva de Hermes ------------------------------------------
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_ocurrencia   numeric(3,2) CHECK (prob_ocurrencia BETWEEN 0 AND 1);
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_razon        text;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_base         numeric(3,2) CHECK (prob_base BETWEEN 0 AND 1);
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_origen       text CHECK (prob_origen IN ('base', 'avia'));
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_factores     jsonb;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS prob_calculada_en timestamptz;
COMMENT ON COLUMN vigilante.signals.prob_ocurrencia IS
  'Probabilidad de que ocurra (0-1), solo en señales confirmadas (33): base de la base de datos, ajustada por AVIA';
COMMENT ON COLUMN vigilante.signals.prob_razon IS 'Por qué esa probabilidad, en una frase (33)';

-- Reserva aparte: así tomar señales no toca la tabla de señales (ni su historial)
CREATE TABLE IF NOT EXISTS vigilante.prob_reservas (
  signal_id  bigint PRIMARY KEY REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  tomada_en  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE vigilante.prob_reservas ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones

-- 2. Cálculo base (sin IA) ---------------------------------------------------------------
-- Recibe los datos sueltos porque al insertar una señal ya confirmada (oficial) la fila aún no existe.
CREATE OR REPLACE FUNCTION vigilante._prob_calcular(p_cliente uuid, p_signal bigint, p_raw bigint, p_source integer,
                                                   p_categoria text, p_oficial boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_peso int; v_fuentes int; v_conf int; v_desc int; v_tasa numeric; v_base numeric; v_dias int; v_mejor text;
  v_cat text;
BEGIN
  -- Noticias de la señal (enlazadas + la de origen) y sus fuentes
  SELECT max(vigilante._peso_fuente(src.tipo::text)),
         count(DISTINCT coalesce('f' || r.source_id::text, 'r' || r.id::text)),
         (array_agg(coalesce(src.nombre, 'búsqueda') ORDER BY vigilante._peso_fuente(src.tipo::text) DESC))[1]
    INTO v_peso, v_fuentes, v_mejor
    FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id
   WHERE r.id = ANY (vigilante._noticias_senal(p_signal) || coalesce(p_raw, -1));
  IF v_peso IS NULL THEN   -- sin noticias: la fuente de la señal o, si no hay, lo que diga fuente_oficial
    SELECT vigilante._peso_fuente(tipo::text), nombre INTO v_peso, v_mejor FROM vigilante.sources WHERE id = p_source;
    v_peso := coalesce(v_peso, CASE WHEN p_oficial THEN 5 ELSE 2 END);
    v_fuentes := 1;
  END IF;
  IF p_oficial THEN v_peso := greatest(v_peso, 5); END IF;
  v_fuentes := greatest(v_fuentes, 1);

  -- Tasa de confirmación de la categoría
  v_dias := coalesce((vigilante.param(p_cliente, 'prob_tasa_dias') #>> '{}')::int, 90);
  SELECT count(*) FILTER (WHERE estado IN ('confirmada', 'publicada', 'cerrada')), count(*) FILTER (WHERE estado = 'descartada')
    INTO v_conf, v_desc
    FROM vigilante.signals
   WHERE cliente_id = p_cliente AND categoria = p_categoria AND id IS DISTINCT FROM p_signal
     AND duplicado_de IS NULL AND created_at > now() - make_interval(days => v_dias);
  v_tasa := CASE WHEN v_conf + v_desc >= 3 THEN round(v_conf::numeric / (v_conf + v_desc), 2) ELSE 0.5 END;

  v_base := round(v_peso / 5.0 * 0.5 + least(v_fuentes, 4) / 4.0 * 0.3 + v_tasa * 0.2, 2);
  v_base := least(greatest(v_base, 0.05), 0.95);
  SELECT coalesce(nombre, p_categoria) INTO v_cat FROM vigilante.categorias WHERE cliente_id = p_cliente AND codigo = p_categoria;

  RETURN jsonb_build_object(
    'base', v_base, 'peso', v_peso, 'fuentes', v_fuentes, 'tasa', v_tasa,
    'tasa_confirmadas', v_conf, 'tasa_descartadas', v_desc, 'tasa_dias', v_dias,
    'razon', 'Cálculo base: ' || CASE v_peso WHEN 5 THEN 'fuente oficial' WHEN 4 THEN 'organismo internacional'
                                             WHEN 3 THEN 'medio de prensa' WHEN 2 THEN 'búsqueda o medio sin documento'
                                             ELSE 'fuente no oficial' END
             || coalesce(' (' || v_mejor || ')', '') || ', '
             || v_fuentes || CASE WHEN v_fuentes = 1 THEN ' fuente' ELSE ' fuentes distintas' END || ' y '
             || CASE WHEN v_conf + v_desc >= 3
                     THEN round(v_tasa * 100) || ' % de las señales de ' || lower(coalesce(v_cat, p_categoria))
                          || ' confirmadas en ' || v_dias || ' días'
                     ELSE 'poco historial de ' || lower(coalesce(v_cat, p_categoria)) END || '.');
END $$;
REVOKE ALL ON FUNCTION vigilante._prob_calcular(uuid, bigint, bigint, integer, text, boolean) FROM public, anon, authenticated;

-- 3. Disparador: al confirmar se calcula; al volver atrás se borra ---------------------------
-- Se llama zzz_ para ejecutarse después de las reglas (01), de zz_sin_aprobacion_y_oficiales (29,
-- que puede confirmar sola una señal oficial) y de signals_updated_at.
CREATE OR REPLACE FUNCTION vigilante.tg_probabilidad_senal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v jsonb; v_quitar text[] := ARRAY['prob_ocurrencia', 'prob_razon', 'prob_base', 'prob_origen', 'prob_factores',
                                          'prob_calculada_en', 'updated_at', 'busqueda'];
BEGIN
  IF NEW.estado = 'confirmada' AND (TG_OP = 'INSERT' OR OLD.estado IS DISTINCT FROM 'confirmada')
     AND NOT (TG_OP = 'UPDATE' AND OLD.estado = 'publicada' AND NEW.prob_ocurrencia IS NOT NULL)   -- retirada de la web: se queda
     AND coalesce((vigilante.param(NEW.cliente_id, 'prob_activa') #>> '{}')::boolean, true) THEN
    v := vigilante._prob_calcular(NEW.cliente_id, NEW.id, NEW.raw_item_id, NEW.source_id, NEW.categoria, NEW.fuente_oficial);
    NEW.prob_base := (v ->> 'base')::numeric;
    NEW.prob_ocurrencia := NEW.prob_base;
    NEW.prob_razon := v ->> 'razon';
    NEW.prob_origen := 'base';
    NEW.prob_factores := v - 'razon' - 'base';
    NEW.prob_calculada_en := now();
  ELSIF TG_OP = 'UPDATE' AND NEW.estado IN ('detectada', 'en_analisis', 'en_verificacion', 'descartada')
        AND NEW.prob_ocurrencia IS NOT NULL THEN
    NEW.prob_ocurrencia := NULL; NEW.prob_razon := NULL; NEW.prob_base := NULL; NEW.prob_origen := NULL;
    NEW.prob_factores := NULL; NEW.prob_calculada_en := NULL;
  END IF;
  -- Si solo cambió la probabilidad, la señal no cuenta como «actualizada» (no reaparece como reciente)
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - v_quitar) = (to_jsonb(OLD) - v_quitar) THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zzz_probabilidad ON vigilante.signals;
CREATE TRIGGER zzz_probabilidad BEFORE INSERT OR UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_probabilidad_senal();

-- Recalcula la base de una confirmada que AVIA aún no ajustó (llegó una noticia)
CREATE OR REPLACE FUNCTION vigilante._prob_refrescar(p_signal bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE s vigilante.signals; v jsonb;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND OR s.estado NOT IN ('confirmada', 'publicada') OR s.prob_origen IS DISTINCT FROM 'base' THEN RETURN; END IF;
  v := vigilante._prob_calcular(s.cliente_id, s.id, s.raw_item_id, s.source_id, s.categoria, s.fuente_oficial);
  IF (v ->> 'base')::numeric IS DISTINCT FROM s.prob_base OR v ->> 'razon' IS DISTINCT FROM s.prob_razon THEN
    UPDATE vigilante.signals SET prob_base = (v ->> 'base')::numeric, prob_ocurrencia = (v ->> 'base')::numeric,
           prob_razon = v ->> 'razon', prob_factores = v - 'razon' - 'base', prob_calculada_en = now()
     WHERE id = s.id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante._prob_refrescar(bigint) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.tg_probabilidad_noticia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  PERFORM vigilante._prob_refrescar(NEW.signal_id);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zzz_probabilidad ON vigilante.signal_raw_items;
CREATE TRIGGER zzz_probabilidad AFTER INSERT ON vigilante.signal_raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_probabilidad_noticia();

-- 4. Para Hermes (por el MCP, con la clave de servicio) ---------------------------------------
-- Pendientes: confirmadas (o ya publicadas) con la base sin ajustar, recientes, sin reserva viva
CREATE OR REPLACE FUNCTION vigilante._prob_pendientes(p_cliente uuid)
RETURNS TABLE (signal_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.id FROM vigilante.signals s
    LEFT JOIN vigilante.prob_reservas r ON r.signal_id = s.id
   WHERE s.cliente_id = p_cliente
     AND s.estado IN ('confirmada', 'publicada')
     AND s.prob_origen = 'base'
     AND greatest(s.created_at, s.updated_at)
         > now() - make_interval(hours => coalesce((vigilante.param(p_cliente, 'prob_horas_avia') #>> '{}')::int, 72))
     AND (r.signal_id IS NULL OR r.tomada_en < now() - interval '30 minutes')
   ORDER BY vigilante._nivel(s.prioridad::text) DESC, s.prob_calculada_en
$$;
REVOKE ALL ON FUNCTION vigilante._prob_pendientes(uuid) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.probabilidades_pendientes_hermes(p_cliente text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT count(*)::int FROM vigilante._prob_pendientes(vigilante.id_cliente(p_cliente))
$$;

-- Lo mínimo para ajustar: la señal, la base con sus factores y 3 líneas de contexto
CREATE OR REPLACE FUNCTION vigilante._prob_entrada(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH s AS (SELECT * FROM vigilante.signals WHERE id = p_signal),
  deps AS (SELECT array_agg(t.nombre ORDER BY t.nombre) AS nombres, array_agg(t.id) AS ids
             FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id
            WHERE st.signal_id = p_signal),
  mes AS (SELECT extract(month FROM now() AT TIME ZONE coalesce(c.zona_horaria, 'America/La_Paz'))::int AS m
            FROM s JOIN vigilante.clientes c ON c.id = s.cliente_id),
  zona AS (SELECT count(DISTINCT o.id) AS n,
                  count(DISTINCT o.id) FILTER (WHERE o.estado IN ('confirmada', 'publicada', 'cerrada')) AS conf
             FROM s, deps, vigilante.signals o JOIN vigilante.signal_territorios ot ON ot.signal_id = o.id
            WHERE o.cliente_id = s.cliente_id AND o.categoria = s.categoria AND o.id <> s.id AND o.duplicado_de IS NULL
              AND o.created_at > now() - make_interval(days => coalesce((s.prob_factores ->> 'tasa_dias')::int, 90))
              AND ot.territorio_id = ANY (deps.ids))
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'codigo', s.codigo, 'titulo', left(s.titulo, 140), 'resumen', left(s.resumen, 200),
    'naturaleza', s.naturaleza, 'categoria', s.categoria, 'escenario', CASE WHEN s.es_escenario THEN true END,
    'cuando', nullif(concat_ws(' → ', vigilante._dia(s.fecha_evento_inicio), vigilante._dia(s.fecha_evento_fin)), ''),
    'plazo_hasta', vigilante._dia(s.plazo_hasta),
    'base', s.prob_base,
    -- lo que ya dijo el clasificador, si lo justificó (gratis: ya está guardado)
    'clasificador', CASE WHEN (s.salida_modelo #>> '{probabilidad,valor}') ~ '^(0(\.\d+)?|1(\.0+)?)$'
                          AND coalesce(trim(s.salida_modelo #>> '{probabilidad,justificacion}'), '') <> ''
                         THEN jsonb_build_object('prob', (s.salida_modelo #>> '{probabilidad,valor}')::numeric,
                                                 'razon', left(s.salida_modelo #>> '{probabilidad,justificacion}', 160)) END,
    'factores', jsonb_build_object('peso_fuente', s.prob_factores -> 'peso', 'fuentes', s.prob_factores -> 'fuentes',
                                   'tasa_categoria', s.prob_factores -> 'tasa'),
    'contexto', jsonb_build_array(
      'Época: ' || (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'])[mes.m]
        || CASE WHEN mes.m IN (11, 12, 1, 2, 3) THEN ', temporada de lluvias (noviembre a marzo)'
                WHEN mes.m IN (5, 6, 7, 8, 9) THEN ', temporada seca y fría en el altiplano (mayo a septiembre)'
                ELSE ', cambio de estación' END,
      'Zona: ' || CASE WHEN s.alcance_total THEN 'todo el país'
                       ELSE coalesce(array_to_string(deps.nombres, ', '), 'sin departamento') END,
      'Historial ' || coalesce(s.prob_factores ->> 'tasa_dias', '90') || ' días en ' || s.categoria || ': confirmadas '
        || coalesce(s.prob_factores ->> 'tasa_confirmadas', '0') || ', descartadas '
        || coalesce(s.prob_factores ->> 'tasa_descartadas', '0')
        || CASE WHEN deps.ids IS NOT NULL THEN '; en esta zona ' || zona.n || ' señales, ' || zona.conf || ' confirmadas' ELSE '' END)))
    FROM s, deps, mes, zona
$$;
REVOKE ALL ON FUNCTION vigilante._prob_entrada(bigint) FROM public, anon, authenticated;

-- Reserva hasta p_limite señales (30 min) y las devuelve
CREATE OR REPLACE FUNCTION vigilante.probabilidades_por_ajustar(p_cliente text, p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_ids bigint[]; v jsonb;
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'El cliente % no existe', p_cliente; END IF;
  v_ids := ARRAY(SELECT signal_id FROM vigilante._prob_pendientes(v_cliente) LIMIT greatest(least(coalesce(p_limite, 10), 10), 1));
  INSERT INTO vigilante.prob_reservas (signal_id, tomada_en) SELECT x, now() FROM unnest(v_ids) x
  ON CONFLICT (signal_id) DO UPDATE SET tomada_en = now();
  SELECT coalesce(jsonb_agg(vigilante._prob_entrada(x) ORDER BY o), '[]') INTO v FROM unnest(v_ids) WITH ORDINALITY AS u(x, o);
  RETURN v;
END $$;

-- Hermes guarda en lote: [{"codigo": "SEN-0012", "prob": 0.78, "razon": "una frase"}, …]
-- La base acota el ajuste a ±prob_ajuste_max de su cálculo y a 5-95 %; si se pasa, lo recorta y lo dice.
CREATE OR REPLACE FUNCTION vigilante.guardar_probabilidades(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; s vigilante.signals; v_p numeric; v_final numeric;
  v_razon text; v_max numeric; v_ok jsonb := '[]'; v_mal jsonb := '[]';
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'El cliente % no existe', p_cliente; END IF;
  IF jsonb_typeof(p_resultados) = 'object' THEN p_resultados := jsonb_build_array(p_resultados); END IF;
  IF jsonb_typeof(p_resultados) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Manda una lista: [{"codigo", "prob", "razon"}]'; END IF;
  v_max := least(greatest(coalesce((vigilante.param(v_cliente, 'prob_ajuste_max') #>> '{}')::numeric, 0.20), 0), 0.5);

  FOR x IN SELECT * FROM jsonb_array_elements(p_resultados) LOOP
    SELECT * INTO s FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = x ->> 'codigo';
    IF NOT FOUND THEN v_mal := v_mal || jsonb_build_object('codigo', x ->> 'codigo', 'error', 'no existe'); CONTINUE; END IF;
    IF s.estado NOT IN ('confirmada', 'publicada') OR s.prob_base IS NULL THEN
      v_mal := v_mal || jsonb_build_object('codigo', s.codigo, 'error', 'ya no está confirmada'); CONTINUE;
    END IF;
    IF coalesce(x ->> 'prob', '') !~ '^(0(\.\d+)?|1(\.0+)?|\.\d+)$' THEN
      v_mal := v_mal || jsonb_build_object('codigo', s.codigo, 'error', '«prob» debe ser un número de 0 a 1'); CONTINUE;
    END IF;
    v_razon := regexp_replace(trim(coalesce(x ->> 'razon', '')), '\s+', ' ', 'g');
    IF v_razon = '' THEN v_mal := v_mal || jsonb_build_object('codigo', s.codigo, 'error', 'falta «razon»'); CONTINUE; END IF;
    IF length(v_razon) > 200 THEN v_razon := left(v_razon, 197) || '…'; END IF;

    v_p := (x ->> 'prob')::numeric;
    v_final := round(least(greatest(v_p, s.prob_base - v_max, 0.05), s.prob_base + v_max, 0.95), 2);
    UPDATE vigilante.signals SET prob_ocurrencia = v_final, prob_razon = v_razon, prob_origen = 'avia',
           prob_factores = coalesce(prob_factores, '{}') || jsonb_build_object('avia_propuso', v_p, 'modelo', coalesce(p_modelo, 'hermes')),
           prob_calculada_en = now()
     WHERE id = s.id;
    DELETE FROM vigilante.prob_reservas WHERE signal_id = s.id;
    v_ok := v_ok || jsonb_strip_nulls(jsonb_build_object('codigo', s.codigo, 'prob', v_final,
              'recortada', CASE WHEN v_final <> round(v_p, 2) THEN 'Fuera de ±' || v_max || ' de la base (' || s.prob_base || '): se guardó ' || v_final END));
  END LOOP;
  RETURN jsonb_build_object('guardadas', v_ok, 'errores', v_mal);
END $$;

REVOKE ALL ON FUNCTION vigilante.probabilidades_pendientes_hermes(text), vigilante.probabilidades_por_ajustar(text, int),
                       vigilante.guardar_probabilidades(text, jsonb, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.probabilidades_pendientes_hermes(text), vigilante.probabilidades_por_ajustar(text, int),
                          vigilante.guardar_probabilidades(text, jsonb, text)
  TO service_role;

-- 5. Puntuaciones (del 22): la probabilidad de las confirmadas sale de aquí ---------------------
-- Igual que en el 22; solo cambia el apartado 2.
CREATE OR REPLACE FUNCTION vigilante.puntuaciones(p_signal bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; m jsonb;
  v_noticias int; v_fuentes int; v_oficial boolean; v_persona boolean; v_fia int;
  v_motivos text[] := '{}';
  v_prob jsonb; v_imp jsonb; v_p numeric; v_rel numeric;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND THEN RETURN NULL; END IF;
  m := coalesce(s.salida_modelo, '{}');

  -- 1. Fiabilidad de la evidencia (solo hechos de la base)
  SELECT count(*), count(DISTINCT coalesce(r.source_id::text, 'b' || coalesce(r.busqueda_id::text, r.id::text))),
         coalesce(bool_or(src.tipo IN ('oficial', 'organismo_internacional')), false)
    INTO v_noticias, v_fuentes, v_oficial
    FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
    LEFT JOIN vigilante.sources src ON src.id = r.source_id
   WHERE sr.signal_id = s.id;
  IF v_noticias = 0 AND jsonb_typeof(m -> 'enlaces') = 'array' THEN   -- señales antiguas copiadas de vigilante.json
    SELECT count(DISTINCT coalesce(e ->> 'nombre', e ->> 'url')) INTO v_fuentes FROM jsonb_array_elements(m -> 'enlaces') e;
  END IF;
  v_oficial := v_oficial OR s.fuente_oficial;
  v_persona := s.estado IN ('confirmada', 'publicada');
  v_fia := least(100, (CASE WHEN v_oficial THEN 50 ELSE 0 END)
                    + (CASE WHEN v_fuentes >= 3 THEN 40 WHEN v_fuentes = 2 THEN 30 WHEN v_fuentes = 1 THEN 15 ELSE 0 END)
                    + (CASE WHEN v_persona THEN 10 ELSE 0 END));
  v_motivos := v_motivos || CASE WHEN v_oficial THEN 'Fuente oficial (+50)' ELSE 'Ninguna fuente oficial (+0)' END;
  v_motivos := v_motivos || CASE WHEN v_fuentes = 0 THEN 'Sin noticias enlazadas (+0)'
                                 ELSE v_fuentes || CASE WHEN v_fuentes = 1 THEN ' fuente' ELSE ' fuentes distintas' END
                                      || ' (+' || CASE WHEN v_fuentes >= 3 THEN 40 WHEN v_fuentes = 2 THEN 30 ELSE 15 END || ')' END;
  v_motivos := v_motivos || CASE WHEN v_persona THEN 'Confirmada por una persona (+10)' ELSE 'Sin confirmar por una persona (+0)' END;

  -- 2. Probabilidad de ocurrencia: la del 33 en las confirmadas; si no, la del modelo solo si la justificó
  IF s.prob_ocurrencia IS NOT NULL AND s.estado IN ('confirmada', 'publicada') THEN
    v_p := s.prob_ocurrencia;
    v_prob := jsonb_build_object('valor', v_p, 'nivel', CASE WHEN v_p >= 0.7 THEN 'alta' WHEN v_p >= 0.4 THEN 'media' ELSE 'baja' END,
                                 'justificacion', s.prob_razon, 'origen', s.prob_origen, 'base', s.prob_base,
                                 'calculada_en', s.prob_calculada_en);
  ELSIF jsonb_typeof(m -> 'probabilidad') = 'object' AND (m #>> '{probabilidad,valor}') ~ '^(0(\.\d+)?|1(\.0+)?)$'
     AND coalesce(trim(m #>> '{probabilidad,justificacion}'), '') <> '' THEN
    v_p := (m #>> '{probabilidad,valor}')::numeric;
    v_prob := jsonb_build_object('valor', v_p, 'nivel', CASE WHEN v_p >= 0.7 THEN 'alta' WHEN v_p >= 0.4 THEN 'media' ELSE 'baja' END,
                                 'justificacion', m #>> '{probabilidad,justificacion}');
  ELSE
    v_prob := jsonb_build_object('valor', NULL, 'nivel', 'sin datos',
                                 'justificacion', 'No hay datos para estimar si pasará; no se inventa');
  END IF;

  -- 3. Impacto turístico: el del modelo con motivo; si no, su relevancia (y se dice)
  IF (m #>> '{impacto,nivel}') IN ('alto', 'medio', 'bajo') AND coalesce(trim(m #>> '{impacto,motivo}'), '') <> '' THEN
    v_imp := jsonb_build_object('nivel', m #>> '{impacto,nivel}', 'motivo', m #>> '{impacto,motivo}', 'origen', 'modelo');
  ELSE
    v_rel := CASE WHEN (m ->> 'relevancia') ~ '^\d+(\.\d+)?$' THEN (m ->> 'relevancia')::numeric
                  WHEN s.puntaje IS NOT NULL THEN s.puntaje / 10 END;
    v_imp := CASE WHEN v_rel IS NULL AND s.prioridad IS NOT NULL
                  THEN jsonb_build_object('nivel', CASE s.prioridad WHEN 'alta' THEN 'alto' WHEN 'media' THEN 'medio' ELSE 'bajo' END,
                                          'motivo', 'Deducido de la prioridad que dio AVIA (' || s.prioridad || ')'
                                                    || coalesce(': ' || nullif(array_to_string(s.motivos_prioridad, ', '), ''), ''),
                                          'origen', 'prioridad')
                  WHEN v_rel IS NULL
                  THEN jsonb_build_object('nivel', 'sin datos', 'motivo', 'AVIA no valoró el impacto de esta señal', 'origen', 'ninguno')
                  ELSE jsonb_build_object('nivel', CASE WHEN v_rel >= 7 THEN 'alto' WHEN v_rel >= 4 THEN 'medio' ELSE 'bajo' END,
                                          'motivo', 'Deducido de la relevancia turística que dio AVIA (' || round(v_rel, 1) || '/10)',
                                          'origen', 'relevancia') END;
  END IF;

  RETURN jsonb_build_object(
    'fiabilidad', jsonb_build_object('valor', v_fia,
                                     'nivel', CASE WHEN v_fia >= 70 THEN 'alta' WHEN v_fia >= 40 THEN 'media' ELSE 'baja' END,
                                     'motivos', to_jsonb(v_motivos), 'noticias', v_noticias, 'fuentes', v_fuentes, 'oficial', v_oficial),
    'probabilidad', v_prob,
    'impacto', v_imp);
END $$;
REVOKE ALL ON FUNCTION vigilante.puntuaciones(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.puntuaciones(bigint) TO authenticated, service_role;

-- 6. Las que ya están confirmadas reciben su cálculo base (AVIA solo ajusta las de las últimas 72 h) ----
UPDATE vigilante.signals s SET
  prob_base = (v ->> 'base')::numeric, prob_ocurrencia = (v ->> 'base')::numeric, prob_razon = v ->> 'razon',
  prob_origen = 'base', prob_factores = v - 'razon' - 'base', prob_calculada_en = now()
  FROM (SELECT id, vigilante._prob_calcular(cliente_id, id, raw_item_id, source_id, categoria, fuente_oficial) AS v
          FROM vigilante.signals WHERE estado = 'confirmada' AND prob_ocurrencia IS NULL) c
 WHERE s.id = c.id;

COMMIT;
