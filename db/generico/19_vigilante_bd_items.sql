-- =============================================================================
-- 19. Arreglo: vigilante_bd() fallaba con «invalid input syntax for type integer: "[]"»
-- =============================================================================
-- Qué pasaba: _vigilante_json() convertía config.items de cada fuente con ::int. Si una fuente
-- guardó items como lista ([]) en vez de número, la función entera fallaba, vigilante_bd()
-- devolvía error y el chat AVIA recibía la lista de señales vacía («No tengo señales…»).
--
-- Arreglo: vigilante._entero(jsonb, defecto) convierte sin fallar (número → número,
-- texto numérico → número, lista → su longitud, otra cosa → defecto), y _vigilante_json()
-- la usa en items y en los dos parámetros numéricos. Mismo contenido que la del 16.
--
-- Cómo aplicarlo: pegar este archivo entero en el SQL Editor de Supabase y pulsar Run.
-- Comprobar después (debe salir un número, no un error):
--   SELECT jsonb_array_length(vigilante._vigilante_json(id) -> 'senales') FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Ver qué fuentes tenían items raro:
--   SELECT codigo, config -> 'items' FROM vigilante.sources WHERE jsonb_typeof(config -> 'items') NOT IN ('number');
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante._entero(p jsonb, p_defecto int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE jsonb_typeof(p)
           WHEN 'number' THEN round((p #>> '{}')::numeric)::int
           WHEN 'string' THEN CASE WHEN (p #>> '{}') ~ '^\s*-?\d+\s*$' THEN (p #>> '{}')::int ELSE p_defecto END
           WHEN 'array'  THEN jsonb_array_length(p)
           ELSE p_defecto
         END
$$;

CREATE OR REPLACE FUNCTION vigilante._vigilante_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT p_cliente AS id,
                    vigilante._entero(vigilante.param(p_cliente, 'retencion_meses'), 6) AS meses,
                    vigilante._entero(vigilante.param(p_cliente, 'web_dias_visibles'), 7) AS dias)
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
                  'items', vigilante._entero(s.config -> 'items', 0), 'hist', coalesce(s.config -> 'hist', '[]'), 'info', s.notas)
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

COMMIT;
