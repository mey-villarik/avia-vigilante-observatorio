-- =============================================================================
-- 46. Evolución del Pulso a 7 y a 30 días (DIANA 2.3)
-- =============================================================================
-- Qué faltaba (Diana, 2026-11-22): el recuadro Pulso del panel decía cómo están los riesgos y las
-- oportunidades AHORA, pero no si van a mejor o a peor. Hay que ver el valor de hace 7 días y el de
-- hace 30 días y si el indicador mejora, empeora o está estable.
--
-- Qué hace este script:
--   1. vigilante._pulso_en(cliente, momento): el Pulso tal como estaba en ese momento, con las
--      MISMAS reglas que web/src/lib/pulso.ts (calcularPulso). Reconstruye las señales de ese día:
--      las que ya existían, el estado que tenían (signal_history), si seguían vigentes (fechas o
--      24 h desde la última noticia) y si su revisión ya había vencido.
--      Límite conocido: la prioridad, la relevancia, la novedad y la fiabilidad son las de hoy
--      (la base no guarda su historial). Por eso los días reconstruidos van marcados.
--   2. vigilante.pulso_registro: una fila por cliente y día (hora de Bolivia) con los dos índices,
--      el nivel de vigilancia y las cifras. La tarea de pg_cron «vigilante-pulso» la actualiza cada
--      hora; el valor que queda de cada día es el de la última hora del día.
--   3. vigilante.reconstruir_pulso(cliente, dias): rellena los 30 días anteriores (marcados como
--      reconstruidos) para que la evolución se vea desde hoy y no dentro de un mes. No inventa
--      días anteriores a la primera señal del cliente: esos quedan «sin datos».
--   4. vigilante.pulso_evolucion(cliente): hoy, hace 7 días, hace 30 días y la serie diaria.
--      Va en vigilante_bd() / vigilante.json como «pulso_evolucion». El panel compara su Pulso de
--      ahora con esos valores; AVIA los cita si le preguntan por la tendencia.
--
-- Mejora / empeora / estable (lo decide el panel, web/src/lib/pulso.ts → tendencia()):
--   · una diferencia de menos de 5 puntos es «estable»;
--   · Atención a riesgos: si sube, EMPEORA; si baja, MEJORA;
--   · Oportunidad: si sube, MEJORA; si baja, EMPEORA.
--
-- Si se cambia una regla del Pulso en web/src/lib/pulso.ts, hay que cambiarla también en
-- _pulso_en() (aquí abajo) y en docs/pulso.md.
--
-- Necesita el 27 (y lo anterior). Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT jsonb_pretty(vigilante.pulso_evolucion(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_pulso_evolucion.sql (termina en ROLLBACK).
-- Se puede ejecutar más de una vez.
-- =============================================================================
BEGIN;

-- 1. Registro diario -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.pulso_registro (
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  dia             date NOT NULL,                 -- día en hora de Bolivia
  riesgo          int  NOT NULL CHECK (riesgo BETWEEN 0 AND 100),
  oportunidad     int  NOT NULL CHECK (oportunidad BETWEEN 0 AND 100),
  vigilancia      text NOT NULL CHECK (vigilancia IN ('Normal', 'Vigilancia', 'Atención', 'Crítico')),
  activas         int  NOT NULL DEFAULT 0,
  riesgos         int  NOT NULL DEFAULT 0,
  oportunidades   int  NOT NULL DEFAULT 0,
  reconstruido    boolean NOT NULL DEFAULT false, -- true = calculado después con el historial de las señales
  registrado_en   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cliente_id, dia)
);
ALTER TABLE vigilante.pulso_registro ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
COMMENT ON TABLE vigilante.pulso_registro IS 'Pulso del observatorio por día (46): índices de riesgo y oportunidad para ver la evolución a 7 y 30 días';

-- número seguro desde el JSON del modelo («7», 7, «7.5»; lo demás → 0, como hace la web con ?? 0)
CREATE OR REPLACE FUNCTION vigilante._num(p text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^\s*-?\d+(\.\d+)?\s*$' THEN p::numeric ELSE 0 END
$$;

-- 2. El Pulso en un momento dado ---------------------------------------------------------
-- Mismas reglas que calcularPulso() (web/src/lib/pulso.ts):
--   riesgo      = prioridad (alta 1 · media 0,5 · baja 0,2) × respaldo (0,5 + 0,5 × fiabilidad/100)
--                 × etapa (confirmada/publicada 1 · en verificación 0,85 · resto 0,7; 1 si la revisión venció)
--                 × 0,5 si es mixta
--   oportunidad = valor (45 % relevancia + 25 % novedad + 30 % fiabilidad, sobre 10) × etapa
--                 × 0,5 si es mixta × 0,5 si es escenario
--   índice      = round(100 × suma ÷ (n + 2))
CREATE OR REPLACE FUNCTION vigilante._pulso_en(p_cliente uuid, p_momento timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH base AS (
    SELECT s.id, s.created_at, s.requiere_revision, s.es_escenario,
           CASE WHEN s.naturaleza::text IN ('riesgo', 'oportunidad') THEN s.naturaleza::text ELSE 'mixta' END AS nat,
           s.prioridad::text AS prio,
           coalesce(s.salida_modelo ->> 'rel', s.salida_modelo ->> 'relevancia') AS rel_t,
           coalesce(s.salida_modelo ->> 'nov', s.salida_modelo ->> 'novedad') AS nov_t,
           -- estado que tenía en ese momento: el último cambio anterior; si no lo hay, el «antes» del primer
           -- cambio posterior; si nunca cambió, el de ahora
           coalesce(
             (SELECT h.estado_nuevo FROM vigilante.signal_history h
               WHERE h.signal_id = s.id AND h.entidad = 'signal' AND h.estado_nuevo IS NOT NULL AND h.created_at <= p_momento
               ORDER BY h.created_at DESC, h.id DESC LIMIT 1),
             (SELECT h.estado_anterior FROM vigilante.signal_history h
               WHERE h.signal_id = s.id AND h.entidad = 'signal' AND h.estado_anterior IS NOT NULL AND h.created_at > p_momento
               ORDER BY h.created_at, h.id LIMIT 1),
             s.estado)::text AS est
      FROM vigilante.signals s
     WHERE s.cliente_id = p_cliente
       AND s.created_at <= p_momento
       AND s.created_at >= p_momento - make_interval(months => vigilante._entero(vigilante.param(p_cliente, 'retencion_meses'), 6))
       -- vigente en ese momento (igual que senal_vigente, con «ese día» en lugar de «hoy»)
       AND CASE
             WHEN coalesce(s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin) IS NOT NULL
               THEN (greatest(s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin) AT TIME ZONE 'UTC')::date
                    >= (p_momento AT TIME ZONE 'America/La_Paz')::date
             ELSE greatest(s.created_at, (SELECT max(r.recolectado_en) FROM vigilante.signal_raw_items sr
                                            JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                           WHERE sr.signal_id = s.id AND r.recolectado_en <= p_momento))
                  >= p_momento - interval '24 hours'
           END
       -- una ficha de oportunidad con el plazo ya vencido se lleva su señal (como senales_visibles)
       AND NOT (s.naturaleza <> 'riesgo' AND EXISTS (
             SELECT 1 FROM vigilante.oportunidades o
              WHERE o.signal_id = s.id AND o.estado <> 'descartada' AND o.plazo_hasta IS NOT NULL
                AND (o.plazo_hasta AT TIME ZONE 'America/La_Paz')::date < (p_momento AT TIME ZONE 'America/La_Paz')::date))
  ),
  act AS (
    SELECT b.*,
           least(100, greatest(0, coalesce((vigilante.puntuaciones(b.id) -> 'fiabilidad' ->> 'valor')::numeric, 0))) AS fia,
           CASE WHEN b.est IN ('confirmada', 'publicada') THEN 1 WHEN b.est = 'en_verificacion' THEN 0.85 ELSE 0.7 END AS etapa,
           (b.requiere_revision AND b.est IN ('detectada', 'en_analisis', 'en_verificacion')
              AND vigilante.calcular_vencimiento(p_cliente, b.created_at) <= p_momento) AS vencida
      FROM base b
     WHERE b.est NOT IN ('descartada', 'cerrada')
  ),
  r AS (
    SELECT count(*) AS n,
           coalesce(sum(CASE prio WHEN 'alta' THEN 1 WHEN 'baja' THEN 0.2 ELSE 0.5 END
                        * (0.5 + 0.5 * fia / 100)
                        * CASE WHEN vencida THEN 1 ELSE etapa END
                        * CASE WHEN nat = 'mixta' THEN 0.5 ELSE 1 END), 0) AS suma,
           count(*) FILTER (WHERE nat = 'riesgo' AND prio = 'alta' AND est IN ('confirmada', 'publicada')) AS altos_verificados
      FROM act WHERE nat <> 'oportunidad'
  ),
  o AS (
    SELECT count(*) AS n,
           coalesce(sum(least(1, greatest(0, (vigilante._num(rel_t) * 0.45 + vigilante._num(nov_t) * 0.25 + fia / 100 * 10 * 0.3) / 10))
                        * etapa
                        * CASE WHEN nat = 'mixta' THEN 0.5 ELSE 1 END
                        * CASE WHEN es_escenario THEN 0.5 ELSE 1 END), 0) AS suma
      FROM act WHERE nat <> 'riesgo'
  ),
  i AS (
    SELECT round(100 * r.suma / (r.n + 2))::int AS riesgo, round(100 * o.suma / (o.n + 2))::int AS oportunidad,
           r.n AS n_r, o.n AS n_o, r.altos_verificados AS av,
           (SELECT count(*) FROM act) AS activas
      FROM r, o
  ),
  v AS (
    SELECT i.*,
           CASE WHEN riesgo >= 75 THEN 'Crítico' WHEN riesgo >= 50 THEN 'Atención' WHEN riesgo >= 25 THEN 'Vigilancia' ELSE 'Normal' END AS nivel
      FROM i
  )
  SELECT jsonb_build_object(
    'momento', p_momento,
    'dia', (p_momento AT TIME ZONE 'America/La_Paz')::date,
    'riesgo', riesgo,
    'oportunidad', oportunidad,
    -- mínimos por volumen: 1 riesgo alto verificado → al menos Vigilancia; 5 o más → al menos Atención
    'vigilancia', CASE
                    WHEN av >= 5 AND nivel IN ('Normal', 'Vigilancia') THEN 'Atención'
                    WHEN av >= 1 AND nivel = 'Normal' THEN 'Vigilancia'
                    ELSE nivel END,
    'activas', activas, 'riesgos', n_r, 'oportunidades', n_o)
  FROM v
$$;
REVOKE ALL ON FUNCTION vigilante._pulso_en(uuid, timestamptz) FROM public, anon, authenticated;

-- fin del día p_dia en Bolivia (o ahora, si es hoy)
CREATE OR REPLACE FUNCTION vigilante._fin_dia_bo(p_dia date)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT least(now(), ((p_dia + 1)::timestamp AT TIME ZONE 'America/La_Paz') - interval '1 second')
$$;

-- primer día con señales del cliente (antes de eso no hay Pulso que mostrar)
CREATE OR REPLACE FUNCTION vigilante._pulso_desde(p_cliente uuid)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT (min(created_at) AT TIME ZONE 'America/La_Paz')::date FROM vigilante.signals WHERE cliente_id = p_cliente
$$;
REVOKE ALL ON FUNCTION vigilante._pulso_desde(uuid) FROM public, anon, authenticated;

-- 3. Guardar el de hoy (la tarea lo llama cada hora; el último valor del día es el que queda) ----
CREATE OR REPLACE FUNCTION vigilante.registrar_pulso(p_cliente uuid DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE c record; p jsonb; n int := 0;
BEGIN
  FOR c IN SELECT id FROM vigilante.clientes WHERE activo AND (p_cliente IS NULL OR id = p_cliente) LOOP
    p := vigilante._pulso_en(c.id, now());
    INSERT INTO vigilante.pulso_registro AS pr (cliente_id, dia, riesgo, oportunidad, vigilancia, activas, riesgos, oportunidades, reconstruido, registrado_en)
    VALUES (c.id, (p ->> 'dia')::date, (p ->> 'riesgo')::int, (p ->> 'oportunidad')::int, p ->> 'vigilancia',
            (p ->> 'activas')::int, (p ->> 'riesgos')::int, (p ->> 'oportunidades')::int, false, now())
    ON CONFLICT (cliente_id, dia) DO UPDATE
      SET riesgo = EXCLUDED.riesgo, oportunidad = EXCLUDED.oportunidad, vigilancia = EXCLUDED.vigilancia,
          activas = EXCLUDED.activas, riesgos = EXCLUDED.riesgos, oportunidades = EXCLUDED.oportunidades,
          reconstruido = false, registrado_en = now();
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION vigilante.registrar_pulso(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.registrar_pulso(uuid) TO service_role;

-- Rellenar los días anteriores con el historial de las señales (no pisa lo ya registrado)
CREATE OR REPLACE FUNCTION vigilante.reconstruir_pulso(p_cliente uuid DEFAULT NULL, p_dias int DEFAULT 30)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE c record; d date; hoy date := (now() AT TIME ZONE 'America/La_Paz')::date; desde date; p jsonb; n int := 0;
BEGIN
  FOR c IN SELECT id FROM vigilante.clientes WHERE activo AND (p_cliente IS NULL OR id = p_cliente) LOOP
    desde := vigilante._pulso_desde(c.id);
    CONTINUE WHEN desde IS NULL;
    FOR d IN SELECT g::date FROM generate_series(greatest(desde, hoy - p_dias), hoy - 1, interval '1 day') g LOOP
      CONTINUE WHEN EXISTS (SELECT 1 FROM vigilante.pulso_registro WHERE cliente_id = c.id AND dia = d);
      p := vigilante._pulso_en(c.id, vigilante._fin_dia_bo(d));
      INSERT INTO vigilante.pulso_registro (cliente_id, dia, riesgo, oportunidad, vigilancia, activas, riesgos, oportunidades, reconstruido)
      VALUES (c.id, d, (p ->> 'riesgo')::int, (p ->> 'oportunidad')::int, p ->> 'vigilancia',
              (p ->> 'activas')::int, (p ->> 'riesgos')::int, (p ->> 'oportunidades')::int, true);
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION vigilante.reconstruir_pulso(uuid, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.reconstruir_pulso(uuid, int) TO service_role;

-- 4. Evolución: hoy, hace 7 días, hace 30 días y la serie -----------------------------
CREATE OR REPLACE FUNCTION vigilante._pulso_dia(p_cliente uuid, p_dia date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
    WHEN p_dia < vigilante._pulso_desde(p_cliente) OR vigilante._pulso_desde(p_cliente) IS NULL THEN NULL
    ELSE coalesce(
      (SELECT jsonb_build_object('dia', dia, 'riesgo', riesgo, 'oportunidad', oportunidad, 'vigilancia', vigilancia,
                                 'activas', activas, 'riesgos', riesgos, 'oportunidades', oportunidades, 'reconstruido', reconstruido)
         FROM vigilante.pulso_registro WHERE cliente_id = p_cliente AND dia = p_dia),
      -- sin fila (aún no se ejecutó la tarea ni la reconstrucción): se calcula al momento
      vigilante._pulso_en(p_cliente, vigilante._fin_dia_bo(p_dia)) - 'momento' || jsonb_build_object('reconstruido', true))
  END
$$;
REVOKE ALL ON FUNCTION vigilante._pulso_dia(uuid, date) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.pulso_evolucion(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH h AS (SELECT (now() AT TIME ZONE 'America/La_Paz')::date AS hoy)
  SELECT jsonb_build_object(
    'hoy', vigilante._pulso_en(p_cliente, now()) - 'momento',
    'hace_7', vigilante._pulso_dia(p_cliente, (SELECT hoy - 7 FROM h)),
    'hace_30', vigilante._pulso_dia(p_cliente, (SELECT hoy - 30 FROM h)),
    'desde', vigilante._pulso_desde(p_cliente),
    -- desde qué día el valor se guardó en el momento (antes: reconstruido con el historial de las señales)
    'registro_desde', (SELECT min(dia) FROM vigilante.pulso_registro WHERE cliente_id = p_cliente AND NOT reconstruido),
    'umbral_estable', 5,
    'serie', (SELECT coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'riesgo', riesgo, 'oportunidad', oportunidad,
                                                           'reconstruido', reconstruido) ORDER BY dia), '[]')
                FROM vigilante.pulso_registro, h
               WHERE cliente_id = p_cliente AND dia BETWEEN h.hoy - 30 AND h.hoy))
$$;
REVOKE ALL ON FUNCTION vigilante.pulso_evolucion(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.pulso_evolucion(uuid) TO service_role;

-- 5. vigilante.json / vigilante_bd(): igual que en el 27, con «pulso_evolucion» ---------
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
    'comparacion_dia', vigilante.comparacion_dia(p_cliente),
    'pulso_evolucion', vigilante.pulso_evolucion(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

-- 6. Hoy y los 30 días anteriores, para que la evolución se vea ya ----------------------
SELECT vigilante.registrar_pulso() AS pulso_hoy, vigilante.reconstruir_pulso(NULL, 30) AS dias_reconstruidos;

COMMIT;

-- 7. Tarea de pg_cron (fuera de la transacción; solo en Supabase) -----------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-pulso', '7 * * * *', 'SELECT vigilante.registrar_pulso()');
    RAISE NOTICE 'Tarea programada: vigilante-pulso (cada hora, minuto 7)';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
