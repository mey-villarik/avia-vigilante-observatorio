-- =============================================================================
-- AVIA Vigilante · Control de las tareas automáticas
-- Requiere 01 a 16. Se puede ejecutar más de una vez.
--
-- Revisión de las tareas de pg_cron del 16 (11-11-2026) para cerrar la PoC:
--
--   1. Borrado a los 6 meses: antes solo borraba señales cerradas o descartadas, y en la
--      PoC casi nada se cierra (lo publicado queda «publicada»), así que no se borraba nada.
--      Ahora borra toda señal con más de 6 meses sin cambios, salvo las que siguen vivas
--      (convocatoria o evento todavía por delante). Las noticias sueltas solo se borran si
--      ninguna señal guardada las usa. También limpia el historial de pg_cron (14 días),
--      que con una tarea cada minuto crece unas 3.000 filas al día.
--   2. Tareas de cada 5 minutos: si el resumen falla, los recordatorios siguen (y al revés).
--      Cada fallo queda en vigilante.system_logs con proceso = 'tareas'.
--   3. vigilante.estado_tareas(): una consulta para ver qué tareas están activas, cuándo
--      corrieron por última vez, si fallaron y cuál fue el error. También dice si falta alguna.
--
-- Tareas que deben quedar (ver al final): vigilante-revision (cada minuto),
-- vigilante-telegram (cada minuto, del 13), vigilante-tareas (cada 5 minutos) y
-- vigilante-retencion (03:00 hora de Bolivia).
-- =============================================================================

DO $$
BEGIN
  IF to_regprocedure('vigilante.vencer_plazos_revision()') IS NULL
     OR to_regprocedure('vigilante.enviar_telegram_pendientes()') IS NULL THEN
    RAISE EXCEPTION 'Falta ejecutar antes 13_publicar_senales.sql y 16_tareas_programadas.sql';
  END IF;
END $$;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Borrado a los 6 meses (sustituye la del 01)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.purgar_retencion()
RETURNS TABLE (tabla text, borrados bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_n bigint;
BEGIN
  -- Fecha de corte por cliente (parámetro retencion_meses, 6 por defecto)
  CREATE TEMP TABLE IF NOT EXISTS _corte (cliente_id uuid PRIMARY KEY, corte timestamptz) ON COMMIT DROP;
  TRUNCATE _corte;
  INSERT INTO _corte
  SELECT c.id, now() - make_interval(months => coalesce((vigilante.param(c.id, 'retencion_meses') #>> '{}')::int, 6))
    FROM vigilante.clientes c;

  -- Señales: más de 6 meses sin cambios y sin convocatoria ni evento por delante.
  -- Se llevan con ellas (en cascada) alertas, envíos, votos, recordatorios, historial y revisiones.
  DELETE FROM vigilante.signals s USING _corte k
   WHERE k.cliente_id = s.cliente_id
     AND s.created_at < k.corte AND s.updated_at < k.corte
     AND coalesce(s.plazo_hasta, '-infinity') < now()
     AND coalesce(s.fecha_evento_fin, s.fecha_evento_inicio, '-infinity') < now();
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'signals'; borrados := v_n; RETURN NEXT;

  -- Noticias sueltas: solo las que ninguna señal guardada usa
  DELETE FROM vigilante.raw_items r USING _corte k
   WHERE k.cliente_id = r.cliente_id AND r.recolectado_en < k.corte
     AND NOT EXISTS (SELECT 1 FROM vigilante.signals s WHERE s.raw_item_id = r.id)
     AND NOT EXISTS (SELECT 1 FROM vigilante.signal_raw_items sr WHERE sr.raw_item_id = r.id);
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'raw_items'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.daily_digests d USING _corte k
   WHERE k.cliente_id = d.cliente_id AND d.generado_en < k.corte;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'daily_digests'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.chat_queries c USING _corte k
   WHERE k.cliente_id = c.cliente_id AND c.created_at < k.corte;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'chat_queries'; borrados := v_n; RETURN NEXT;

  -- Registros: los que no tienen cliente usan los 6 meses por defecto
  DELETE FROM vigilante.system_logs l
   WHERE l.created_at < coalesce((SELECT corte FROM _corte WHERE cliente_id = l.cliente_id), now() - interval '6 months');
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'system_logs'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.audit_log a
   WHERE a.created_at < coalesce((SELECT corte FROM _corte WHERE cliente_id = a.cliente_id), now() - interval '6 months');
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'audit_log'; borrados := v_n; RETURN NEXT;

  -- Historial de pg_cron: 14 días bastan para ver si las tareas fallan
  IF to_regclass('cron.job_run_details') IS NOT NULL THEN
    BEGIN
      EXECUTE 'DELETE FROM cron.job_run_details WHERE end_time < now() - interval ''14 days''';
      GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'cron.job_run_details'; borrados := v_n; RETURN NEXT;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END IF;
END $$;

-- Lo que lanza pg_cron cada noche: borra y deja constancia en el registro
CREATE OR REPLACE FUNCTION vigilante.tarea_retencion()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_object_agg(tabla, borrados), '{}') INTO v FROM vigilante.purgar_retencion();
  INSERT INTO vigilante.system_logs (nivel, proceso, paso, mensaje, detalle)
  VALUES ('info', 'tareas', 'retencion', 'Borrado de datos con más de 6 meses', v);
  RETURN v;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Tareas de cada 5 minutos: un fallo no para a las demás (sustituye la del 16)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._tarea_segura(p_paso text, p_sql text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v jsonb;
BEGIN
  EXECUTE p_sql INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  INSERT INTO vigilante.system_logs (nivel, proceso, paso, mensaje, detalle)
  VALUES ('error', 'tareas', p_paso, left(SQLERRM, 500), jsonb_build_object('sqlstate', SQLSTATE));
  RETURN jsonb_build_object('error', left(SQLERRM, 300));
END $$;

CREATE OR REPLACE FUNCTION vigilante.tareas_programadas()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  RETURN jsonb_build_object(
    'resumen',       vigilante._tarea_segura('resumen',       'SELECT vigilante.enviar_resumenes_diarios()'),
    'recordatorios', vigilante._tarea_segura('recordatorios', 'SELECT vigilante.enviar_recordatorios()'));
END $$;

-- -----------------------------------------------------------------------------
-- 3. Estado de las tareas: SELECT * FROM vigilante.estado_tareas();
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.estado_tareas()
RETURNS TABLE (tarea text, cada text, activa boolean, ultima_vez timestamptz, ultimo_resultado text,
               ultimo_error text, corridas_24h bigint, fallos_24h bigint, estado text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    tarea := '(pg_cron)'; estado := 'pg_cron no está activo: Database → Extensions → pg_cron';
    RETURN NEXT; RETURN;
  END IF;
  RETURN QUERY EXECUTE $q$
    WITH esperadas(tarea, orden) AS (VALUES
      ('vigilante-revision', 1), ('vigilante-telegram', 2), ('vigilante-tareas', 3), ('vigilante-retencion', 4)),
    tareas AS (
      SELECT coalesce(j.jobname, e.tarea) AS tarea, coalesce(e.orden, 9) AS orden, j.jobid, j.schedule, j.active
        FROM esperadas e FULL JOIN (SELECT * FROM cron.job WHERE jobname LIKE 'vigilante-%') j ON j.jobname = e.tarea
    ),
    ultima AS (
      SELECT DISTINCT ON (d.jobid) d.jobid, d.start_time, d.status, d.return_message
        FROM cron.job_run_details d ORDER BY d.jobid, d.start_time DESC
    ),
    dia AS (
      SELECT d.jobid, count(*) AS n, count(*) FILTER (WHERE d.status = 'failed') AS fallos
        FROM cron.job_run_details d WHERE d.start_time > now() - interval '24 hours' GROUP BY d.jobid
    )
    SELECT t.tarea::text, t.schedule::text, t.active, u.start_time, u.status::text,
           CASE WHEN u.status = 'failed' THEN left(u.return_message, 300) END,
           coalesce(d.n, 0), coalesce(d.fallos, 0),
           CASE WHEN t.jobid IS NULL THEN 'FALTA: volver a ejecutar el 17'
                WHEN NOT t.active THEN 'Desactivada'
                WHEN u.status = 'failed' THEN 'FALLA'
                WHEN u.start_time IS NULL THEN 'Aún no ha corrido'
                WHEN coalesce(d.fallos, 0) > 0 THEN 'OK (con fallos en 24 h)'
                ELSE 'OK' END
      FROM tareas t LEFT JOIN ultima u ON u.jobid = t.jobid LEFT JOIN dia d ON d.jobid = t.jobid
     ORDER BY t.orden, t.tarea
  $q$;

  -- Envíos a Telegram: la tarea no falla aunque Telegram rechace el mensaje, así que se mira aparte
  tarea := '(envíos Telegram)'; cada := NULL; activa := NULL; ultimo_resultado := NULL; ultimo_error := NULL;
  SELECT max(coalesce(d.enviado_en, d.created_at)),
         count(*) FILTER (WHERE d.estado IN ('enviado', 'fallido')),
         count(*) FILTER (WHERE d.estado = 'fallido'),
         (array_agg(d.error ORDER BY d.created_at DESC) FILTER (WHERE d.estado = 'fallido'))[1]
    INTO ultima_vez, corridas_24h, fallos_24h, ultimo_error
    FROM vigilante.deliveries d WHERE d.canal = 'telegram' AND d.created_at > now() - interval '24 hours';
  BEGIN
    PERFORM 1 FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token' AND coalesce(decrypted_secret, '') <> '';
    estado := CASE WHEN NOT FOUND THEN 'FALTA el secreto telegram_bot_token en el Vault'
                   WHEN fallos_24h > 0 THEN 'FALLA: ' || coalesce(ultimo_error, 'ver vigilante.deliveries')
                   WHEN corridas_24h = 0 THEN 'OK (nada que enviar en 24 h)'
                   ELSE 'OK' END;
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN
    estado := 'Sin Vault (no es Supabase)';
  END;
  RETURN NEXT;
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'vigilante.purgar_retencion()', 'vigilante.tarea_retencion()', 'vigilante._tarea_segura(text, text)',
    'vigilante.tareas_programadas()', 'vigilante.estado_tareas()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon, authenticated', f);
  END LOOP;
END $$;

COMMIT;

-- 4. Tareas de pg_cron (fuera de la transacción; solo en Supabase) ---------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- cron.schedule con el mismo nombre actualiza la tarea existente
    PERFORM cron.schedule('vigilante-revision',  '* * * * *',   'SELECT vigilante.vencer_plazos_revision()');
    PERFORM cron.schedule('vigilante-telegram',  '* * * * *',   'SELECT vigilante.enviar_telegram_pendientes()');
    PERFORM cron.schedule('vigilante-tareas',    '*/5 * * * *', 'SELECT vigilante.tareas_programadas()');
    -- 07:00 UTC = 03:00 en Bolivia
    PERFORM cron.schedule('vigilante-retencion', '0 7 * * *',   'SELECT vigilante.tarea_retencion()');
    RAISE NOTICE 'Tareas programadas: vigilante-revision, vigilante-telegram, vigilante-tareas, vigilante-retencion';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;

-- Cómo están ahora (en el SQL Editor sale como tabla)
SELECT * FROM vigilante.estado_tareas();
