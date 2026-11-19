-- =============================================================================
-- 28. Eventos compuestos: señales que se juntan en el mismo lugar y en las mismas fechas
-- =============================================================================
-- Qué faltaba: cada señal se veía sola. Una huelga en La Paz y una lluvia fuerte prevista en La Paz
-- el mismo fin de semana eran dos tarjetas distintas; nadie decía «ojo, se juntan».
--
-- Ahora hay tres piezas, y cada una hace solo lo suyo:
--
--   1. LA BASE DETECTA (sin IA): vigilante.componer_eventos() busca señales activas que coinciden
--      en territorio y en ventana de fechas, y crea o actualiza un EVENTO COMPUESTO (EVC-0001…) con:
--        · las señales que lo forman
--        · el tipo de correlación: riesgo_acumulado / oportunidad_combinada / confluencia (riesgo + oportunidad)
--        · una prioridad calculada (0-100, con el desglose guardado para poder explicarla)
--      La llama pg_cron cada 5 minutos y el analizador al terminar cada ronda.
--
--   2. HERMES INTERPRETA (el cerebro): con la skill «interpretar-eventos» y el MCP del Vigilante,
--      Hermes toma los eventos pendientes (eventos_por_interpretar) y decide qué significan para el
--      turismo, a quién afectan y qué se recomienda hacer (guardar_interpretacion_evento). Hermes
--      también puede decir que NO es una confluencia real (lo descarta con el motivo) o subir o bajar
--      la prioridad un nivel con su motivo. La base solo comprueba que la respuesta está completa.
--
--   3. EL PANEL AVISA: vigilante.eventos_emergentes() devuelve los eventos abiertos con su
--      interpretación; los de prioridad alta salen como alerta emergente en el panel hasta que cada
--      persona pulsa «Entendido» (marcar_evento_visto). Si Hermes añade señales nuevas al evento, la
--      versión sube y el aviso vuelve a salir.
--
-- Esto es INTERNO (panel del equipo). Nada sale a la web pública ni a Telegram sin aprobación humana.
--
-- Cómo se forma la ventana de cada señal:
--   · con fechas del evento: del inicio al fin (sin fin, el día del inicio entero)
--   · sin fechas del evento: desde la última noticia hasta «eventos_horizonte_horas» después (72 h)
--   · el plazo de una convocatoria NO cuenta: es una fecha límite, no algo que pase en el territorio
--   · una OPORTUNIDAD sin fechas de evento no entra (salvo «eventos_oportunidad_sin_fecha» = true):
--     un anuncio o una programación habitual no coincide con nada en el tiempo
-- Territorio: el departamento de la señal (una ciudad o zona cuenta en su departamento). Las señales
-- nacionales (alcance_total o territorio «país») se suman a los departamentos que ya tienen alguna
-- señal propia en esa ventana, si «eventos_incluir_nacional» es true. Un evento necesita 2 señales o
-- más y al menos una del propio departamento.
--
-- Necesita del 01 al 27. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT vigilante.componer_eventos('orbita-bolivia');
--            SELECT codigo, tipo, territorio_nombre, prioridad, estado FROM vigilante.eventos_compuestos;
-- Prueba: 99_prueba_eventos.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 0. Parámetros (cada cliente puede sobrescribirlos) ---------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'eventos_horizonte_horas', '72', 'Ventana de una señal sin fechas de evento: desde la última noticia hasta estas horas después'),
  (NULL, 'eventos_anticipacion_dias', '30', 'Solo se juntan señales cuya ventana empieza antes de estos días desde hoy'),
  (NULL, 'eventos_incluir_nacional', 'true', 'Las señales nacionales se suman a los departamentos que ya tienen alguna señal propia'),
  (NULL, 'eventos_umbral_alta', '70', 'Prioridad calculada desde la que un evento es «alta» (sale como alerta emergente)'),
  (NULL, 'eventos_umbral_media', '45', 'Prioridad calculada desde la que un evento es «media»'),
  (NULL, 'eventos_espera_hermes_min', '20', 'Minutos que el panel espera la interpretación de Hermes antes de avisar igualmente'),
  (NULL, 'eventos_oportunidad_sin_fecha', 'false', 'Si es false, una oportunidad sin fechas de evento (un anuncio, una programación habitual) no entra en eventos: no es algo que pase en unas fechas')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Tabla de eventos compuestos -------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.eventos_compuestos (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id         uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  codigo             text NOT NULL,                                   -- EVC-0001
  tipo               text NOT NULL CHECK (tipo IN ('riesgo_acumulado', 'oportunidad_combinada', 'confluencia')),
  territorio_id      integer NOT NULL,
  territorio_nombre  text NOT NULL,
  ventana_inicio     timestamptz NOT NULL,
  ventana_fin        timestamptz NOT NULL,
  senal_ids          bigint[] NOT NULL CHECK (cardinality(senal_ids) >= 2),
  -- prioridad calculada por la base (reglas fijas) y, si la da, la de Hermes (un nivel arriba o abajo, con motivo)
  puntaje            numeric(5,1) NOT NULL CHECK (puntaje BETWEEN 0 AND 100),
  prioridad_calculada vigilante.prioridad NOT NULL,
  calculo            jsonb NOT NULL DEFAULT '{}',                    -- desglose del puntaje, para «¿cómo se calcula?»
  prioridad_hermes   vigilante.prioridad,
  prioridad          vigilante.prioridad GENERATED ALWAYS AS (coalesce(prioridad_hermes, prioridad_calculada)) STORED,
  -- ciclo de vida
  estado             text NOT NULL DEFAULT 'por_interpretar'
                       CHECK (estado IN ('por_interpretar', 'interpretando', 'interpretado', 'descartado', 'cerrado')),
  version            integer NOT NULL DEFAULT 1,                     -- sube cuando entran señales nuevas
  motivo_cierre      text,
  -- lo que escribe Hermes
  titular            text,                                           -- «Confluencia en La Paz: huelga + lluvia prevista»
  interpretacion     jsonb,                                          -- significado, a quién afecta, recomendación…
  interpretado_por   text,
  interpretado_en    timestamptz,
  tomado_en          timestamptz,                                    -- Hermes lo reservó (vuelve a la cola a los 30 min)
  descartado_por     text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, codigo),
  FOREIGN KEY (cliente_id, territorio_id) REFERENCES vigilante.territorios(cliente_id, id) ON DELETE CASCADE,
  CHECK (ventana_fin >= ventana_inicio)
);
CREATE INDEX IF NOT EXISTS eventos_compuestos_abiertos_idx ON vigilante.eventos_compuestos (cliente_id, territorio_id)
  WHERE estado IN ('por_interpretar', 'interpretando', 'interpretado');
CREATE INDEX IF NOT EXISTS eventos_compuestos_senales_idx ON vigilante.eventos_compuestos USING gin (senal_ids);
DROP TRIGGER IF EXISTS b_updated_at ON vigilante.eventos_compuestos;
CREATE TRIGGER b_updated_at BEFORE UPDATE ON vigilante.eventos_compuestos
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
ALTER TABLE vigilante.eventos_compuestos ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
COMMENT ON TABLE vigilante.eventos_compuestos IS
  'Eventos compuestos (28): 2 o más señales que coinciden en territorio y fechas. La base los detecta, Hermes los interpreta';

-- Quién vio cada versión del aviso (para no repetir la alerta emergente a la misma persona)
CREATE TABLE IF NOT EXISTS vigilante.eventos_vistos (
  evento_id  bigint NOT NULL REFERENCES vigilante.eventos_compuestos(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES vigilante.users(id) ON DELETE CASCADE,
  version    integer NOT NULL,
  visto_en   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (evento_id, user_id)
);
ALTER TABLE vigilante.eventos_vistos ENABLE ROW LEVEL SECURITY;

-- 2. Ventana y territorio de cada señal activa ------------------------------------------
-- Una fila por (señal, departamento). nacional = true si la señal es de todo el país.
CREATE OR REPLACE FUNCTION vigilante._senales_para_eventos(p_cliente uuid)
RETURNS TABLE (signal_id bigint, territorio_id integer, nacional boolean, ini timestamptz, fin timestamptz,
               naturaleza vigilante.naturaleza_senal, prioridad vigilante.prioridad, categoria text,
               certeza text, oficial boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH p AS (
    SELECT vigilante._entero(vigilante.param(p_cliente, 'eventos_horizonte_horas'), 72) AS horas,
           vigilante._entero(vigilante.param(p_cliente, 'eventos_anticipacion_dias'), 30) AS dias
  ), s AS (
    SELECT v.id, v.naturaleza, v.prioridad, v.categoria, v.alcance_total, v.fuente_oficial,
           (v.fecha_evento_inicio IS NOT NULL OR v.fecha_evento_fin IS NOT NULL) AS con_fecha,
           CASE WHEN v.fecha_evento_inicio IS NOT NULL OR v.fecha_evento_fin IS NOT NULL
                THEN coalesce(v.fecha_evento_inicio, v.fecha_evento_fin)
                ELSE vigilante.ultima_noticia(v.id, v.created_at) END AS ini,
           CASE WHEN v.fecha_evento_inicio IS NOT NULL OR v.fecha_evento_fin IS NOT NULL
                -- fechas sin hora se guardan a medianoche UTC: el día entero cuenta (hasta el final del día de Bolivia)
                THEN ((coalesce(v.fecha_evento_fin, v.fecha_evento_inicio) AT TIME ZONE 'UTC')::date + 1)::timestamp
                       AT TIME ZONE 'America/La_Paz'
                ELSE vigilante.ultima_noticia(v.id, v.created_at) + make_interval(hours => (SELECT horas FROM p)) END AS fin
      FROM vigilante.senales_visibles(p_cliente) v
     WHERE v.estado NOT IN ('descartada', 'cerrada') AND v.duplicado_de IS NULL
  ), t AS (
    -- departamento de cada señal: una ciudad o zona cuenta en su padre; «país» = nacional
    SELECT st.signal_id, CASE WHEN te.nivel = 'pais' THEN NULL
                              WHEN te.nivel = 'region' OR te.padre_id IS NULL THEN te.id
                              ELSE te.padre_id END AS territorio_id,
           te.nivel = 'pais' AS es_pais
      FROM vigilante.signal_territorios st JOIN vigilante.territorios te ON te.id = st.territorio_id
     WHERE st.signal_id IN (SELECT id FROM s)
  )
  SELECT DISTINCT s.id, t.territorio_id, (s.alcance_total OR coalesce(t.es_pais, false)) AS nacional, s.ini, s.fin,
         s.naturaleza, s.prioridad, s.categoria, vigilante.certeza(s.id) ->> 'nivel', s.fuente_oficial
    FROM s LEFT JOIN t ON t.signal_id = s.id
   WHERE s.fin >= now()                                                  -- aún no ha pasado
     AND s.ini <= now() + make_interval(days => (SELECT dias FROM p))   -- no demasiado lejos
     AND (t.territorio_id IS NOT NULL OR s.alcance_total OR coalesce(t.es_pais, false))
     AND (s.con_fecha OR s.naturaleza <> 'oportunidad'
          OR coalesce((vigilante.param(p_cliente, 'eventos_oportunidad_sin_fecha'))::text, 'false') IN ('true', '"true"'))
$$;
REVOKE ALL ON FUNCTION vigilante._senales_para_eventos(uuid) FROM public, anon, authenticated;

-- 3. Puntaje de un grupo de señales (reglas fijas, explicables) -------------------------
--   peso de cada señal = prioridad (alta 3, media 2, baja 1) × certeza (confirmado 1, convocado 0,8, posible 0,5, rumor 0,25)
--   dentro de una misma categoría, la señal más fuerte cuenta entera y cada una de las demás la mitad
--   (varias notas del mismo tema no deben inflar el evento como si fueran riesgos distintos)
--   puntaje = 10 × suma de pesos
--           + 8 por cada categoría distinta después de la primera (riesgos de distinto tipo se suman)
--           + 15 si la ventana común ya empezó o empieza en 48 h; + 8 si empieza en 7 días
--           + 5 si alguna señal viene de fuente oficial
--   máximo 100. Nivel: ≥ eventos_umbral_alta = alta; ≥ eventos_umbral_media = media; si no, baja.
CREATE OR REPLACE FUNCTION vigilante._puntaje_evento(p_cliente uuid, p_ids bigint[], p_inicio timestamptz)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH m AS (
    SELECT s.id, s.codigo, s.prioridad, s.categoria, s.fuente_oficial,
           vigilante.certeza(s.id) ->> 'nivel' AS certeza
      FROM vigilante.signals s WHERE s.id = ANY (p_ids)
  ), w AS (
    SELECT m.*, (CASE m.prioridad WHEN 'alta' THEN 3 WHEN 'media' THEN 2 ELSE 1 END)
              * (CASE m.certeza WHEN 'confirmado' THEN 1 WHEN 'convocado' THEN 0.8 WHEN 'posible' THEN 0.5 ELSE 0.25 END) AS peso
      FROM m
  ), wc AS (
    SELECT w.*, CASE WHEN row_number() OVER (PARTITION BY categoria ORDER BY peso DESC, id) = 1 THEN 1 ELSE 0.5 END AS factor
      FROM w
  ), r AS (
    SELECT round(10 * sum(peso * factor), 1) AS base,
           8 * greatest(count(DISTINCT categoria) - 1, 0) AS categorias,
           CASE WHEN p_inicio <= now() + interval '48 hours' THEN 15
                WHEN p_inicio <= now() + interval '7 days' THEN 8 ELSE 0 END AS proximidad,
           CASE WHEN bool_or(fuente_oficial) THEN 5 ELSE 0 END AS oficial,
           jsonb_agg(jsonb_build_object('senal', codigo, 'prioridad', prioridad, 'certeza', coalesce(certeza, 'rumor'),
                                        'peso', round(peso * factor, 2)) ORDER BY peso * factor DESC) AS detalle
      FROM wc
  )
  SELECT jsonb_build_object(
           'puntaje', least(100, base + categorias + proximidad + oficial),
           'prioridad', CASE WHEN least(100, base + categorias + proximidad + oficial)
                                  >= vigilante._entero(vigilante.param(p_cliente, 'eventos_umbral_alta'), 70) THEN 'alta'
                             WHEN least(100, base + categorias + proximidad + oficial)
                                  >= vigilante._entero(vigilante.param(p_cliente, 'eventos_umbral_media'), 45) THEN 'media'
                             ELSE 'baja' END,
           'calculo', jsonb_build_object('senales', base, 'categorias_distintas', categorias, 'proximidad', proximidad,
                                         'fuente_oficial', oficial, 'detalle', detalle,
                                         'regla', '10 × Σ(prioridad × certeza; en la misma categoría, las demás señales cuentan la mitad) + 8 por categoría extra + proximidad (15 en 48 h, 8 en 7 días) + 5 si hay fuente oficial; máx. 100'))
    FROM r
$$;
REVOKE ALL ON FUNCTION vigilante._puntaje_evento(uuid, bigint[], timestamptz) FROM public, anon, authenticated;

-- 4. El compositor ----------------------------------------------------------------------
-- Junta por departamento las señales cuyas ventanas se solapan (como unir intervalos en una línea
-- de tiempo), y para cada grupo de 2 o más crea o actualiza su evento. Los eventos cuyas señales
-- ya no coinciden se cierran. Devuelve cuántos creó, actualizó (con señales nuevas) y cerró.
CREATE OR REPLACE FUNCTION vigilante.componer_eventos(p_cliente text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  c record; g record; v_ev vigilante.eventos_compuestos; v_pt jsonb; v_tipo text; v_nuevas bigint[];
  v_creados int := 0; v_actualizados int := 0; v_cerrados int := 0; v_vistos bigint[]; v_codigo text;
BEGIN
  FOR c IN SELECT id, slug FROM vigilante.clientes
            WHERE activo AND (p_cliente IS NULL OR slug = p_cliente) LOOP
    PERFORM set_config('vigilante.actor', 'compositor', true);
    -- solo un compositor a la vez por cliente (pg_cron y el analizador pueden coincidir)
    IF NOT pg_try_advisory_xact_lock(hashtext('vigilante.componer_eventos'), hashtext(c.id::text)) THEN
      CONTINUE;
    END IF;
    v_vistos := '{}';

    FOR g IN
      WITH base AS (SELECT * FROM vigilante._senales_para_eventos(c.id)),
      locales AS (SELECT * FROM base WHERE territorio_id IS NOT NULL AND NOT nacional),
      nacionales AS (SELECT DISTINCT ON (signal_id) * FROM base WHERE nacional
                      AND coalesce((vigilante.param(c.id, 'eventos_incluir_nacional'))::text, 'true') NOT IN ('false', '"false"')),
      -- cada señal nacional se suma a los departamentos que ya tienen una señal propia
      filas AS (
        SELECT l.signal_id, l.territorio_id, false AS nacional, l.ini, l.fin, l.naturaleza FROM locales l
        UNION
        SELECT n.signal_id, d.territorio_id, true, n.ini, n.fin, n.naturaleza
          FROM nacionales n CROSS JOIN (SELECT DISTINCT territorio_id FROM locales) d
      ),
      -- unir intervalos: empieza un grupo nuevo cuando la ventana empieza después de que terminaron todas las anteriores
      ord AS (
        SELECT f.*, max(f.fin) OVER (PARTITION BY f.territorio_id ORDER BY f.ini, f.signal_id
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS fin_previo
          FROM filas f
      ),
      islas AS (
        SELECT o.*, sum(CASE WHEN o.fin_previo IS NULL OR o.ini > o.fin_previo THEN 1 ELSE 0 END)
                      OVER (PARTITION BY o.territorio_id ORDER BY o.ini, o.signal_id) AS isla
          FROM ord o
      )
      SELECT i.territorio_id, te.nombre AS territorio_nombre,
             array_agg(DISTINCT i.signal_id ORDER BY i.signal_id) AS ids,
             min(i.ini) AS ini, max(i.fin) AS fin,
             bool_and(i.naturaleza = 'riesgo') AS solo_riesgo,
             bool_and(i.naturaleza = 'oportunidad') AS solo_oportunidad
        FROM islas i JOIN vigilante.territorios te ON te.id = i.territorio_id
       GROUP BY i.territorio_id, te.nombre, i.isla
      HAVING count(DISTINCT i.signal_id) >= 2 AND bool_or(NOT i.nacional)
    LOOP
      v_tipo := CASE WHEN g.solo_riesgo THEN 'riesgo_acumulado'
                     WHEN g.solo_oportunidad THEN 'oportunidad_combinada'
                     ELSE 'confluencia' END;
      v_pt := vigilante._puntaje_evento(c.id, g.ids, g.ini);

      -- ¿ya hay un evento (abierto o descartado por Hermes) con alguna de estas señales en este departamento?
      SELECT * INTO v_ev FROM vigilante.eventos_compuestos e
       WHERE e.cliente_id = c.id AND e.territorio_id = g.territorio_id
         AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado', 'descartado')
         AND e.senal_ids && g.ids AND NOT (e.id = ANY (v_vistos))
       ORDER BY (e.estado <> 'descartado') DESC, (SELECT count(*) FROM unnest(e.senal_ids) x WHERE x = ANY (g.ids)) DESC, e.id DESC
       LIMIT 1;

      IF v_ev.id IS NULL THEN
        SELECT 'EVC-' || lpad((coalesce(max(substring(codigo FROM '^EVC-(\d+)$')::int), 0) + 1)::text, 4, '0')
          INTO v_codigo FROM vigilante.eventos_compuestos WHERE cliente_id = c.id;
        INSERT INTO vigilante.eventos_compuestos (cliente_id, codigo, tipo, territorio_id, territorio_nombre,
                                                  ventana_inicio, ventana_fin, senal_ids, puntaje, prioridad_calculada, calculo)
        VALUES (c.id, v_codigo, v_tipo, g.territorio_id, g.territorio_nombre, g.ini, g.fin, g.ids,
                (v_pt ->> 'puntaje')::numeric, (v_pt ->> 'prioridad')::vigilante.prioridad, v_pt -> 'calculo')
        RETURNING * INTO v_ev;
        v_creados := v_creados + 1;
      ELSE
        v_nuevas := ARRAY(SELECT unnest(g.ids) EXCEPT SELECT unnest(v_ev.senal_ids));
        IF cardinality(v_nuevas) > 0 THEN
          -- entraron señales nuevas: Hermes debe volver a interpretarlo (también si lo había descartado)
          UPDATE vigilante.eventos_compuestos
             SET senal_ids = g.ids, tipo = v_tipo, ventana_inicio = g.ini, ventana_fin = g.fin,
                 puntaje = (v_pt ->> 'puntaje')::numeric, prioridad_calculada = (v_pt ->> 'prioridad')::vigilante.prioridad,
                 calculo = v_pt -> 'calculo', prioridad_hermes = NULL,
                 estado = 'por_interpretar', version = version + 1, tomado_en = NULL, motivo_cierre = NULL, descartado_por = NULL
           WHERE id = v_ev.id;
          v_actualizados := v_actualizados + 1;
        ELSIF v_ev.estado <> 'descartado' THEN
          -- mismas señales o menos: se refrescan ventana y puntaje sin pedir otra interpretación
          UPDATE vigilante.eventos_compuestos
             SET senal_ids = g.ids, tipo = v_tipo, ventana_inicio = g.ini, ventana_fin = g.fin,
                 puntaje = (v_pt ->> 'puntaje')::numeric, prioridad_calculada = (v_pt ->> 'prioridad')::vigilante.prioridad,
                 calculo = v_pt -> 'calculo'
           WHERE id = v_ev.id
             AND (senal_ids, tipo, ventana_inicio, ventana_fin, puntaje, prioridad_calculada)
                 IS DISTINCT FROM (g.ids, v_tipo, g.ini, g.fin, (v_pt ->> 'puntaje')::numeric, (v_pt ->> 'prioridad')::vigilante.prioridad);
        END IF;
      END IF;
      v_vistos := v_vistos || v_ev.id;
      v_ev := NULL;
    END LOOP;

    -- los abiertos que ya no salen en ningún grupo: sus señales dejaron de coincidir o de estar vigentes
    WITH x AS (
      UPDATE vigilante.eventos_compuestos
         SET estado = 'cerrado', motivo_cierre = 'Las señales ya no coinciden o dejaron de estar vigentes'
       WHERE cliente_id = c.id AND estado IN ('por_interpretar', 'interpretando', 'interpretado')
         AND NOT (id = ANY (v_vistos))
      RETURNING 1)
    SELECT v_cerrados + count(*) INTO v_cerrados FROM x;
  END LOOP;

  RETURN jsonb_build_object('creados', v_creados, 'con_senales_nuevas', v_actualizados, 'cerrados', v_cerrados);
END $$;
REVOKE ALL ON FUNCTION vigilante.componer_eventos(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.componer_eventos(text) TO service_role;

-- 5. Ficha de un evento (lo que ven Hermes y el panel) -----------------------------------
CREATE OR REPLACE FUNCTION vigilante._evento_json(p_id bigint, p_con_noticias boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'codigo', e.codigo, 'tipo', e.tipo, 'territorio', e.territorio_nombre,
    'ventana_inicio', e.ventana_inicio, 'ventana_fin', e.ventana_fin,
    'puntaje', e.puntaje, 'prioridad', e.prioridad, 'prioridad_calculada', e.prioridad_calculada,
    'prioridad_hermes', e.prioridad_hermes, 'calculo', e.calculo,
    'estado', e.estado, 'version', e.version, 'titular', e.titular, 'interpretacion', e.interpretacion,
    'interpretado_en', e.interpretado_en, 'detectado', e.created_at, 'actualizado', e.updated_at,
    'senales', (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'codigo', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen, 'naturaleza', s.naturaleza,
                   'categoria', s.categoria, 'prioridad', s.prioridad, 'estado', s.estado,
                   'certeza', vigilante.certeza(s.id), 'nacional', s.alcance_total,
                   'evento_inicio', to_char(s.fecha_evento_inicio AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                   'evento_fin', to_char(s.fecha_evento_fin AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                   'recomendacion', s.recomendacion,
                   'recomendacion_segura', CASE WHEN p_con_noticias THEN vigilante.recomendacion_segura(s.id) END,
                   'noticias', CASE WHEN p_con_noticias THEN (
                      SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'titulo', r.titulo, 'url', r.url,
                                                'fuente', coalesce(src.nombre, 'búsqueda'),
                                                'fuente_tipo', coalesce(src.tipo::text, 'no_oficial'),
                                                'publicado_en', r.publicado_en, 'texto', left(r.contenido, 600))
                                                ORDER BY r.recolectado_en DESC), '[]')
                        FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                        LEFT JOIN vigilante.sources src ON src.id = r.source_id
                       WHERE sr.signal_id = s.id) END))
                 ORDER BY s.prioridad DESC, s.id), '[]')
                  FROM vigilante.signals s WHERE s.id = ANY (e.senal_ids)))
    FROM vigilante.eventos_compuestos e WHERE e.id = p_id
$$;
REVOKE ALL ON FUNCTION vigilante._evento_json(bigint, boolean) FROM public, anon, authenticated;

-- 6. Para Hermes (por el MCP, con la clave de servicio) ----------------------------------
-- Cuántos esperan interpretación: lo usa el script que despierta a Hermes, sin gastar tokens si es 0
CREATE OR REPLACE FUNCTION vigilante.eventos_pendientes_hermes(p_cliente text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT count(*)::int FROM vigilante.eventos_compuestos
   WHERE cliente_id = vigilante.id_cliente(p_cliente)
     AND (estado = 'por_interpretar' OR (estado = 'interpretando' AND tomado_en < now() - interval '30 minutes'))
$$;

-- Hermes reserva hasta N eventos (primero los de más puntaje). Los reservados vuelven a la cola a los 30 min.
CREATE OR REPLACE FUNCTION vigilante.eventos_por_interpretar(p_cliente text, p_limite int DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  UPDATE vigilante.eventos_compuestos SET estado = 'por_interpretar', tomado_en = NULL
   WHERE cliente_id = v_cliente AND estado = 'interpretando' AND tomado_en < now() - interval '30 minutes';
  WITH t AS (
    SELECT id FROM vigilante.eventos_compuestos
     WHERE cliente_id = v_cliente AND estado = 'por_interpretar'
     ORDER BY puntaje DESC, created_at
     LIMIT greatest(least(coalesce(p_limite, 3), 10), 1) FOR UPDATE SKIP LOCKED
  ), u AS (
    UPDATE vigilante.eventos_compuestos e SET estado = 'interpretando', tomado_en = now()
      FROM t WHERE e.id = t.id RETURNING e.id, e.puntaje
  )
  SELECT coalesce(jsonb_agg(vigilante._evento_json(u.id, true) ORDER BY u.puntaje DESC), '[]') INTO v FROM u;
  RETURN v;
END $$;

-- Hermes guarda su interpretación. La base comprueba que está completa; el contenido es de Hermes.
--   p_int = {
--     "es_confluencia": true,                       -- false = no es un evento real (se descarta con «motivo_descarte»)
--     "titular": "Confluencia en La Paz: huelga + lluvia prevista",
--     "significado": "Qué significa para el turismo (2-3 frases, hechos e interpretación separados)",
--     "a_quien_afecta": ["operadores de turismo receptivo de La Paz", "…"],
--     "impacto": {"nivel": "alto|medio|bajo", "motivo": "…"},
--     "recomendacion": {"accion": "…", "para_quien": "…", "cuando": "avisar con 48 h", "verificar_con": "…"},
--     "escenarios": [{"si": "…", "entonces": "…"}],
--     "falta_saber": ["…"],
--     "prioridad": {"nivel": "alta|media|baja", "motivo": "…"}   -- opcional: solo un nivel arriba o abajo
--   }
CREATE OR REPLACE FUNCTION vigilante.guardar_interpretacion_evento(p_cliente text, p_codigo text, p_int jsonb,
                                                                  p_modelo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); e vigilante.eventos_compuestos;
  v_rec jsonb := p_int -> 'recomendacion'; v_pr text; v_niv int; v_calc int; v_limpio jsonb;
BEGIN
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = v_cliente AND codigo = p_codigo FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'El evento % no existe', p_codigo; END IF;
  IF e.estado NOT IN ('por_interpretar', 'interpretando', 'interpretado') THEN
    RAISE EXCEPTION 'El evento % está %: ya no se interpreta', p_codigo, e.estado;
  END IF;
  IF jsonb_typeof(p_int) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'La interpretación debe ser un objeto JSON'; END IF;

  -- Hermes puede decir que no es un evento real
  IF (p_int ->> 'es_confluencia') = 'false' THEN
    IF coalesce(trim(p_int ->> 'motivo_descarte'), '') = '' THEN
      RAISE EXCEPTION 'Para descartar un evento hace falta «motivo_descarte»';
    END IF;
    UPDATE vigilante.eventos_compuestos
       SET estado = 'descartado', motivo_cierre = left(p_int ->> 'motivo_descarte', 500),
           descartado_por = 'hermes', interpretado_por = coalesce(p_modelo, 'hermes'), interpretado_en = now(), tomado_en = NULL
     WHERE id = e.id;
    RETURN jsonb_build_object('ok', true, 'estado', 'descartado');
  END IF;

  -- campos obligatorios
  IF coalesce(trim(p_int ->> 'titular'), '') = '' THEN RAISE EXCEPTION 'Falta «titular»'; END IF;
  IF coalesce(trim(p_int ->> 'significado'), '') = '' THEN RAISE EXCEPTION 'Falta «significado» (qué significa para el turismo)'; END IF;
  IF jsonb_typeof(p_int -> 'a_quien_afecta') IS DISTINCT FROM 'array' OR jsonb_array_length(p_int -> 'a_quien_afecta') = 0 THEN
    RAISE EXCEPTION 'Falta «a_quien_afecta» (lista de a quién afecta)';
  END IF;
  IF jsonb_typeof(v_rec) IS DISTINCT FROM 'object' OR coalesce(trim(v_rec ->> 'accion'), '') = '' OR coalesce(trim(v_rec ->> 'para_quien'), '') = '' THEN
    RAISE EXCEPTION 'Falta «recomendacion» con «accion» y «para_quien»';
  END IF;

  -- prioridad de Hermes: solo un nivel arriba o abajo de la calculada, y con motivo
  v_pr := p_int #>> '{prioridad,nivel}';
  IF v_pr IS NOT NULL THEN
    IF v_pr NOT IN ('alta', 'media', 'baja') OR coalesce(trim(p_int #>> '{prioridad,motivo}'), '') = '' THEN
      RAISE EXCEPTION '«prioridad» necesita nivel (alta, media o baja) y motivo';
    END IF;
    v_niv := CASE v_pr WHEN 'alta' THEN 3 WHEN 'media' THEN 2 ELSE 1 END;
    v_calc := CASE e.prioridad_calculada WHEN 'alta' THEN 3 WHEN 'media' THEN 2 ELSE 1 END;
    IF abs(v_niv - v_calc) > 1 THEN
      RAISE EXCEPTION 'La prioridad calculada es %: Hermes solo puede subirla o bajarla un nivel', e.prioridad_calculada;
    END IF;
  END IF;

  -- se guarda solo lo previsto, recortado
  v_limpio := jsonb_strip_nulls(jsonb_build_object(
    'significado', left(p_int ->> 'significado', 1200),
    'a_quien_afecta', (SELECT jsonb_agg(left(x, 160)) FROM (SELECT jsonb_array_elements_text(p_int -> 'a_quien_afecta') x LIMIT 8) q),
    'impacto', CASE WHEN (p_int #>> '{impacto,nivel}') IN ('alto', 'medio', 'bajo') AND coalesce(trim(p_int #>> '{impacto,motivo}'), '') <> ''
                    THEN jsonb_build_object('nivel', p_int #>> '{impacto,nivel}', 'motivo', left(p_int #>> '{impacto,motivo}', 400)) END,
    'recomendacion', jsonb_strip_nulls(jsonb_build_object(
        'accion', left(v_rec ->> 'accion', 400), 'para_quien', left(v_rec ->> 'para_quien', 200),
        'cuando', left(v_rec ->> 'cuando', 120), 'verificar_con', left(v_rec ->> 'verificar_con', 200))),
    'escenarios', (SELECT jsonb_agg(jsonb_build_object('si', left(x ->> 'si', 300), 'entonces', left(x ->> 'entonces', 300)))
                     FROM (SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_int -> 'escenarios') = 'array'
                                                                   THEN p_int -> 'escenarios' ELSE '[]' END) x
                            WHERE coalesce(x ->> 'si', '') <> '' AND coalesce(x ->> 'entonces', '') <> '' LIMIT 3) q),
    'falta_saber', (SELECT jsonb_agg(left(x, 200)) FROM (SELECT jsonb_array_elements_text(
                      CASE WHEN jsonb_typeof(p_int -> 'falta_saber') = 'array' THEN p_int -> 'falta_saber' ELSE '[]' END) x LIMIT 4) q),
    'prioridad_motivo', CASE WHEN v_pr IS NOT NULL THEN left(p_int #>> '{prioridad,motivo}', 600) END,
    'version', e.version));

  UPDATE vigilante.eventos_compuestos
     SET titular = left(trim(p_int ->> 'titular'), 140), interpretacion = v_limpio,
         prioridad_hermes = v_pr::vigilante.prioridad,
         estado = 'interpretado', interpretado_por = coalesce(p_modelo, 'hermes'), interpretado_en = now(), tomado_en = NULL
   WHERE id = e.id;
  RETURN jsonb_build_object('ok', true, 'estado', 'interpretado',
                            'prioridad', coalesce(v_pr, e.prioridad_calculada::text));
END $$;

-- Lectura sin reservar (para el chat de AVIA y las skills de decisión): eventos abiertos con su interpretación
CREATE OR REPLACE FUNCTION vigilante.eventos_abiertos(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(vigilante._evento_json(e.id) ORDER BY e.puntaje DESC, e.created_at DESC), '[]')
    FROM vigilante.eventos_compuestos e
   WHERE e.cliente_id = vigilante.id_cliente(p_cliente) AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado')
$$;
REVOKE ALL ON FUNCTION vigilante.eventos_abiertos(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.eventos_abiertos(text) TO service_role;

REVOKE ALL ON FUNCTION vigilante.eventos_pendientes_hermes(text), vigilante.eventos_por_interpretar(text, int),
                       vigilante.guardar_interpretacion_evento(text, text, jsonb, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.eventos_pendientes_hermes(text), vigilante.eventos_por_interpretar(text, int),
                          vigilante.guardar_interpretacion_evento(text, text, jsonb, text) TO service_role;

-- 7. Para el panel (usuario con sesión; solo analistas y administradores) ---------------
--   alerta = prioridad alta y (ya interpretado, o Hermes tarda más de eventos_espera_hermes_min)
--   visto  = esta persona ya pulsó «Entendido» en esta versión
CREATE OR REPLACE FUNCTION vigilante.eventos_emergentes()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.cliente_actual(); v_user uuid := vigilante.usuario_actual(); v_espera int;
BEGIN
  IF v_cliente IS NULL OR NOT vigilante.es_staff() THEN RETURN '[]'::jsonb; END IF;
  v_espera := vigilante._entero(vigilante.param(v_cliente, 'eventos_espera_hermes_min'), 20);
  RETURN (
    SELECT coalesce(jsonb_agg(vigilante._evento_json(e.id) || jsonb_build_object(
             'alerta', e.prioridad = 'alta' AND (e.estado = 'interpretado' OR e.updated_at < now() - make_interval(mins => v_espera)),
             'esperando_hermes', e.estado <> 'interpretado',
             'visto', EXISTS (SELECT 1 FROM vigilante.eventos_vistos v
                               WHERE v.evento_id = e.id AND v.user_id = v_user AND v.version >= e.version))
             ORDER BY e.puntaje DESC, e.created_at DESC), '[]')
      FROM vigilante.eventos_compuestos e
     WHERE e.cliente_id = v_cliente AND e.estado IN ('por_interpretar', 'interpretando', 'interpretado'));
END $$;

CREATE OR REPLACE FUNCTION vigilante.marcar_evento_visto(p_codigo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_user uuid := vigilante.usuario_actual(); e vigilante.eventos_compuestos;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Hace falta iniciar sesión'; END IF;
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'El evento % no existe', p_codigo; END IF;
  INSERT INTO vigilante.eventos_vistos (evento_id, user_id, version) VALUES (e.id, v_user, e.version)
  ON CONFLICT (evento_id, user_id) DO UPDATE SET version = EXCLUDED.version, visto_en = now();
  RETURN jsonb_build_object('ok', true);
END $$;

-- Un analista descarta un evento que no tiene sentido (no vuelve a salir salvo que entren señales nuevas)
CREATE OR REPLACE FUNCTION vigilante.descartar_evento(p_codigo text, p_motivo text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_quien text;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede descartar eventos'; END IF;
  IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Escribe el motivo del descarte'; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  UPDATE vigilante.eventos_compuestos
     SET estado = 'descartado', motivo_cierre = left(p_motivo, 500), descartado_por = coalesce(v_quien, 'analista'), tomado_en = NULL
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo
     AND estado IN ('por_interpretar', 'interpretando', 'interpretado');
  IF NOT FOUND THEN RAISE EXCEPTION 'El evento % no existe o ya está cerrado', p_codigo; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE ALL ON FUNCTION vigilante.eventos_emergentes(), vigilante.marcar_evento_visto(text),
                       vigilante.descartar_evento(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.eventos_emergentes(), vigilante.marcar_evento_visto(text),
                          vigilante.descartar_evento(text, text) TO authenticated, service_role;

-- 8. Primera composición con las señales que ya hay
SELECT vigilante.componer_eventos() AS primera_composicion;

COMMIT;

-- 9. Tarea de pg_cron (fuera de la transacción; solo en Supabase) -----------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-eventos', '*/5 * * * *', 'SELECT vigilante.componer_eventos()');
    RAISE NOTICE 'Tarea programada: vigilante-eventos (cada 5 minutos)';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
