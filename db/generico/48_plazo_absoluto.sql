-- =============================================================================
-- 48. Plazos con fecha fija y certeza del plazo aparte (CP1 y CP2 de Carlos)
-- =============================================================================
-- Qué pasó (Carlos, 2026-11-22): para la misma señal (IWT, SEN-0027) AVIA dijo «quedan 12 días» y
-- «cierra en 5 días». Había cuatro cuentas distintas y ninguna fija:
--   · el chat no sabía qué día es hoy y contaba los días él mismo, o copiaba «quedan 12 días» del
--     resumen, que se escribió el día de la noticia y no cambia aunque pasen los días;
--   · vigilante_bd() daba «fecha_limite» en UTC desde el 19: un plazo guardado a las 23:59 de Bolivia
--     son las 03:59 del día SIGUIENTE en UTC, así que el panel veía el cierre un día más tarde;
--   · vigilante.dias_para() (21) sumaba otro día por la misma razón;
--   · la web pública y la vista Oportunidades tenían su propia cuenta.
-- Y «confirmado» se aplicaba a plazos que ninguna fuente primaria había dado (la certeza del EVENTO
-- se usaba también para la FECHA).
--
-- Regla única a partir de este script (igual en web/src/lib/plazo.ts y en avia_api.py):
--   · Se guarda la FECHA de cierre (signals.plazo_hasta, fin de ese día en Bolivia), nunca «N días».
--   · Días que faltan = día de cierre − hoy, los dos en hora de Bolivia, calculados al consultar.
--     0 = cierra hoy · 1 = mañana · negativo = ya cerró.
--   · Certeza del plazo (aparte de la certeza del evento):
--       confirmado              → la fecha la da tal cual una fuente primaria (oficial u organismo
--                                 internacional) o una persona del equipo la comprobó;
--       pendiente de verificar  → todo lo demás: fecha de un medio no oficial, o calculada por AVIA
--                                 a partir de «quedan N días» y la fecha de publicación.
--
-- Qué hace:
--   1. vigilante.hoy_bo(), vigilante.dia_bo(ts) y vigilante.dias_para(ts) con la regla de arriba
--      (contadores, síntesis y Pulso la heredan sin tocar nada más).
--   2. vigilante.certeza_plazo(señal) y vigilante.cierre(señal): fecha, días que faltan, texto
--      («cierra el 30/11/2026, en 8 días») y certeza del plazo con su motivo.
--   3. Al guardar la clasificación (disparador sobre analisis, como el 31 y el 37) se anota de dónde
--      salió la fecha: «texto» (la fuente da la fecha) o «calculado» (AVIA la sacó de «quedan N días»),
--      la frase de la fuente, la noticia y si esa noticia es de una fuente oficial.
--   4. vigilante.verificar_plazo(código, fecha, fuente): una persona del equipo comprueba la fecha
--      con quien convoca y el plazo pasa a «confirmado».
--   5. vigilante.reparar_plazos_relativos(aplicar): busca señales viejas con «quedan N días» en el
--      resumen y sin fecha guardada; con aplicar = true les pone la fecha (publicación + N días),
--      marcada como calculada y por tanto «pendiente de verificar».
--   6. vigilante_bd(), alertas_publicas(), sintesis_dia(), metricas_oportunidades() y
--      buscar_senales() devuelven la fecha en hora de Bolivia y la certeza del plazo.
--
-- Necesita el 47 (y lo anterior). Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar:
--   SELECT codigo, vigilante.cierre(id) FROM vigilante.signals WHERE plazo_hasta IS NOT NULL ORDER BY plazo_hasta LIMIT 10;
--   SELECT vigilante.reparar_plazos_relativos(false);   -- lo que arreglaría, sin tocar nada
-- Prueba: 99_prueba_plazo_absoluto.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 1. Hoy y los días que faltan, en Bolivia -----------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.hoy_bo() RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/La_Paz')::date
$$;
CREATE OR REPLACE FUNCTION vigilante.dia_bo(p timestamptz) RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (p AT TIME ZONE 'America/La_Paz')::date
$$;

-- Antes (21): fin del día en UTC + 1 → un día de más. Ahora: día de cierre − hoy, en Bolivia.
-- Nunca negativo aquí (los contadores cuentan «< 15»); para saber si ya cerró, vigilante.cierre().
CREATE OR REPLACE FUNCTION vigilante.dias_para(p_plazo timestamptz)
RETURNS int LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_plazo IS NULL THEN NULL ELSE greatest(0, vigilante.dia_bo(p_plazo) - vigilante.hoy_bo()) END
$$;

-- «cierra hoy (22/11/2026)» · «cierra mañana (23/11/2026)» · «cierra el 30/11/2026, en 8 días» · «cerró el 20/11/2026»
-- (la misma frase que cierreTexto() en web/src/lib/plazo.ts y _texto_cierre() en avia_api.py)
CREATE OR REPLACE FUNCTION vigilante.texto_cierre(p_plazo timestamptz)
RETURNS text LANGUAGE sql STABLE AS $$
  WITH d AS (SELECT vigilante.dia_bo(p_plazo) AS dia, vigilante.dia_bo(p_plazo) - vigilante.hoy_bo() AS n)
  SELECT CASE
    WHEN p_plazo IS NULL THEN NULL
    WHEN n < 0 THEN 'cerró el ' || to_char(dia, 'DD/MM/YYYY')
    WHEN n = 0 THEN 'cierra hoy (' || to_char(dia, 'DD/MM/YYYY') || ')'
    WHEN n = 1 THEN 'cierra mañana (' || to_char(dia, 'DD/MM/YYYY') || ')'
    ELSE 'cierra el ' || to_char(dia, 'DD/MM/YYYY') || ', en ' || n || ' días' END
    FROM d
$$;

-- 2. Certeza del plazo y cierre de una señal ----------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.certeza_plazo(p_signal bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; m jsonb; v_dia text; v_oficial boolean; v_fuente text;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND OR s.plazo_hasta IS NULL THEN RETURN NULL; END IF;
  m := coalesce(s.salida_modelo, '{}');
  v_dia := to_char(vigilante.dia_bo(s.plazo_hasta), 'YYYY-MM-DD');

  -- a. una persona del equipo comprobó ESTA fecha (si después cambió la fecha, ya no vale)
  IF m ->> 'plazo_verificado_por' IS NOT NULL AND m ->> 'plazo_verificado_fecha' = v_dia THEN
    RETURN jsonb_build_object('nivel', 'confirmado', 'origen', 'persona',
      'motivo', 'Fecha comprobada por ' || (m ->> 'plazo_verificado_por')
                || coalesce(' con ' || nullif(m ->> 'plazo_verificado_fuente', ''), ''));
  END IF;

  -- b. AVIA la calculó a partir de «quedan N días»: nunca es confirmada
  IF m ->> 'plazo_origen' = 'calculado' THEN
    RETURN jsonb_build_object('nivel', 'pendiente de verificar', 'origen', 'calculado',
      'motivo', 'La fuente no da la fecha: AVIA la calculó' || coalesce(' a partir de «' || nullif(m ->> 'plazo_cita', '') || '»', '')
                || ' y la fecha de publicación. Falta confirmarla con quien convoca');
  END IF;

  -- c. la noticia que dio la fecha (desde el 48) o, en señales anteriores, sus noticias
  IF m ? 'plazo_fuente_oficial' THEN
    v_oficial := coalesce((m ->> 'plazo_fuente_oficial')::boolean, false);
    v_fuente := m ->> 'plazo_fuente';
  ELSE
    SELECT coalesce(bool_or(src.tipo IN ('oficial', 'organismo_internacional')), false),
           (array_agg(src.nombre ORDER BY (src.tipo IN ('oficial', 'organismo_internacional')) DESC NULLS LAST))[1]
      INTO v_oficial, v_fuente
      FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
      LEFT JOIN vigilante.sources src ON src.id = r.source_id
     WHERE sr.signal_id = s.id;
    v_oficial := coalesce(v_oficial, false) OR coalesce(s.fuente_oficial, false);
  END IF;

  IF v_oficial THEN
    RETURN jsonb_build_object('nivel', 'confirmado', 'origen', 'fuente_primaria',
      'motivo', 'La fecha la da una fuente oficial' || coalesce(' (' || v_fuente || ')', ''));
  END IF;
  RETURN jsonb_build_object('nivel', 'pendiente de verificar', 'origen', 'sin_fuente_primaria',
    'motivo', 'La fecha la da ' || coalesce(v_fuente, 'una fuente no oficial')
              || ', no una fuente primaria (oficial o quien convoca). Falta comprobarla');
END $$;
REVOKE ALL ON FUNCTION vigilante.certeza_plazo(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.certeza_plazo(bigint) TO authenticated, service_role;

-- {fecha, dias_restantes, vencido, texto, certeza, motivo, origen}: lo que leen panel, web pública y chat
CREATE OR REPLACE FUNCTION vigilante.cierre(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN s.plazo_hasta IS NULL THEN NULL ELSE jsonb_build_object(
           'fecha', to_char(vigilante.dia_bo(s.plazo_hasta), 'YYYY-MM-DD'),
           'dias_restantes', vigilante.dia_bo(s.plazo_hasta) - vigilante.hoy_bo(),
           'vencido', vigilante.dia_bo(s.plazo_hasta) < vigilante.hoy_bo(),
           'texto', vigilante.texto_cierre(s.plazo_hasta),
           'calculado_el', to_char(vigilante.hoy_bo(), 'YYYY-MM-DD'),
           'certeza', cp ->> 'nivel', 'motivo', cp ->> 'motivo', 'origen', cp ->> 'origen') END
    FROM vigilante.signals s, LATERAL (SELECT vigilante.certeza_plazo(s.id) AS cp) c
   WHERE s.id = p_signal
$$;
REVOKE ALL ON FUNCTION vigilante.cierre(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.cierre(bigint) TO authenticated, service_role;

-- 3. De dónde salió la fecha (al guardar la clasificación) ---------------------------------
-- El analizador (hermes/analizador/analizador.py ≥ clasificador-1.11) manda con cada resultado:
--   plazo_hasta (AAAA-MM-DD), plazo_origen ('texto' | 'calculado') y plazo_cita (la frase de la fuente).
CREATE OR REPLACE FUNCTION vigilante.tg_plazo_origen()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  x jsonb := NEW.salida; s vigilante.signals; v_oficial boolean; v_fuente text; m jsonb;
BEGIN
  IF NEW.tipo <> 'clasificacion' OR NEW.signal_id IS NULL OR coalesce(x ->> 'plazo_hasta', '') !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM vigilante.signals WHERE id = NEW.signal_id;
  -- solo si la fecha de esta noticia es la que quedó guardada
  IF s.plazo_hasta IS NULL OR to_char(vigilante.dia_bo(s.plazo_hasta), 'YYYY-MM-DD') <> left(x ->> 'plazo_hasta', 10) THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(src.tipo IN ('oficial', 'organismo_internacional'), false), src.nombre INTO v_oficial, v_fuente
    FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE r.id = NEW.raw_item_id;
  v_oficial := coalesce(v_oficial, false) AND coalesce(x ->> 'plazo_origen', 'texto') <> 'calculado';
  m := coalesce(s.salida_modelo, '{}');
  -- una fuente oficial que ya dio ESTA misma fecha no se pisa con un medio que la repite
  IF coalesce((m ->> 'plazo_fuente_oficial')::boolean, false) AND NOT v_oficial
     AND m ->> 'plazo_fecha' = left(x ->> 'plazo_hasta', 10) THEN
    RETURN NULL;
  END IF;
  UPDATE vigilante.signals SET salida_modelo = coalesce(salida_modelo, '{}') || jsonb_strip_nulls(jsonb_build_object(
      'plazo_fecha', left(x ->> 'plazo_hasta', 10),
      'plazo_origen', CASE WHEN x ->> 'plazo_origen' = 'calculado' THEN 'calculado' ELSE 'texto' END,
      'plazo_cita', nullif(left(trim(x ->> 'plazo_cita'), 200), ''),
      'plazo_noticia', NEW.raw_item_id,
      'plazo_fuente', coalesce(v_fuente, 'búsqueda de AVIA'),
      'plazo_fuente_oficial', v_oficial))
   WHERE id = NEW.signal_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_plazo_origen ON vigilante.analisis;
CREATE TRIGGER zz_plazo_origen AFTER UPDATE OF signal_id ON vigilante.analisis
  FOR EACH ROW WHEN (NEW.signal_id IS NOT NULL AND OLD.signal_id IS DISTINCT FROM NEW.signal_id)
  EXECUTE FUNCTION vigilante.tg_plazo_origen();

-- 4. Una persona comprueba la fecha -------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.verificar_plazo(p_codigo text, p_fecha date, p_fuente text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint; v_quien text;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede verificar un plazo'; END IF;
  IF p_fecha IS NULL THEN RAISE EXCEPTION 'Falta la fecha de cierre comprobada'; END IF;
  SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % no está en la base de datos', p_codigo; END IF;
  SELECT coalesce(nullif(u.nombre, ''), u.email, 'una persona del equipo') INTO v_quien
    FROM vigilante.users u WHERE u.id = vigilante.usuario_actual();
  UPDATE vigilante.signals SET
      plazo_hasta = (to_char(p_fecha, 'YYYY-MM-DD') || 'T23:59:59-04:00')::timestamptz,
      salida_modelo = coalesce(salida_modelo, '{}') || jsonb_strip_nulls(jsonb_build_object(
        'plazo_verificado_por', coalesce(v_quien, 'una persona del equipo'),
        'plazo_verificado_fecha', to_char(p_fecha, 'YYYY-MM-DD'),
        'plazo_verificado_fuente', nullif(trim(p_fuente), ''),
        'plazo_verificado_en', now()))
   WHERE id = v_id;
  RETURN vigilante.cierre(v_id) || jsonb_build_object('codigo', p_codigo);
END $$;
REVOKE ALL ON FUNCTION vigilante.verificar_plazo(text, date, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.verificar_plazo(text, date, text) TO authenticated, service_role;

-- 5. Señales viejas con «quedan N días» y sin fecha ---------------------------------------
-- Lee «quedan / faltan / restan N días», «cierra / vence / termina en N días», «dentro de N días»
-- (N en cifras) en el título y el resumen. Fecha = día de publicación de la primera noticia + N.
CREATE OR REPLACE FUNCTION vigilante.reparar_plazos_relativos(p_aplicar boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v_out jsonb := '[]'; v_n int := 0;
  v_re text := '(?:quedan|faltan|restan|cierra en|vence en|termina en|finaliza en|concluye en|dentro de)\s+(?:solo\s+|apenas\s+)?(\d{1,3})\s+d[ií]as?';
BEGIN
  FOR r IN
    SELECT s.id, s.codigo, s.titulo, m.cita, m.n::int AS n,
           coalesce((SELECT min(vigilante.dia_bo(coalesce(ri.publicado_en, ri.recolectado_en)))
                       FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items ri ON ri.id = sr.raw_item_id
                      WHERE sr.signal_id = s.id), vigilante.dia_bo(s.created_at)) AS desde
      FROM vigilante.signals s,
           LATERAL (SELECT (regexp_match(lower(coalesce(s.titulo, '') || ' ' || coalesce(s.resumen, '')), v_re))[1] AS n,
                           (regexp_match(coalesce(s.titulo, '') || ' ' || coalesce(s.resumen, ''), '(?i)(' || v_re || ')'))[1] AS cita) m
     WHERE s.plazo_hasta IS NULL AND m.n IS NOT NULL AND s.estado NOT IN ('descartada', 'cerrada')
  LOOP
    v_n := v_n + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object('codigo', r.codigo, 'titulo', r.titulo, 'frase', r.cita,
               'desde', r.desde, 'fecha_cierre', r.desde + r.n));
    IF p_aplicar THEN
      UPDATE vigilante.signals SET
          plazo_hasta = (to_char(r.desde + r.n, 'YYYY-MM-DD') || 'T23:59:59-04:00')::timestamptz,
          salida_modelo = coalesce(salida_modelo, '{}') || jsonb_build_object(
            'plazo_fecha', to_char(r.desde + r.n, 'YYYY-MM-DD'), 'plazo_origen', 'calculado', 'plazo_cita', r.cita,
            'plazo_fuente_oficial', false)
       WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('aplicado', p_aplicar, 'senales', v_n, 'detalle', v_out,
    'nota', CASE WHEN p_aplicar THEN 'Fechas guardadas como calculadas: salen «pendiente de verificar» hasta que alguien las compruebe'
                 ELSE 'Nada cambiado. Revisa la lista y ejecuta vigilante.reparar_plazos_relativos(true) para guardar las fechas' END);
END $$;
REVOKE ALL ON FUNCTION vigilante.reparar_plazos_relativos(boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.reparar_plazos_relativos(boolean) TO service_role;

-- 6. Lo que leen panel, chat, web pública y Hermes -----------------------------------------
-- 6a. vigilante.json / vigilante_bd(): igual que en el 46, con «fecha_limite» en hora de Bolivia
--     (antes en UTC: un día de más) y «cierre» con días y certeza del plazo
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
                       -- 48: la fecha de cierre sale SIEMPRE de plazo_hasta (también en señales copiadas de
                       -- vigilante.json), en hora de Bolivia, y los días se cuentan ahora (vigilante.cierre)
                       'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
                       'cierre', vigilante.cierre(s.id),
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

-- 6b. Web pública: igual que en el 19, con la fecha de cierre en Bolivia y la certeza del plazo
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
               -- 48: fecha de cierre en Bolivia y certeza del PLAZO (aparte de la del evento)
               'fecha_cierre', to_char(l.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
               'plazo_certeza', vigilante.cierre(l.signal_id) ->> 'certeza',
               'plazo_motivo', vigilante.cierre(l.signal_id) ->> 'motivo',
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

-- 6c. Síntesis del día: igual que en el 45, y la línea de plazo con fecha y certeza del plazo
CREATE OR REPLACE FUNCTION vigilante.sintesis_dia(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  b jsonb := vigilante._sintesis_dia_base(p_cliente);
BEGIN
  RETURN b
    || jsonb_build_object(
         'que_vigilar', coalesce((
           SELECT jsonb_agg(CASE WHEN e ->> 'tipo' = 'plazo' AND c.cierre IS NOT NULL
                                 THEN e || jsonb_build_object(
                                        'texto', 'Oportunidad que ' || (c.cierre ->> 'texto')
                                                 || CASE WHEN c.cierre ->> 'certeza' = 'confirmado' THEN ''
                                                         ELSE ' (fecha pendiente de verificar)' END,
                                        'plazo_certeza', c.cierre ->> 'certeza')
                                 ELSE e END ORDER BY i)
             FROM jsonb_array_elements(b -> 'que_vigilar') WITH ORDINALITY a(e, i)
             LEFT JOIN LATERAL (SELECT vigilante.cierre(s.id) AS cierre FROM vigilante.signals s
                                 WHERE s.cliente_id = p_cliente AND s.codigo = e ->> 'codigo' LIMIT 1) c ON true
            WHERE e ->> 'tipo' IS DISTINCT FROM 'revision_vencida'), '[]'),
         'revisiones_vencidas', vigilante.revisiones_vencidas(p_cliente));
END $$;
REVOKE ALL ON FUNCTION vigilante.sintesis_dia(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.sintesis_dia(uuid) TO service_role;

-- 6d. Hermes (MCP): métricas de oportunidad con la misma cuenta de días y la certeza del plazo
CREATE OR REPLACE FUNCTION vigilante.metricas_oportunidades(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = p_cliente),
  vigentes AS (
    SELECT s.codigo, s.titulo, s.naturaleza, s.categoria, s.estado, s.prioridad, s.confianza,
           -- 48: misma cuenta que panel, web pública y chat: fecha de cierre − hoy, en Bolivia (0 = hoy)
           vigilante.dia_bo(s.plazo_hasta) - vigilante.hoy_bo() AS dias_plazo,
           to_char(s.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD') AS fecha_cierre,
           vigilante.certeza_plazo(s.id) ->> 'nivel' AS certeza_plazo,
           CASE WHEN s.fecha_evento_inicio IS NOT NULL THEN ceil(extract(epoch FROM s.fecha_evento_inicio - now()) / 86400)::int END AS dias_evento,
           ARRAY(SELECT t.nombre FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id
                  WHERE st.signal_id = s.id) AS territorios
      FROM vigilante.signals s, c
     WHERE s.cliente_id = c.id AND s.naturaleza IN ('oportunidad', 'mixta')
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND (s.plazo_hasta IS NULL OR vigilante.dia_bo(s.plazo_hasta) >= vigilante.hoy_bo())
       AND (s.fecha_evento_fin IS NULL OR s.fecha_evento_fin >= now())
       AND s.created_at >= now() - interval '90 days'
  ),
  menciones AS (
    SELECT t.nombre,
           count(*) FILTER (WHERE r.recolectado_en >= now() - interval '7 days') AS ult7,
           count(*) FILTER (WHERE r.recolectado_en < now() - interval '7 days') / 4.0 AS media_semana
      FROM vigilante.raw_items r, c, unnest(r.territorios_detectados) tid
      JOIN vigilante.territorios t ON t.id = tid
     WHERE r.cliente_id = c.id AND r.estado <> 'descartado' AND r.recolectado_en >= now() - interval '35 days'
     GROUP BY t.nombre
  ),
  coinciden AS (
    SELECT min(r.titulo) AS titulo, count(DISTINCT coalesce(r.source_id::text, 'b' || r.busqueda_id)) AS fuentes, max(r.recolectado_en) AS ultima
      FROM vigilante.raw_items r, c
     WHERE r.cliente_id = c.id AND r.recolectado_en >= now() - interval '48 hours' AND r.estado <> 'descartado'
     GROUP BY r.titulo_norm HAVING count(DISTINCT coalesce(r.source_id::text, 'b' || r.busqueda_id)) >= 2
  )
  SELECT jsonb_build_object(
    'generado', now(),
    'oportunidades_vigentes', (SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY least(coalesce(v.dias_plazo, 999), coalesce(v.dias_evento, 999))), '[]')
                                 FROM (SELECT * FROM vigentes LIMIT 30) v),
    'cierran_en_15_dias', (SELECT count(*) FROM vigentes WHERE dias_plazo BETWEEN 0 AND 15),
    'eventos_proximos_60_dias', (SELECT coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'dias', dias_evento, 'territorios', territorios) ORDER BY dias_evento), '[]')
                                   FROM vigentes WHERE dias_evento BETWEEN 0 AND 60),
    'impulso_territorios', (SELECT coalesce(jsonb_agg(jsonb_build_object('territorio', nombre, 'menciones_7d', ult7,
                                     'media_semanal_anterior', round(media_semana, 1),
                                     'impulso', CASE WHEN media_semana > 0 THEN round(ult7 / media_semana, 2) END) ORDER BY ult7 DESC), '[]')
                              FROM menciones),
    'temas_en_varias_fuentes_48h', (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.fuentes DESC, x.ultima DESC), '[]')
                                      FROM (SELECT * FROM coinciden ORDER BY fuentes DESC, ultima DESC LIMIT 15) x)
  )
$$;

-- 6e. Hermes (MCP): buscar_senales con la fecha en Bolivia y el cierre
CREATE OR REPLACE FUNCTION vigilante.buscar_senales(p_cliente text, p_texto text DEFAULT NULL, p_dias int DEFAULT 30,
                                                    p_naturaleza text DEFAULT NULL, p_limite int DEFAULT 10)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'creada') DESC), '[]') FROM (
    SELECT jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', left(s.resumen, 300),
             'naturaleza', s.naturaleza, 'categoria', s.categoria, 'prioridad', s.prioridad, 'estado', s.estado,
             'plazo_hasta', to_char(s.plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD'),
             'cierre', vigilante.cierre(s.id), 'fecha_evento_inicio', s.fecha_evento_inicio, 'creada', s.created_at) AS x
      FROM vigilante.signals s JOIN vigilante.clientes c ON c.id = s.cliente_id AND c.slug = p_cliente
     WHERE s.created_at >= now() - make_interval(days => greatest(coalesce(p_dias, 30), 1))
       AND (p_naturaleza IS NULL OR s.naturaleza::text = p_naturaleza)
       AND (coalesce(trim(p_texto), '') = ''
            OR s.busqueda @@ plainto_tsquery('spanish', p_texto)
            OR vigilante.texto_norm(s.titulo) LIKE '%' || vigilante.texto_norm(p_texto) || '%')
     ORDER BY s.created_at DESC
     LIMIT greatest(least(coalesce(p_limite, 10), 50), 1)) t
$$;

COMMIT;
