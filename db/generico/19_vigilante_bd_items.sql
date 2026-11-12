-- =============================================================================
-- 19. Arreglo: vigilante_bd() fallaba con «invalid input syntax for type integer: "[]"»
-- =============================================================================
-- Qué pasaba: _vigilante_json() convertía config.items de cada fuente con ::int. Si una fuente
-- guardó items como lista ([]) en vez de número, la función entera fallaba, vigilante_bd()
-- devolvía error y el chat AVIA recibía la lista de señales vacía («No tengo señales…»).
--
-- Arreglo: vigilante._entero(jsonb, defecto) convierte sin fallar (número → número,
-- texto numérico → número, lista → su longitud, otra cosa → defecto), y _vigilante_json()
-- la usa en items y en los dos parámetros numéricos. Mismo contenido que la del 16, salvo que
-- además solo devuelve las señales vigentes (regla de Meysel, 2026-11-12), así el chat AVIA
-- tampoco ve las caducadas:
--   · con fechas (evento de inicio a fin, o plazo): se ve hasta que termina el último día,
--     en hora de Bolivia. Del 10 al 14 → se ve el 11; solo el 10 → el 11 ya no.
--   · sin fechas: se ve 24 h desde la última noticia que la alimentó («noticia viva»:
--     si llega una noticia nueva sobre el mismo tema, vuelve a contar 24 h).
-- Siguen guardadas en la base hasta la retención; solo dejan de mostrarse.
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

-- Última noticia que alimentó la señal (o su detección si no tiene noticias enlazadas)
CREATE OR REPLACE FUNCTION vigilante.ultima_noticia(p_signal bigint, p_creada timestamptz)
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT greatest(p_creada, (SELECT max(r.recolectado_en) FROM vigilante.signal_raw_items sr
                               JOIN vigilante.raw_items r ON r.id = sr.raw_item_id WHERE sr.signal_id = p_signal))
$$;

-- ¿Se muestra la señal? Con fechas: hasta el final del último día (Bolivia). Sin fechas: 24 h desde la última noticia.
-- Las fechas sin hora («2026-11-14») se guardan como medianoche UTC; por eso el día se lee en UTC:
-- leído en hora de Bolivia saldría el día anterior (20:00 del 13) y la señal caducaría un día antes.
CREATE OR REPLACE FUNCTION vigilante.senal_vigente(p_signal bigint, p_creada timestamptz, p_plazo timestamptz,
                                                   p_ev_inicio timestamptz, p_ev_fin timestamptz)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
           WHEN coalesce(p_plazo, p_ev_inicio, p_ev_fin) IS NOT NULL
             THEN (greatest(p_plazo, p_ev_inicio, p_ev_fin) AT TIME ZONE 'UTC')::date
                  >= (now() AT TIME ZONE 'America/La_Paz')::date
           ELSE vigilante.ultima_noticia(p_signal, p_creada) >= now() - interval '24 hours'
         END
$$;
REVOKE ALL ON FUNCTION vigilante.ultima_noticia(bigint, timestamptz) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.senal_vigente(bigint, timestamptz, timestamptz, timestamptz, timestamptz) FROM public, anon;

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
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM (SELECT s.* FROM vigilante.signals s, c WHERE s.cliente_id = c.id
                          AND s.created_at >= now() - make_interval(months => c.meses)
                          AND vigilante.senal_vigente(s.id, s.created_at, s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin)
                        ORDER BY s.created_at DESC LIMIT 1000) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

-- Web pública: la misma regla (sustituye la del 16)
CREATE OR REPLACE FUNCTION vigilante.alertas_publicas(p_cliente text, p_anteriores boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (
    SELECT cl.*, coalesce((vigilante.param(cl.id, 'web_dias_visibles') #>> '{}')::int, 7) AS dias,
           coalesce((vigilante.param(cl.id, 'retencion_meses') #>> '{}')::int, 6) AS meses
      FROM vigilante.clientes cl WHERE cl.slug = p_cliente AND cl.activo
  ), base AS (
    SELECT a.*, s.codigo, s.naturaleza, s.categoria, s.prioridad, s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin,
           s.salida_modelo, cat.nombre AS categoria_nombre,
           -- vigente: con fechas, hasta el último día; sin fechas, 24 h desde lo último (publicación o noticia)
           coalesce((a.vigente_hasta IS NULL OR a.vigente_hasta > now())
             AND vigilante.senal_vigente(s.id, greatest(s.created_at, a.publicada_en), s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin),
             false) AS actual
      FROM c
      JOIN vigilante.alerts a ON a.cliente_id = c.id
      JOIN vigilante.signals s ON s.id = a.signal_id
      LEFT JOIN vigilante.categorias cat ON cat.cliente_id = s.cliente_id AND cat.codigo = s.categoria
     WHERE a.visibilidad = 'publica' AND a.publicada_en IS NOT NULL AND a.cerrada_en IS NULL AND NOT a.es_escenario
       AND a.publicada_en > now() - make_interval(months => c.meses)
  ), lista AS (
    -- lo caducado ya no se muestra, tampoco con «Ver anteriores» (p_anteriores se mantiene por compatibilidad)
    SELECT * FROM base WHERE actual ORDER BY publicada_en DESC LIMIT 500
  ), hoy AS (
    SELECT d.* FROM vigilante.daily_digests d, c
     WHERE d.cliente_id = c.id AND d.publicado_en IS NOT NULL
       AND d.fecha >= ((now() AT TIME ZONE c.zona_horaria)::date - 1)
     ORDER BY d.fecha DESC LIMIT 1
  )
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'nombre', c.nombre,
    'telegram_url', vigilante.param(c.id, 'telegram_canal_url') #>> '{}',
    'generado', now(),
    'dias_visibles', c.dias,
    'anteriores', p_anteriores,
    'n_anteriores', 0,
    'mensaje_sin_alertas', coalesce(vigilante.param(c.id, 'mensaje_sin_alertas') #>> '{}', 'No hay alertas confirmadas en este momento'),
    'resumen', (SELECT jsonb_build_object('fecha', h.fecha, 'texto', CASE WHEN h.sin_alertas THEN h.texto END,
                                          'alertas', coalesce((SELECT jsonb_agg(i.alert_id ORDER BY i.orden)
                                                                 FROM vigilante.daily_digest_items i WHERE i.digest_id = h.id), '[]'::jsonb))
                  FROM hoy h),
    'alertas', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', l.id,
               'codigo', l.codigo,
               'titulo', l.titulo,
               'texto', l.texto,
               'importancia', l.salida_modelo ->> 'importancia',
               'recomendacion', l.recomendacion,
               'enlace', l.enlace_fuente,
               'verificacion', l.estado_verificacion,
               'naturaleza', l.naturaleza,
               'categoria', l.categoria,
               'categoria_nombre', l.categoria_nombre,
               'prioridad', l.prioridad,
               'deps', coalesce(l.salida_modelo -> 'deps', '[]'::jsonb),
               'destinos', coalesce(l.salida_modelo -> 'destinos', '[]'::jsonb),
               'plazo_hasta', l.plazo_hasta,
               'fecha_evento', coalesce(l.fecha_evento_inicio, l.fecha_evento_fin),
               'fecha_evento_fin', l.fecha_evento_fin,
               'publicada_en', l.publicada_en,
               'actualizada_en', l.updated_at,
               'actual', l.actual,
               'util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = l.id AND f.util),
               'no_util', (SELECT count(*) FROM vigilante.feedback f WHERE f.alert_id = l.id AND NOT f.util))
             ORDER BY l.publicada_en DESC)
        FROM lista l), '[]'::jsonb))
  FROM c
$$;
REVOKE ALL ON FUNCTION vigilante.alertas_publicas(text, boolean) FROM public;
GRANT EXECUTE ON FUNCTION vigilante.alertas_publicas(text, boolean) TO anon, authenticated;

COMMIT;
