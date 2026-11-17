-- =============================================================================
-- 21. Panel y AVIA cuentan lo mismo (mejora 1 de la PoC, documento del revisor)
-- =============================================================================
-- Qué pasaba: el panel decía 7 señales y AVIA 8. Cada uno contaba a su manera:
--   · el panel quitaba las descartadas, las oportunidades con la ficha vencida y contaba en el
--     navegador; AVIA recibía las 10 últimas tal cual (con descartadas) y las contaba él;
--   · una señal «cerrada» en la base llegaba al panel como «detectada» y seguía contando;
--   · las fichas de oportunidad vencidas ayer seguían en la base un día más que en el panel.
--
-- Arreglo: una sola lista y un solo conteo, en la base.
--   · vigilante.senales_visibles(cliente): las señales que se muestran (retención, vigencia,
--     sin cerradas y sin las oportunidades cuya ficha ya venció). Panel, chat y vigilante.json
--     salen de aquí.
--   · vigilante.contadores(cliente): los números con definiciones fijas y la hora del cálculo.
--     vigilante_bd() los devuelve en «contadores»; el panel los muestra tal cual y AVIA los
--     recibe y debe citarlos («datos actualizados a las HH:MM»).
--
-- Definiciones (las mismas en web/src/lib/contadores.ts):
--   señales activas      = visibles que no están descartadas
--   oportunidades        = activas de naturaleza «oportunidad»
--   riesgos              = activas de naturaleza «riesgo»
--   mixtas               = activas de naturaleza «mixta» (oportunidades + riesgos + mixtas = activas)
--   plazo corto          = activas que no son riesgo y cuyo plazo vence en menos de 15 días
--   riesgos altos        = riesgos de prioridad alta
--   verificadas          = activas confirmadas o publicadas
--   con 2+ fuentes       = verificadas con 2 o más noticias enlazadas
--   por verificar        = activas detectadas, en análisis o en verificación
--   esperan aprobación   = activas que requieren revisión de una persona y aún no la tienen
--   alertas publicadas   = activas publicadas (alerta = señal confirmada y publicada)
--   noticias 24 h        = noticias recogidas en las últimas 24 horas
--
-- Necesita el 19 (senal_vigente). Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_contadores.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- Ficha de oportunidad vencida: el día del plazo (hora de Bolivia) ya terminó
CREATE OR REPLACE FUNCTION vigilante.plazo_vencido(p_plazo timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_plazo IS NOT NULL
     AND (p_plazo AT TIME ZONE 'America/La_Paz')::date < (now() AT TIME ZONE 'America/La_Paz')::date
$$;

-- Las señales que se muestran en el panel y que ve AVIA (con descartadas, para la columna «Descartada»)
CREATE OR REPLACE FUNCTION vigilante.senales_visibles(p_cliente uuid)
RETURNS SETOF vigilante.signals LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.*
    FROM vigilante.signals s
   WHERE s.cliente_id = p_cliente
     AND s.estado <> 'cerrada'
     AND s.created_at >= now() - make_interval(months => vigilante._entero(vigilante.param(p_cliente, 'retencion_meses'), 6))
     AND vigilante.senal_vigente(s.id, s.created_at, s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin)
     AND NOT (s.naturaleza <> 'riesgo' AND EXISTS (
           SELECT 1 FROM vigilante.oportunidades o
            WHERE o.signal_id = s.id AND o.estado <> 'descartada' AND vigilante.plazo_vencido(o.plazo_hasta)))
   ORDER BY s.created_at DESC
   LIMIT 1000
$$;
REVOKE ALL ON FUNCTION vigilante.senales_visibles(uuid) FROM public, anon, authenticated;

-- Días para actuar, igual que el panel: hasta el final del día del plazo en Bolivia, redondeado hacia arriba
CREATE OR REPLACE FUNCTION vigilante.dias_para(p_plazo timestamptz)
RETURNS int LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_plazo IS NULL THEN NULL ELSE greatest(0, ceil(extract(epoch FROM (
           (((p_plazo AT TIME ZONE 'UTC')::date + 1)::timestamp AT TIME ZONE 'America/La_Paz') - now())) / 86400))::int END
$$;

CREATE OR REPLACE FUNCTION vigilante.contadores(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.*, (SELECT count(*) FROM vigilante.signal_raw_items sr WHERE sr.signal_id = s.id) AS n_noticias
      FROM vigilante.senales_visibles(p_cliente) s
     WHERE s.estado <> 'descartada'
  )
  SELECT jsonb_build_object(
    'actualizado', now(),
    'senales_activas',     (SELECT count(*) FROM a),
    'oportunidades',       (SELECT count(*) FROM a WHERE naturaleza = 'oportunidad'),
    'riesgos',             (SELECT count(*) FROM a WHERE naturaleza = 'riesgo'),
    'mixtas',              (SELECT count(*) FROM a WHERE naturaleza = 'mixta'),
    'plazo_corto',         (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15),
    'riesgos_altos',       (SELECT count(*) FROM a WHERE naturaleza = 'riesgo' AND prioridad = 'alta'),
    'verificadas',         (SELECT count(*) FROM a WHERE estado IN ('confirmada', 'publicada')),
    'verificadas_2_fuentes', (SELECT count(*) FROM a WHERE estado IN ('confirmada', 'publicada') AND n_noticias >= 2),
    'por_verificar',       (SELECT count(*) FROM a WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'esperan_aprobacion',  (SELECT count(*) FROM a WHERE requiere_revision AND estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'alertas_publicadas',  (SELECT count(*) FROM a WHERE estado = 'publicada'),
    'descartadas',         (SELECT count(*) FROM vigilante.senales_visibles(p_cliente) s WHERE s.estado = 'descartada'),
    'noticias_24h',        (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = p_cliente AND r.recolectado_en > now() - interval '24 hours')
  )
$$;
REVOKE ALL ON FUNCTION vigilante.contadores(uuid) FROM public, anon, authenticated;

-- Para la web con sesión (el cliente sale del usuario)
CREATE OR REPLACE FUNCTION vigilante.contadores_web()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN vigilante.cliente_actual() IS NULL THEN NULL ELSE vigilante.contadores(vigilante.cliente_actual()) END
$$;
REVOKE ALL ON FUNCTION vigilante.contadores_web() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.contadores_web() TO authenticated, service_role;

-- Para Hermes por el MCP (herramienta «contadores»): el cliente va por su slug
CREATE OR REPLACE FUNCTION vigilante.contadores_cliente(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante.contadores(vigilante.id_cliente(p_cliente))
$$;
REVOKE ALL ON FUNCTION vigilante.contadores_cliente(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.contadores_cliente(text) TO service_role;

-- Fichas de oportunidad: mismo corte que el panel (hasta el final del día del plazo, en Bolivia)
CREATE OR REPLACE FUNCTION vigilante._oportunidades_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', o.id, 'nivel', o.nivel, 'tipo', o.tipo, 'hecho', o.hecho, 'interpretacion', o.interpretacion,
           'beneficiarios', to_jsonb(o.beneficiarios), 'accion', o.accion, 'importancia', o.importancia,
           'plazo_hasta', to_char(o.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'), 'estado', o.estado,
           'senal', s.codigo, 'creada_por', o.creada_por, 'creada', o.created_at,
           'evidencias', (SELECT jsonb_agg(jsonb_build_object('id', r.id, 'titulo', r.titulo, 'url', r.url, 'fuente', coalesce(src.nombre, 'búsqueda')))
                            FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE r.id = ANY (o.evidencias))
         )) ORDER BY o.estado <> 'propuesta', o.plazo_hasta NULLS LAST, o.created_at DESC), '[]')
    FROM vigilante.oportunidades o LEFT JOIN vigilante.signals s ON s.id = o.signal_id
   WHERE o.cliente_id = p_cliente AND o.estado <> 'descartada' AND o.created_at > now() - interval '90 days'
     AND NOT vigilante.plazo_vencido(o.plazo_hasta)
$$;
REVOKE ALL ON FUNCTION vigilante._oportunidades_json(uuid) FROM public, anon, authenticated;

-- vigilante.json / vigilante_bd(): igual que en el 19, pero la lista sale de senales_visibles()
-- y lleva «contadores»
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
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

COMMIT;
