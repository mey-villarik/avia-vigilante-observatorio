-- =============================================================================
-- 34. Eventos dinámicos: cada evento nuevo salta con alarma, y a las 24 h deja el panel
-- =============================================================================
-- Qué cambia respecto al 28 (Meysel, 2026-11-20):
--
--   «Los eventos tienen que ser dinámicos, como los cambios: que se queden en Eventos pero que lancen
--    alarmas; cuando se detecte un evento, que lo avise.»
--   «Cuando pase un día del evento, se guarda pero se deja de mostrar en la ventana de eventos.»
--
--   1. AVISA TODO EVENTO NUEVO, NO SOLO LOS DE PRIORIDAD ALTA. Antes solo salían como alerta los de
--      prioridad alta, y además esperaban 20 min a que AVIA los interpretara. Ahora:
--        · eventos_alerta_desde = "baja" → todos los eventos salen con alarma (se puede subir a media o alta)
--        · eventos_espera_hermes_min = 0 → la alarma sale en cuanto la base lo detecta; la
--          interpretación de AVIA aparece en la misma ventana cuando llega
--   2. DETECCIÓN CADA MINUTO. La tarea de pg_cron «vigilante-eventos» pasa de cada 5 minutos a cada
--      minuto (el analizador sigue componiendo al terminar cada ronda). El panel pregunta cada 30 s.
--   3. 24 HORAS EN EL PANEL. Un evento se ve en la ventana de Eventos durante «eventos_horas_panel»
--      (24) desde que se detectó, o desde que entraron señales nuevas (eso sube su versión y vuelve a
--      avisar). Pasado ese tiempo NO se borra ni se cierra: sigue en la base, Hermes lo sigue viendo
--      por el MCP (eventos_abiertos) y cuenta para la historia. Solo deja de mostrarse en el panel.
--   4. «Marcar todo como visto»: marcar_evento_visto(NULL) marca todos los que se ven en el panel.
--   5. eventos_emergentes() devuelve además «nuevo» (esta persona nunca lo vio, en ninguna versión)
--      y «oculta_en» (cuándo deja de mostrarse).
--
-- Nada de esto publica: los eventos siguen siendo internos (panel del equipo).
--
-- Necesita el 28 (y el 31 si se quiere que los cambios re-encolen eventos; no es obligatorio).
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run. Se puede ejecutar varias veces.
-- Volver a lo de antes: UPDATE vigilante.parametros SET valor = '"alta"' WHERE cliente_id IS NULL AND clave = 'eventos_alerta_desde';
--                       UPDATE vigilante.parametros SET valor = '20' WHERE cliente_id IS NULL AND clave = 'eventos_espera_hermes_min';
-- Prueba: 99_prueba_eventos_dinamicos.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 0. Parámetros ------------------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'eventos_alerta_desde', '"baja"', 'Prioridad mínima de un evento para que salga la ventana con alarma: baja (todos), media o alta'),
  (NULL, 'eventos_horas_panel', '24', 'Horas que un evento se ve en la ventana de Eventos desde que se detectó (o desde que entraron señales nuevas). Después sigue guardado en la base')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- la alarma ya no espera a AVIA (solo si nadie lo había cambiado a mano: el 28 lo dejó en 20)
UPDATE vigilante.parametros
   SET valor = '0', descripcion = 'Minutos que la alarma de un evento espera la interpretación de Hermes (0 = sale al momento; la interpretación se añade después)'
 WHERE cliente_id IS NULL AND clave = 'eventos_espera_hermes_min' AND valor = '20'::jsonb;

-- 1. Cuándo cambió la versión (para contar las 24 h desde la última vez que avisó) -------------
ALTER TABLE vigilante.eventos_compuestos ADD COLUMN IF NOT EXISTS version_en timestamptz;
UPDATE vigilante.eventos_compuestos SET version_en = created_at WHERE version_en IS NULL;
ALTER TABLE vigilante.eventos_compuestos ALTER COLUMN version_en SET DEFAULT now();
ALTER TABLE vigilante.eventos_compuestos ALTER COLUMN version_en SET NOT NULL;
COMMENT ON COLUMN vigilante.eventos_compuestos.version_en IS
  'Cuándo se detectó o cuándo entraron señales nuevas por última vez (34): el panel lo muestra eventos_horas_panel desde aquí';

CREATE OR REPLACE FUNCTION vigilante.tg_evento_version_en() RETURNS trigger
LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NEW.version > OLD.version THEN NEW.version_en := now(); END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS c_version_en ON vigilante.eventos_compuestos;
CREATE TRIGGER c_version_en BEFORE UPDATE OF version ON vigilante.eventos_compuestos
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_evento_version_en();

-- nivel de prioridad (también lo define el 31; aquí por si no se ejecutó)
CREATE OR REPLACE FUNCTION vigilante._nivel(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'alta' THEN 3 WHEN 'media' THEN 2 WHEN 'baja' THEN 1 ELSE 0 END
$$;

-- 2. Para el panel ---------------------------------------------------------------------------
--   Solo los abiertos detectados (o con señales nuevas) en las últimas eventos_horas_panel horas.
--   alerta    = prioridad ≥ eventos_alerta_desde y (interpretado, o lleva eventos_espera_hermes_min sin interpretar)
--   visto     = esta persona ya pulsó «Entendido» (o lo abrió en la lista) en esta versión
--   nuevo     = esta persona no lo ha visto en ninguna versión (si no, es una actualización)
--   oculta_en = cuándo deja de mostrarse
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
    SELECT coalesce(jsonb_agg(vigilante._evento_json(e.id) || jsonb_build_object(
             'alerta', vigilante._nivel(e.prioridad::text) >= v_desde
                       AND (e.estado = 'interpretado' OR e.version_en <= now() - make_interval(mins => v_espera)),
             'esperando_hermes', e.estado <> 'interpretado',
             'visto', EXISTS (SELECT 1 FROM vigilante.eventos_vistos v
                               WHERE v.evento_id = e.id AND v.user_id = v_user AND v.version >= e.version),
             'nuevo', NOT EXISTS (SELECT 1 FROM vigilante.eventos_vistos v WHERE v.evento_id = e.id AND v.user_id = v_user),
             'version_en', e.version_en,
             'oculta_en', e.version_en + make_interval(hours => v_horas))
             ORDER BY e.version_en DESC, e.puntaje DESC), '[]')
      FROM vigilante.eventos_compuestos e
     WHERE e.cliente_id = v_cliente AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado')
       AND e.version_en > now() - make_interval(hours => v_horas));
END $$;

-- p_codigo NULL = marcar como vistos todos los que se ven ahora en el panel
CREATE OR REPLACE FUNCTION vigilante.marcar_evento_visto(p_codigo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_user uuid := vigilante.usuario_actual(); v_cliente uuid := vigilante.cliente_actual(); v_n int;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Hace falta iniciar sesión'; END IF;
  IF p_codigo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vigilante.eventos_compuestos WHERE cliente_id = v_cliente AND codigo = p_codigo) THEN
    RAISE EXCEPTION 'El evento % no existe', p_codigo;
  END IF;
  INSERT INTO vigilante.eventos_vistos (evento_id, user_id, version)
  SELECT e.id, v_user, e.version FROM vigilante.eventos_compuestos e
   WHERE e.cliente_id = v_cliente
     AND (p_codigo = e.codigo
          OR (p_codigo IS NULL AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado')
              AND e.version_en > now() - make_interval(hours => coalesce(vigilante._entero(vigilante.param(v_cliente, 'eventos_horas_panel'), 24), 24))))
  ON CONFLICT (evento_id, user_id) DO UPDATE SET version = EXCLUDED.version, visto_en = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'marcados', v_n);
END $$;

REVOKE ALL ON FUNCTION vigilante.eventos_emergentes(), vigilante.marcar_evento_visto(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.eventos_emergentes(), vigilante.marcar_evento_visto(text) TO authenticated, service_role;

COMMIT;

-- 3. pg_cron: componer cada minuto (fuera de la transacción; solo en Supabase) ------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-eventos', '* * * * *', 'SELECT vigilante.componer_eventos()');
    RAISE NOTICE 'Tarea vigilante-eventos: cada minuto';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
