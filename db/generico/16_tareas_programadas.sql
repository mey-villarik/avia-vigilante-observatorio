-- =============================================================================
-- AVIA Vigilante · Tareas automáticas y ventana de 7 días
-- Requiere 01 a 15. Se puede ejecutar más de una vez.
--
-- Cierra los huecos de la auditoría contra la especificación de la beta (10-11-2026).
-- Todo lo hace Supabase solo, con pg_cron (sin IA, sin Hermes, sin n8n):
--
--   1. Plazo de revisión: una señal que pide revisión humana tiene 15 minutos en horario
--      de guardia (07:00–22:00, parámetros sla_revision_minutos, guardia_inicio, guardia_fin).
--      Si vence, queda marcada «Plazo vencido» en el panel. Si el parámetro
--      publicar_al_vencer = true, las que reproducen un aviso oficial con enlace se publican
--      solas con la etiqueta «En verificación» (por defecto está apagado: decide una persona).
--   2. Resumen diario: a la hora resumen_hora (08:00 hora local) junta las 7 alertas más
--      importantes de las últimas 24 h, lo envía al canal de Telegram y sale en la web pública.
--   3. Recordatorios: convocatorias a 30/15/5 días del cierre y eventos a 90/60/30 días.
--   4. Retención: cada noche borra lo que tenga más de 6 meses (retencion_meses).
--   5. Web pública: por defecto, riesgos y noticias de los últimos 7 días (web_dias_visibles)
--      y oportunidades mientras su plazo siga abierto. «Ver anteriores» pide el archivo.
--   6. Panel: las señales de todo el periodo guardado (no solo 60 días), con su plazo de
--      revisión y la marca de escenario.
--
-- Tareas de pg_cron que crea (ver al final): vigilante-revision (cada minuto),
-- vigilante-tareas (cada 5 minutos) y vigilante-retencion (03:00 hora de Bolivia).
-- =============================================================================

BEGIN;

-- Parámetros nuevos (cada cliente puede sobrescribirlos en vigilante.parametros) ------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'web_dias_visibles',   '7',     'Días que se ven riesgos y noticias en la web (las oportunidades, mientras su plazo siga abierto)'),
  (NULL, 'publicar_al_vencer',  'false', 'Si vence el plazo de revisión, publicar «En verificación» lo que reproduce un aviso oficial con enlace'),
  (NULL, 'resumen_canal',       '"telegram"', 'Por dónde sale el resumen diario (telegram o ninguno)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS revision_vencida_en timestamptz;

-- -----------------------------------------------------------------------------
-- 1. Plazo de revisión
-- -----------------------------------------------------------------------------
-- Cuándo vence la revisión de una señal (NULL si no espera revisión)
CREATE OR REPLACE FUNCTION vigilante.vence_revision(p_cliente uuid, p_requiere boolean,
                                                     p_estado vigilante.estado_senal, p_desde timestamptz)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN p_requiere AND p_estado IN ('detectada', 'en_analisis', 'en_verificacion')
              THEN vigilante.calcular_vencimiento(p_cliente, p_desde) END
$$;

CREATE OR REPLACE FUNCTION vigilante.vencer_plazos_revision()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE s vigilante.signals; n_venc int := 0; n_pub int := 0;
BEGIN
  FOR s IN SELECT * FROM vigilante.signals x
            WHERE x.requiere_revision AND x.estado IN ('detectada', 'en_analisis', 'en_verificacion')
              AND x.revision_vencida_en IS NULL
              AND vigilante.calcular_vencimiento(x.cliente_id, x.created_at) <= now()
            ORDER BY x.created_at LIMIT 200 FOR UPDATE SKIP LOCKED LOOP
    UPDATE vigilante.signals SET revision_vencida_en = now() WHERE id = s.id;
    n_venc := n_venc + 1;

    -- Publicar «En verificación» solo si está encendido, reproduce un aviso oficial con enlace,
    -- no es una predicción y es reciente (al instalar no se publica nada antiguo).
    IF coalesce((vigilante.param(s.cliente_id, 'publicar_al_vencer') #>> '{}')::boolean, false)
       AND s.fuente_oficial AND coalesce(s.enlace_oficial, '') <> '' AND NOT s.es_escenario
       AND s.created_at > now() - interval '24 hours' THEN
      -- las etapas no se saltan: detectada → en_analisis → en_verificacion → publicada
      IF s.estado = 'detectada' THEN
        UPDATE vigilante.signals SET estado = 'en_analisis' WHERE id = s.id;
      END IF;
      IF s.estado <> 'en_verificacion' THEN
        UPDATE vigilante.signals SET estado = 'en_verificacion' WHERE id = s.id;
      END IF;
      -- estado_manual = true: el disparador de publicación (13) lo trata como decisión del equipo,
      -- aquí tomada por la regla acordada. Queda en el historial con su nota.
      UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE id = s.id;
      INSERT INTO vigilante.signal_history (signal_id, cliente_id, entidad, estado_nuevo, nota)
      VALUES (s.id, s.cliente_id, 'signal', 'publicada',
              'Plazo de revisión vencido: publicada «En verificación» porque reproduce un aviso oficial con enlace');
      n_pub := n_pub + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('vencidas', n_venc, 'publicadas_en_verificacion', n_pub);
END $$;

-- -----------------------------------------------------------------------------
-- 2. Resumen diario
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.texto_resumen(p_digest bigint)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT concat_ws(E'\n',
    '🗞️ <b>Resumen del día · ' || to_char(d.fecha, 'DD/MM/YYYY') || '</b>',
    '',
    CASE WHEN d.sin_alertas THEN vigilante.html_tg(coalesce(d.texto, 'No hay alertas confirmadas en este momento'))
         ELSE (SELECT string_agg(
                  i.orden || '. '
                  || CASE s.naturaleza WHEN 'riesgo' THEN '⚠️ ' WHEN 'oportunidad' THEN '✨ ' ELSE '🔷 ' END
                  || '<b>' || vigilante.html_tg(a.titulo) || '</b>'
                  || CASE WHEN a.estado_verificacion = 'en_verificacion' THEN ' (en verificación)' ELSE '' END
                  || CASE WHEN jsonb_array_length(coalesce(s.salida_modelo -> 'deps', '[]')) > 0
                          THEN ' · ' || vigilante.html_tg((SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(s.salida_modelo -> 'deps') x))
                          ELSE '' END,
                  E'\n' ORDER BY i.orden)
                 FROM vigilante.daily_digest_items i
                 JOIN vigilante.alerts a ON a.id = i.alert_id
                 JOIN vigilante.signals s ON s.id = a.signal_id
                WHERE i.digest_id = d.id) END,
    CASE WHEN vigilante.param(d.cliente_id, 'web_publica_url') #>> '{}' IS NOT NULL
         THEN E'\n<a href="' || vigilante.html_tg(vigilante.param(d.cliente_id, 'web_publica_url') #>> '{}') || '">Ver el detalle en la web</a>' END)
  FROM vigilante.daily_digests d
  WHERE d.id = p_digest
$$;

-- Genera y pone en cola el resumen de cada cliente cuando llega su hora (una vez al día).
-- Solo en las 3 horas siguientes a la hora fijada: si se instala por la tarde, empieza mañana.
CREATE OR REPLACE FUNCTION vigilante.enviar_resumenes_diarios()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE c record; v_local timestamp; v_hora time; v_id bigint; n int := 0;
BEGIN
  FOR c IN SELECT id, zona_horaria FROM vigilante.clientes WHERE activo LOOP
    v_local := now() AT TIME ZONE coalesce(c.zona_horaria, 'UTC');
    v_hora  := coalesce((vigilante.param(c.id, 'resumen_hora') #>> '{}')::time, '08:00');
    CONTINUE WHEN v_local::time < v_hora OR v_local::time - v_hora >= interval '3 hours';
    CONTINUE WHEN EXISTS (SELECT 1 FROM vigilante.daily_digests WHERE cliente_id = c.id AND fecha = v_local::date);

    v_id := vigilante.generar_resumen_diario(c.id, v_local::date);
    UPDATE vigilante.daily_digests SET publicado_en = now() WHERE id = v_id;
    IF coalesce(vigilante.param(c.id, 'resumen_canal') #>> '{}', 'telegram') = 'telegram'
       AND coalesce(vigilante.param(c.id, 'telegram_canal') #>> '{}', '') <> '' THEN
      INSERT INTO vigilante.deliveries (cliente_id, canal, digest_id, plantilla)
      VALUES (c.id, 'telegram', v_id, 'resumen') ON CONFLICT DO NOTHING;
    END IF;
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('resumenes', n);
END $$;

-- -----------------------------------------------------------------------------
-- 3. Recordatorios de convocatorias y eventos
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.texto_recordatorio(p_follow_up bigint)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT concat_ws(E'\n',
    '⏰ <b>Recordatorio · ' || CASE WHEN f.dias_antes = 1 THEN 'falta 1 día' ELSE 'faltan ' || f.dias_antes || ' días' END || '</b>',
    '<b>' || vigilante.html_tg(a.titulo) || '</b>',
    CASE f.tipo WHEN 'plazo_convocatoria' THEN 'Cierra el ' ELSE 'Empieza el ' END
      || to_char(f.fecha_objetivo AT TIME ZONE coalesce(c.zona_horaria, 'UTC'), 'DD/MM/YYYY'),
    CASE WHEN a.recomendacion IS NOT NULL THEN '➜ ' || vigilante.html_tg(a.recomendacion) END,
    CASE WHEN a.enlace_fuente IS NOT NULL THEN '<a href="' || vigilante.html_tg(a.enlace_fuente) || '">Fuente</a>' END)
  FROM vigilante.follow_ups f
  JOIN vigilante.alerts a ON a.signal_id = f.signal_id
  JOIN vigilante.clientes c ON c.id = f.cliente_id
  WHERE f.id = p_follow_up
$$;

CREATE OR REPLACE FUNCTION vigilante.enviar_recordatorios()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; n_prog int := 0; n_env int := 0; n_canc int := 0;
BEGIN
  -- programar los de las alertas publicadas con plazo o fecha de evento por delante
  FOR r IN SELECT a.signal_id FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id
            WHERE a.cerrada_en IS NULL AND a.publicada_en IS NOT NULL AND a.visibilidad = 'publica' AND NOT a.es_escenario
              AND (s.plazo_hasta > now() OR s.fecha_evento_inicio > now()) LOOP
    n_prog := n_prog + vigilante.programar_recordatorios(r.signal_id);
  END LOOP;

  -- los que ya tocan
  FOR r IN SELECT f.id, f.cliente_id, f.signal_id, f.programado_para, f.fecha_objetivo
             FROM vigilante.follow_ups f
            WHERE f.enviado_en IS NULL AND NOT f.cancelado AND f.programado_para <= now()
            ORDER BY f.programado_para FOR UPDATE SKIP LOCKED LOOP
    IF r.fecha_objetivo <= now() OR r.programado_para < now() - interval '1 day'
       OR NOT EXISTS (SELECT 1 FROM vigilante.alerts a WHERE a.signal_id = r.signal_id AND a.cerrada_en IS NULL
                         AND a.visibilidad = 'publica' AND NOT a.es_escenario) THEN
      -- retirada, ya pasó o llegó tarde (más de un día): no se manda
      UPDATE vigilante.follow_ups SET cancelado = true WHERE id = r.id;
      n_canc := n_canc + 1;
      CONTINUE;
    END IF;
    IF coalesce(vigilante.param(r.cliente_id, 'telegram_canal') #>> '{}', '') <> '' THEN
      INSERT INTO vigilante.deliveries (cliente_id, canal, follow_up_id, plantilla)
      VALUES (r.cliente_id, 'telegram', r.id, 'recordatorio') ON CONFLICT DO NOTHING;
    END IF;
    UPDATE vigilante.follow_ups SET enviado_en = now() WHERE id = r.id;
    n_env := n_env + 1;
  END LOOP;
  RETURN jsonb_build_object('programados', n_prog, 'enviados', n_env, 'cancelados', n_canc);
END $$;

-- -----------------------------------------------------------------------------
-- 4. Envío a Telegram: alertas, resúmenes y recordatorios (sustituye la del 13)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.enviar_telegram_pendientes()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, extensions, pg_temp AS $$
DECLARE
  v_token text; d record; v_canal text; v_texto text; v_resp record; n_ok int := 0; n_mal int := 0;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token' LIMIT 1;
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN v_token := NULL;
  END;
  IF coalesce(v_token, '') = '' THEN RETURN jsonb_build_object('error', 'Falta el secreto telegram_bot_token en el Vault'); END IF;

  FOR d IN SELECT dl.id, dl.alert_id, dl.digest_id, dl.follow_up_id, dl.cliente_id FROM vigilante.deliveries dl
            WHERE dl.canal = 'telegram' AND dl.estado = 'pendiente' AND dl.user_id IS NULL
            ORDER BY dl.created_at LIMIT 20 FOR UPDATE SKIP LOCKED LOOP
    v_canal := vigilante.param(d.cliente_id, 'telegram_canal') #>> '{}';
    -- la alerta (o la del recordatorio) se retiró antes de salir → no se envía
    IF coalesce(v_canal, '') = ''
       OR (d.alert_id IS NOT NULL AND EXISTS (SELECT 1 FROM vigilante.alerts WHERE id = d.alert_id AND cerrada_en IS NOT NULL))
       OR (d.follow_up_id IS NOT NULL AND NOT EXISTS (
             SELECT 1 FROM vigilante.follow_ups f JOIN vigilante.alerts a ON a.signal_id = f.signal_id
              WHERE f.id = d.follow_up_id AND NOT f.cancelado AND a.cerrada_en IS NULL)) THEN
      UPDATE vigilante.deliveries SET estado = 'omitido', error = 'Retirada o sin canal' WHERE id = d.id;
      CONTINUE;
    END IF;
    v_texto := CASE WHEN d.alert_id IS NOT NULL THEN vigilante.texto_telegram(d.alert_id)
                    WHEN d.digest_id IS NOT NULL THEN vigilante.texto_resumen(d.digest_id)
                    ELSE vigilante.texto_recordatorio(d.follow_up_id) END;
    BEGIN
      SELECT * INTO v_resp FROM extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        jsonb_build_object('chat_id', v_canal, 'text', v_texto,
                           'parse_mode', 'HTML', 'disable_web_page_preview', true)::text,
        'application/json');
      IF v_resp.status = 200 THEN
        UPDATE vigilante.deliveries SET estado = 'enviado', enviado_en = now(), error = NULL,
               mensaje_externo_id = (v_resp.content::jsonb #>> '{result,message_id}') WHERE id = d.id;
        n_ok := n_ok + 1;
      ELSE
        UPDATE vigilante.deliveries SET estado = 'fallido',
               error = left(coalesce(v_resp.content::jsonb ->> 'description', 'HTTP ' || v_resp.status), 300) WHERE id = d.id;
        n_mal := n_mal + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE vigilante.deliveries SET estado = 'fallido', error = left(replace(SQLERRM, v_token, '***'), 300) WHERE id = d.id;
      n_mal := n_mal + 1;
    END;
  END LOOP;
  RETURN jsonb_build_object('enviados', n_ok, 'fallidos', n_mal);
END $$;

-- Todas las tareas de cada 5 minutos juntas (también sirve para lanzarlas a mano)
CREATE OR REPLACE FUNCTION vigilante.tareas_programadas()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object('resumen', vigilante.enviar_resumenes_diarios(),
                            'recordatorios', vigilante.enviar_recordatorios())
$$;

-- -----------------------------------------------------------------------------
-- 5. Web pública: 7 días por defecto, oportunidades mientras el plazo siga abierto
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS vigilante.alertas_publicas(text);
CREATE OR REPLACE FUNCTION vigilante.alertas_publicas(p_cliente text, p_anteriores boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (
    SELECT cl.*, coalesce((vigilante.param(cl.id, 'web_dias_visibles') #>> '{}')::int, 7) AS dias,
           coalesce((vigilante.param(cl.id, 'retencion_meses') #>> '{}')::int, 6) AS meses
      FROM vigilante.clientes cl WHERE cl.slug = p_cliente AND cl.activo
  ), base AS (
    SELECT a.*, s.codigo, s.naturaleza, s.categoria, s.prioridad, s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin,
           s.salida_modelo, cat.nombre AS categoria_nombre,
           coalesce((a.vigente_hasta IS NULL OR a.vigente_hasta > now())
             AND (a.publicada_en > now() - make_interval(days => c.dias)
                  OR s.plazo_hasta > now() OR s.fecha_evento_inicio > now() OR s.fecha_evento_fin > now()), false) AS actual
      FROM c
      JOIN vigilante.alerts a ON a.cliente_id = c.id
      JOIN vigilante.signals s ON s.id = a.signal_id
      LEFT JOIN vigilante.categorias cat ON cat.cliente_id = s.cliente_id AND cat.codigo = s.categoria
     WHERE a.visibilidad = 'publica' AND a.publicada_en IS NOT NULL AND a.cerrada_en IS NULL AND NOT a.es_escenario
       AND a.publicada_en > now() - make_interval(months => c.meses)
  ), lista AS (
    SELECT * FROM base WHERE actual OR p_anteriores ORDER BY publicada_en DESC LIMIT 500
  ), hoy AS (
    SELECT d.* FROM vigilante.daily_digests d, c
     WHERE d.cliente_id = c.id AND d.publicado_en IS NOT NULL
       AND d.fecha >= ((now() AT TIME ZONE c.zona_horaria)::date - 1)
     ORDER BY d.fecha DESC LIMIT 1
  )
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'nombre', c.nombre,
    'telegram_url', vigilante.param(c.id, 'telegram_canal_url') #>> '{}',
    'generado', now(),
    'dias_visibles', c.dias,
    'anteriores', p_anteriores,
    'n_anteriores', (SELECT count(*) FROM base WHERE NOT actual),
    'mensaje_sin_alertas', coalesce(vigilante.param(c.id, 'mensaje_sin_alertas') #>> '{}', 'No hay alertas confirmadas en este momento'),
    'resumen', (SELECT jsonb_build_object('fecha', h.fecha, 'texto', CASE WHEN h.sin_alertas THEN h.texto END,
                                          'alertas', coalesce((SELECT jsonb_agg(i.alert_id ORDER BY i.orden)
                                                                 FROM vigilante.daily_digest_items i WHERE i.digest_id = h.id), '[]'::jsonb))
                  FROM hoy h),
    'alertas', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', l.id,
               'codigo', l.codigo,
               'titulo', l.titulo,
               'texto', l.texto,
               'importancia', l.salida_modelo ->> 'importancia',
               'recomendacion', l.recomendacion,
               'enlace', l.enlace_fuente,
               'verificacion', l.estado_verificacion,
               'naturaleza', l.naturaleza,
               'categoria', l.categoria,
               'categoria_nombre', l.categoria_nombre,
               'prioridad', l.prioridad,
               'deps', coalesce(l.salida_modelo -> 'deps', '[]'::jsonb),
               'destinos', coalesce(l.salida_modelo -> 'destinos', '[]'::jsonb),
               'plazo_hasta', l.plazo_hasta,
               'fecha_evento', coalesce(l.fecha_evento_inicio, l.fecha_evento_fin),
               'publicada_en', l.publicada_en,
               'actualizada_en', l.updated_at,
               'actual', l.actual,
               'util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = l.id AND f.util),
               'no_util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = l.id AND NOT f.util))
             ORDER BY l.publicada_en DESC)
        FROM lista l), '[]'::jsonb))
  FROM c
$$;
REVOKE ALL ON FUNCTION vigilante.alertas_publicas(text, boolean) FROM public;
GRANT EXECUTE ON FUNCTION vigilante.alertas_publicas(text, boolean) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6. Panel: todo el periodo guardado, plazo de revisión y escenario (sustituye la del 15)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._vigilante_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT p_cliente AS id,
                    coalesce((vigilante.param(p_cliente, 'retencion_meses') #>> '{}')::int, 6) AS meses,
                    coalesce((vigilante.param(p_cliente, 'web_dias_visibles') #>> '{}')::int, 7) AS dias)
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
                  'items', coalesce((s.config ->> 'items')::int, 0), 'hist', coalesce(s.config -> 'hist', '[]'), 'info', s.notas)
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
                         'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
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
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM (SELECT s.* FROM vigilante.signals s, c WHERE s.cliente_id = c.id
                          AND s.created_at >= now() - make_interval(months => c.meses)
                        ORDER BY s.created_at DESC LIMIT 1000) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

-- Permisos: las tareas solo las lanza pg_cron (o el administrador desde el SQL Editor)
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'vigilante.vencer_plazos_revision()',
    'vigilante.enviar_resumenes_diarios()',
    'vigilante.enviar_recordatorios()',
    'vigilante.enviar_telegram_pendientes()',
    'vigilante.tareas_programadas()',
    'vigilante.texto_resumen(bigint)',
    'vigilante.texto_recordatorio(bigint)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon, authenticated', f);
  END LOOP;
END $$;

COMMIT;

-- 7. Tareas de pg_cron (fuera de la transacción; solo en Supabase) ---------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('vigilante-revision', 'vigilante-tareas', 'vigilante-retencion');
    PERFORM cron.schedule('vigilante-revision',  '* * * * *',   'SELECT vigilante.vencer_plazos_revision()');
    PERFORM cron.schedule('vigilante-tareas',    '*/5 * * * *', 'SELECT vigilante.tareas_programadas()');
    -- 07:00 UTC = 03:00 en Bolivia
    PERFORM cron.schedule('vigilante-retencion', '0 7 * * *',   'SELECT vigilante.purgar_retencion()');
    RAISE NOTICE 'Tareas programadas: vigilante-revision, vigilante-tareas, vigilante-retencion';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
