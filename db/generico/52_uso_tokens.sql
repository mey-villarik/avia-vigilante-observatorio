-- =============================================================================
-- 52. Uso de tokens de IA: hoy, este mes y acumulado (con coste y lo que queda)
-- =============================================================================
-- Qué pide Meysel (2026-11-23): «pon en algún lugar algo que muestre los tokens que se han usado y lo
-- que le queda». Solo para el equipo (analista y administrador), nunca en la web pública.
--
-- Dónde están los tokens hoy:
--   · El clasificador (analizador.py) anota cada lote en vigilante.system_logs con proceso
--     'clasificador' y detalle {"tokens_entrada", "tokens_salida", "costo_usd", "modelo"} (desde el 15).
--     vigilante.analisis guarda lo mismo repartido por noticia: NO se suma aquí para no contarlo dos veces.
--   · El chat, el análisis y la evaluación de AVIA (avia_api.py) desde esta versión anotan igual,
--     con proceso 'avia-chat', 'avia-analisis' y 'avia-evaluar'.
--   · Lo que Hermes gasta dentro de sus propias tareas (skills, interpretar eventos) NO se anota en la base:
--     eso solo se ve en el saldo de la cuenta de DeepSeek, que la web pide aparte a avia_api (/saldo).
--
-- Coste: si el registro trae costo_usd > 0 se usa tal cual; si no (el analizador no tenía tarifa en el
-- .env), se estima con la tarifa guardada en parámetros (USD por millón de tokens). Editable por cliente.
--
-- «Lo que queda»: solo si hay un límite guardado.
--   ia_presupuesto_usd_mes → USD que se pueden gastar al mes (restante = presupuesto − coste del mes)
--   ia_tope_tokens_mes     → tokens al mes (restante = tope − tokens del mes)
--   Sin ninguno de los dos, la web muestra solo lo consumido (y el saldo real de DeepSeek si avia_api lo da).
--
-- Acumulado: lo que queda en system_logs, que se borra a los 6 meses (16/17). La respuesta dice desde cuándo.
--
-- Qué hace:
--   1. Parámetros por defecto de tarifa (DeepSeek, estimado) sin presupuesto.
--   2. vigilante._uso_tokens_filas(cliente): una fila por llamada al modelo con tokens y coste.
--   3. vigilante.uso_tokens(cliente): hoy, mes, acumulado, por proceso, últimos 14 días y lo que queda.
--      Desde la web (sesión) siempre es el cliente de quien pregunta y solo para analista o administrador;
--      con service_role se puede pasar cualquier cliente.
-- =============================================================================
BEGIN;

INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'ia_precio_entrada_usd_millon', '0.30', 'USD por millón de tokens de entrada (para estimar el coste cuando el registro no lo trae). DeepSeek, estimado'),
  (NULL, 'ia_precio_salida_usd_millon', '1.20', 'USD por millón de tokens de salida (para estimar el coste cuando el registro no lo trae). DeepSeek, estimado')
ON CONFLICT (cliente_id, clave) DO NOTHING;
-- Sin valor por defecto (no hay límite hasta que alguien lo ponga):
--   INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
--   SELECT id, 'ia_presupuesto_usd_mes', '20', 'Presupuesto mensual de IA en USD' FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
--   ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = excluded.valor;

-- -----------------------------------------------------------------------------
-- 2. Una fila por llamada al modelo
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._uso_tokens_filas(p_cliente uuid)
RETURNS TABLE (creado timestamptz, proceso text, modelo text, entrada bigint, salida bigint, costo numeric, estimado boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH t AS (
    SELECT coalesce((vigilante.param(p_cliente, 'ia_precio_entrada_usd_millon') #>> '{}')::numeric, 0) AS pe,
           coalesce((vigilante.param(p_cliente, 'ia_precio_salida_usd_millon') #>> '{}')::numeric, 0) AS ps
  ), l AS (
    SELECT l.created_at, coalesce(l.proceso, 'otro') AS proceso, l.detalle ->> 'modelo' AS modelo,
           coalesce((l.detalle ->> 'tokens_entrada')::numeric, 0)::bigint AS entrada,
           coalesce((l.detalle ->> 'tokens_salida')::numeric, 0)::bigint AS salida,
           coalesce(l.costo_usd, (l.detalle ->> 'costo_usd')::numeric, 0) AS costo_reg
      FROM vigilante.system_logs l
     WHERE l.cliente_id = p_cliente
       AND l.detalle IS NOT NULL AND jsonb_typeof(l.detalle) = 'object'
       AND (l.detalle ? 'tokens_entrada' OR l.detalle ? 'tokens_salida')
  )
  SELECT l.created_at, l.proceso, l.modelo, l.entrada, l.salida,
         CASE WHEN l.costo_reg > 0 THEN l.costo_reg ELSE (l.entrada * t.pe + l.salida * t.ps) / 1e6 END,
         NOT (l.costo_reg > 0)
    FROM l, t
$$;
REVOKE ALL ON FUNCTION vigilante._uso_tokens_filas(uuid) FROM public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Resumen para el panel
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.uso_tokens(p_cliente uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid; v_tz text; v_hoy date; v_mes date;
  v_pres numeric; v_tope numeric; v_pe numeric; v_ps numeric;
  r_hoy record; r_mes record; r_tot record; v_proc jsonb; v_serie jsonb; v_res jsonb;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    -- desde la web: siempre el cliente propio y solo el equipo
    IF NOT vigilante.es_staff() THEN RETURN NULL; END IF;
    v_cliente := vigilante.cliente_actual();
  ELSE
    v_cliente := coalesce(p_cliente, vigilante.cliente_actual());
  END IF;
  IF v_cliente IS NULL THEN RETURN NULL; END IF;

  SELECT coalesce(nullif(zona_horaria, ''), 'UTC') INTO v_tz FROM vigilante.clientes WHERE id = v_cliente;
  v_hoy := (now() AT TIME ZONE v_tz)::date;
  v_mes := date_trunc('month', v_hoy)::date;
  v_pres := (vigilante.param(v_cliente, 'ia_presupuesto_usd_mes') #>> '{}')::numeric;
  v_tope := (vigilante.param(v_cliente, 'ia_tope_tokens_mes') #>> '{}')::numeric;
  v_pe := (vigilante.param(v_cliente, 'ia_precio_entrada_usd_millon') #>> '{}')::numeric;
  v_ps := (vigilante.param(v_cliente, 'ia_precio_salida_usd_millon') #>> '{}')::numeric;

  SELECT count(*) FILTER (WHERE dia = v_hoy) AS n,
         coalesce(sum(entrada) FILTER (WHERE dia = v_hoy), 0) AS e,
         coalesce(sum(salida) FILTER (WHERE dia = v_hoy), 0) AS s,
         coalesce(sum(costo) FILTER (WHERE dia = v_hoy), 0) AS c
    INTO r_hoy FROM (SELECT *, (creado AT TIME ZONE v_tz)::date AS dia FROM vigilante._uso_tokens_filas(v_cliente)) u;
  SELECT count(*) AS n, coalesce(sum(entrada), 0) AS e, coalesce(sum(salida), 0) AS s, coalesce(sum(costo), 0) AS c
    INTO r_mes FROM vigilante._uso_tokens_filas(v_cliente) WHERE (creado AT TIME ZONE v_tz)::date >= v_mes;
  SELECT count(*) AS n, coalesce(sum(entrada), 0) AS e, coalesce(sum(salida), 0) AS s, coalesce(sum(costo), 0) AS c,
         min(creado) AS desde, max(creado) AS ultimo, bool_or(estimado) AS algo_estimado
    INTO r_tot FROM vigilante._uso_tokens_filas(v_cliente);

  SELECT coalesce(jsonb_agg(jsonb_build_object('proceso', proceso, 'llamadas', n, 'tokens', e + s,
                                               'entrada', e, 'salida', s, 'costo_usd', round(c, 4)) ORDER BY e + s DESC), '[]')
    INTO v_proc
    FROM (SELECT proceso, count(*) AS n, sum(entrada) AS e, sum(salida) AS s, sum(costo) AS c
            FROM vigilante._uso_tokens_filas(v_cliente)
           WHERE (creado AT TIME ZONE v_tz)::date >= v_mes GROUP BY proceso) x;

  SELECT jsonb_agg(jsonb_build_object('dia', g.d::date, 'tokens', coalesce(u.e + u.s, 0), 'costo_usd', round(coalesce(u.c, 0), 4)) ORDER BY g.d)
    INTO v_serie
    FROM generate_series(v_hoy - 13, v_hoy, interval '1 day') g(d)
    LEFT JOIN (SELECT (creado AT TIME ZONE v_tz)::date AS dia, sum(entrada) AS e, sum(salida) AS s, sum(costo) AS c
                 FROM vigilante._uso_tokens_filas(v_cliente) GROUP BY 1) u ON u.dia = g.d::date;

  v_res := jsonb_build_object(
    'hoy',       jsonb_build_object('llamadas', r_hoy.n, 'entrada', r_hoy.e, 'salida', r_hoy.s, 'tokens', r_hoy.e + r_hoy.s, 'costo_usd', round(r_hoy.c, 4)),
    'mes',       jsonb_build_object('llamadas', r_mes.n, 'entrada', r_mes.e, 'salida', r_mes.s, 'tokens', r_mes.e + r_mes.s, 'costo_usd', round(r_mes.c, 4),
                                    'desde', v_mes),
    'acumulado', jsonb_build_object('llamadas', r_tot.n, 'entrada', r_tot.e, 'salida', r_tot.s, 'tokens', r_tot.e + r_tot.s, 'costo_usd', round(r_tot.c, 4),
                                    'desde', r_tot.desde, 'ultimo', r_tot.ultimo),
    'por_proceso', v_proc,
    'serie_14d', coalesce(v_serie, '[]'),
    'tarifa', CASE WHEN v_pe IS NULL AND v_ps IS NULL THEN NULL
                   ELSE jsonb_build_object('entrada_usd_millon', v_pe, 'salida_usd_millon', v_ps) END,
    'costo_estimado', coalesce(r_tot.algo_estimado, false),
    'presupuesto_usd_mes', v_pres,
    'restante_usd_mes', CASE WHEN v_pres IS NULL THEN NULL ELSE round(greatest(v_pres - r_mes.c, 0), 4) END,
    'tope_tokens_mes', v_tope,
    'restante_tokens_mes', CASE WHEN v_tope IS NULL THEN NULL ELSE greatest(v_tope - (r_mes.e + r_mes.s), 0) END,
    'zona_horaria', v_tz,
    'generado', now());
  RETURN v_res;
END $$;

REVOKE ALL ON FUNCTION vigilante.uso_tokens(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.uso_tokens(uuid) TO authenticated, service_role;

COMMIT;
