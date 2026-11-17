-- =============================================================================
-- 23. Trazabilidad mínima por señal (mejora 5 de la PoC, documento del revisor)
-- =============================================================================
-- Qué pasaba: cada enlace llevaba una sola «fecha» que mezclaba la publicación de la noticia con
-- el momento en que AVIA la recogió, y no se veía cuándo se comprobó por última vez ni quién.
--
-- Ahora cada señal lleva «trazabilidad»:
--   · detectada: cuándo AVIA creó la señal
--   · fuentes[]: por cada noticia que la sostiene: nombre de la fuente, si es oficial, enlace,
--       fecha de publicación (la que da la fuente; null si no la da) y fecha en que AVIA la recogió
--   · primera_publicacion / ultima_noticia
--   · fuente_comprobada: última vez que AVIA volvió a leer alguna de esas fuentes
--   · ultima_verificacion: última decisión de una PERSONA (en verificación, confirmada, publicada o
--       descartada) con quién y cuándo; null = «sin verificar por una persona»
-- Las señales antiguas copiadas de vigilante.json (sin noticias enlazadas) muestran sus enlaces con
-- «fecha sin distinguir»: no se sabe si es publicación o recogida, y se dice.
--
-- Necesita el 22. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT codigo, vigilante.trazabilidad(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 3;
-- Prueba: 99_prueba_trazabilidad.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante.trazabilidad(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH s AS (SELECT * FROM vigilante.signals WHERE id = p_signal),
  n AS (
    SELECT coalesce(src.nombre, 'Búsqueda de AVIA') AS nombre, coalesce(src.tipo::text, 'no_oficial') AS tipo,
           coalesce(src.tipo IN ('oficial', 'organismo_internacional'), false) AS oficial,
           r.url, r.titulo, r.publicado_en, r.recolectado_en, src.ultima_consulta_en
      FROM s JOIN vigilante.signal_raw_items sr ON sr.signal_id = s.id
      JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
      LEFT JOIN vigilante.sources src ON src.id = r.source_id
  ),
  v AS (   -- última decisión de una persona (actor = id de usuario de Supabase Auth)
    SELECT h.created_at, h.estado_nuevo, coalesce(u.nombre, 'una persona del equipo') AS quien
      FROM s JOIN vigilante.signal_history h ON h.signal_id = s.id
      JOIN vigilante.users u ON u.auth_user_id::text = h.actor
     WHERE h.estado_nuevo IN ('en_verificacion', 'confirmada', 'publicada', 'descartada')
     ORDER BY h.created_at DESC LIMIT 1
  )
  SELECT jsonb_build_object(
    'detectada', s.created_at,
    'fuentes', coalesce(
       (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'nombre', n.nombre, 'tipo', n.tipo, 'oficial', n.oficial, 'url', n.url, 'titulo', n.titulo,
                 'publicada', n.publicado_en, 'recogida', n.recolectado_en))
               ORDER BY n.oficial DESC, coalesce(n.publicado_en, n.recolectado_en) DESC)
          FROM (SELECT * FROM n ORDER BY oficial DESC, coalesce(publicado_en, recolectado_en) DESC LIMIT 10) n),
       (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                 'nombre', coalesce(e ->> 'nombre', 'Fuente'), 'url', e ->> 'url', 'fecha', e ->> 'fecha',
                 'nota', 'fecha sin distinguir (dato antiguo): no se sabe si es publicación o recogida')))
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.salida_modelo -> 'enlaces') = 'array' THEN s.salida_modelo -> 'enlaces' ELSE '[]' END) e
         WHERE e ->> 'url' IS NOT NULL),
       '[]'::jsonb),
    'noticias', (SELECT count(*) FROM n),
    'primera_publicacion', (SELECT min(publicado_en) FROM n),
    'ultima_noticia', (SELECT max(recolectado_en) FROM n),
    'fuente_comprobada', (SELECT max(ultima_consulta_en) FROM n),
    'ultima_verificacion', (SELECT jsonb_build_object('cuando', v.created_at, 'quien', v.quien, 'estado', v.estado_nuevo) FROM v))
  FROM s
$$;
REVOKE ALL ON FUNCTION vigilante.trazabilidad(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.trazabilidad(bigint) TO authenticated, service_role;

-- vigilante.json / vigilante_bd(): igual que en el 22, con «trazabilidad» en cada señal
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
                         'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
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
                       'evento_inicio', to_char(s.fecha_evento_inicio AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'evento_fin', to_char(s.fecha_evento_fin AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'ultima_noticia', vigilante.ultima_noticia(s.id, s.created_at),
                       'puntuaciones', vigilante.puntuaciones(s.id),
                       'trazabilidad', vigilante.trazabilidad(s.id),
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

COMMIT;
