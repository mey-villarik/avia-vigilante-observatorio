-- =============================================================================
-- 53 · Reparar la síntesis del día: vuelve a crear vigilante._sintesis_dia_base
-- =============================================================================
-- Síntoma (2026-11-24): el chat de AVIA dice «no puedo consultar el observatorio» y el log de avia-api
-- muestra «function vigilante._sintesis_dia_base(uuid) does not exist». vigilante_bd() → _vigilante_json()
-- → sintesis_dia() (la del 48) llama a _sintesis_dia_base(), que no existe en la base.
-- Pasa si el 48 se ejecutó sin haber ejecutado antes el 45, o si se reejecutó el 26 y luego el 48.
--
-- Este archivo solo crea la base de la síntesis (la del 26, con su nombre nuevo) y revisiones_vencidas()
-- (la del 45). No toca sintesis_dia() ni _vigilante_json(): se quedan como las dejó el 48.
-- Se puede ejecutar más de una vez.
--
-- Comprobar: SELECT jsonb_pretty(vigilante.sintesis_dia(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- =============================================================================
BEGIN;

INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'sintesis_max', '3', 'Elementos por bloque en la síntesis del día (qué vigilar admite el doble)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- Base de la síntesis (cuerpo del 26)
CREATE OR REPLACE FUNCTION vigilante._sintesis_dia_base(p_cliente uuid)
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
REVOKE ALL ON FUNCTION vigilante._sintesis_dia_base(uuid) FROM public, anon, authenticated;

-- Revisiones vencidas (del 45; sintesis_dia() del 48 también la usa)
CREATE OR REPLACE FUNCTION vigilante.revisiones_vencidas(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_total int; v_senales jsonb; v_resp text; v_origen text;
BEGIN
  SELECT count(*),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'desde', revision_vencida_en)
                            ORDER BY revision_vencida_en, id) FILTER (WHERE n <= 5), '[]')
    INTO v_total, v_senales
    FROM (SELECT s.id, s.codigo, s.titulo, s.revision_vencida_en,
                 row_number() OVER (ORDER BY s.revision_vencida_en, s.id) AS n
            FROM vigilante.signals s
           WHERE s.cliente_id = p_cliente AND s.revision_vencida_en IS NOT NULL
             AND s.revision_decidida_en IS NULL
             AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion')) q;

  v_resp := nullif(btrim(vigilante.param(p_cliente, 'responsable_revision') #>> '{}'), '');
  IF v_resp IS NOT NULL THEN
    v_origen := 'asignado';
  ELSE
    SELECT string_agg(nombre, ', ' ORDER BY nombre) INTO v_resp
      FROM vigilante.users WHERE cliente_id = p_cliente AND activo AND rol = 'analista';
    v_origen := CASE WHEN v_resp IS NULL THEN NULL ELSE 'analistas' END;
  END IF;

  RETURN jsonb_build_object('total', v_total, 'senales', v_senales,
                            'responsable', v_resp, 'responsable_origen', v_origen);
END $$;
REVOKE ALL ON FUNCTION vigilante.revisiones_vencidas(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.revisiones_vencidas(uuid) TO service_role;

COMMIT;
