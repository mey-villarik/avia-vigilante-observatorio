-- =============================================================================
-- AVIA Vigilante · Publicar señales: web pública y Telegram
-- Requiere 01 a 05. Se puede ejecutar más de una vez.
--
-- Cuando una PERSONA (analista o administrador) pasa una señal a «Publicada» desde la web:
--   1. se crea (o se reabre) su alerta pública en vigilante.alerts;
--   2. sale en la web pública: vigilante.alertas_publicas(cliente), sin iniciar sesión;
--   3. queda en cola un aviso de Telegram para el canal del cliente, que Supabase envía
--      cada minuto con vigilante.enviar_telegram_pendientes().
-- Si la señal sale de «Publicada» (vuelve a verificación, se descarta o se cierra),
-- la alerta se retira de la web. Lo que AVIA marque como publicada por su cuenta NO se publica:
-- siempre tiene que decidirlo una persona.
--
-- Telegram (lo configura el administrador, ver docs/publicar-senales.md):
--   * el token del bot va en el Vault de Supabase con el nombre telegram_bot_token (nunca en el repo);
--   * el canal va en vigilante.parametros: telegram_canal  (p. ej. "@orbita_alertas" o "-100123…");
--   * opcional: telegram_canal_url (enlace para suscribirse) y web_publica_url (enlace en cada aviso).
-- =============================================================================

BEGIN;

-- 1. Al publicar / despublicar una señal ----------------------------------------
CREATE OR REPLACE FUNCTION vigilante.tg_publicar_senal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_alerta  bigint;
  v_enlace  text;
  v_reco    text;
  v_quien   uuid;
BEGIN
  -- Publicar: solo cuando la mueve una persona (mover_senal pone estado_manual = true)
  IF NEW.estado = 'publicada' AND OLD.estado IS DISTINCT FROM 'publicada' AND NEW.estado_manual THEN
    v_enlace := coalesce(nullif(NEW.enlace_oficial, ''), nullif(NEW.salida_modelo #>> '{enlaces,0,url}', ''));
    v_reco   := coalesce(nullif(NEW.recomendacion, ''), nullif(NEW.salida_modelo #>> '{soluciones,0,t}', ''));
    v_quien  := vigilante.usuario_actual();

    INSERT INTO vigilante.alerts AS a (signal_id, cliente_id, titulo, texto, recomendacion, enlace_fuente,
                                       estado_verificacion, visibilidad, es_escenario,
                                       aprobada_por, aprobada_en, publicada_en, vigente_hasta)
    VALUES (NEW.id, NEW.cliente_id, NEW.titulo, NEW.resumen, v_reco, v_enlace,
            -- viene de «En verificación» y hay enlace → se publica como «En verificación»
            CASE WHEN OLD.estado = 'en_verificacion' AND v_enlace IS NOT NULL THEN 'en_verificacion' ELSE 'confirmada' END::vigilante.estado_verificacion,
            'publica', NEW.es_escenario,
            v_quien, CASE WHEN v_quien IS NOT NULL THEN now() END, now(),
            coalesce(NEW.fecha_evento_fin, NEW.plazo_hasta))
    ON CONFLICT (signal_id) DO UPDATE SET
      titulo = EXCLUDED.titulo, texto = EXCLUDED.texto, recomendacion = EXCLUDED.recomendacion,
      enlace_fuente = EXCLUDED.enlace_fuente, estado_verificacion = EXCLUDED.estado_verificacion,
      visibilidad = 'publica', es_escenario = EXCLUDED.es_escenario,
      aprobada_por = EXCLUDED.aprobada_por, aprobada_en = EXCLUDED.aprobada_en,
      publicada_en = now(), cerrada_en = NULL, vigente_hasta = EXCLUDED.vigente_hasta
    RETURNING a.id INTO v_alerta;

    -- Aviso de Telegram al canal del cliente (si está configurado). Una vez por versión de la alerta.
    IF coalesce(vigilante.param(NEW.cliente_id, 'telegram_canal') #>> '{}', '') <> '' AND NOT NEW.es_escenario THEN
      INSERT INTO vigilante.deliveries (cliente_id, canal, alert_id, plantilla)
      VALUES (NEW.cliente_id, 'telegram', v_alerta, 'canal')
      ON CONFLICT DO NOTHING;
    END IF;

  -- Despublicar: la alerta se retira de la web
  ELSIF OLD.estado = 'publicada' AND NEW.estado <> 'publicada' THEN
    UPDATE vigilante.alerts SET cerrada_en = now() WHERE signal_id = NEW.id AND cerrada_en IS NULL;

  -- Sigue publicada y AVIA actualizó el texto: la alerta pública también
  ELSIF NEW.estado = 'publicada' AND (NEW.titulo, NEW.resumen) IS DISTINCT FROM (OLD.titulo, OLD.resumen) THEN
    UPDATE vigilante.alerts SET titulo = NEW.titulo, texto = NEW.resumen
     WHERE signal_id = NEW.id AND cerrada_en IS NULL;
  END IF;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS z_publicar_senal ON vigilante.signals;
CREATE TRIGGER z_publicar_senal AFTER UPDATE OF estado, titulo, resumen ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_publicar_senal();

-- 2. Web pública (sin iniciar sesión) ------------------------------------------
-- Devuelve el nombre del observatorio, los enlaces y las alertas vigentes con sus votos.
CREATE OR REPLACE FUNCTION vigilante.alertas_publicas(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'nombre', c.nombre,
    'telegram_url', vigilante.param(c.id, 'telegram_canal_url') #>> '{}',
    'generado', now(),
    'alertas', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id,
               'codigo', s.codigo,
               'titulo', a.titulo,
               'texto', a.texto,
               'importancia', s.salida_modelo ->> 'importancia',
               'recomendacion', a.recomendacion,
               'enlace', a.enlace_fuente,
               'verificacion', a.estado_verificacion,
               'naturaleza', s.naturaleza,
               'categoria', s.categoria,
               'categoria_nombre', cat.nombre,
               'prioridad', s.prioridad,
               'deps', coalesce(s.salida_modelo -> 'deps', '[]'::jsonb),
               'destinos', coalesce(s.salida_modelo -> 'destinos', '[]'::jsonb),
               'plazo_hasta', s.plazo_hasta,
               'publicada_en', a.publicada_en,
               'actualizada_en', a.updated_at,
               'util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = a.id AND f.util),
               'no_util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = a.id AND NOT f.util))
             ORDER BY a.publicada_en DESC)
        FROM vigilante.alerts a
        JOIN vigilante.signals s ON s.id = a.signal_id
        LEFT JOIN vigilante.categorias cat ON cat.cliente_id = s.cliente_id AND cat.codigo = s.categoria
       WHERE a.cliente_id = c.id AND a.visibilidad = 'publica' AND a.publicada_en IS NOT NULL
         AND a.cerrada_en IS NULL AND NOT a.es_escenario
         AND (a.vigente_hasta IS NULL OR a.vigente_hasta > now())
         AND a.publicada_en > now() - interval '45 days'), '[]'::jsonb))
  FROM vigilante.clientes c
  WHERE c.slug = p_cliente AND c.activo
$$;
REVOKE ALL ON FUNCTION vigilante.alertas_publicas(text) FROM public;
GRANT EXECUTE ON FUNCTION vigilante.alertas_publicas(text) TO anon, authenticated;

-- «¿Te fue útil?» desde la web pública. Un voto por navegador y alerta (se puede cambiar).
CREATE OR REPLACE FUNCTION vigilante.votar_alerta(p_alerta bigint, p_util boolean, p_visitante text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_hash text;
BEGIN
  IF coalesce(length(p_visitante), 0) < 8 THEN RAISE EXCEPTION 'Falta el identificador del navegador'; END IF;
  IF NOT EXISTS (SELECT 1 FROM vigilante.alerts WHERE id = p_alerta AND visibilidad = 'publica'
                    AND publicada_en IS NOT NULL AND cerrada_en IS NULL) THEN
    RAISE EXCEPTION 'Esa alerta ya no está publicada';
  END IF;
  v_hash := md5('avia:' || p_visitante);
  UPDATE vigilante.feedback SET util = p_util, created_at = now()
   WHERE alert_id = p_alerta AND user_id IS NULL AND visitante_hash = v_hash;
  IF NOT FOUND THEN
    INSERT INTO vigilante.feedback (alert_id, canal, util, visitante_hash) VALUES (p_alerta, 'web', p_util, v_hash);
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.votar_alerta(bigint, boolean, text) FROM public;
GRANT EXECUTE ON FUNCTION vigilante.votar_alerta(bigint, boolean, text) TO anon, authenticated;

-- 3. Envío a Telegram ----------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.html_tg(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- Texto del aviso (también sirve para ver cómo quedará: SELECT vigilante.texto_telegram(id))
CREATE OR REPLACE FUNCTION vigilante.texto_telegram(p_alerta bigint)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT concat_ws(E'\n',
    CASE s.naturaleza WHEN 'riesgo' THEN '⚠️ Riesgo' WHEN 'oportunidad' THEN '✨ Oportunidad' ELSE '🔷 Riesgo y oportunidad' END
      || CASE WHEN a.estado_verificacion = 'en_verificacion' THEN ' · en verificación' ELSE '' END
      || coalesce(' · ' || vigilante.html_tg(cat.nombre), ''),
    '<b>' || vigilante.html_tg(a.titulo) || '</b>',
    '',
    vigilante.html_tg(left(a.texto, 700)) || CASE WHEN length(a.texto) > 700 THEN '…' ELSE '' END,
    CASE WHEN jsonb_array_length(coalesce(s.salida_modelo -> 'deps', '[]')) > 0
         THEN E'\n📍 ' || vigilante.html_tg((SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(s.salida_modelo -> 'deps') x)) END,
    CASE WHEN a.recomendacion IS NOT NULL THEN '➜ ' || vigilante.html_tg(a.recomendacion) END,
    CASE WHEN a.enlace_fuente IS NOT NULL THEN '<a href="' || vigilante.html_tg(a.enlace_fuente) || '">Fuente</a>' END,
    CASE WHEN vigilante.param(a.cliente_id, 'web_publica_url') #>> '{}' IS NOT NULL
         THEN '<a href="' || vigilante.html_tg(vigilante.param(a.cliente_id, 'web_publica_url') #>> '{}') || '">Ver todas las alertas</a>' END)
  FROM vigilante.alerts a
  JOIN vigilante.signals s ON s.id = a.signal_id
  LEFT JOIN vigilante.categorias cat ON cat.cliente_id = s.cliente_id AND cat.codigo = s.categoria
  WHERE a.id = p_alerta
$$;

-- Envía los avisos pendientes. La ejecuta pg_cron cada minuto.
CREATE OR REPLACE FUNCTION vigilante.enviar_telegram_pendientes()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, extensions, pg_temp AS $$
DECLARE
  v_token text; d record; v_canal text; v_resp record; n_ok int := 0; n_mal int := 0;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token' LIMIT 1;
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN v_token := NULL;
  END;
  IF coalesce(v_token, '') = '' THEN RETURN jsonb_build_object('error', 'Falta el secreto telegram_bot_token en el Vault'); END IF;

  FOR d IN SELECT dl.id, dl.alert_id, dl.cliente_id FROM vigilante.deliveries dl
            WHERE dl.canal = 'telegram' AND dl.estado = 'pendiente' AND dl.alert_id IS NOT NULL AND dl.user_id IS NULL
            ORDER BY dl.created_at LIMIT 20 FOR UPDATE SKIP LOCKED LOOP
    v_canal := vigilante.param(d.cliente_id, 'telegram_canal') #>> '{}';
    -- la alerta se retiró antes de salir → no se envía
    IF coalesce(v_canal, '') = '' OR EXISTS (SELECT 1 FROM vigilante.alerts WHERE id = d.alert_id AND cerrada_en IS NOT NULL) THEN
      UPDATE vigilante.deliveries SET estado = 'omitido', error = 'Retirada o sin canal' WHERE id = d.id;
      CONTINUE;
    END IF;
    BEGIN
      SELECT * INTO v_resp FROM extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        jsonb_build_object('chat_id', v_canal, 'text', vigilante.texto_telegram(d.alert_id),
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
REVOKE ALL ON FUNCTION vigilante.enviar_telegram_pendientes() FROM public, anon, authenticated;

-- Para el panel: cómo salió el aviso de Telegram de cada señal publicada
CREATE OR REPLACE FUNCTION vigilante.publicaciones()
RETURNS TABLE (codigo text, publicada_en timestamptz, retirada_en timestamptz, telegram text, telegram_error text,
               util bigint, no_util bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.codigo, a.publicada_en, a.cerrada_en,
         (SELECT d.estado::text FROM vigilante.deliveries d WHERE d.alert_id = a.id AND d.canal = 'telegram' ORDER BY d.id DESC LIMIT 1),
         (SELECT d.error FROM vigilante.deliveries d WHERE d.alert_id = a.id AND d.canal = 'telegram' ORDER BY d.id DESC LIMIT 1),
         (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = a.id AND f.util),
         (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = a.id AND NOT f.util)
    FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id
   WHERE a.cliente_id = vigilante.cliente_actual() AND vigilante.usuario_actual() IS NOT NULL
$$;
REVOKE ALL ON FUNCTION vigilante.publicaciones() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.publicaciones() TO authenticated;

COMMIT;

-- 4. Tarea de envío cada minuto (fuera de la transacción; solo en Supabase) -------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'vigilante-telegram';
    PERFORM cron.schedule('vigilante-telegram', '* * * * *', 'SELECT vigilante.enviar_telegram_pendientes()');
  END IF;
END $$;
