-- =============================================================================
-- 41. Una sola cifra de fuentes: leídas / activas / sin leer
-- =============================================================================
-- Qué se veía (Meysel, 2026-11-21): el encabezado del panel, el recuadro Pulso y la pestaña
-- Fuentes daban tres cifras distintas de fuentes:
--   · encabezado: una pastilla por estado (OK, AVISO, CRÍTICO, DESCONOCIDO, MANTENIMIENTO),
--     contando también las en pausa;
--   · Pulso: «leyendo bien X de Y activas», con X = solo las OK (las de AVISO no contaban);
--   · Fuentes: «Total» con las en pausa y las activas al lado.
--
-- Regla única desde el 41 (la misma en web/src/lib/contadores.ts → cifrasFuentes() y en
-- hermes/avia-api/avia_api.py):
--
--   ACTIVAS  = fuentes del catálogo que AVIA vigila (no eliminadas, ni en pausa, ni propuestas)
--   LEÍDAS   = activas cuya última comprobación dio OK o AVISO (AVIA obtuvo respuesta; es la
--              misma regla con la que la base pone ultimo_exito_en)
--   SIN LEER = activas que no: CRÍTICO (no se pudo leer) o DESCONOCIDO (aún sin comprobar)
--   ACTIVAS  = LEÍDAS + SIN LEER. Las en pausa van aparte y no cuentan.
--
-- Este script solo añade fuentes_leidas y fuentes_sin_leer a vigilante.contadores();
-- el resto de la función queda igual que en el 40. Se puede ejecutar más de una vez.
-- Prueba: 99_prueba_contadores.sql (al final).
-- =============================================================================

CREATE OR REPLACE FUNCTION vigilante.contadores(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.*, r.n_fuentes, r.verificada
      FROM vigilante.senales_visibles(p_cliente) s
      CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
     WHERE s.estado <> 'descartada'
  ),
  c AS (SELECT * FROM a WHERE estado IN ('confirmada', 'publicada')),
  v AS (SELECT * FROM c WHERE verificada),
  f AS (
    SELECT * FROM vigilante.sources
     WHERE cliente_id = p_cliente AND eliminada_en IS NULL
  ),
  -- activas = las que AVIA vigila; leída = su última comprobación dio OK o AVISO (el mismo «estado» que vigilante_bd() manda a la web)
  fa AS (
    SELECT coalesce(config ->> 'estado', 'UNKNOWN') IN ('OK', 'WARN') AS leida
      FROM f WHERE activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)
  )
  SELECT jsonb_build_object(
    'actualizado', now(),
    'senales_activas',     (SELECT count(*) FROM a),
    'oportunidades',       (SELECT count(*) FROM a WHERE naturaleza = 'oportunidad'),
    'riesgos',             (SELECT count(*) FROM a WHERE naturaleza = 'riesgo'),
    'mixtas',              (SELECT count(*) FROM a WHERE naturaleza = 'mixta'),
    'plazo_corto',         (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15),
    'riesgos_altos',       (SELECT count(*) FROM a WHERE naturaleza = 'riesgo' AND prioridad = 'alta'),
    'verificadas',               (SELECT count(*) FROM v),
    'verificadas_2_fuentes',     (SELECT count(*) FROM v WHERE n_fuentes >= 2),
    'verificadas_oficial',       (SELECT count(*) FROM v WHERE n_fuentes < 2),
    'verificadas_una_fuente',    0,
    'confirmadas_sin_verificar', (SELECT count(*) FROM c WHERE NOT verificada),
    'por_verificar',       (SELECT count(*) FROM a WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'esperan_aprobacion',  (SELECT count(*) FROM a WHERE requiere_revision AND estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'alertas_publicadas',  (SELECT count(*) FROM a WHERE estado = 'publicada'),
    'alertas_verificadas', (SELECT count(*) FROM v WHERE estado = 'publicada'),
    'descartadas',         (SELECT count(*) FROM vigilante.senales_visibles(p_cliente) s WHERE s.estado = 'descartada'),
    'noticias_24h',        (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = p_cliente AND r.recolectado_en > now() - interval '24 hours'),
    'fuentes_activas',     (SELECT count(*) FROM fa),
    'fuentes_leidas',      (SELECT count(*) FROM fa WHERE leida),
    'fuentes_sin_leer',    (SELECT count(*) FROM fa WHERE NOT leida),
    'fuentes_en_pausa',    (SELECT count(*) FROM f WHERE NOT activa OR coalesce((config ->> 'propuesta_avia')::boolean, false))
  )
$$;
REVOKE ALL ON FUNCTION vigilante.contadores(uuid) FROM public, anon, authenticated;
