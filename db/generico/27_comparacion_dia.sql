-- =============================================================================
-- 27. Comparación con el día anterior («Cambios desde ayer»)
-- =============================================================================
-- Qué faltaba: la síntesis del día (26) dice cómo está todo AHORA, pero no qué cambió desde ayer.
-- Quien entra cada mañana tenía que acordarse de lo que vio el día anterior.
--
-- Ahora vigilante.comparacion_dia(cliente) devuelve, para las últimas 24 h:
--   · senales_nuevas: señales activas creadas en las últimas 24 h (código, título, certeza, naturaleza)
--   · subieron_certeza: señales cuya certeza es mayor que hace 24 h (rumor < posible < convocado < confirmado)
--   · bajaron_certeza: lo contrario
--   · resueltas: señales que se cerraron o se descartaron en las últimas 24 h, o cuyo evento o plazo
--       terminó en ese tiempo (dejan de estar vigentes)
--   · conteos: los totales de cada lista (las listas traen como máximo 10 elementos)
--   · historial_desde: desde cuándo hay registro de certezas. Si hace menos de 24 h, subieron/bajaron
--       van vacías porque aún no se puede comparar (se dice, no se inventa)
--
-- Por qué hace falta una tabla nueva: la certeza (24) no se guarda, se CALCULA con las fuentes y el
-- estado de cada señal. updated_at solo dice que algo cambió, no qué certeza tenía ayer. Por eso
-- vigilante.certeza_registro guarda cada cambio de nivel (una fila solo cuando cambia) y la tarea
-- de pg_cron «vigilante-certezas» lo toma cada 15 minutos.
--
-- vigilante_bd() la devuelve como «comparacion_dia»; el panel la muestra como «Cambios desde ayer»
-- (solo si hay algo) y AVIA la usa cuando preguntan qué cambió.
--
-- Necesita el 26. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT jsonb_pretty(vigilante.comparacion_dia(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_comparacion.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 1. Registro de certezas (una fila por cambio de nivel) ----------------------------
CREATE TABLE IF NOT EXISTS vigilante.certeza_registro (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id   bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  nivel       text NOT NULL CHECK (nivel IN ('confirmado', 'convocado', 'posible', 'rumor')),
  desde       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS certeza_registro_signal_idx ON vigilante.certeza_registro (signal_id, desde DESC);
CREATE INDEX IF NOT EXISTS certeza_registro_cliente_idx ON vigilante.certeza_registro (cliente_id, desde);
ALTER TABLE vigilante.certeza_registro ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
COMMENT ON TABLE vigilante.certeza_registro IS 'Historial del grado de certeza de cada señal (27): una fila cada vez que cambia';

CREATE OR REPLACE FUNCTION vigilante._nivel_certeza(p text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'rumor' THEN 1 WHEN 'posible' THEN 2 WHEN 'convocado' THEN 3 WHEN 'confirmado' THEN 4 END
$$;

-- Guarda la certeza actual de las señales activas si cambió desde la última vez. Devuelve cuántas filas añadió.
CREATE OR REPLACE FUNCTION vigilante.registrar_certezas(p_cliente uuid DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_n int := 0;
BEGIN
  WITH act AS (
    SELECT s.id, s.cliente_id, vigilante.certeza(s.id) ->> 'nivel' AS nivel
      FROM vigilante.clientes c
      CROSS JOIN LATERAL vigilante.senales_visibles(c.id) s
     WHERE c.activo AND (p_cliente IS NULL OR c.id = p_cliente) AND s.estado <> 'descartada'
  ), ins AS (
    INSERT INTO vigilante.certeza_registro (signal_id, cliente_id, nivel)
    SELECT a.id, a.cliente_id, a.nivel FROM act a
     WHERE a.nivel IS NOT NULL
       AND a.nivel IS DISTINCT FROM (SELECT r.nivel FROM vigilante.certeza_registro r
                                      WHERE r.signal_id = a.id ORDER BY r.desde DESC, r.id DESC LIMIT 1)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION vigilante.registrar_certezas(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.registrar_certezas(uuid) TO service_role;

-- 2. Comparación con hace 24 h ------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.comparacion_dia(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_desde timestamptz := now() - interval '24 hours';
  v_hist timestamptz; v_vis jsonb; v_nuevas jsonb; v_cambios jsonb; v_resueltas jsonb;
BEGIN
  SELECT min(desde) INTO v_hist FROM vigilante.certeza_registro WHERE cliente_id = p_cliente;

  -- señales activas ahora, con su certeza de ahora y la de hace 24 h (si hay registro)
  SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]') INTO v_vis FROM (
    SELECT s.id, s.codigo, s.titulo, s.naturaleza::text AS naturaleza, s.created_at,
           CASE s.prioridad WHEN 'alta' THEN 0 WHEN 'media' THEN 1 ELSE 2 END AS p,
           vigilante.certeza(s.id) ->> 'nivel' AS ahora,
           (SELECT cr.nivel FROM vigilante.certeza_registro cr
             WHERE cr.signal_id = s.id AND cr.desde <= v_desde ORDER BY cr.desde DESC, cr.id DESC LIMIT 1) AS antes
      FROM vigilante.senales_visibles(p_cliente) s
     WHERE s.estado <> 'descartada') r;

  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'certeza', ahora, 'naturaleza', naturaleza)
                            ORDER BY p, created_at DESC), '[]')
    INTO v_nuevas
    FROM jsonb_to_recordset(v_vis) AS x(id bigint, codigo text, titulo text, naturaleza text, created_at timestamptz, p int, ahora text, antes text)
   WHERE created_at >= v_desde;

  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'antes', antes, 'ahora', ahora,
                                               'sube', vigilante._nivel_certeza(ahora) > vigilante._nivel_certeza(antes))
                            ORDER BY p, created_at DESC), '[]')
    INTO v_cambios
    FROM jsonb_to_recordset(v_vis) AS x(id bigint, codigo text, titulo text, naturaleza text, created_at timestamptz, p int, ahora text, antes text)
   WHERE created_at < v_desde AND antes IS NOT NULL AND ahora IS NOT NULL AND antes <> ahora;

  -- resueltas: cerradas o descartadas en 24 h, o cuyo evento/plazo terminó en 24 h
  SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'como', como) ORDER BY cuando DESC), '[]')
    INTO v_resueltas FROM (
      (SELECT DISTINCT ON (s.id) s.codigo, s.titulo, s.estado::text AS como, h.created_at AS cuando
        FROM vigilante.signals s JOIN vigilante.signal_history h ON h.signal_id = s.id
       WHERE s.cliente_id = p_cliente AND s.estado IN ('cerrada', 'descartada')
         AND h.estado_nuevo = s.estado AND h.estado_anterior IS DISTINCT FROM s.estado AND h.created_at >= v_desde
       ORDER BY s.id, h.created_at DESC)
      UNION ALL
      SELECT s.codigo, s.titulo, 'terminada', greatest(s.plazo_hasta, s.fecha_evento_fin)
        FROM vigilante.signals s
       WHERE s.cliente_id = p_cliente AND s.estado NOT IN ('cerrada', 'descartada')
         AND greatest(s.plazo_hasta, s.fecha_evento_fin) BETWEEN v_desde AND now()
         AND NOT EXISTS (SELECT 1 FROM vigilante.senales_visibles(p_cliente) v WHERE v.id = s.id)
    ) q;

  RETURN jsonb_build_object(
    'generado', now(),
    'desde', v_desde,
    'historial_desde', v_hist,
    'comparable', v_hist IS NOT NULL AND v_hist <= v_desde,
    'conteos', jsonb_build_object(
      'nuevas', jsonb_array_length(v_nuevas),
      'subieron', (SELECT count(*) FROM jsonb_array_elements(v_cambios) e WHERE (e ->> 'sube')::boolean),
      'bajaron', (SELECT count(*) FROM jsonb_array_elements(v_cambios) e WHERE NOT (e ->> 'sube')::boolean),
      'resueltas', jsonb_array_length(v_resueltas)),
    'senales_nuevas', (SELECT coalesce(jsonb_agg(e), '[]') FROM (SELECT e FROM jsonb_array_elements(v_nuevas) WITH ORDINALITY a(e, i) ORDER BY i LIMIT 10) q),
    'subieron_certeza', (SELECT coalesce(jsonb_agg(e - 'sube'), '[]') FROM (SELECT e FROM jsonb_array_elements(v_cambios) WITH ORDINALITY a(e, i) WHERE (e ->> 'sube')::boolean ORDER BY i LIMIT 10) q),
    'bajaron_certeza', (SELECT coalesce(jsonb_agg(e - 'sube'), '[]') FROM (SELECT e FROM jsonb_array_elements(v_cambios) WITH ORDINALITY a(e, i) WHERE NOT (e ->> 'sube')::boolean ORDER BY i LIMIT 10) q),
    'resueltas', (SELECT coalesce(jsonb_agg(e), '[]') FROM (SELECT e FROM jsonb_array_elements(v_resueltas) WITH ORDINALITY a(e, i) ORDER BY i LIMIT 10) q));
END $$;
REVOKE ALL ON FUNCTION vigilante.comparacion_dia(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.comparacion_dia(uuid) TO service_role;

-- 3. vigilante.json / vigilante_bd(): igual que en el 26, con «comparacion_dia»
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
                       'certeza', vigilante.certeza(s.id),
                       'recomendacion_segura', vigilante.recomendacion_segura(s.id),
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente),
    'sintesis_dia', vigilante.sintesis_dia(p_cliente),
    'comparacion_dia', vigilante.comparacion_dia(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

-- 4. Primera foto de las certezas (a partir de aquí, en 24 h ya se puede comparar)
SELECT vigilante.registrar_certezas() AS certezas_registradas;

COMMIT;

-- 5. Tarea de pg_cron (fuera de la transacción; solo en Supabase) -----------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-certezas', '*/15 * * * *', 'SELECT vigilante.registrar_certezas()');
    RAISE NOTICE 'Tarea programada: vigilante-certezas (cada 15 minutos)';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
