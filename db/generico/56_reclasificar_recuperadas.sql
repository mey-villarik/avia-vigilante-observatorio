-- =============================================================================
-- 56. Volver a clasificar las noticias recuperadas por el 55 que la IA rechazó (2026-11-26)
-- =============================================================================
-- Por qué: el 55 sacó del filtro previo 287 noticias de servicios esenciales y atención turística
-- (sobre todo combustible). Pero el clasificador 1.11 solo daba por relevante lo que «afecta a
-- visitantes, operadores o destinos», y un corte de agua o la falta de diésel sin la palabra
-- «turista» la marcaba no relevante («IA: …»). Resultado: la vista Dirección seguía sin esos ejes.
-- El clasificador 1.12 (hermes/analizador/prompt_clasificador.md) dice que sí son relevantes.
--
-- Qué hace: vigilante.reclasificar_recuperadas(cliente, aplicar) devuelve a la cola las recuperadas
-- por el 55 que la IA descartó (sin señal), borrando solo esa clasificación para que el analizador
-- las vuelva a mirar con el prompt nuevo. Por defecto solo cuenta (aplicar = false).
--
-- ORDEN: primero copiar prompt_clasificador.md 1.12 al VPS, después ejecutar esto con aplicar = true.
-- Se puede ejecutar varias veces. Necesita el 55.
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante.reclasificar_recuperadas(p_cliente text, p_aplicar boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_n int; v_ej jsonb; v_hecho int := 0;
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'Cliente % no existe', p_cliente; END IF;
  CREATE TEMP TABLE IF NOT EXISTS _reclasificar (id bigint PRIMARY KEY, version int, titulo text, motivo text) ON COMMIT DROP;
  TRUNCATE _reclasificar;
  INSERT INTO _reclasificar
  SELECT r.id, r.version, r.titulo, r.motivo_descarte
    FROM vigilante.raw_items r
   WHERE r.cliente_id = v_cliente AND r.payload ? 'recuperada_55'
     AND r.estado = 'descartado' AND r.motivo_descarte LIKE 'IA:%'
     AND NOT EXISTS (SELECT 1 FROM vigilante.analisis a WHERE a.raw_item_id = r.id AND a.signal_id IS NOT NULL);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  SELECT coalesce(jsonb_agg(jsonb_build_object('titulo', left(titulo, 90), 'motivo', motivo)), '[]')
    INTO v_ej FROM (SELECT * FROM _reclasificar ORDER BY id DESC LIMIT 12) x;

  IF p_aplicar AND v_n > 0 THEN
    DELETE FROM vigilante.analisis a USING _reclasificar x
     WHERE a.raw_item_id = x.id AND a.version = x.version AND a.tipo = 'clasificacion' AND a.signal_id IS NULL;
    UPDATE vigilante.raw_items r SET estado = 'nuevo', motivo_descarte = NULL,
           payload = r.payload || jsonb_build_object('reclasificada_56', now(), 'motivo_ia_anterior', x.motivo)
      FROM _reclasificar x WHERE r.id = x.id;
    GET DIAGNOSTICS v_hecho = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('rechazadas_por_ia', v_n, 'vuelven_a_la_cola', v_hecho, 'ejemplos', v_ej);
END $$;
REVOKE ALL ON FUNCTION vigilante.reclasificar_recuperadas(text, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.reclasificar_recuperadas(text, boolean) TO service_role;

-- Solo cuenta. Para aplicarlo (DESPUÉS de copiar el prompt 1.12 al VPS):
--   SELECT vigilante.reclasificar_recuperadas('orbita-bolivia', true);
SELECT vigilante.reclasificar_recuperadas('orbita-bolivia', false) AS vista_previa;

COMMIT;
