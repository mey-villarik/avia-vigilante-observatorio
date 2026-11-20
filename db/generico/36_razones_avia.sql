-- 36 · Razones de AVIA: por qué esa fiabilidad, esa probabilidad y ese impacto, en texto
--
-- Pedido de Meysel (2026-11-20): al pasar el ratón por la fiabilidad, la probabilidad o el impacto de una
-- señal confirmada no debe salir la fórmula, sino la interpretación de AVIA en una frase. Ejemplo:
-- «AVIA determina que la fiabilidad es del 40 % porque estos hechos siempre ocurren en invierno y en
-- estas fechas, y la fuente es un medio de prensa no oficial».
--
-- Cómo se determina cada número (no cambia con este archivo):
--   · Fiabilidad (22): la calcula la base, sin IA, con el tipo de fuente, cuántas fuentes distintas y si
--     la confirmó una persona. AVIA no la cambia: solo explica por qué es así.
--   · Probabilidad (33): la base calcula una base al confirmar y AVIA la ajusta (±0,20) con la época,
--     la zona y el historial.
--   · Impacto (22): lo da el analizador de AVIA (alto/medio/bajo) o se deduce de su relevancia turística.
--
-- Lo nuevo: en la misma ronda de la skill avia-probabilidad (una sola llamada al modelo por lote, sin
-- gastar más rondas), AVIA escribe tres «porqués» y se guardan en la señal:
--   prob_razon (ya existía, 33) · razon_fiabilidad · razon_impacto · razones_en
-- Cada razón es lo que va después de «porque», sin el número: el panel compone
--   «AVIA determina que la probabilidad es del 82 % porque <razón>».
-- Así el número que se lee es siempre el guardado (aunque la base recorte el ajuste).
--
-- Señales confirmadas que ya tenían probabilidad sin estas razones: entran solas en la siguiente ronda
-- (las de los últimos `razones_dias`, 30 por defecto) y AVIA solo las rellena (repite su probabilidad).
-- Si llega una noticia nueva a la señal, la fiabilidad puede cambiar: se borra su razón y AVIA la rehace.
-- Si la señal vuelve atrás (detectada, en análisis, descartada), se borran las tres.
--
-- Requiere 01 a 33. Se puede ejecutar más de una vez.
BEGIN;

-- 1. Columnas ----------------------------------------------------------------------------------
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS razon_fiabilidad text;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS razon_impacto    text;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS razones_en       timestamptz;
COMMENT ON COLUMN vigilante.signals.razon_fiabilidad IS 'Por qué esa fiabilidad según AVIA, lo que va tras «porque» (36)';
COMMENT ON COLUMN vigilante.signals.razon_impacto IS 'Por qué ese impacto turístico según AVIA, lo que va tras «porque» (36)';
COMMENT ON COLUMN vigilante.signals.razones_en IS 'Cuándo escribió AVIA las razones (36); NULL = pendientes';

-- 2. Disparadores: borrar razones que ya no valen -----------------------------------------------
-- zzzz_ para ir después de zzz_probabilidad (33), que ya decidió si la probabilidad se queda o se borra.
CREATE OR REPLACE FUNCTION vigilante.tg_razones_senal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_quitar text[] := ARRAY['prob_ocurrencia', 'prob_razon', 'prob_base', 'prob_origen', 'prob_factores',
                                 'prob_calculada_en', 'razon_fiabilidad', 'razon_impacto', 'razones_en',
                                 'updated_at', 'busqueda'];
BEGIN
  IF NEW.estado NOT IN ('confirmada', 'publicada') OR NEW.prob_ocurrencia IS NULL THEN
    NEW.razon_fiabilidad := NULL; NEW.razon_impacto := NULL; NEW.razones_en := NULL;
  ELSIF TG_OP = 'UPDATE' AND NEW.salida_modelo IS DISTINCT FROM OLD.salida_modelo
        AND NEW.razones_en IS NOT DISTINCT FROM OLD.razones_en THEN
    -- el analizador volvió a valorar la señal: el impacto puede ser otro
    NEW.razon_impacto := NULL; NEW.razones_en := NULL;
  END IF;
  -- Si solo cambiaron la probabilidad o las razones, la señal no cuenta como «actualizada»
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - v_quitar) = (to_jsonb(OLD) - v_quitar) THEN
    NEW.updated_at := OLD.updated_at;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zzzz_razones ON vigilante.signals;
CREATE TRIGGER zzzz_razones BEFORE INSERT OR UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_razones_senal();

-- Noticia nueva en la señal: cambia la evidencia, AVIA vuelve a explicar la fiabilidad
CREATE OR REPLACE FUNCTION vigilante.tg_razones_noticia()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  UPDATE vigilante.signals SET razon_fiabilidad = NULL, razones_en = NULL
   WHERE id = NEW.signal_id AND razones_en IS NOT NULL;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zzzz_razones ON vigilante.signal_raw_items;
CREATE TRIGGER zzzz_razones AFTER INSERT ON vigilante.signal_raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_razones_noticia();

-- 3. Pendientes para AVIA: las de siempre (33) + las confirmadas sin razones ----------------------
CREATE OR REPLACE FUNCTION vigilante._prob_pendientes(p_cliente uuid)
RETURNS TABLE (signal_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.id FROM vigilante.signals s
    LEFT JOIN vigilante.prob_reservas r ON r.signal_id = s.id
   WHERE s.cliente_id = p_cliente
     AND s.estado IN ('confirmada', 'publicada')
     AND s.prob_ocurrencia IS NOT NULL
     AND ((s.prob_origen = 'base'
           AND greatest(s.created_at, s.updated_at)
               > now() - make_interval(hours => coalesce((vigilante.param(p_cliente, 'prob_horas_avia') #>> '{}')::int, 72)))
       OR (s.razones_en IS NULL
           AND coalesce((vigilante.param(p_cliente, 'razones_activas') #>> '{}')::boolean, true)
           AND greatest(s.created_at, s.updated_at)
               > now() - make_interval(days => coalesce((vigilante.param(p_cliente, 'razones_dias') #>> '{}')::int, 30))))
     AND (r.signal_id IS NULL OR r.tomada_en < now() - interval '30 minutes')
   ORDER BY (s.prob_origen = 'base') DESC, vigilante._nivel(s.prioridad::text) DESC, s.prob_calculada_en
$$;
REVOKE ALL ON FUNCTION vigilante._prob_pendientes(uuid) FROM public, anon, authenticated;

-- 4. Lo que AVIA necesita para explicar fiabilidad e impacto (se suma a la entrada del 33) ----------
CREATE OR REPLACE FUNCTION vigilante._razones_entrada(p_signal bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE s vigilante.signals; p jsonb; v_fuentes jsonb;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND THEN RETURN '{}'; END IF;
  p := vigilante.puntuaciones(p_signal);
  -- Hasta 3 fuentes de la señal, la de más peso primero, con su tipo en palabras
  SELECT jsonb_agg(f ORDER BY peso DESC, f) INTO v_fuentes FROM (
    SELECT DISTINCT ON (coalesce(src.nombre, 'búsqueda'))
           coalesce(src.nombre, 'búsqueda web') || ' (' ||
           CASE src.tipo::text WHEN 'oficial' THEN 'oficial' WHEN 'organismo_internacional' THEN 'organismo internacional'
                               WHEN 'medio' THEN 'medio de prensa' WHEN 'no_oficial' THEN 'no oficial: redes o blog'
                               ELSE 'búsqueda, sin documento oficial' END || ')' AS f,
           vigilante._peso_fuente(src.tipo::text) AS peso
      FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id
     WHERE r.id = ANY (vigilante._noticias_senal(p_signal) || coalesce(s.raw_item_id, -1))
     ORDER BY coalesce(src.nombre, 'búsqueda'), vigilante._peso_fuente(src.tipo::text) DESC
     LIMIT 3) x;
  RETURN jsonb_strip_nulls(jsonb_build_object(
    'fiabilidad', jsonb_build_object(
       'valor', p #> '{fiabilidad,valor}', 'nivel', p #> '{fiabilidad,nivel}',
       'fuentes_distintas', p #> '{fiabilidad,fuentes}', 'oficial', p #> '{fiabilidad,oficial}',
       'fuentes', v_fuentes),
    'impacto', jsonb_build_object('nivel', p #> '{impacto,nivel}', 'motivo', left(p #>> '{impacto,motivo}', 200)),
    -- ya la ajustó AVIA antes: solo faltan las razones; que repita su probabilidad salvo motivo claro
    'ya_ajustada', CASE WHEN s.prob_origen = 'avia' THEN s.prob_ocurrencia END));
END $$;
REVOKE ALL ON FUNCTION vigilante._razones_entrada(bigint) FROM public, anon, authenticated;

-- Igual que en el 33; cada señal lleva además fiabilidad, impacto y ya_ajustada
CREATE OR REPLACE FUNCTION vigilante.probabilidades_por_ajustar(p_cliente text, p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_ids bigint[]; v jsonb;
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'El cliente % no existe', p_cliente; END IF;
  v_ids := ARRAY(SELECT signal_id FROM vigilante._prob_pendientes(v_cliente) LIMIT greatest(least(coalesce(p_limite, 10), 10), 1));
  INSERT INTO vigilante.prob_reservas (signal_id, tomada_en) SELECT x, now() FROM unnest(v_ids) x
  ON CONFLICT (signal_id) DO UPDATE SET tomada_en = now();
  SELECT coalesce(jsonb_agg(vigilante._prob_entrada(x) || vigilante._razones_entrada(x) ORDER BY o), '[]') INTO v
    FROM unnest(v_ids) WITH ORDINALITY AS u(x, o);
  RETURN v;
END $$;

-- 5. Guardar: probabilidad (33) + las tres razones --------------------------------------------
-- [{"codigo": "SEN-0012", "prob": 0.78, "razon": "…", "razon_fiabilidad": "…", "razon_impacto": "…"}, …]
-- Limpia cada razón: espacios, «porque» inicial y punto final; máximo 200 caracteres.
CREATE OR REPLACE FUNCTION vigilante._razon_limpia(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(left(regexp_replace(regexp_replace(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'),
                                                   '^(AVIA[^,]*? porque|porque)\s+', '', 'i'),
                                    '[.\s]+$', ''), 200), '')
$$;

CREATE OR REPLACE FUNCTION vigilante.guardar_probabilidades(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; s vigilante.signals; v_p numeric; v_final numeric;
  v_razon text; v_rf text; v_ri text; v_max numeric; v_ok jsonb := '[]'; v_mal jsonb := '[]';
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'El cliente % no existe', p_cliente; END IF;
  IF jsonb_typeof(p_resultados) = 'object' THEN p_resultados := jsonb_build_array(p_resultados); END IF;
  IF jsonb_typeof(p_resultados) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Manda una lista: [{"codigo", "prob", "razon", "razon_fiabilidad", "razon_impacto"}]';
  END IF;
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
    v_razon := vigilante._razon_limpia(x ->> 'razon');
    IF v_razon IS NULL THEN v_mal := v_mal || jsonb_build_object('codigo', s.codigo, 'error', 'falta «razon»'); CONTINUE; END IF;
    v_rf := vigilante._razon_limpia(x ->> 'razon_fiabilidad');
    v_ri := vigilante._razon_limpia(x ->> 'razon_impacto');

    v_p := (x ->> 'prob')::numeric;
    v_final := round(least(greatest(v_p, s.prob_base - v_max, 0.05), s.prob_base + v_max, 0.95), 2);
    -- razones_en se marca aunque falte alguna: así no vuelve a pedirse en bucle (la que falte muestra solo el número)
    UPDATE vigilante.signals SET prob_ocurrencia = v_final, prob_razon = v_razon, prob_origen = 'avia',
           prob_factores = coalesce(prob_factores, '{}') || jsonb_build_object('avia_propuso', v_p, 'modelo', coalesce(p_modelo, 'hermes')),
           prob_calculada_en = now(),
           razon_fiabilidad = coalesce(v_rf, razon_fiabilidad), razon_impacto = coalesce(v_ri, razon_impacto),
           razones_en = now()
     WHERE id = s.id;
    DELETE FROM vigilante.prob_reservas WHERE signal_id = s.id;
    v_ok := v_ok || jsonb_strip_nulls(jsonb_build_object('codigo', s.codigo, 'prob', v_final,
              'recortada', CASE WHEN v_final <> round(v_p, 2) THEN 'Fuera de ±' || v_max || ' de la base (' || s.prob_base || '): se guardó ' || v_final END,
              'aviso', CASE WHEN v_rf IS NULL OR v_ri IS NULL
                            THEN 'Faltó ' || concat_ws(' y ', CASE WHEN v_rf IS NULL THEN '«razon_fiabilidad»' END,
                                                             CASE WHEN v_ri IS NULL THEN '«razon_impacto»' END)
                                 || ': el panel mostrará solo el número' END));
  END LOOP;
  RETURN jsonb_build_object('guardadas', v_ok, 'errores', v_mal);
END $$;

REVOKE ALL ON FUNCTION vigilante.probabilidades_por_ajustar(text, int), vigilante.guardar_probabilidades(text, jsonb, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.probabilidades_por_ajustar(text, int), vigilante.guardar_probabilidades(text, jsonb, text)
  TO service_role;

-- 6. Puntuaciones (22/33): cada una lleva «avia», la razón de AVIA (o nada) -----------------------
-- Igual que en el 33; solo se añaden las tres claves «avia».
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
                                 'calculada_en', s.prob_calculada_en,
                                 'avia', CASE WHEN s.prob_origen = 'avia' THEN s.prob_razon END);
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
  IF s.razon_impacto IS NOT NULL AND v_imp ->> 'nivel' <> 'sin datos' THEN
    v_imp := v_imp || jsonb_build_object('avia', s.razon_impacto);
  END IF;

  RETURN jsonb_build_object(
    'fiabilidad', jsonb_build_object('valor', v_fia,
                                     'nivel', CASE WHEN v_fia >= 70 THEN 'alta' WHEN v_fia >= 40 THEN 'media' ELSE 'baja' END,
                                     'motivos', to_jsonb(v_motivos), 'noticias', v_noticias, 'fuentes', v_fuentes, 'oficial', v_oficial,
                                     'avia', s.razon_fiabilidad),
    'probabilidad', v_prob,
    'impacto', v_imp);
END $$;
REVOKE ALL ON FUNCTION vigilante.puntuaciones(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.puntuaciones(bigint) TO authenticated, service_role;

COMMIT;
