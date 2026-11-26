-- =============================================================================
-- 57. Datos del panel preparados de antemano (2026-11-26)
-- =============================================================================
-- Por qué: con 308 señales vigentes, vigilante_bd() tarda unos 12 s (cada señal calcula eje,
-- acción, ficha, seguimiento…). Supabase corta a los 8 s las consultas de los usuarios
-- (rol authenticated), así que el panel fallaba en silencio y se quedaba con el vigilante.json
-- viejo («Datos generados 07:11»): Dirección enseñaba Servicios esenciales vacío aunque la base lo
-- tenía en Acción con 91 señales.
--
-- Qué hace:
--   1. vigilante.panel_cache: lo que devuelve vigilante_json() por cliente, con la hora y lo que tardó.
--   2. vigilante.refrescar_panel(): lo recalcula para todos los clientes. pg_cron lo lanza cada 2 min.
--   3. vigilante_bd() lee la copia si tiene menos de 10 min (respuesta en milisegundos) y solo
--      corrige el estado de cada señal con el de la tabla (así lo que mueve el analista en
--      Señales se ve al recargar, sin esperar a la copia). Si no hay copia reciente, calcula
--      como antes.
--   vigilante_json(slug), que usan avia_api y los scripts, no cambia.
--
-- Necesita el 50 (y lo anterior). Se puede ejecutar varias veces.
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run (tarda lo que una carga: ~12 s).
-- Si se vuelve a ejecutar el 49 o el 50, ejecutar después este 57.
-- Comprobar:
--   SELECT c.slug, p.generado, p.tarda_ms, jsonb_array_length(p.datos -> 'senales')
--     FROM vigilante.panel_cache p JOIN vigilante.clientes c ON c.id = p.cliente_id;
--   SELECT jobname, schedule FROM cron.job WHERE jobname = 'vigilante-panel';
-- Deshacer: SELECT cron.unschedule('vigilante-panel'); y volver a ejecutar el 50.
-- =============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS vigilante.panel_cache (
  cliente_id uuid PRIMARY KEY REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  datos      jsonb NOT NULL,
  generado   timestamptz NOT NULL DEFAULT now(),
  tarda_ms   integer
);
REVOKE ALL ON TABLE vigilante.panel_cache FROM public, anon, authenticated;

-- 2. Recalcular la copia ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.refrescar_panel(p_cliente uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE c record; t0 timestamptz; j jsonb; v_out jsonb := '[]';
BEGIN
  FOR c IN SELECT id, slug FROM vigilante.clientes WHERE p_cliente IS NULL OR id = p_cliente LOOP
    t0 := clock_timestamp();
    j := vigilante.vigilante_json(c.slug);
    CONTINUE WHEN j IS NULL;
    INSERT INTO vigilante.panel_cache AS p (cliente_id, datos, generado, tarda_ms)
    VALUES (c.id, j, now(), (extract(epoch FROM clock_timestamp() - t0) * 1000)::int)
    ON CONFLICT (cliente_id) DO UPDATE SET datos = EXCLUDED.datos, generado = EXCLUDED.generado, tarda_ms = EXCLUDED.tarda_ms;
    v_out := v_out || jsonb_build_object('cliente', c.slug, 'senales', jsonb_array_length(coalesce(j -> 'senales', '[]')),
                                         'tarda_ms', (extract(epoch FROM clock_timestamp() - t0) * 1000)::int);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION vigilante.refrescar_panel(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.refrescar_panel(uuid) TO service_role;

-- 3. vigilante_bd(): la copia, con el estado de cada señal al día -----------------------------------
CREATE OR REPLACE FUNCTION vigilante._estado_al_dia(p_json jsonb, p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT p_json || jsonb_build_object('senales', coalesce((
    SELECT jsonb_agg(CASE WHEN s.id IS NULL THEN x ELSE x || jsonb_build_object('estado', s.estado) END ORDER BY o)
      FROM jsonb_array_elements(p_json -> 'senales') WITH ORDINALITY e(x, o)
      LEFT JOIN vigilante.signals s ON s.cliente_id = p_cliente AND s.codigo = x ->> 'id'
     WHERE s.id IS NULL OR s.estado <> 'cerrada'), '[]'))
$$;
REVOKE ALL ON FUNCTION vigilante._estado_al_dia(jsonb, uuid) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.vigilante_bd()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
    WHEN vigilante.cliente_actual() IS NULL THEN NULL
    WHEN EXISTS (SELECT 1 FROM vigilante.panel_cache p
                  WHERE p.cliente_id = vigilante.cliente_actual() AND p.generado > now() - interval '10 minutes')
      THEN (SELECT vigilante._estado_al_dia(p.datos, p.cliente_id) FROM vigilante.panel_cache p
             WHERE p.cliente_id = vigilante.cliente_actual())
    ELSE vigilante._con_seguimiento(
           vigilante._con_direccion(vigilante._vigilante_json(vigilante.cliente_actual()), vigilante.cliente_actual()),
           vigilante.cliente_actual())
  END
$$;

-- primera copia ya
SELECT vigilante.refrescar_panel() AS primera_copia;

COMMIT;

-- 4. pg_cron cada 2 min (fuera de la transacción; solo en Supabase) ------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'vigilante-panel';
    PERFORM cron.schedule('vigilante-panel', '*/2 * * * *', 'SELECT vigilante.refrescar_panel()');
    RAISE NOTICE 'Tarea programada: vigilante-panel (cada 2 min)';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: el panel solo usará la copia mientras alguien llame a refrescar_panel()';
  END IF;
END $$;
