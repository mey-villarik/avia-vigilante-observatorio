-- =============================================================================
-- 39. Contadores que cuadran: «Verificadas» y número de fuentes
-- =============================================================================
-- Qué se veía en el panel (Meysel, 2026-11-21):
--   · «Verificadas 59 · 2 con 2 o más fuentes». No es un error de suma: desde el 29 las señales de
--     fuente oficial pasan solas a Confirmadas con UNA sola noticia, así que casi todas las
--     verificadas lo están por la fuente oficial, no por dos fuentes. El panel solo mostraba la parte
--     de «2 o más fuentes» y parecía que faltaban 57. Además «fuentes» contaba noticias enlazadas
--     (dos notas del mismo medio contaban como dos fuentes).
--   · «39 fuentes» en Panorama y en la cabecera del panel Fuentes, pero «Fuentes leyendo bien: X de
--     33» en el Pulso: las 39 incluían las fuentes en pausa (o propuestas por AVIA sin aprobar), las
--     33 no.
--
-- Arreglo: el desglose de verificadas suma el total y las fuentes se cuentan igual en todas partes.
--   verificadas            = activas confirmadas o publicadas (igual que en el 21)
--     verificadas_2_fuentes   = de ellas, con noticias de 2 o más fuentes DISTINTAS
--     verificadas_oficial     = el resto que tiene fuente oficial (pasaron solas a Confirmadas, 29)
--     verificadas_una_fuente  = el resto: una sola fuente no oficial (las movió una persona)
--     (las tres suman «verificadas»)
--   fuentes_activas        = fuentes del catálogo que AVIA vigila (no eliminadas, no propuestas, activas)
--   fuentes_en_pausa       = fuentes del catálogo en pausa o propuestas por AVIA sin aprobar
--
-- Mismas reglas en web/src/lib/contadores.ts y hermes/avia-api/avia_api.py.
-- Necesita el 21. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_contadores.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante.contadores(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.*,
           -- fuentes distintas que sostienen la señal (una noticia sin fuente del catálogo cuenta por su dominio)
           (SELECT count(DISTINCT coalesce(r.source_id::text, substring(r.url FROM '^[a-z]+://([^/]+)'), r.id::text))
              FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
             WHERE sr.signal_id = s.id) AS n_fuentes
      FROM vigilante.senales_visibles(p_cliente) s
     WHERE s.estado <> 'descartada'
  ),
  v AS (SELECT * FROM a WHERE estado IN ('confirmada', 'publicada')),
  f AS (
    SELECT * FROM vigilante.sources
     WHERE cliente_id = p_cliente AND eliminada_en IS NULL
  )
  SELECT jsonb_build_object(
    'actualizado', now(),
    'senales_activas',     (SELECT count(*) FROM a),
    'oportunidades',       (SELECT count(*) FROM a WHERE naturaleza = 'oportunidad'),
    'riesgos',             (SELECT count(*) FROM a WHERE naturaleza = 'riesgo'),
    'mixtas',              (SELECT count(*) FROM a WHERE naturaleza = 'mixta'),
    'plazo_corto',         (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15),
    'riesgos_altos',       (SELECT count(*) FROM a WHERE naturaleza = 'riesgo' AND prioridad = 'alta'),
    'verificadas',            (SELECT count(*) FROM v),
    'verificadas_2_fuentes',  (SELECT count(*) FROM v WHERE n_fuentes >= 2),
    'verificadas_oficial',    (SELECT count(*) FROM v WHERE n_fuentes < 2 AND coalesce(fuente_oficial, false)),
    'verificadas_una_fuente', (SELECT count(*) FROM v WHERE n_fuentes < 2 AND NOT coalesce(fuente_oficial, false)),
    'por_verificar',       (SELECT count(*) FROM a WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'esperan_aprobacion',  (SELECT count(*) FROM a WHERE requiere_revision AND estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'alertas_publicadas',  (SELECT count(*) FROM a WHERE estado = 'publicada'),
    'descartadas',         (SELECT count(*) FROM vigilante.senales_visibles(p_cliente) s WHERE s.estado = 'descartada'),
    'noticias_24h',        (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = p_cliente AND r.recolectado_en > now() - interval '24 hours'),
    'fuentes_activas',     (SELECT count(*) FROM f WHERE activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)),
    'fuentes_en_pausa',    (SELECT count(*) FROM f WHERE NOT activa OR coalesce((config ->> 'propuesta_avia')::boolean, false))
  )
$$;
REVOKE ALL ON FUNCTION vigilante.contadores(uuid) FROM public, anon, authenticated;

COMMIT;
