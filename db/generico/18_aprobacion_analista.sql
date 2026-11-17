-- =============================================================================
-- AVIA Vigilante · Aprobación del analista (alertas de riesgo)
-- Requiere 01 a 17. Se puede ejecutar más de una vez.
--
-- Decisión de Meysel (11-11-2026):
--   * NUNCA se publica nada que pida revisión sin que lo apruebe una persona.
--     Al vencer el plazo la señal NO sale: queda «Plazo vencido» y se avisa otra vez al equipo.
--   * El plazo para revisar pasa de 15 minutos a 1 hora (en horario de guardia 07:00–22:00;
--     lo que llega de noche vence a las 08:00).
--
-- Qué añade:
--   1. aprobar_senal(codigo, nota) y rechazar_senal(codigo, nota) para la web: un solo clic.
--      Aprobar pasa la señal por las etapas que falten y la publica (web pública + canal de
--      Telegram, con el 13). Un escenario se aprueba pero no se publica nunca.
--   2. Quién y cuándo decidió cada revisión: signals.revision_decidida_en / _por.
--   3. Avisos a los analistas en un grupo privado de Telegram (parámetro telegram_analistas_chat)
--      con botones «Aprobar y publicar» y «Rechazar»: uno al llegar la señal y otro si vence.
--      Cuando alguien decide (en la web o en Telegram), el mensaje se actualiza y pierde los botones.
--   4. decidir_senal_telegram(): la llama la función de Supabase telegram-revision
--      (supabase/functions/telegram-revision) cuando alguien pulsa un botón.
--
-- Guía: docs/aprobacion-analista.md
-- =============================================================================

BEGIN;

-- 0. Parámetros ---------------------------------------------------------------------
UPDATE vigilante.parametros
   SET valor = '60', descripcion = 'Minutos que tiene el analista para aprobar (1 hora, en horario de guardia)'
 WHERE cliente_id IS NULL AND clave = 'sla_revision_minutos';
-- Nunca se publica sin aprobación: se apaga en todos los clientes (vencer_plazos_revision ya no lo usa)
UPDATE vigilante.parametros SET valor = 'false',
       descripcion = 'Sin uso desde el 18: nunca se publica sin aprobación de una persona'
 WHERE clave = 'publicar_al_vencer';

INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'telegram_analistas_chat', '""', 'Grupo privado de Telegram de los analistas (p. ej. "-100123…"): recibe las señales por aprobar con botones'),
  (NULL, 'panel_url',               '""', 'Dirección del panel del equipo (enlace en los avisos a analistas)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Quién decidió cada revisión -----------------------------------------------------
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS revision_decidida_en  timestamptz;
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS revision_decidida_por uuid REFERENCES vigilante.users(id) ON DELETE SET NULL;

-- Estados en los que una señal todavía espera la decisión de una persona
CREATE OR REPLACE FUNCTION vigilante.espera_revision(s vigilante.signals) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT s.requiere_revision AND s.revision_decidida_en IS NULL
     AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion')
$$;

-- Si una persona mueve a mano (mover_senal, panel) una señal que esperaba revisión a
-- Confirmada, Publicada o Descartada, eso también cuenta como su decisión.
CREATE OR REPLACE FUNCTION vigilante.tg_revision_decidida() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NEW.requiere_revision AND NEW.revision_decidida_en IS NULL AND NEW.estado_manual
     AND NEW.estado IN ('confirmada', 'publicada', 'descartada') AND NEW.estado IS DISTINCT FROM OLD.estado THEN
    NEW.revision_decidida_en  := now();
    NEW.revision_decidida_por := coalesce(NEW.revision_decidida_por, vigilante.usuario_actual());
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS c_revision_decidida ON vigilante.signals;
CREATE TRIGGER c_revision_decidida BEFORE UPDATE OF estado ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_revision_decidida();

-- 2. Decidir (núcleo común a la web y a Telegram) -------------------------------------
CREATE OR REPLACE FUNCTION vigilante._decidir_senal(p_id bigint, p_usuario uuid, p_aprobar boolean,
                                                    p_nota text DEFAULT NULL, p_via text DEFAULT 'web')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; u vigilante.users; v_quien text; v_resultado text; v_nota text;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'La señal no existe'; END IF;
  SELECT * INTO u FROM vigilante.users WHERE id = p_usuario;
  IF u.id IS NULL OR NOT u.activo OR u.cliente_id <> s.cliente_id OR u.rol NOT IN ('analista', 'administrador') THEN
    RAISE EXCEPTION 'Solo un analista o un administrador puede aprobar o rechazar señales';
  END IF;

  -- ya decidida (por otra persona, en la web o en Telegram)
  IF s.estado IN ('descartada', 'cerrada')
     OR (s.estado IN ('confirmada', 'publicada') AND p_aprobar
         AND NOT EXISTS (SELECT 1 FROM vigilante.alerts a WHERE a.signal_id = s.id AND a.cerrada_en IS NULL
                           AND a.estado_verificacion = 'en_verificacion')
         AND (s.estado = 'publicada' OR s.es_escenario)) THEN
    RETURN jsonb_build_object('ok', false, 'codigo', s.codigo, 'estado', s.estado,
      'mensaje', 'Ya estaba decidida: ' || CASE s.estado WHEN 'publicada' THEN 'publicada' WHEN 'confirmada' THEN 'confirmada'
                                                         ELSE 'descartada' END
                 || coalesce(' por ' || (SELECT nombre FROM vigilante.users WHERE id = s.revision_decidida_por), ''));
  END IF;

  -- quién queda en el historial: la cuenta de la persona (así sale con su nombre en la Bitácora)
  v_quien := coalesce(u.auth_user_id::text, 'telegram:' || u.telegram_chat_id::text, u.id::text);
  PERFORM set_config('vigilante.actor', v_quien, true);
  v_nota := nullif(trim(concat_ws(' · ', CASE WHEN p_via = 'telegram' THEN 'Desde Telegram' END, nullif(trim(p_nota), ''))), '');

  UPDATE vigilante.signals SET revision_decidida_por = u.id WHERE id = s.id;

  IF p_aprobar THEN
    -- las etapas no se saltan: detectada → en_analisis → confirmada → publicada
    IF s.estado = 'detectada' THEN
      UPDATE vigilante.signals SET estado = 'en_analisis', estado_manual = true WHERE id = s.id;
      s.estado := 'en_analisis';
    END IF;
    IF s.estado IN ('en_analisis', 'en_verificacion') THEN
      UPDATE vigilante.signals SET estado = 'confirmada', estado_manual = true WHERE id = s.id;
      s.estado := 'confirmada';
    END IF;
    IF s.estado = 'confirmada' AND NOT s.es_escenario THEN
      UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE id = s.id;
      v_resultado := 'publicada';
    ELSIF s.estado = 'publicada' THEN
      -- estaba publicada «En verificación» (la publicó alguien a mano): ahora queda confirmada
      UPDATE vigilante.alerts SET estado_verificacion = 'confirmada' WHERE signal_id = s.id AND cerrada_en IS NULL;
      UPDATE vigilante.signals SET revision_decidida_en = coalesce(revision_decidida_en, now()) WHERE id = s.id;
      v_resultado := 'confirmada_publicada';
    ELSE
      v_resultado := 'confirmada';   -- escenario: aprobado, pero no sale en la web ni en Telegram
    END IF;
    UPDATE vigilante.alerts SET aprobada_por = u.id, aprobada_en = now() WHERE signal_id = s.id AND cerrada_en IS NULL;
  ELSE
    UPDATE vigilante.signals SET estado = 'descartada', estado_manual = true WHERE id = s.id;
    v_resultado := 'descartada';
  END IF;

  UPDATE vigilante.signal_history SET nota = v_nota
   WHERE id = (SELECT max(id) FROM vigilante.signal_history
                WHERE signal_id = s.id AND entidad = 'signal' AND estado_nuevo IS NOT NULL) AND v_nota IS NOT NULL;

  RETURN jsonb_build_object('ok', true, 'codigo', s.codigo, 'estado', v_resultado, 'quien', u.nombre,
    'mensaje', CASE v_resultado
                 WHEN 'publicada' THEN 'Aprobada y publicada por ' || u.nombre
                 WHEN 'confirmada_publicada' THEN 'Confirmada por ' || u.nombre || ' (ya estaba publicada)'
                 WHEN 'confirmada' THEN 'Aprobada por ' || u.nombre || ' (es un escenario: no se publica)'
                 ELSE 'Rechazada por ' || u.nombre END);
END $$;
REVOKE ALL ON FUNCTION vigilante._decidir_senal(bigint, uuid, boolean, text, text) FROM public, anon, authenticated;

-- Web: la llama el panel (analista o administrador con sesión)
CREATE OR REPLACE FUNCTION vigilante.aprobar_senal(p_codigo text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede aprobar señales'; END IF;
  SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % aún no está en la base de datos', p_codigo; END IF;
  RETURN vigilante._decidir_senal(v_id, vigilante.usuario_actual(), true, p_nota, 'web');
END $$;

CREATE OR REPLACE FUNCTION vigilante.rechazar_senal(p_codigo text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede rechazar señales'; END IF;
  SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % aún no está en la base de datos', p_codigo; END IF;
  RETURN vigilante._decidir_senal(v_id, vigilante.usuario_actual(), false, p_nota, 'web');
END $$;
REVOKE ALL ON FUNCTION vigilante.aprobar_senal(text, text), vigilante.rechazar_senal(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.aprobar_senal(text, text), vigilante.rechazar_senal(text, text) TO authenticated;

-- 3. Avisos a los analistas por Telegram ---------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.avisos_revision (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id   bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL,
  tipo        text NOT NULL CHECK (tipo IN ('pendiente', 'vencida')),
  chat_id     text NOT NULL,
  mensaje_id  bigint,
  estado      text NOT NULL DEFAULT 'enviado' CHECK (estado IN ('enviado', 'fallido', 'cerrado')),
  error       text,
  enviado_en  timestamptz NOT NULL DEFAULT now(),
  cerrado_en  timestamptz,
  UNIQUE (signal_id, tipo)
);
CREATE INDEX IF NOT EXISTS avisos_revision_abiertos ON vigilante.avisos_revision (signal_id) WHERE estado = 'enviado';
DROP TRIGGER IF EXISTS a_heredar_cliente ON vigilante.avisos_revision;
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.avisos_revision
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');
ALTER TABLE vigilante.avisos_revision ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_staff ON vigilante.avisos_revision;
CREATE POLICY lectura_staff ON vigilante.avisos_revision FOR SELECT TO authenticated
  USING (cliente_id = vigilante.cliente_actual() AND vigilante.es_staff());
GRANT SELECT ON vigilante.avisos_revision TO authenticated;

-- Texto del aviso (HTML de Telegram)
CREATE OR REPLACE FUNCTION vigilante.texto_aviso_revision(p_signal bigint, p_tipo text)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT concat_ws(E'\n',
    CASE p_tipo WHEN 'vencida' THEN '⏰ <b>Plazo vencido sin aprobación</b> · no se ha publicado'
                ELSE '🔎 <b>Señal por aprobar</b>' END
      || coalesce(' · ' || vigilante.html_tg(cat.nombre), '') || ' · prioridad ' || s.prioridad,
    '',
    '<b>' || vigilante.html_tg(s.titulo) || '</b>',
    nullif(vigilante.html_tg(left(coalesce(s.resumen, ''), 400)), ''),
    CASE WHEN s.es_escenario THEN '<i>Es un escenario (predicción): si se aprueba, no se publica.</i>' END,
    'Motivo: ' || vigilante.html_tg(coalesce(s.motivo_revision, 'Requiere revisión de una persona')),
    CASE WHEN coalesce(s.enlace_oficial, '') <> '' THEN '<a href="' || vigilante.html_tg(s.enlace_oficial) || '">Fuente</a>' END,
    CASE WHEN p_tipo = 'pendiente' THEN
      '⏱ Plazo: hasta las ' || to_char(vigilante.calcular_vencimiento(s.cliente_id, s.created_at)
                                        AT TIME ZONE coalesce(cl.zona_horaria, 'UTC'), 'HH24:MI') END,
    CASE WHEN coalesce(vigilante.param(s.cliente_id, 'panel_url') #>> '{}', '') <> ''
         THEN '<a href="' || vigilante.html_tg(vigilante.param(s.cliente_id, 'panel_url') #>> '{}') || '">Abrir el panel</a> · ' || s.codigo
         ELSE s.codigo END)
  FROM vigilante.signals s
  JOIN vigilante.clientes cl ON cl.id = s.cliente_id
  LEFT JOIN vigilante.categorias cat ON cat.cliente_id = s.cliente_id AND cat.codigo = s.categoria
 WHERE s.id = p_signal
$$;

-- Envía avisos nuevos (pendiente / vencida) y cierra los de señales ya decididas.
CREATE OR REPLACE FUNCTION vigilante.avisar_analistas()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, extensions, pg_temp AS $$
DECLARE
  v_token text; x record; v_chat text; v_resp record; v_texto text; v_botones jsonb;
  n_env int := 0; n_mal int := 0; n_cer int := 0;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token' LIMIT 1;
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN v_token := NULL;
  END;
  IF coalesce(v_token, '') = '' THEN RETURN jsonb_build_object('error', 'Falta el secreto telegram_bot_token en el Vault'); END IF;

  -- a) avisos nuevos: al llegar (pendiente) y al vencer el plazo (vencida). Solo de las últimas 24 h.
  FOR x IN
    SELECT s.id, s.cliente_id, s.es_escenario, t.tipo
      FROM vigilante.signals s
      CROSS JOIN LATERAL (VALUES ('pendiente'), ('vencida')) AS t(tipo)
     WHERE vigilante.espera_revision(s)
       AND s.created_at > now() - interval '24 hours'
       AND (t.tipo = 'pendiente' OR s.revision_vencida_en IS NOT NULL)
       AND NOT EXISTS (SELECT 1 FROM vigilante.avisos_revision a WHERE a.signal_id = s.id AND a.tipo = t.tipo)
     ORDER BY s.created_at, t.tipo DESC
     LIMIT 20
  LOOP
    v_chat := vigilante.param(x.cliente_id, 'telegram_analistas_chat') #>> '{}';
    CONTINUE WHEN coalesce(v_chat, '') = '';
    -- si ya venció antes del primer aviso, basta con el de «vencida»
    CONTINUE WHEN x.tipo = 'pendiente' AND EXISTS (SELECT 1 FROM vigilante.signals WHERE id = x.id AND revision_vencida_en IS NOT NULL);
    v_texto := vigilante.texto_aviso_revision(x.id, x.tipo);
    v_botones := jsonb_build_object('inline_keyboard', jsonb_build_array(jsonb_build_array(
      jsonb_build_object('text', CASE WHEN x.es_escenario THEN '✅ Aprobar (no se publica)' ELSE '✅ Aprobar y publicar' END,
                         'callback_data', 'ap:' || x.id),
      jsonb_build_object('text', '✖️ Rechazar', 'callback_data', 're:' || x.id))));
    BEGIN
      SELECT * INTO v_resp FROM extensions.http_post(
        'https://api.telegram.org/bot' || v_token || '/sendMessage',
        jsonb_build_object('chat_id', v_chat, 'text', v_texto, 'parse_mode', 'HTML',
                           'disable_web_page_preview', true, 'reply_markup', v_botones)::text,
        'application/json');
      INSERT INTO vigilante.avisos_revision (signal_id, tipo, chat_id, mensaje_id, estado, error)
      VALUES (x.id, x.tipo, v_chat,
              CASE WHEN v_resp.status = 200 THEN (v_resp.content::jsonb #>> '{result,message_id}')::bigint END,
              CASE WHEN v_resp.status = 200 THEN 'enviado' ELSE 'fallido' END,
              CASE WHEN v_resp.status <> 200 THEN left(coalesce(v_resp.content::jsonb ->> 'description', 'HTTP ' || v_resp.status), 300) END)
      ON CONFLICT (signal_id, tipo) DO NOTHING;
      IF v_resp.status = 200 THEN n_env := n_env + 1; ELSE n_mal := n_mal + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO vigilante.avisos_revision (signal_id, tipo, chat_id, estado, error)
      VALUES (x.id, x.tipo, v_chat, 'fallido', left(replace(SQLERRM, v_token, '***'), 300))
      ON CONFLICT (signal_id, tipo) DO NOTHING;
      n_mal := n_mal + 1;
    END;
  END LOOP;

  -- b) señales ya decididas (o que dejaron de esperar): el mensaje dice cómo acabó y pierde los botones
  FOR x IN
    SELECT a.id, a.chat_id, a.mensaje_id, a.signal_id, s.estado, s.titulo,
           (SELECT nombre FROM vigilante.users WHERE id = s.revision_decidida_por) AS quien
      FROM vigilante.avisos_revision a JOIN vigilante.signals s ON s.id = a.signal_id
     WHERE a.estado = 'enviado' AND NOT vigilante.espera_revision(s)
     LIMIT 20
  LOOP
    BEGIN
      IF x.mensaje_id IS NOT NULL THEN
        SELECT * INTO v_resp FROM extensions.http_post(
          'https://api.telegram.org/bot' || v_token || '/editMessageText',
          jsonb_build_object('chat_id', x.chat_id, 'message_id', x.mensaje_id, 'parse_mode', 'HTML',
            'disable_web_page_preview', true,
            'text', '<b>' || vigilante.html_tg(x.titulo) || E'</b>\n'
                    || CASE x.estado WHEN 'publicada' THEN '✅ Aprobada y publicada'
                                     WHEN 'confirmada' THEN '✅ Aprobada'
                                     WHEN 'descartada' THEN '✖️ Rechazada'
                                     ELSE 'Ya no espera revisión' END
                    || coalesce(' por ' || vigilante.html_tg(x.quien), ''))::text,
          'application/json');
      END IF;
      UPDATE vigilante.avisos_revision SET estado = 'cerrado', cerrado_en = now() WHERE id = x.id;
      n_cer := n_cer + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE vigilante.avisos_revision SET estado = 'cerrado', cerrado_en = now(),
             error = left(replace(SQLERRM, v_token, '***'), 300) WHERE id = x.id;
    END;
  END LOOP;
  RETURN jsonb_build_object('avisos', n_env, 'fallidos', n_mal, 'cerrados', n_cer);
END $$;
REVOKE ALL ON FUNCTION vigilante.avisar_analistas() FROM public, anon, authenticated;

-- 4. Telegram: alguien pulsó un botón (lo llama la función de Supabase telegram-revision) ----
-- Comprueba que el botón viene del grupo de analistas configurado y que quien lo pulsa
-- es un analista o administrador activo de ese cliente (users.telegram_chat_id = su id de Telegram).
CREATE OR REPLACE FUNCTION vigilante.decidir_senal_telegram(p_signal_id bigint, p_telegram_user bigint,
                                                            p_chat text, p_aprobar boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid; v_usuario uuid; r jsonb;
BEGIN
  SELECT cliente_id INTO v_cliente FROM vigilante.signals WHERE id = p_signal_id;
  IF v_cliente IS NULL THEN RETURN jsonb_build_object('ok', false, 'mensaje', 'La señal ya no existe'); END IF;
  IF coalesce(vigilante.param(v_cliente, 'telegram_analistas_chat') #>> '{}', '') <> p_chat THEN
    RETURN jsonb_build_object('ok', false, 'mensaje', 'Este chat no es el grupo de analistas');
  END IF;
  SELECT id INTO v_usuario FROM vigilante.users
   WHERE cliente_id = v_cliente AND telegram_chat_id = p_telegram_user AND activo AND rol IN ('analista', 'administrador');
  IF v_usuario IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'mensaje',
      'Tu cuenta de Telegram no está registrada como analista. Pide al administrador que añada tu id ' || p_telegram_user || ' en el Equipo.');
  END IF;
  r := vigilante._decidir_senal(p_signal_id, v_usuario, p_aprobar, NULL, 'telegram');
  -- el mensaje pulsado lo actualiza la propia función; el resto de avisos los cierra avisar_analistas()
  RETURN r;
END $$;
REVOKE ALL ON FUNCTION vigilante.decidir_senal_telegram(bigint, bigint, text, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.decidir_senal_telegram(bigint, bigint, text, boolean) TO service_role;

-- 5. Plazo de revisión: vence pero NUNCA publica; luego avisa a los analistas ----------
CREATE OR REPLACE FUNCTION vigilante.vencer_plazos_revision()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE n_venc int; v_avisos jsonb;
BEGIN
  WITH v AS (
    UPDATE vigilante.signals x SET revision_vencida_en = now()
     WHERE x.id IN (SELECT y.id FROM vigilante.signals y
                     WHERE vigilante.espera_revision(y) AND y.revision_vencida_en IS NULL
                       AND vigilante.calcular_vencimiento(y.cliente_id, y.created_at) <= now()
                     ORDER BY y.created_at LIMIT 200 FOR UPDATE SKIP LOCKED)
    RETURNING 1)
  SELECT count(*) INTO n_venc FROM v;

  -- los avisos no deben impedir que se marque el vencimiento
  BEGIN
    v_avisos := vigilante.avisar_analistas();
  EXCEPTION WHEN OTHERS THEN
    v_avisos := jsonb_build_object('error', left(SQLERRM, 300));
  END;
  RETURN jsonb_build_object('vencidas', n_venc, 'publicadas_en_verificacion', 0, 'telegram', v_avisos);
END $$;
REVOKE ALL ON FUNCTION vigilante.vencer_plazos_revision() FROM public, anon, authenticated;

-- 6. Panel: cola de revisión (para la bandeja «Por revisar») --------------------------
CREATE OR REPLACE FUNCTION vigilante.cola_revision()
RETURNS TABLE (codigo text, titulo text, categoria text, prioridad vigilante.prioridad, motivo text,
               vence_en timestamptz, vencida boolean, aviso_telegram text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.codigo, s.titulo, s.categoria, s.prioridad, coalesce(s.motivo_revision, 'Requiere revisión de una persona'),
         vigilante.calcular_vencimiento(s.cliente_id, s.created_at), s.revision_vencida_en IS NOT NULL,
         (SELECT a.estado || coalesce(': ' || a.error, '') FROM vigilante.avisos_revision a
           WHERE a.signal_id = s.id ORDER BY a.id DESC LIMIT 1)
    FROM vigilante.signals s
   WHERE s.cliente_id = vigilante.cliente_actual() AND vigilante.es_staff() AND vigilante.espera_revision(s)
   ORDER BY 6
$$;
REVOKE ALL ON FUNCTION vigilante.cola_revision() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.cola_revision() TO authenticated;

COMMIT;
