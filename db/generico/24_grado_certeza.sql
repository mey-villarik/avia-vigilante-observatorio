-- =============================================================================
-- 24. Grado de certeza por señal (mejora 6 de la PoC, documento del revisor)
-- =============================================================================
-- Qué pasaba: AVIA contaba igual un hecho comprobado, un paro anunciado para la semana que viene
-- y un comentario de redes. La fiabilidad (22) dice cuánto respaldo hay, pero no QUÉ TIPO de hecho es.
--
-- Ahora cada señal lleva «certeza» con una de cuatro palabras, siempre las mismas:
--   · confirmado: ya pasó o está pasando, y lo respalda una fuente oficial, dos fuentes distintas
--                 o una persona del equipo
--   · convocado:  anunciado por quien lo organiza para una fecha futura (paro, bloqueo, feria,
--                 cierre programado). Está anunciado; no se sabe si al final ocurrirá
--   · posible:    hay indicios en una fuente creíble, pero nadie lo ha confirmado; también las
--                 predicciones (escenarios)
--   · rumor:      sin fuente identificable, o solo redes/fuentes no oficiales sin respaldo
--
-- Quién lo decide (en este orden):
--   1. Escenario → «posible», siempre.
--   2. Una persona confirmó o publicó la señal → «confirmado» (o «convocado» si es un evento futuro).
--   3. El modelo lo propone (clasificador-1.3, con motivo) y la base lo comprueba con las fuentes:
--        «confirmado» sin fuente oficial ni dos fuentes → baja a «posible»; «convocado» o «posible»
--        sin ninguna noticia → baja a «rumor». Nunca se sube lo que el modelo bajó.
--   4. Señales antiguas sin propuesta del modelo: se deduce de las fuentes y la fecha del evento.
--   El resultado dice el origen y, si se ajustó, qué propuso el modelo.
--
-- Necesita el 23. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT codigo, vigilante.certeza(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 5;
-- Prueba: 99_prueba_certeza.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante.certeza(p_signal bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; m jsonb; v_prop text; v_motivo text;
  v_noticias int; v_fuentes int; v_oficial boolean; v_solo_no_oficial boolean; v_respaldo boolean;
  v_futuro boolean; v_quien text;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND THEN RETURN NULL; END IF;
  m := coalesce(s.salida_modelo, '{}');

  -- fuentes (mismas reglas que la fiabilidad del 22)
  SELECT count(*), count(DISTINCT coalesce(r.source_id::text, 'b' || coalesce(r.busqueda_id::text, r.id::text))),
         coalesce(bool_or(src.tipo IN ('oficial', 'organismo_internacional')), false),
         coalesce(bool_and(src.tipo = 'no_oficial'), false)
    INTO v_noticias, v_fuentes, v_oficial, v_solo_no_oficial
    FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
    LEFT JOIN vigilante.sources src ON src.id = r.source_id
   WHERE sr.signal_id = s.id;
  IF v_noticias = 0 AND jsonb_typeof(m -> 'enlaces') = 'array' THEN   -- señales antiguas copiadas de vigilante.json
    SELECT count(DISTINCT coalesce(e ->> 'nombre', e ->> 'url')) INTO v_fuentes FROM jsonb_array_elements(m -> 'enlaces') e;
    v_noticias := v_fuentes;
  END IF;
  v_oficial := v_oficial OR s.fuente_oficial;
  v_respaldo := v_oficial OR v_fuentes >= 2;
  v_futuro := s.fecha_evento_inicio IS NOT NULL AND s.fecha_evento_inicio > s.created_at;
  v_prop := CASE WHEN (m #>> '{certeza,nivel}') IN ('confirmado', 'convocado', 'posible', 'rumor') THEN m #>> '{certeza,nivel}' END;
  v_motivo := nullif(trim(m #>> '{certeza,motivo}'), '');

  -- 1. escenario
  IF s.es_escenario THEN
    RETURN jsonb_build_object('nivel', 'posible', 'origen', 'reglas',
                              'motivo', 'Es un escenario (predicción), no un hecho');
  END IF;

  -- 2. una persona la confirmó o publicó
  IF s.estado IN ('confirmada', 'publicada') THEN
    v_quien := vigilante.trazabilidad(s.id) #>> '{ultima_verificacion,quien}';
    RETURN jsonb_build_object(
      'nivel', CASE WHEN v_prop = 'convocado' OR (v_prop IS NULL AND v_futuro) THEN 'convocado' ELSE 'confirmado' END,
      'origen', 'persona',
      'motivo', CASE WHEN v_prop = 'convocado' OR (v_prop IS NULL AND v_futuro)
                     THEN 'Anuncio comprobado por ' || coalesce(v_quien, 'una persona del equipo') || '; el evento aún no ha ocurrido'
                     ELSE 'Comprobado por ' || coalesce(v_quien, 'una persona del equipo') END);
  END IF;

  -- 3. lo que propuso el modelo, comprobado con las fuentes
  IF v_prop IS NOT NULL AND v_motivo IS NOT NULL THEN
    IF v_prop = 'confirmado' AND NOT v_respaldo THEN
      RETURN jsonb_build_object('nivel', CASE WHEN v_noticias = 0 THEN 'rumor' ELSE 'posible' END, 'origen', 'modelo_ajustado', 'propuesto', v_prop,
        'motivo', 'AVIA lo daba por confirmado, pero ' ||
                  CASE WHEN v_noticias = 0 THEN 'no hay ninguna noticia que lo respalde'
                       ELSE 'solo lo dice una fuente no oficial; falta una fuente oficial o una segunda fuente' END);
    ELSIF v_prop IN ('convocado', 'posible') AND v_noticias = 0 THEN
      RETURN jsonb_build_object('nivel', 'rumor', 'origen', 'modelo_ajustado', 'propuesto', v_prop,
        'motivo', 'AVIA lo daba por ' || v_prop || ', pero no hay ninguna noticia que lo respalde');
    END IF;
    RETURN jsonb_build_object('nivel', v_prop, 'origen', 'modelo', 'motivo', v_motivo);
  END IF;

  -- 4. sin propuesta del modelo (señales antiguas): fuentes y fecha del evento
  RETURN CASE
    WHEN v_noticias = 0 THEN jsonb_build_object('nivel', 'rumor', 'origen', 'reglas',
           'motivo', 'Ninguna noticia la respalda')
    WHEN v_futuro THEN jsonb_build_object('nivel', 'convocado', 'origen', 'reglas',
           'motivo', 'Evento anunciado para el ' || to_char(s.fecha_evento_inicio AT TIME ZONE 'America/La_Paz', 'DD/MM/YYYY')
                     || '; aún no ha ocurrido')
    WHEN v_respaldo THEN jsonb_build_object('nivel', 'confirmado', 'origen', 'reglas',
           'motivo', CASE WHEN v_oficial THEN 'Lo publica una fuente oficial' ELSE v_fuentes || ' fuentes distintas lo cuentan' END)
    WHEN v_solo_no_oficial THEN jsonb_build_object('nivel', 'rumor', 'origen', 'reglas',
           'motivo', 'Solo lo cuenta una fuente no oficial, sin respaldo')
    ELSE jsonb_build_object('nivel', 'posible', 'origen', 'reglas',
           'motivo', 'Lo cuenta una sola fuente no oficial; falta confirmación')
  END;
END $$;
REVOKE ALL ON FUNCTION vigilante.certeza(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.certeza(bigint) TO authenticated, service_role;

-- El analizador pide la certeza (prompt clasificador-1.3): guardar_clasificacion la pasa a la
-- señal (igual que en el 22, con la clave «certeza» más)
CREATE OR REPLACE FUNCTION vigilante.guardar_clasificacion(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL,
                                                           p_prompt_version text DEFAULT NULL, p_uso jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; v_doc vigilante.raw_items; v_ids bigint[];
  v_sig bigint; v_cod text; v_res jsonb; v_senal jsonb; v_op jsonb; v_nivel text; v_tarea jsonb; v_n int;
  n_desc int := 0; n_nuevas int := 0; n_act int := 0; n_opp int := 0; n_tareas int := 0; n_ignoradas int := 0;
BEGIN
  v_n := greatest(jsonb_array_length(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END), 1);
  PERFORM set_config('vigilante.actor', 'clasificador:' || coalesce(p_modelo, '?'), true);
  FOR x IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END) LOOP
    -- solo se acepta lo que se mandó a clasificar (clave = id de la noticia principal del grupo)
    SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = v_cliente AND id = (x ->> 'clave')::bigint AND estado IN ('en_cola', 'nuevo');
    IF v_doc.id IS NULL OR (x ->> 'clave') !~ '^\d+$' THEN n_ignoradas := n_ignoradas + 1; CONTINUE; END IF;
    -- el grupo: misma noticia en otras fuentes, también pendiente
    v_ids := ARRAY(SELECT id FROM vigilante.raw_items WHERE cliente_id = v_cliente AND titulo_norm = v_doc.titulo_norm
                     AND estado IN ('en_cola', 'nuevo') ORDER BY id);

    INSERT INTO vigilante.analisis (cliente_id, raw_item_id, version, tipo, modelo, prompt_version, salida, relevante,
                                    tokens_entrada, tokens_salida, costo_usd)
    VALUES (v_cliente, v_doc.id, v_doc.version, 'clasificacion', p_modelo, p_prompt_version, x,
            coalesce((x ->> 'relevante')::boolean, false),
            ((p_uso ->> 'tokens_entrada')::numeric / v_n)::int, ((p_uso ->> 'tokens_salida')::numeric / v_n)::int,
            (p_uso ->> 'costo_usd')::numeric / v_n)
    ON CONFLICT (raw_item_id, version, tipo) DO NOTHING;

    IF NOT coalesce((x ->> 'relevante')::boolean, false) THEN
      UPDATE vigilante.raw_items SET estado = 'descartado', motivo_descarte = 'IA: ' || coalesce(nullif(x ->> 'motivo', ''), 'no relevante')
       WHERE id = ANY (v_ids);
      n_desc := n_desc + 1; CONTINUE;
    END IF;

    -- ¿ya hay señal para este hecho? (una noticia del grupo ya enlazada, o el mismo título en 72 h)
    SELECT s.codigo INTO v_cod FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
     WHERE sr.raw_item_id = ANY (v_ids) ORDER BY s.id DESC LIMIT 1;
    IF v_cod IS NULL THEN
      SELECT s.codigo INTO v_cod FROM vigilante.raw_items r JOIN vigilante.signal_raw_items sr ON sr.raw_item_id = r.id
        JOIN vigilante.signals s ON s.id = sr.signal_id
       WHERE r.cliente_id = v_cliente AND r.titulo_norm = v_doc.titulo_norm AND r.recolectado_en > now() - interval '72 hours'
         AND s.estado NOT IN ('descartada', 'cerrada')
       ORDER BY s.id DESC LIMIT 1;
    END IF;

    v_senal := jsonb_strip_nulls(jsonb_build_object(
      'codigo', v_cod,
      'titulo', coalesce(nullif(x ->> 'titulo', ''), v_doc.titulo),
      'resumen', coalesce(nullif(x ->> 'resumen', ''), left(v_doc.contenido, 300), v_doc.titulo),
      'recomendacion', x ->> 'recomendacion', 'naturaleza', x ->> 'naturaleza', 'categoria', x ->> 'categoria',
      'prioridad', x ->> 'prioridad', 'motivos_prioridad', x -> 'motivos_prioridad', 'departamentos', x -> 'departamentos',
      'fecha_evento_inicio', x ->> 'fecha_evento_inicio', 'fecha_evento_fin', x ->> 'fecha_evento_fin',
      'plazo_hasta', x ->> 'plazo_hasta', 'es_escenario', x -> 'es_escenario', 'confianza', x -> 'confianza',
      'impacto', x -> 'impacto', 'probabilidad', x -> 'probabilidad',   -- 22: se guardan en salida_modelo
      'certeza', x -> 'certeza',                                         -- 24: grado de certeza que propone el modelo
      'modelo', p_modelo, 'noticias', to_jsonb(v_ids),
      -- para la web (mismo formato que vigilante.json)
      'tipo_oportunidad', x #>> '{oportunidad,tipo}', 'actores', x #> '{oportunidad,beneficiarios}',
      'importancia', x #>> '{oportunidad,interpretacion}',
      'soluciones', CASE WHEN x #>> '{oportunidad,accion}' IS NOT NULL
                         THEN jsonb_build_array(jsonb_build_object('t', x #>> '{oportunidad,accion}')) END));
    v_res := vigilante.guardar_senal(p_cliente, v_senal);
    SELECT id INTO v_sig FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = v_res ->> 'codigo';
    UPDATE vigilante.analisis SET signal_id = v_sig WHERE raw_item_id = v_doc.id AND version = v_doc.version AND tipo = 'clasificacion';
    IF (v_res ->> 'nueva')::boolean THEN n_nuevas := n_nuevas + 1; ELSE n_act := n_act + 1; END IF;

    -- oportunidad
    v_op := x -> 'oportunidad';
    IF jsonb_typeof(v_op) = 'object' AND coalesce(trim(v_op ->> 'hecho'), '') <> '' AND coalesce(trim(v_op ->> 'tipo'), '') <> '' THEN
      v_nivel := CASE WHEN lower(v_op ->> 'tipo') = ANY (v_doc.tipos_oportunidad) THEN 'explicita' ELSE 'inferida' END;
      IF v_nivel = 'explicita' OR coalesce(trim(v_op ->> 'interpretacion'), '') <> '' THEN
        INSERT INTO vigilante.oportunidades (cliente_id, signal_id, nivel, tipo, hecho, interpretacion, beneficiarios, accion,
                                             plazo_hasta, importancia, evidencias, creada_por)
        VALUES (v_cliente, v_sig, v_nivel, lower(v_op ->> 'tipo'), v_op ->> 'hecho', nullif(trim(v_op ->> 'interpretacion'), ''),
                CASE WHEN jsonb_typeof(v_op -> 'beneficiarios') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_op -> 'beneficiarios')) ELSE '{}' END,
                v_op ->> 'accion', (SELECT plazo_hasta FROM vigilante.signals WHERE id = v_sig),
                CASE WHEN (v_op ->> 'importancia') ~ '^[1-5]$' THEN (v_op ->> 'importancia')::smallint END,
                v_ids, 'clasificador')
        ON CONFLICT (signal_id, nivel, tipo) DO UPDATE SET
          hecho = EXCLUDED.hecho, interpretacion = EXCLUDED.interpretacion, beneficiarios = EXCLUDED.beneficiarios,
          accion = EXCLUDED.accion, plazo_hasta = EXCLUDED.plazo_hasta, importancia = EXCLUDED.importancia,
          evidencias = ARRAY(SELECT DISTINCT unnest(vigilante.oportunidades.evidencias || EXCLUDED.evidencias)), updated_at = now();
        n_opp := n_opp + 1;
      END IF;
    END IF;

    -- tareas para Hermes
    v_tarea := x -> 'tarea';
    IF coalesce((x ->> 'necesita_agente')::boolean, false) AND jsonb_typeof(v_tarea) = 'object'
       AND v_tarea ->> 'tipo' IN ('corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida') THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, v_tarea ->> 'tipo', v_sig, v_ids,
                                                    coalesce(nullif(v_tarea ->> 'motivo', ''), 'Pedido por el clasificador'), 'clasificador') ->> 'nueva')::boolean::int;
    ELSIF x ->> 'prioridad' = 'alta' AND NOT (v_res ->> 'fuente_oficial')::boolean THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, 'corroborar', v_sig, v_ids,
                                                    'Prioridad alta sin fuente oficial: buscar confirmación', 'regla') ->> 'nueva')::boolean::int;
    END IF;
  END LOOP;

  IF coalesce((p_uso ->> 'costo_usd')::numeric, 0) > 0 OR coalesce((p_uso ->> 'tokens_entrada')::int, 0) > 0 THEN
    PERFORM vigilante.registrar_log(p_cliente, 'clasificador', 'info', format('Lote de %s noticias', v_n), p_uso || jsonb_build_object('modelo', p_modelo),
                                    (p_uso ->> 'costo_usd')::numeric, NULL);
  END IF;
  RETURN jsonb_build_object('descartadas', n_desc, 'senales_nuevas', n_nuevas, 'senales_actualizadas', n_act,
                            'oportunidades', n_opp, 'tareas_agente', n_tareas, 'ignoradas', n_ignoradas);
END $$;

-- vigilante.json / vigilante_bd(): igual que en el 23, con «certeza» en cada señal
CREATE OR REPLACE FUNCTION vigilante._vigilante_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT p_cliente AS id,
                    vigilante._entero(vigilante.param(p_cliente, 'retencion_meses'), 6) AS meses,
                    vigilante._entero(vigilante.param(p_cliente, 'web_dias_visibles'), 7) AS dias)
  SELECT jsonb_build_object(
    'version', 1,
    'generado', now(),
    'origen', 'base',
    'dias_visibles', (SELECT dias FROM c),
    'noticias_revisadas', (SELECT count(*) FROM vigilante.raw_items r, c WHERE r.cliente_id = c.id AND r.recolectado_en > now() - interval '24 hours'),
    'ventana_horas', 24,
    'fuentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', s.codigo, 'nombre', s.nombre, 'canal', s.categorias[1], 'tipo', s.tipo, 'url', s.url,
                  'metodo', s.metodo, 'estado', CASE WHEN NOT s.activa THEN 'MANT' ELSE coalesce(s.config ->> 'estado', 'UNKNOWN') END,
                  'ultima', s.ultima_consulta_en, 'proxima', s.proxima_revision_en,
                  'items', vigilante._entero(s.config -> 'items', 0), 'hist', coalesce(s.config -> 'hist', '[]'), 'info', s.notas)
                  ORDER BY s.nombre), '[]')
                  FROM vigilante.sources s, c
                 WHERE s.cliente_id = c.id AND s.eliminada_en IS NULL AND NOT coalesce((s.config ->> 'propuesta_avia')::boolean, false)),
    'senales', (SELECT coalesce(jsonb_agg(
                  (CASE WHEN s.salida_modelo ? 'id' AND s.salida_modelo ? 'titulo'
                       THEN s.salida_modelo || jsonb_build_object('id', s.codigo, 'estado', s.estado)
                       ELSE jsonb_strip_nulls(jsonb_build_object(
                         'id', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen, 'naturaleza', s.naturaleza,
                         'categoria', s.categoria, 'estado', s.estado, 'prioridad', s.prioridad,
                         'conf', s.confianza,
                         'rel', (s.salida_modelo ->> 'relevancia')::numeric, 'nov', (s.salida_modelo ->> 'novedad')::numeric,
                         'deps', (SELECT jsonb_agg(t.nombre) FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id WHERE st.signal_id = s.id),
                         'destinos', s.salida_modelo -> 'destinos',
                         'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                         'enlaces', (SELECT jsonb_agg(jsonb_build_object('nombre', coalesce(src.nombre, 'Fuente'), 'url', r.url,
                                                                         'fecha', to_char(coalesce(r.publicado_en, r.recolectado_en), 'YYYY-MM-DD')))
                                       FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                       LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE sr.signal_id = s.id),
                         'tipoOpp', s.salida_modelo ->> 'tipo_oportunidad', 'actores', s.salida_modelo -> 'actores',
                         'importancia', coalesce(s.salida_modelo ->> 'importancia', s.recomendacion),
                         'soluciones', s.salida_modelo -> 'soluciones',
                         'revision', CASE WHEN s.requiere_revision THEN coalesce(s.motivo_revision, 'Requiere revisión de una persona') END,
                         'detectada', s.created_at))
                  END)
                  || jsonb_strip_nulls(jsonb_build_object(
                       'escenario', s.es_escenario,
                       'revision_vence', vigilante.vence_revision(s.cliente_id, s.requiere_revision, s.estado, s.created_at),
                       'revision_vencida', s.revision_vencida_en,
                       'evento_inicio', to_char(s.fecha_evento_inicio AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'evento_fin', to_char(s.fecha_evento_fin AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'ultima_noticia', vigilante.ultima_noticia(s.id, s.created_at),
                       'puntuaciones', vigilante.puntuaciones(s.id),
                       'trazabilidad', vigilante.trazabilidad(s.id),
                       'certeza', vigilante.certeza(s.id),
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

COMMIT;
