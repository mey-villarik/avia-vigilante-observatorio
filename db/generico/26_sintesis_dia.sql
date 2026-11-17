-- =============================================================================
-- 26. Síntesis del día en 3 bloques (mejora 8 de la PoC, documento del revisor)
-- =============================================================================
-- Qué pasaba: la síntesis era un párrafo libre (o el texto que dejaba Hermes en vigilante.json) que
-- mezclaba hechos, importancia y pendientes, y podía no cuadrar con los contadores.
--
-- Ahora la arma la BASE, sin IA, con las mismas señales que cuentan los contadores (21):
--   · que_pasa: los hechos principales (certeza confirmado o convocado; primero prioridad alta e
--       impacto alto), con su certeza y territorio, y una línea de totales
--   · por_que_importa: el impacto turístico de esos mismos hechos, con su motivo y a quién afecta
--       (si el impacto es «sin datos», se dice)
--   · que_vigilar: lo que puede cambiar el panorama: riesgos sin confirmar (posible o rumor),
--       convocados en los próximos 7 días, oportunidades que cierran en menos de 15 días,
--       recomendaciones que afirman algo sin verificar, revisiones vencidas y fuentes caídas
-- Cada bloque lleva como máximo «sintesis_max» elementos (parámetro, 3 por defecto; «qué vigilar»
-- hasta el doble). No se rellenan: si no hay nada, el bloque va vacío y el panel dice «Sin novedades».
-- vigilante_bd() la devuelve como «sintesis_dia»; el panel y AVIA la usan tal cual.
--
-- Necesita el 25. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT jsonb_pretty(vigilante.sintesis_dia(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_sintesis.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'sintesis_max', '3', 'Elementos por bloque en la síntesis del día (qué vigilar admite el doble)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

CREATE OR REPLACE FUNCTION vigilante.sintesis_dia(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_max int := least(greatest(vigilante._entero(vigilante.param(p_cliente, 'sintesis_max'), 3), 1), 10);
  k jsonb := vigilante.contadores(p_cliente);
  v_rows jsonb; v_pasa jsonb; v_importa jsonb; v_vigilar jsonb; v_frase text; v_caidas int; v_vencidas int;
BEGIN
  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]') INTO v_rows FROM (
    SELECT s.id, s.codigo, s.titulo, left(s.resumen, 180) AS resumen, s.naturaleza::text AS naturaleza, s.categoria, s.prioridad::text AS prioridad,
           CASE s.prioridad WHEN 'alta' THEN 0 WHEN 'media' THEN 1 ELSE 2 END AS p, s.es_escenario AS escenario,
           s.plazo_hasta, s.fecha_evento_inicio AS evento, s.revision_vencida_en IS NOT NULL AS vencida,
           vigilante.certeza(s.id) AS cert, vigilante.puntuaciones(s.id) AS pun, vigilante.recomendacion_segura(s.id) AS reco,
           (SELECT string_agg(t.nombre, ', ' ORDER BY t.nombre) FROM vigilante.signal_territorios st
              JOIN vigilante.territorios t ON t.id = st.territorio_id WHERE st.signal_id = s.id) AS lugares
      FROM vigilante.senales_visibles(p_cliente) s
     WHERE s.estado <> 'descartada') r;

  -- 1. Qué pasa: hechos (confirmado o convocado), lo más serio primero
  SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') INTO v_pasa FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'certeza', cert ->> 'nivel',
             'naturaleza', naturaleza, 'lugares', lugares, 'texto', resumen,
             'impacto', pun #>> '{impacto,nivel}', 'motivo', pun #>> '{impacto,motivo}',
             'para_quien', reco ->> 'para_quien')) AS x,
           row_number() OVER (ORDER BY p, CASE pun #>> '{impacto,nivel}' WHEN 'alto' THEN 0 WHEN 'medio' THEN 1 ELSE 2 END, id DESC) AS o
      FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text) WHERE NOT escenario AND cert ->> 'nivel' IN ('confirmado', 'convocado')
     ORDER BY o LIMIT v_max) q;

  -- 2. Por qué importa: el impacto de esos mismos hechos
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'codigo', e ->> 'codigo', 'titulo', e ->> 'titulo', 'impacto', coalesce(e ->> 'impacto', 'sin datos'),
           'texto', CASE WHEN coalesce(e ->> 'impacto', 'sin datos') = 'sin datos' THEN 'Impacto turístico sin datos: AVIA no lo valoró'
                         ELSE e ->> 'motivo' END,
           'para_quien', e ->> 'para_quien')) ORDER BY i), '[]')
    INTO v_importa FROM jsonb_array_elements(v_pasa) WITH ORDINALITY a(e, i);

  -- 3. Qué vigilar
  SELECT count(*) FILTER (WHERE vencida) INTO v_vencidas FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text);
  SELECT count(*) INTO v_caidas FROM vigilante.sources
   WHERE cliente_id = p_cliente AND activa AND eliminada_en IS NULL AND config ->> 'estado' = 'CRIT';
  SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') INTO v_vigilar FROM (
    SELECT x, o FROM (
      SELECT jsonb_build_object('codigo', codigo, 'titulo', titulo, 'tipo', 'sin_confirmar', 'certeza', cert ->> 'nivel',
               'texto', 'Riesgo sin confirmar (' || (cert ->> 'nivel') || ')'
                        || coalesce('. Falta saber: ' || lower(left(reco #>> '{falta_saber,0}', 1)) || substr(reco #>> '{falta_saber,0}', 2), '')) AS x,
             10 + p AS o, id
        FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text) WHERE NOT escenario AND naturaleza IN ('riesgo', 'mixta') AND cert ->> 'nivel' IN ('posible', 'rumor') AND p < 2
      UNION ALL
      SELECT jsonb_build_object('codigo', codigo, 'titulo', titulo, 'tipo', 'convocado', 'certeza', 'convocado',
               'texto', 'Anunciado para el ' || to_char(evento AT TIME ZONE 'America/La_Paz', 'DD/MM')
                        || '. Confirmar si se mantiene'), 20 + p, id
        FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text) WHERE cert ->> 'nivel' = 'convocado' AND evento BETWEEN now() AND now() + interval '7 days'
      UNION ALL
      SELECT jsonb_build_object('codigo', codigo, 'titulo', titulo, 'tipo', 'plazo',
               'texto', 'Oportunidad que cierra en ' || vigilante.dias_para(plazo_hasta)
                        || CASE WHEN vigilante.dias_para(plazo_hasta) = 1 THEN ' día' ELSE ' días' END), 30 + p, id
        FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text) WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15
      UNION ALL
      SELECT jsonb_build_object('codigo', codigo, 'titulo', titulo, 'tipo', 'recomendacion_sin_verificar',
               'texto', 'La recomendación da algo por operativo sin dato oficial reciente: comprobar con ' || (reco ->> 'verificar_con')), 15, id
        FROM jsonb_to_recordset(v_rows) AS _sd(id bigint, codigo text, titulo text, resumen text, naturaleza text, categoria text, prioridad text, p int, escenario boolean, plazo_hasta timestamptz, evento timestamptz, vencida boolean, cert jsonb, pun jsonb, reco jsonb, lugares text) WHERE (reco ->> 'afirma_sin_verificar')::boolean
    ) u ORDER BY o, id DESC LIMIT v_max * 2) q;
  IF v_vencidas > 0 THEN
    v_vigilar := v_vigilar || jsonb_build_object('tipo', 'revision_vencida',
      'texto', v_vencidas || CASE WHEN v_vencidas = 1 THEN ' señal con la revisión vencida: nadie la decidió a tiempo'
                                  ELSE ' señales con la revisión vencida: nadie las decidió a tiempo' END);
  END IF;
  IF v_caidas > 0 THEN
    v_vigilar := v_vigilar || jsonb_build_object('tipo', 'fuentes',
      'texto', v_caidas || CASE WHEN v_caidas = 1 THEN ' fuente no se puede leer' ELSE ' fuentes no se pueden leer' END
               || ': puede haber hechos sin detectar');
  END IF;

  v_frase := (k ->> 'senales_activas') || CASE WHEN (k ->> 'senales_activas')::int = 1 THEN ' señal activa: ' ELSE ' señales activas: ' END
             || (k ->> 'riesgos') || CASE WHEN (k ->> 'riesgos')::int = 1 THEN ' riesgo, ' ELSE ' riesgos, ' END || (k ->> 'oportunidades')
             || CASE WHEN (k ->> 'oportunidades')::int = 1 THEN ' oportunidad' ELSE ' oportunidades' END
             || CASE WHEN (k ->> 'mixtas')::int > 0 THEN ' y ' || (k ->> 'mixtas') || CASE WHEN (k ->> 'mixtas')::int = 1 THEN ' mixta' ELSE ' mixtas' END ELSE '' END
             || '; ' || (k ->> 'noticias_24h') || ' noticias revisadas en 24 h.';

  RETURN jsonb_build_object(
    'generado', now(),
    'totales', v_frase,
    'que_pasa', v_pasa,
    'por_que_importa', v_importa,
    'que_vigilar', v_vigilar,
    'max', v_max);
END $$;
REVOKE ALL ON FUNCTION vigilante.sintesis_dia(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.sintesis_dia(uuid) TO service_role;

-- vigilante.json / vigilante_bd(): igual que en el 25, con «sintesis_dia»
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
                       'recomendacion_segura', vigilante.recomendacion_segura(s.id),
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente),
    'sintesis_dia', vigilante.sintesis_dia(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

COMMIT;
