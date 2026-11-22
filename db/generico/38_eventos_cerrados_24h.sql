-- =============================================================================
-- 38. Eventos: los cerrados o descartados también se ven sus 24 h (con el motivo)
-- =============================================================================
-- Qué cambia respecto al 34 (Meysel, 2026-11-21: «¿por qué solo me muestra 3 eventos?»):
--
--   El panel no tiene ningún límite de cantidad. Un evento deja de verse en la ventana de Eventos por
--   una de estas razones, y las tres dejaban el evento invisible sin decir por qué:
--     a) pasaron más de eventos_horas_panel (24 h) desde que se detectó o desde que le entraron
--        señales nuevas: es la regla del 34, se mantiene;
--     b) el compositor lo CERRÓ porque sus señales dejaron de coincidir en fechas, caducaron, o una
--        se descartó o se fusionó como duplicado (pasa a menudo: el compositor corre cada minuto);
--     c) Hermes o un analista lo DESCARTÓ como no relevante.
--   b) y c) desaparecían al momento aunque el evento tuviera solo unas horas.
--
--   Ahora eventos_emergentes() devuelve también los cerrados y descartados de las mismas 24 h, con
--   «motivo_cierre» y «descartado_por». No suenan ni salen como ventana (alerta = false, visto = true):
--   el panel los enseña aparte, en «Cerrados o descartados en las últimas 24 h», con el motivo.
--
-- Diagnóstico (en el SQL Editor, cambia el slug si hace falta): cuántos eventos hay y por qué no se ven
--   SELECT e.estado, (e.version_en > now() - interval '24 hours') AS en_24h, count(*),
--          string_agg(e.codigo || coalesce(' (' || e.motivo_cierre || ')', ''), ', ' ORDER BY e.codigo) AS eventos
--     FROM vigilante.eventos_compuestos e JOIN vigilante.clientes c ON c.id = e.cliente_id
--    WHERE c.slug = 'orbita-bolivia' GROUP BY 1, 2 ORDER BY 1, 2;
--
-- Necesita el 34. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run. Se puede ejecutar varias veces.
-- Volver a lo de antes: ejecutar otra vez el 34 (reescribe eventos_emergentes sin los cerrados).
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante.eventos_emergentes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.cliente_actual(); v_user uuid := vigilante.usuario_actual();
        v_espera int; v_desde int; v_horas int;
BEGIN
  IF v_cliente IS NULL OR NOT vigilante.es_staff() THEN RETURN '[]'::jsonb; END IF;
  v_espera := coalesce(vigilante._entero(vigilante.param(v_cliente, 'eventos_espera_hermes_min'), 0), 0);
  v_desde  := greatest(vigilante._nivel(coalesce(vigilante.param(v_cliente, 'eventos_alerta_desde') #>> '{}', 'baja')), 1);
  v_horas  := coalesce(vigilante._entero(vigilante.param(v_cliente, 'eventos_horas_panel'), 24), 24);
  RETURN (
    SELECT coalesce(jsonb_agg(vigilante._evento_json(e.id) || CASE WHEN e.abierto THEN jsonb_build_object(
             'alerta', vigilante._nivel(e.prioridad::text) >= v_desde
                       AND (e.estado = 'interpretado' OR e.version_en <= now() - make_interval(mins => v_espera)),
             'esperando_hermes', e.estado <> 'interpretado',
             'visto', EXISTS (SELECT 1 FROM vigilante.eventos_vistos v
                               WHERE v.evento_id = e.id AND v.user_id = v_user AND v.version >= e.version),
             'nuevo', NOT EXISTS (SELECT 1 FROM vigilante.eventos_vistos v WHERE v.evento_id = e.id AND v.user_id = v_user),
             'version_en', e.version_en,
             'oculta_en', e.version_en + make_interval(hours => v_horas))
           ELSE jsonb_build_object(
             -- cerrado o descartado: solo informativo, sin alarma ni ventana
             'alerta', false, 'esperando_hermes', false, 'visto', true, 'nuevo', false,
             'motivo_cierre', e.motivo_cierre, 'descartado_por', e.descartado_por,
             'cerrado_en', e.updated_at,
             'version_en', e.version_en,
             'oculta_en', e.version_en + make_interval(hours => v_horas))
           END
             ORDER BY e.abierto DESC, e.version_en DESC, e.puntaje DESC), '[]')
      FROM (SELECT x.*, x.estado IN ('por_interpretar', 'interpretando', 'interpretado') AS abierto
              FROM vigilante.eventos_compuestos x
             WHERE x.cliente_id = v_cliente
               AND x.version_en > now() - make_interval(hours => v_horas)) e);
END $$;

REVOKE ALL ON FUNCTION vigilante.eventos_emergentes() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.eventos_emergentes() TO authenticated, service_role;

COMMIT;
