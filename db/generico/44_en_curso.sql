-- =============================================================================
-- 44. «En curso» no es «cierra en N días»
-- =============================================================================
-- Qué se veía (Meysel, 2026-11-22): el Festival de la Canción Boliviana y el Bicentenario,
-- que ya están ocurriendo, salían como oportunidades que «cierran en N días». Un evento en
-- curso no es una oportunidad con plazo: no lleva cuenta atrás.
--
-- Regla única (la misma en web/src/lib/vigencia.ts → enCurso()):
--   inicio ≤ hoy ≤ fin  → EN CURSO (no cuenta como «plazo corto» ni sale en «Qué vigilar»
--                         como «Oportunidad que cierra en N días»)
--   hoy < inicio        → cuenta atrás normal
--   hoy > fin           → cerrado (ya lo ocultaba senal_vigente)
--   Si falta el fin del evento se usa el plazo y, si tampoco hay, el mismo día de inicio.
--   «hoy» = día en Bolivia; las fechas se leen como día (igual que vigilante.json).
--
-- Este script:
--   1. crea vigilante.en_curso(inicio, fin, plazo);
--   2. vigilante.contadores(): plazo_corto ya no cuenta lo en curso y añade «en_curso»
--      (resto igual que en el 41);
--   3. vigilante.sintesis_dia(): «Oportunidad que cierra en N días» salta lo en curso
--      (resto igual que en el 26).
-- No cambia tablas ni datos. Se puede ejecutar más de una vez.
-- Prueba: 99_prueba_en_curso.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION vigilante.en_curso(p_inicio timestamptz, p_fin timestamptz, p_plazo timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_inicio IS NOT NULL
     AND (p_inicio AT TIME ZONE 'UTC')::date <= (now() AT TIME ZONE 'America/La_Paz')::date
     AND (now() AT TIME ZONE 'America/La_Paz')::date <= greatest(
           (p_inicio AT TIME ZONE 'UTC')::date,
           (coalesce(p_fin, p_plazo, p_inicio) AT TIME ZONE 'UTC')::date)
$$;

CREATE OR REPLACE FUNCTION vigilante.contadores(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.*, r.n_fuentes, r.verificada
      FROM vigilante.senales_visibles(p_cliente) s
      CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
     WHERE s.estado <> 'descartada'
  ),
  c AS (SELECT * FROM a WHERE estado IN ('confirmada', 'publicada')),
  v AS (SELECT * FROM c WHERE verificada),
  f AS (
    SELECT * FROM vigilante.sources
     WHERE cliente_id = p_cliente AND eliminada_en IS NULL
  ),
  -- activas = las que AVIA vigila; leída = su última comprobación dio OK o AVISO (el mismo «estado» que vigilante_bd() manda a la web)
  fa AS (
    SELECT coalesce(config ->> 'estado', 'UNKNOWN') IN ('OK', 'WARN') AS leida
      FROM f WHERE activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)
  )
  SELECT jsonb_build_object(
    'actualizado', now(),
    'senales_activas',     (SELECT count(*) FROM a),
    'oportunidades',       (SELECT count(*) FROM a WHERE naturaleza = 'oportunidad'),
    'riesgos',             (SELECT count(*) FROM a WHERE naturaleza = 'riesgo'),
    'mixtas',              (SELECT count(*) FROM a WHERE naturaleza = 'mixta'),
    'plazo_corto',         (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15
                                                    AND NOT vigilante.en_curso(fecha_evento_inicio, fecha_evento_fin, plazo_hasta)),
    'en_curso',            (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.en_curso(fecha_evento_inicio, fecha_evento_fin, plazo_hasta)),
    'riesgos_altos',       (SELECT count(*) FROM a WHERE naturaleza = 'riesgo' AND prioridad = 'alta'),
    'verificadas',               (SELECT count(*) FROM v),
    'verificadas_2_fuentes',     (SELECT count(*) FROM v WHERE n_fuentes >= 2),
    'verificadas_oficial',       (SELECT count(*) FROM v WHERE n_fuentes < 2),
    'verificadas_una_fuente',    0,
    'confirmadas_sin_verificar', (SELECT count(*) FROM c WHERE NOT verificada),
    'por_verificar',       (SELECT count(*) FROM a WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'esperan_aprobacion',  (SELECT count(*) FROM a WHERE requiere_revision AND estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'alertas_publicadas',  (SELECT count(*) FROM a WHERE estado = 'publicada'),
    'alertas_verificadas', (SELECT count(*) FROM v WHERE estado = 'publicada'),
    'descartadas',         (SELECT count(*) FROM vigilante.senales_visibles(p_cliente) s WHERE s.estado = 'descartada'),
    'noticias_24h',        (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = p_cliente AND r.recolectado_en > now() - interval '24 hours'),
    'fuentes_activas',     (SELECT count(*) FROM fa),
    'fuentes_leidas',      (SELECT count(*) FROM fa WHERE leida),
    'fuentes_sin_leer',    (SELECT count(*) FROM fa WHERE NOT leida),
    'fuentes_en_pausa',    (SELECT count(*) FROM f WHERE NOT activa OR coalesce((config ->> 'propuesta_avia')::boolean, false))
  )
$$;
REVOKE ALL ON FUNCTION vigilante.contadores(uuid) FROM public, anon, authenticated;

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
         AND NOT EXISTS (SELECT 1 FROM vigilante.signals e WHERE e.id = _sd.id
                          AND vigilante.en_curso(e.fecha_evento_inicio, e.fecha_evento_fin, e.plazo_hasta))
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
