-- =============================================================================
-- 49. Vista Dirección: 3 ejes, semáforo, ficha de acción y «Lo que viene»
-- =============================================================================
-- Qué pide la Dirección (auditoría para la Dirección de Turismo, P1, 2026-11-22):
--   · una sola pantalla, sin editar nada, con el semáforo de Bolivia y 3 tarjetas: movilidad,
--     servicios esenciales y atención turística (los 3 ejes de la premisa), cada una Normal /
--     Atención / Acción;
--   · las 3 decisiones de hoy con una ficha fija: Acción recomendada · Plazo · Cómo verificar
--     (sale de la recomendación segura del 25, no la sustituye). Sin responsable: la Dirección no
--     tiene responsables asignados por eje (Meysel, 2026-11-22);
--   · el semáforo de cada departamento con su motivo en una frase y qué se recomienda;
--   · «Lo que viene» en 24 h, 72 h y 7 días, por fecha de OCURRENCIA, no de detección.
--
-- Reglas (las mismas en web/src/lib/direccion.ts y web/src/lib/accion.ts):
--   Eje de cada señal (vigilante.eje_de):
--     salud → servicios esenciales · vial y seguridad → movilidad
--     clima → movilidad («clima en rutas»), salvo que hable de agua, sequía, energía… → servicios
--     cualquier tema que hable de bloqueo, marcha, paro, huelga, protesta → movilidad (conflicto social)
--     eventos, conectividad (AÉREA en AVIA: aeropuertos y vuelos), turismo y mercados → atención turística
--     el resto (financiación, normativa, economía) solo entra si habla de agua, energía, combustible,
--     internet o telefonía (servicios) o de aeropuertos, hoteles, visitantes (atención); si no, sin eje.
--   Acción de cada riesgo (vigilante.accion_direccion, igual que «Actuar hoy / Preparar / Seguir» del PR #40):
--     actuar   = prioridad alta, impacto alto valorado por AVIA o palabras de daño grave;
--     preparar = prioridad media, impacto medio o avisos serios; seguir = el resto;
--     un escenario nunca pasa de preparar.
--   Estado (vigilante.estado_direccion): solo riesgos y mixtas activos.
--     Acción   = actuar y certeza confirmado o convocado;
--     Atención = actuar sin confirmar (posible, rumor) o preparar;
--     Normal   = seguir, oportunidades o nada.
--   Semáforo de Bolivia = el peor de los 3 ejes. Departamento = su señal que más pesa
--   (las nacionales se listan aparte y no tiñen todo el mapa).
--
-- Qué hace:
--   1. vigilante.eje_de(categoría, texto), vigilante.accion_direccion(señal),
--      vigilante.estado_direccion(señal) y vigilante.ficha_direccion(señal).
--   2. vigilante.direccion(cliente): semáforo de Bolivia, ejes, 3 decisiones, departamentos y lo que
--      viene en 7 días (el chat AVIA lo usa para responder lo mismo que la pantalla).
--   3. vigilante_bd() y vigilante_json() añaden a cada señal «direccion» (eje, acción y ficha) y, arriba,
--      «direccion». No se toca _vigilante_json(): los scripts que la cambien después
--      siguen valiendo.
--
-- Necesita el 48 (y lo anterior). Se puede ejecutar varias veces.
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar:
--   SELECT codigo, vigilante.eje_de(categoria, titulo || ' ' || coalesce(resumen, '')) AS eje,
--          vigilante.estado_direccion(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 20;
--   SELECT jsonb_pretty(vigilante.direccion(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_vista_direccion.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 1a. Eje de una señal ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.eje_de(p_categoria text, p_texto text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH t AS (SELECT ' ' || vigilante.texto_norm(p_texto) || ' ' AS x, lower(coalesce(p_categoria, '')) AS c),
  r AS (
    SELECT c,
      x ~ '\m(bloqueo|bloqueos|bloquean|marcha|marchas|paro|paros|huelga|protesta|protestas|movilizacion|movilizaciones|conflicto social|cerco|enfrentamiento|toma de)\M' AS conflicto,
      x ~ '\m(agua|potable|sequia|racionamiento|electricidad|energia electrica|suministro electrico|apagon\w*|corte de luz|cortes de luz|corte de energia|cortes de energia|combustible|gasolina|diesel|desabastec\w*|gnv|garrafa|internet|telefon\w*|telecomunicac\w*|conectividad movil|senal movil|hospital\w*|sanitari\w*)\M' AS servicios,
      x ~ '\m(aeropuerto|aeropuertos|vuelo|vuelos|aerolinea\w*|hotel\w*|alojamiento\w*|hosped\w*|reserva\w*|ocupacion|visitantes|turistas|demanda|feria|festival|fiesta|carnaval|entrada folklorica)\M' AS atencion
    FROM t)
  SELECT CASE
    WHEN c = 'salud' THEN 'servicios'
    WHEN c IN ('vial', 'seguridad') THEN 'movilidad'
    WHEN c = 'clima' THEN CASE WHEN servicios THEN 'servicios' ELSE 'movilidad' END
    WHEN conflicto THEN 'movilidad'
    WHEN c IN ('eventos', 'conectividad', 'turismo', 'mercado', 'mercados') THEN 'atencion'
    WHEN servicios THEN 'servicios'
    WHEN atencion THEN 'atencion'
  END FROM r
$$;

-- 1b. Actuar hoy / Preparar / Seguir (igual que web/src/lib/accion.ts) -----------------------------
CREATE OR REPLACE FUNCTION vigilante.accion_direccion(p_signal bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH s AS (
    SELECT sg.prioridad, sg.es_escenario,
           vigilante.texto_norm(sg.titulo || ' ' || coalesce(sg.resumen, '')) AS t,
           CASE WHEN vigilante.puntuaciones(sg.id) -> 'impacto' ->> 'origen' = 'modelo'
                THEN vigilante.puntuaciones(sg.id) -> 'impacto' ->> 'nivel' END AS impacto
      FROM vigilante.signals sg WHERE sg.id = p_signal),
  k AS (
    SELECT s.*,
      EXISTS (SELECT 1 FROM unnest(ARRAY['alerta roja','emergencia','desastre','catastrofe','derrumbe','deslizamiento','mazamorra','riada',
        'desborde','inundacion','fallecid','muert','herid','desaparecid','evacua','cierre total','bloqueo total',
        'incomunicad','colapso','brote','epidemia']) p WHERE s.t LIKE '%' || p || '%') AS grave,
      EXISTS (SELECT 1 FROM unnest(ARRAY['alerta naranja','bloqueo','cierre','corte','paro','huelga','suspension','cancelacion','restriccion',
        'granizada','helada','incendio','sequia','alerta']) p WHERE s.t LIKE '%' || p || '%') AS serio
    FROM s)
  SELECT CASE
    WHEN (prioridad = 'alta' OR impacto = 'alto' OR grave) THEN CASE WHEN es_escenario THEN 'preparar' ELSE 'actuar' END
    WHEN (prioridad = 'media' OR impacto = 'medio' OR serio) THEN 'preparar'
    ELSE 'seguir' END
  FROM k
$$;

-- 1c. Normal / Atención / Acción de una señal ------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.estado_direccion(p_signal bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
    WHEN s.estado IN ('descartada', 'cerrada') OR s.naturaleza = 'oportunidad' THEN 'normal'
    WHEN a.accion = 'seguir' THEN 'normal'
    WHEN a.accion = 'actuar' AND coalesce(vigilante.certeza(s.id) ->> 'nivel', 'posible') NOT IN ('posible', 'rumor') THEN 'accion'
    ELSE 'atencion' END
  FROM vigilante.signals s, LATERAL (SELECT vigilante.accion_direccion(s.id) AS accion) a
  WHERE s.id = p_signal
$$;

-- 1d. Ficha fija: Acción recomendada · Plazo · Cómo verificar ------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.ficha_direccion(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH s AS (
    SELECT sg.*, vigilante.recomendacion_segura(sg.id) AS r, vigilante.hoy_bo() AS hoy,
           vigilante.accion_direccion(sg.id) AS accion,
           vigilante.dia_bo(sg.plazo_hasta) AS cierre,
           (sg.fecha_evento_inicio AT TIME ZONE 'UTC')::date AS inicio,
           vigilante.certeza_plazo(sg.id) ->> 'nivel' AS certeza_plazo
      FROM vigilante.signals sg WHERE sg.id = p_signal),
  p AS (
    SELECT s.*,
      CASE
        WHEN naturaleza = 'oportunidad' AND cierre >= hoy THEN cierre
        WHEN naturaleza = 'oportunidad' AND inicio >= hoy THEN inicio
        WHEN naturaleza = 'oportunidad' THEN hoy + 7
        WHEN accion = 'actuar' THEN hoy
        WHEN accion = 'preparar' THEN CASE WHEN inicio > hoy AND inicio <= hoy + 3 THEN inicio - 1 ELSE hoy + 3 END
        ELSE hoy + 7 END AS plazo_fecha
    FROM s)
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'accion', CASE WHEN coalesce((r ->> 'afirma_sin_verificar')::boolean, false)
                   THEN 'Comprobar con ' || (r ->> 'verificar_con') || ' antes de avisar a nadie: no hay dato oficial de las últimas 24 h'
                   ELSE regexp_replace(coalesce(r ->> 'texto', salida_modelo -> 'soluciones' -> 0 ->> 't', 'Seguir la evolución'), '\.$', '') END,
    'afecta', r ->> 'para_quien',
    'plazo', CASE
        WHEN naturaleza = 'oportunidad' AND cierre >= hoy
          THEN 'Antes del cierre: ' || vigilante.texto_cierre(plazo_hasta)
               || CASE WHEN certeza_plazo = 'confirmado' THEN '' ELSE ' (fecha pendiente de verificar)' END
        WHEN naturaleza = 'oportunidad' AND inicio >= hoy THEN 'Antes del ' || to_char(inicio, 'DD/MM') || ', cuando empieza'
        WHEN naturaleza = 'oportunidad' THEN 'Esta semana'
        WHEN accion = 'actuar' THEN 'Hoy'
        WHEN accion = 'preparar' THEN CASE WHEN plazo_fecha = hoy THEN 'Hoy' ELSE 'Antes del ' || to_char(plazo_fecha, 'DD/MM') END
        ELSE 'Revisar en 7 días' END,
    'plazo_fecha', to_char(plazo_fecha, 'YYYY-MM-DD'),
    'verificar', 'Con ' || coalesce(r ->> 'verificar_con', 'la fuente oficial del tema')
                 || coalesce('. Falta saber: ' || lower(regexp_replace(r -> 'falta_saber' ->> 0, '\.$', '')), ''),
    'sin_verificar', CASE WHEN coalesce((r ->> 'afirma_sin_verificar')::boolean, false) THEN true END))
  FROM p
$$;

-- departamentos de una señal: los suyos (o el padre de una provincia/ciudad); 'nacional' para el país
CREATE OR REPLACE FUNCTION vigilante.departamentos_senal(p_signal bigint)
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(array_agg(DISTINCT d) FILTER (WHERE d IS NOT NULL), '{}')
    FROM (SELECT CASE WHEN t.nivel = 'pais' THEN 'nacional'
                      WHEN t.nivel = 'region' THEN t.nombre
                      WHEN pa.nivel = 'region' THEN pa.nombre END AS d
            FROM vigilante.signal_territorios st
            JOIN vigilante.territorios t ON t.id = st.territorio_id
            LEFT JOIN vigilante.territorios pa ON pa.id = t.padre_id
           WHERE st.signal_id = p_signal) x
$$;

-- 2. Todo lo de la vista para un cliente (lo usa el chat AVIA) ---------------------------------------
CREATE OR REPLACE FUNCTION vigilante.direccion(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.id, s.codigo, s.titulo, s.resumen, s.naturaleza, s.prioridad, s.created_at, s.plazo_hasta,
           s.fecha_evento_inicio, s.fecha_evento_fin, s.categoria,
           vigilante.eje_de(s.categoria, s.titulo || ' ' || coalesce(s.resumen, '')) AS eje,
           vigilante.estado_direccion(s.id) AS estado,
           vigilante.certeza(s.id) ->> 'nivel' AS certeza,
           vigilante.departamentos_senal(s.id) AS deps,
           vigilante.dia_bo(s.plazo_hasta) AS cierre,
           (s.fecha_evento_inicio AT TIME ZONE 'UTC')::date AS ini,
           (s.fecha_evento_fin AT TIME ZONE 'UTC')::date AS fin,
           CASE vigilante.estado_direccion(s.id) WHEN 'accion' THEN 0 WHEN 'atencion' THEN 1 ELSE 2 END AS orden
      FROM vigilante.senales_visibles(p_cliente) s
     WHERE s.estado <> 'descartada'),
  e AS (
    SELECT x.eje,
           CASE min(a.orden) WHEN 0 THEN 'accion' WHEN 1 THEN 'atencion' ELSE 'normal' END AS estado,
           count(*) FILTER (WHERE a.estado = 'accion') AS n_accion,
           count(*) FILTER (WHERE a.estado = 'atencion') AS n_atencion,
           count(*) FILTER (WHERE a.naturaleza = 'oportunidad') AS n_opp,
           (array_agg(a.titulo ORDER BY a.orden, a.created_at DESC) FILTER (WHERE a.estado <> 'normal'))[1] AS peor,
           coalesce(jsonb_agg(jsonb_build_object('codigo', a.codigo, 'titulo', a.titulo, 'estado', a.estado)
                     ORDER BY a.orden, a.created_at DESC) FILTER (WHERE a.estado <> 'normal'), '[]') AS senales
      FROM (VALUES ('movilidad'), ('servicios'), ('atencion')) x(eje)
      LEFT JOIN a ON a.eje = x.eje
     GROUP BY x.eje),
  d AS (
    SELECT dep, a.codigo, a.titulo, a.eje, a.estado, a.id,
           row_number() OVER (PARTITION BY dep ORDER BY a.orden, a.created_at DESC) AS n,
           count(*) FILTER (WHERE a.estado <> 'normal') OVER (PARTITION BY dep) AS con_peso
      FROM a, unnest(a.deps) dep
     WHERE a.eje IS NOT NULL AND dep <> 'nacional'),
  dec AS (
    SELECT a.*, CASE WHEN a.estado = 'accion' THEN 0
                     WHEN a.naturaleza <> 'riesgo' AND a.cierre BETWEEN vigilante.hoy_bo() AND vigilante.hoy_bo() + 7 THEN 1
                     WHEN a.estado = 'atencion' THEN 2
                     WHEN a.naturaleza <> 'riesgo' AND a.prioridad = 'alta' THEN 3 ELSE 9 END AS rango
      FROM a WHERE a.eje IS NOT NULL),
  v AS (
    SELECT a.codigo, a.titulo, a.eje, a.certeza, a.deps,
           CASE WHEN ' ' || vigilante.texto_norm(a.titulo || ' ' || coalesce(a.resumen, '')) || ' '
                     ~ '\m(bloqueo|bloqueos|bloquean|marcha|marchas|paro|paros|huelga|protesta|protestas|movilizacion|movilizaciones|cerco)\M' THEN 'conflicto'
                WHEN a.categoria = 'clima' THEN 'pronostico' ELSE 'evento' END AS tipo,
           greatest(a.ini, vigilante.hoy_bo()) AS fecha, a.fin
      FROM a
     WHERE a.ini IS NOT NULL AND a.ini <= vigilante.hoy_bo() + 7
       AND (a.ini >= vigilante.hoy_bo() OR a.fin >= vigilante.hoy_bo())
    UNION ALL
    SELECT a.codigo, a.titulo, a.eje, a.certeza, a.deps, 'plazo', a.cierre, NULL
      FROM a
     WHERE a.naturaleza <> 'riesgo' AND a.cierre BETWEEN vigilante.hoy_bo() AND vigilante.hoy_bo() + 7
       AND a.cierre IS DISTINCT FROM a.ini)
  SELECT jsonb_build_object(
    'generado', now(),
    'hoy', to_char(vigilante.hoy_bo(), 'YYYY-MM-DD'),
    'bolivia', (SELECT CASE min(CASE estado WHEN 'accion' THEN 0 WHEN 'atencion' THEN 1 ELSE 2 END)
                         WHEN 0 THEN 'accion' WHEN 1 THEN 'atencion' ELSE 'normal' END FROM e),
    'ejes', (SELECT jsonb_agg(jsonb_build_object(
                'eje', e.eje, 'estado', e.estado,
                'motivo', coalesce(e.peor || CASE WHEN e.n_accion + e.n_atencion > 1 THEN ' y ' || (e.n_accion + e.n_atencion - 1) || ' más' ELSE '' END,
                                   'Sin riesgos que pidan medidas'),
                'para_actuar_hoy', e.n_accion, 'para_preparar', e.n_atencion, 'oportunidades', e.n_opp,
                'senales', (SELECT jsonb_agg(x) FROM (SELECT jsonb_array_elements(e.senales) x LIMIT 5) y))
              ORDER BY array_position(ARRAY['movilidad','servicios','atencion'], e.eje)) FROM e),
    'decisiones', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', x.codigo, 'titulo', x.titulo, 'eje', x.eje,
                     'naturaleza', x.naturaleza, 'estado', x.estado, 'certeza', x.certeza, 'ficha', vigilante.ficha_direccion(x.id))
                     ORDER BY x.rango, x.cierre NULLS LAST, x.created_at DESC), '[]')
                     FROM (SELECT * FROM dec WHERE rango < 9 ORDER BY rango, cierre NULLS LAST, created_at DESC LIMIT 3) x),
    'departamentos', (SELECT coalesce(jsonb_object_agg(d.dep, jsonb_build_object(
                        'estado', d.estado,
                        'motivo', CASE WHEN d.estado = 'normal' THEN 'Sin riesgos que pidan medidas'
                                       ELSE CASE d.eje WHEN 'movilidad' THEN 'Movilidad' WHEN 'servicios' THEN 'Servicios esenciales' ELSE 'Atención turística' END
                                            || ': ' || d.titulo || CASE WHEN d.con_peso > 1 THEN ' (y ' || (d.con_peso - 1) || ' más)' ELSE '' END END,
                        'senal', CASE WHEN d.estado <> 'normal' THEN d.codigo END,
                        'recomendacion', CASE WHEN d.estado <> 'normal' THEN vigilante.ficha_direccion(d.id) ->> 'accion' END)), '{}')
                        FROM d WHERE d.n = 1),
    'nacionales', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', a.codigo, 'titulo', a.titulo, 'estado', a.estado) ORDER BY a.orden), '[]')
                     FROM a WHERE 'nacional' = ANY (a.deps) AND a.eje IS NOT NULL AND a.estado <> 'normal'),
    'lo_que_viene', (SELECT coalesce(jsonb_agg(jsonb_build_object('fecha', to_char(v.fecha, 'YYYY-MM-DD'), 'dias', v.fecha - vigilante.hoy_bo(),
                       'fin', to_char(v.fin, 'YYYY-MM-DD'), 'tipo', v.tipo, 'codigo', v.codigo, 'titulo', v.titulo, 'eje', v.eje,
                       'certeza', v.certeza, 'departamentos', to_jsonb(v.deps)) ORDER BY v.fecha, v.codigo), '[]') FROM v)
  )
$$;

-- 3. vigilante_bd() y vigilante_json(): cada señal con su eje, acción y ficha; arriba la direccion
CREATE OR REPLACE FUNCTION vigilante._con_direccion(p_json jsonb, p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN p_json IS NULL THEN NULL ELSE
    p_json
    || jsonb_build_object(
         'senales', coalesce((
           SELECT jsonb_agg(CASE WHEN s.id IS NULL THEN x ELSE x || jsonb_build_object('direccion', jsonb_strip_nulls(jsonb_build_object(
                    'eje', vigilante.eje_de(s.categoria, s.titulo || ' ' || coalesce(s.resumen, '')),
                    'accion', vigilante.accion_direccion(s.id),
                    'ficha', vigilante.ficha_direccion(s.id)))) END ORDER BY o)
             FROM jsonb_array_elements(p_json -> 'senales') WITH ORDINALITY e(x, o)
             LEFT JOIN vigilante.signals s ON s.cliente_id = p_cliente AND s.codigo = x ->> 'id'), '[]'),
         'direccion', vigilante.direccion(p_cliente))
  END
$$;

CREATE OR REPLACE FUNCTION vigilante.vigilante_bd()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN vigilante.cliente_actual() IS NULL THEN NULL
              ELSE vigilante._con_direccion(vigilante._vigilante_json(vigilante.cliente_actual()), vigilante.cliente_actual()) END
$$;

CREATE OR REPLACE FUNCTION vigilante.vigilante_json(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante._con_direccion(vigilante._vigilante_json(vigilante.id_cliente(p_cliente)), vigilante.id_cliente(p_cliente))
$$;

-- Permisos ------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION vigilante.accion_direccion(bigint) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.estado_direccion(bigint) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.ficha_direccion(bigint) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.departamentos_senal(bigint) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.direccion(uuid) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION vigilante._con_direccion(jsonb, uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.accion_direccion(bigint), vigilante.estado_direccion(bigint),
  vigilante.ficha_direccion(bigint), vigilante.departamentos_senal(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION vigilante.direccion(uuid), vigilante._con_direccion(jsonb, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION vigilante.eje_de(text, text) TO authenticated, service_role;
-- si se ejecutó una versión anterior del 49
DROP FUNCTION IF EXISTS vigilante.responsable_eje(uuid, text);

COMMIT;
