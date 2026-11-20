-- =============================================================================
-- 35. Cambios en noticias: 24 horas en el panel y después solo guardados
-- =============================================================================
-- Qué cambia respecto al 31 (Meysel, 2026-11-20):
--
--   «Los cambios también quiero que se quiten de la lista a las 24 horas, se guarden en la BD
--    pero no se muestren, para evitar listas muy largas.»
--
--   Es lo mismo que el 34 hizo con los eventos:
--   1. Un cambio se ve en la lista «Cambios» del panel durante «cambios_horas_panel» (24) desde que
--      se detectó. Antes eran 3 días (cambios_dias_panel, que deja de usarse).
--   2. Pasado ese tiempo NO se borra ni se descarta: sigue en vigilante.cambios_senal, Hermes lo sigue
--      viendo por el MCP (cambios_abiertos, últimos 3 días por defecto) y cuenta para la historia.
--      Solo deja de mostrarse en el panel.
--   3. Las repeticiones (otra noticia con el mismo cambio) no alargan el plazo: no vuelven a sonar.
--   4. cambios_recientes() devuelve además «oculta_en» (cuándo deja de mostrarse), y
--      marcar_cambio_visto(NULL) marca solo los que se ven en el panel.
--
-- Necesita el 31. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run. Se puede ejecutar varias veces.
-- Cambiar el plazo: UPDATE vigilante.parametros SET valor = '48' WHERE cliente_id IS NULL AND clave = 'cambios_horas_panel';
-- Prueba: 99_prueba_cambios_24h.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regclass('vigilante.cambios_senal') IS NULL THEN
    RAISE EXCEPTION 'Falta el 31 (cambios_noticias): ejecútalo antes que este';
  END IF;
END $$;

-- 0. Parámetros ------------------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'cambios_horas_panel', '24', 'Horas que un cambio se ve en la lista «Cambios» del panel desde que se detectó. Después sigue guardado en la base')
ON CONFLICT (cliente_id, clave) DO NOTHING;

UPDATE vigilante.parametros
   SET descripcion = 'Ya no se usa desde el 35: ver cambios_horas_panel'
 WHERE cliente_id IS NULL AND clave = 'cambios_dias_panel';

CREATE OR REPLACE FUNCTION vigilante._cambios_horas_panel(p_cliente uuid) RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT greatest(coalesce(vigilante._entero(vigilante.param(p_cliente, 'cambios_horas_panel'), 24), 24), 1)
$$;
REVOKE ALL ON FUNCTION vigilante._cambios_horas_panel(uuid) FROM public, anon, authenticated;

-- 1. Para el panel ---------------------------------------------------------------------------
--   Solo los no descartados detectados en las últimas cambios_horas_panel horas.
--   alerta    = importancia ≥ cambios_alerta_desde y (interpretado, o lleva cambios_espera_hermes_min sin interpretar)
--   visto     = esta persona ya pulsó «Entendido»
--   oculta_en = cuándo deja de mostrarse
CREATE OR REPLACE FUNCTION vigilante.cambios_recientes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.cliente_actual(); v_user uuid := vigilante.usuario_actual();
        v_horas int; v_espera int; v_desde int;
BEGIN
  IF v_cliente IS NULL OR NOT vigilante.es_staff() THEN RETURN '[]'::jsonb; END IF;
  v_horas  := vigilante._cambios_horas_panel(v_cliente);
  v_espera := coalesce(vigilante._entero(vigilante.param(v_cliente, 'cambios_espera_hermes_min'), 0), 0);
  v_desde  := greatest(vigilante._nivel(coalesce(vigilante.param(v_cliente, 'cambios_alerta_desde') #>> '{}', 'baja')), 1);
  RETURN (
    SELECT coalesce(jsonb_agg(vigilante._cambio_json(c.id) || jsonb_build_object(
             'alerta', vigilante._nivel(c.importancia::text) >= v_desde
                       AND (c.estado = 'interpretado' OR c.created_at <= now() - make_interval(mins => v_espera)),
             'esperando_hermes', c.estado <> 'interpretado',
             'visto', EXISTS (SELECT 1 FROM vigilante.cambios_vistos v WHERE v.cambio_id = c.id AND v.user_id = v_user),
             'oculta_en', c.created_at + make_interval(hours => v_horas))
             ORDER BY c.created_at DESC), '[]')
      FROM vigilante.cambios_senal c
     WHERE c.cliente_id = v_cliente AND c.estado <> 'descartado'
       AND c.created_at > now() - make_interval(hours => v_horas));
END $$;

-- p_codigo NULL = marcar como vistos todos los que se ven ahora en el panel
CREATE OR REPLACE FUNCTION vigilante.marcar_cambio_visto(p_codigo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_user uuid := vigilante.usuario_actual(); v_cliente uuid := vigilante.cliente_actual(); v_n int;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Hace falta iniciar sesión'; END IF;
  IF p_codigo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vigilante.cambios_senal WHERE cliente_id = v_cliente AND codigo = p_codigo) THEN
    RAISE EXCEPTION 'El cambio % no existe', p_codigo;
  END IF;
  INSERT INTO vigilante.cambios_vistos (cambio_id, user_id)
  SELECT c.id, v_user FROM vigilante.cambios_senal c
   WHERE c.cliente_id = v_cliente
     AND (p_codigo = c.codigo
          OR (p_codigo IS NULL AND c.estado <> 'descartado'
              AND c.created_at > now() - make_interval(hours => vigilante._cambios_horas_panel(v_cliente))))
  ON CONFLICT (cambio_id, user_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'marcados', v_n);
END $$;

REVOKE ALL ON FUNCTION vigilante.cambios_recientes(), vigilante.marcar_cambio_visto(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.cambios_recientes(), vigilante.marcar_cambio_visto(text) TO authenticated, service_role;

COMMIT;
