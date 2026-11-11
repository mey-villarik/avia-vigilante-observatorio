-- =============================================================================
-- AVIA Vigilante · Sincronización automática hecha por el propio Supabase
-- OBSOLETO desde el 15 (la web lee la base). El 17 borra esta tarea. No ejecutar.
-- Opcional. Cada 5 minutos Supabase descarga vigilante.json del VPS y lo pasa a
-- las tablas con vigilante.sincronizar_vigilante(). No hay que tocar el VPS.
--
-- Solo sirve mientras el archivo del VPS sea público. Cuando se cierre /data en
-- nginx, hay que borrar esta tarea (ver al final) y usar el script del VPS
-- integraciones/hermes-web/subir_vigilante_json.sh, que empuja el archivo.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- una vez ahora, para comprobar que funciona (debe devolver cuántas fuentes y señales pasó)
SELECT vigilante.sincronizar_vigilante('orbita-bolivia',
  (extensions.http_get('https://vigilante-bolivia.duckdns.org/data/vigilante.json')).content::jsonb);

-- y cada 5 minutos
SELECT cron.schedule('vigilante-sincronizar', '*/5 * * * *', $$
  SELECT vigilante.sincronizar_vigilante('orbita-bolivia',
    (extensions.http_get('https://vigilante-bolivia.duckdns.org/data/vigilante.json')).content::jsonb);
$$);

-- Para quitarla:  SELECT cron.unschedule('vigilante-sincronizar');
-- Para ver cómo van las ejecuciones:
--   SELECT status, return_message, start_time FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
