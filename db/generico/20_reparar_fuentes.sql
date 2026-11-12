-- =============================================================================
-- AVIA Vigilante · 20 · Reparar fuentes que fallan (Gaceta Oficial, Conoce Bolivia, SENAMHI)
-- =============================================================================
-- Requiere: 14 y 15 (recolector con versiones) y el recolector 1.2.0 en el VPS (lee las opciones
-- nuevas de sources.config: timeout_s, reintentos, urls_alternativas, extractor, respaldo).
--
-- Qué hace (solo cliente orbita-bolivia; se puede ejecutar varias veces):
--   1. Gaceta Oficial  → diagnóstico del VPS (2026-11-12): DNS bien, pero el servidor no acepta la conexión
--                        desde el VPS (TCP agotado en 80 y 443). Intenta 30 s el listado por fecha y el buscador;
--                        si no responde, lee las noticias sobre la Gaceta en Google News (aviso, no fallo).
--   2. Conoce Bolivia  → turismoyculturas.gob.bo ya no existe (DNS falla). El portal está ahora en
--                        conocebolivia.produccion.gob.bo, pero tampoco acepta conexiones desde el VPS:
--                        se cambia la dirección y, mientras no responda, entra por respaldo de noticias.
--   3. SENAMHI         → deja Apify: lectura directa de la tabla de avisos (cada fila = un aviso con su PDF)
--                        y respaldo de noticias «Senamhi alerta». Si ya había otra fuente SENAMHI directa,
--                        la de Apify se desactiva para no duplicar.
-- Todas quedan marcadas gestionada_web = true para que la sincronización con vigilante.json no
-- devuelva la dirección antigua, y con proxima_revision_en = now() para que el recolector las lea ya.
-- Al final muestra cómo quedaron.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');
  n int;
  v_directa int;
BEGIN
  IF c IS NULL THEN RAISE EXCEPTION 'No existe el cliente orbita-bolivia'; END IF;
  IF to_regprocedure('vigilante.fuentes_para_recolector(text)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 14 (recolector). Ejecuta 14 y 15 antes que este archivo';
  END IF;

  -- 1. Gaceta Oficial ---------------------------------------------------------
  UPDATE vigilante.sources SET
      url = 'http://www.gacetaoficialdebolivia.gob.bo/normas/listadofec',
      metodo = 'http_html',
      config = config - 'apify_actor' - 'apify_input' || jsonb_build_object(
        'timeout_s', 30,
        'reintentos', 0,
        'urls_alternativas', jsonb_build_array('http://www.gacetaoficialdebolivia.gob.bo/normas/buscar'),
        'respaldo', jsonb_build_object(
          'metodo', 'google_news_rss',
          'query', '"Gaceta Oficial" OR "decreto supremo" Bolivia (turismo OR feriado OR "área protegida" OR aeropuerto OR visa)'),
        'reparada', '2026-11-12: el servidor no acepta conexiones desde el VPS (TCP agotado en 80 y 443); respaldo Google News'),
      gestionada_web = true,
      errores_seguidos = 0,
      proxima_revision_en = now(),
      updated_at = now()
   WHERE cliente_id = c AND eliminada_en IS NULL
     AND (url ILIKE '%gacetaoficialdebolivia%' OR codigo ILIKE '%gaceta%');
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'Gaceta Oficial: % fuente(s) actualizada(s)', n;

  -- 2. Conoce Bolivia ---------------------------------------------------------
  UPDATE vigilante.sources SET
      url = 'https://conocebolivia.produccion.gob.bo/',
      metodo = 'http_html',
      config = config - 'apify_actor' - 'apify_input' || jsonb_build_object(
        'timeout_s', 20,
        'reintentos', 0,
        'respaldo', jsonb_build_object(
          'metodo', 'google_news_rss',
          'query', '"Conoce Bolivia" OR "Bolivia te espera" OR "Viceministerio de Turismo" Bolivia'),
        'url_anterior', coalesce(config ->> 'url_anterior', url),
        'reparada', '2026-11-12: el dominio turismoyculturas no responde; el portal pasó a produccion.gob.bo'),
      gestionada_web = true,
      errores_seguidos = 0,
      proxima_revision_en = now(),
      updated_at = now()
   WHERE cliente_id = c AND eliminada_en IS NULL
     AND (url ILIKE '%conocebolivia%' OR codigo ILIKE 'conoce%');
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'Conoce Bolivia: % fuente(s) actualizada(s)', n;

  -- 3. SENAMHI sin Apify ------------------------------------------------------
  -- ¿Ya hay una fuente SENAMHI que lee la web directamente?
  SELECT min(id) INTO v_directa FROM vigilante.sources
   WHERE cliente_id = c AND eliminada_en IS NULL AND activa
     AND url ILIKE '%senamhi.gob.bo%' AND metodo <> 'apify';

  IF v_directa IS NOT NULL THEN
    -- la de Apify sobra: se desactiva (no se borra, conserva su historial)
    UPDATE vigilante.sources SET activa = false, gestionada_web = true,
        notas = concat_ws(' · ', notas, '2026-11-12: desactivada, sin Apify; la lee la fuente SENAMHI directa'),
        updated_at = now()
     WHERE cliente_id = c AND eliminada_en IS NULL AND activa
       AND (url ILIKE '%senamhi%' OR codigo ILIKE '%senamhi%') AND metodo = 'apify';
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'SENAMHI: % fuente(s) de Apify desactivada(s); se mantiene la directa (id %)', n, v_directa;
  ELSE
    -- no hay directa: la de Apify pasa a lectura directa
    UPDATE vigilante.sources SET url = 'https://senamhi.gob.bo/alertas3.php', metodo = 'http_html', updated_at = now()
     WHERE cliente_id = c AND eliminada_en IS NULL
       AND (url ILIKE '%senamhi%' OR codigo ILIKE '%senamhi%') AND metodo = 'apify';
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'SENAMHI: % fuente(s) de Apify pasada(s) a lectura directa', n;
  END IF;

  -- la tabla de avisos (alertas3.php) se lee fila a fila: cada aviso con su PDF es un documento
  UPDATE vigilante.sources SET
      metodo = 'http_html',
      config = config - 'apify_actor' - 'apify_input' || jsonb_build_object(
        'extractor', 'tabla',
        'tabla_filtro', 'ALERTA|AVISO',
        'timeout_s', 45,
        'reintentos', 2,
        'urls_alternativas', jsonb_build_array('https://senamhi.gob.bo/alertasanteriores1.php'),
        'respaldo', jsonb_build_object(
          'metodo', 'google_news_rss',
          'query', 'Senamhi (alerta OR aviso) (naranja OR roja OR amarilla OR lluvias OR helada OR crecida)'),
        'reparada', '2026-11-12: sin Apify, lectura directa de la tabla de avisos'),
      gestionada_web = true,
      errores_seguidos = 0,
      proxima_revision_en = now(),
      updated_at = now()
   WHERE cliente_id = c AND eliminada_en IS NULL AND activa
     AND url ILIKE '%senamhi.gob.bo/alertas%';
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'SENAMHI: % fuente(s) leen la tabla de avisos', n;

  -- propuestas pendientes de pasar estas fuentes a Apify: ya no aplican (no hay Apify)
  UPDATE vigilante.source_proposals p SET estado = 'rechazada', decidida_por = 'sql 20', decidida_en = now(),
      nota = 'Sin Apify: se reparó con lectura directa, timeout, reintentos y respaldo (2026-11-12)'
    FROM vigilante.sources s
   WHERE p.source_id = s.id AND s.cliente_id = c AND p.estado = 'pendiente' AND p.metodo_propuesto = 'apify'
     AND (s.url ILIKE ANY (ARRAY['%senamhi%', '%gacetaoficial%', '%conocebolivia%']) OR s.codigo ILIKE 'conoce%');
END $$;

COMMIT;

-- Cómo quedaron
SELECT codigo, activa, metodo, url, frecuencia_minutos AS cada_min,
       config ->> 'timeout_s' AS espera_s, config ->> 'reintentos' AS reintentos,
       config -> 'respaldo' ->> 'metodo' AS respaldo, config ->> 'extractor' AS extractor,
       errores_seguidos, proxima_revision_en
  FROM vigilante.sources
 WHERE cliente_id = (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia')
   AND (url ILIKE '%senamhi%' OR url ILIKE '%gacetaoficial%' OR url ILIKE '%conocebolivia%' OR codigo ILIKE 'conoce%')
 ORDER BY codigo;

-- -----------------------------------------------------------------------------
-- SOLO SI el diagnóstico desde el VPS dice que conocebolivia.produccion.gob.bo TAMPOCO responde:
-- marcar Conoce Bolivia como inactiva (no se borra; se puede reactivar desde la web).
-- -----------------------------------------------------------------------------
-- UPDATE vigilante.sources SET activa = false, gestionada_web = true, updated_at = now(),
--        notas = concat_ws(' · ', notas, '2026-11-12: inactiva, el portal no responde desde el VPS')
--  WHERE cliente_id = (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia')
--    AND url ILIKE '%conocebolivia%';
