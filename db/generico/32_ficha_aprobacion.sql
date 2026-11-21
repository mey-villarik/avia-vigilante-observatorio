-- =============================================================================
-- 32. Ficha de aprobación: AVIA resume la evidencia de un riesgo antes de que una persona lo publique
-- =============================================================================
-- Qué faltaba: para publicar un riesgo (clima, salud, vial, seguridad…) el analista tenía que abrir
-- las noticias una a una y decidir si la prueba bastaba. Nadie le decía qué fuente sostenía la
-- afirmación, cuánto pesaba ni qué faltaba.
--
-- Ahora, para cada riesgo que aún no está publicado, AVIA (Hermes, skill «avia-ficha-aprobacion»)
-- prepara una FICHA de seis líneas, con el método del GPT AVIA-Auditor («AVIA-Fake»):
--
--   1. Afirmación clave      lo que la alerta diría, en una frase
--   2. Mejor evidencia       las noticias que la sostienen y su peso (1 a 5)
--   3. Qué falta             el dato o documento que cerraría la duda
--   4. Riesgo                U1 a U4 (cuánto daño hace si es falsa)
--   5. Sugerencia            publicar, esperar o no publicar, con motivo
--   6. Texto prudente        cómo contarlo sin alarmismo
--
-- Pesos (la base pone el TECHO según el tipo de fuente; AVIA no puede pasarlo):
--   5 oficial (SENAMHI, ABC, Ministerio de Salud, DGAC, Gaceta…) · 4 organismo internacional (OPS…)
--   3 medio (de referencia con documento, o dos medios) · 2 búsqueda sin fuente del catálogo · 1 no oficial / redes
--
-- Regla de oro (la comprueba la base): con riesgo U3, si la mejor evidencia pesa menos de 4,
-- la sugerencia no puede ser «publicar»; con U4 hace falta peso 5; un rumor (peso 1) nunca.
--
-- La ficha NO publica ni mueve nada: la decisión sigue siendo de una persona. Se ve:
--   * en el panel, en la ficha de la señal, encima de los botones (vigilante.ficha_aprobacion);
--   * en Telegram, como respuesta al aviso «Señal por aprobar» del 18 (si aprobacion_previa = true),
--     o como mensaje propio al grupo de analistas si ficha_telegram_siempre = true.
--
-- Ahorro de tokens: solo riesgos (y mixtas) de prioridad media o alta, no publicados, de las últimas
-- 72 h; una ficha por señal, que solo se rehace si llegan noticias nuevas. Hermes solo se despierta si
-- hay alguna pendiente (despertar_hermes.py cuenta fichas_pendientes_hermes).
--
-- Necesita del 01 al 31 (usa vigilante._senal_corta y vigilante._nivel del 31; certeza del 24 y
-- avisos del 18 si están). Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Se puede ejecutar más de una vez. Prueba: 99_prueba_ficha_aprobacion.sql (termina en ROLLBACK).
-- Guía: docs/ficha-aprobacion.md
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante._senal_corta(bigint)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 31 (cambios_noticias): ejecútalo antes que este';
  END IF;
END $$;

-- 0. Parámetros (cada cliente puede sobrescribirlos) ---------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'ficha_activa', 'true', 'AVIA prepara una ficha de evidencia para cada riesgo antes de publicarlo'),
  (NULL, 'ficha_prioridad_min', '"media"', 'Prioridad mínima de la señal para preparar ficha: baja, media o alta'),
  (NULL, 'ficha_horas', '72', 'Solo señales creadas o actualizadas en estas horas'),
  (NULL, 'ficha_naturalezas', '["riesgo", "mixta"]', 'Naturalezas que llevan ficha (además, toda categoría con revisión obligatoria)'),
  (NULL, 'ficha_telegram_siempre', 'false', 'true = la ficha va al grupo de analistas aunque no haya aviso «Señal por aprobar» (sin aprobación previa)')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Tabla ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.fichas_aprobacion (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id          uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  signal_id           bigint NOT NULL UNIQUE REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  estado              text NOT NULL DEFAULT 'preparando' CHECK (estado IN ('preparando', 'lista')),
  tomado_en           timestamptz,
  ficha               jsonb,                       -- lo que escribió AVIA (ver guardar_ficha_aprobacion)
  sugerencia          text CHECK (sugerencia IN ('publicar', 'esperar', 'no_publicar')),
  riesgo              text CHECK (riesgo IN ('U1', 'U2', 'U3', 'U4')),
  peso                smallint CHECK (peso BETWEEN 1 AND 5),
  noticias_n          integer NOT NULL DEFAULT 0,  -- noticias que tenía la señal al preparar la ficha
  preparada_por       text,
  preparada_en        timestamptz,
  version             integer NOT NULL DEFAULT 0,  -- sube cada vez que AVIA la rehace
  telegram_version    integer,                     -- última versión enviada al grupo de analistas
  telegram_error      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fichas_aprobacion_cliente_idx ON vigilante.fichas_aprobacion (cliente_id, estado);
DROP TRIGGER IF EXISTS b_updated_at ON vigilante.fichas_aprobacion;
CREATE TRIGGER b_updated_at BEFORE UPDATE ON vigilante.fichas_aprobacion
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
ALTER TABLE vigilante.fichas_aprobacion ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
COMMENT ON TABLE vigilante.fichas_aprobacion IS
  'Ficha de evidencia de AVIA para cada riesgo antes de publicarlo (32): afirmación, evidencia y peso, qué falta, riesgo U1-U4, sugerencia y texto prudente';

-- 2. Utilidades ------------------------------------------------------------------------------
-- Techo de peso de una noticia según su fuente
CREATE OR REPLACE FUNCTION vigilante._peso_fuente(p_tipo text) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_tipo WHEN 'oficial' THEN 5 WHEN 'organismo_internacional' THEN 4 WHEN 'medio' THEN 3
                     WHEN 'no_oficial' THEN 1 ELSE 2 END   -- NULL = búsqueda sin fuente del catálogo
$$;

-- Noticias de una señal (las enlazadas y la de origen)
CREATE OR REPLACE FUNCTION vigilante._noticias_senal(p_signal bigint)
RETURNS bigint[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') FROM (
    SELECT raw_item_id AS x FROM vigilante.signal_raw_items WHERE signal_id = p_signal
    UNION SELECT raw_item_id FROM vigilante.signals WHERE id = p_signal AND raw_item_id IS NOT NULL) q
$$;
REVOKE ALL ON FUNCTION vigilante._noticias_senal(bigint) FROM public, anon, authenticated;

-- ¿Esta señal lleva ficha? (riesgo vivo, sin publicar, con la prioridad mínima, reciente)
CREATE OR REPLACE FUNCTION vigilante._ficha_candidata(p_signal bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce((vigilante.param(s.cliente_id, 'ficha_activa') #>> '{}')::boolean, true)
     AND NOT s.es_escenario
     AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion', 'confirmada')
     AND vigilante._nivel(s.prioridad::text)
         >= greatest(vigilante._nivel(coalesce(vigilante.param(s.cliente_id, 'ficha_prioridad_min') #>> '{}', 'media')), 1)
     AND greatest(s.created_at, s.updated_at)
         > now() - make_interval(hours => coalesce((vigilante.param(s.cliente_id, 'ficha_horas') #>> '{}')::int, 72))
     AND (s.naturaleza::text IN (SELECT jsonb_array_elements_text(coalesce(vigilante.param(s.cliente_id, 'ficha_naturalezas'),
                                                                          '["riesgo", "mixta"]'::jsonb)))
          OR EXISTS (SELECT 1 FROM vigilante.categorias c
                      WHERE c.cliente_id = s.cliente_id AND c.codigo = s.categoria AND c.revision_obligatoria))
    FROM vigilante.signals s WHERE s.id = p_signal
$$;
REVOKE ALL ON FUNCTION vigilante._ficha_candidata(bigint) FROM public, anon, authenticated;

-- Señales que esperan ficha: sin ficha, con ficha vieja (llegaron noticias) o reservada hace más de 30 min
CREATE OR REPLACE FUNCTION vigilante._fichas_pendientes(p_cliente uuid)
RETURNS TABLE (signal_id bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT s.id FROM vigilante.signals s
    LEFT JOIN vigilante.fichas_aprobacion f ON f.signal_id = s.id
   WHERE s.cliente_id = p_cliente
     AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion', 'confirmada')
     AND NOT s.es_escenario
     AND vigilante._ficha_candidata(s.id)
     AND (f.id IS NULL
          OR (f.estado = 'preparando' AND (f.tomado_en IS NULL OR f.tomado_en < now() - interval '30 minutes'))
          OR (f.estado = 'lista' AND cardinality(vigilante._noticias_senal(s.id)) > f.noticias_n
              AND (f.tomado_en IS NULL OR f.tomado_en < now() - interval '30 minutes')))
   ORDER BY vigilante._nivel(s.prioridad::text) DESC, s.created_at
$$;
REVOKE ALL ON FUNCTION vigilante._fichas_pendientes(uuid) FROM public, anon, authenticated;

-- Lo que Hermes necesita para preparar la ficha de una señal
CREATE OR REPLACE FUNCTION vigilante._ficha_entrada(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH n AS (
    SELECT r.id, r.titulo, r.url, r.publicado_en, r.recolectado_en, left(r.contenido, 500) AS texto,
           src.nombre AS fuente, src.tipo::text AS fuente_tipo, vigilante._peso_fuente(src.tipo::text) AS peso_max
      FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id
     WHERE r.id = ANY (vigilante._noticias_senal(p_signal))
  )
  SELECT vigilante._senal_corta(s.id) || jsonb_strip_nulls(jsonb_build_object(
    'resumen', s.resumen,
    'recomendacion', s.recomendacion,
    'fuente_oficial', s.fuente_oficial,
    'enlace_oficial', s.enlace_oficial,
    'certeza', CASE WHEN to_regprocedure('vigilante.certeza(bigint)') IS NOT NULL THEN vigilante.certeza(s.id) END,
    'publicada', false,
    'noticias', (SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                    'id', n.id, 'titulo', n.titulo, 'url', n.url, 'fuente', coalesce(n.fuente, 'búsqueda'),
                    'fuente_tipo', coalesce(n.fuente_tipo, 'busqueda'), 'peso_max', n.peso_max,
                    'publicado_en', n.publicado_en, 'texto', n.texto))
                  ORDER BY n.peso_max DESC, n.recolectado_en DESC), '[]')
                   FROM (SELECT * FROM n ORDER BY peso_max DESC, recolectado_en DESC LIMIT 6) n),
    'noticias_total', (SELECT count(*) FROM n),
    'fuentes_distintas', (SELECT count(DISTINCT coalesce(n.fuente, n.url)) FROM n),
    'peso_max_disponible', (SELECT max(n.peso_max) FROM n),
    -- si AVIA ya hizo una ficha y llegaron noticias nuevas: la rehace partiendo de esta
    'ficha_anterior', (SELECT f.ficha FROM vigilante.fichas_aprobacion f WHERE f.signal_id = s.id AND f.ficha IS NOT NULL)))
    FROM vigilante.signals s WHERE s.id = p_signal
$$;
REVOKE ALL ON FUNCTION vigilante._ficha_entrada(bigint) FROM public, anon, authenticated;

-- Ficha guardada, lista para mostrar (panel, chat, Telegram)
CREATE OR REPLACE FUNCTION vigilante._ficha_json(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_strip_nulls(f.ficha || jsonb_build_object(
           'senal', s.codigo, 'estado_senal', s.estado,
           'preparada_en', f.preparada_en, 'preparada_por', f.preparada_por, 'version', f.version,
           -- llegaron noticias después de la ficha: AVIA la está rehaciendo
           'desactualizada', cardinality(vigilante._noticias_senal(s.id)) > f.noticias_n,
           'noticias_citadas', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                   'id', r.id, 'titulo', r.titulo, 'url', r.url, 'fuente', coalesce(src.nombre, 'búsqueda'),
                                   'peso_max', vigilante._peso_fuente(src.tipo::text))) ORDER BY r.id)
                                  FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id
                                 WHERE r.id IN (SELECT x::bigint FROM jsonb_array_elements_text(
                                                  coalesce(f.ficha #> '{evidencia,noticias}', '[]')) x WHERE x ~ '^\d+$'))))
    FROM vigilante.fichas_aprobacion f JOIN vigilante.signals s ON s.id = f.signal_id
   WHERE f.signal_id = p_signal AND f.estado = 'lista'
$$;
REVOKE ALL ON FUNCTION vigilante._ficha_json(bigint) FROM public, anon, authenticated;

-- 3. Para Hermes (por el MCP, con la clave de servicio) ---------------------------------------
CREATE OR REPLACE FUNCTION vigilante.fichas_pendientes_hermes(p_cliente text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT count(*)::int FROM vigilante._fichas_pendientes(vigilante.id_cliente(p_cliente))
$$;

-- Reserva hasta p_limite señales (30 min) y devuelve lo necesario para preparar su ficha
CREATE OR REPLACE FUNCTION vigilante.fichas_por_preparar(p_cliente text, p_limite int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_ids bigint[]; v jsonb;
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'El cliente % no existe', p_cliente; END IF;
  v_ids := ARRAY(SELECT signal_id FROM vigilante._fichas_pendientes(v_cliente)
                  LIMIT greatest(least(coalesce(p_limite, 5), 10), 1));
  INSERT INTO vigilante.fichas_aprobacion (cliente_id, signal_id, estado, tomado_en)
  SELECT v_cliente, x, 'preparando', now() FROM unnest(v_ids) x
  ON CONFLICT (signal_id) DO UPDATE SET tomado_en = now(),
    -- una ficha vieja sigue visible (marcada como desactualizada) mientras AVIA prepara la nueva
    estado = CASE WHEN vigilante.fichas_aprobacion.ficha IS NOT NULL THEN vigilante.fichas_aprobacion.estado ELSE 'preparando' END;
  SELECT coalesce(jsonb_agg(vigilante._ficha_entrada(x) ORDER BY o), '[]') INTO v
    FROM unnest(v_ids) WITH ORDINALITY AS u(x, o);
  RETURN v;
END $$;

-- Hermes guarda la ficha. La base comprueba que está completa, que el peso no pasa el techo de las
-- fuentes citadas y la regla de oro; el contenido es de Hermes.
--   p_ficha = {
--     "afirmacion": "Alerta naranja por lluvias en el norte de La Paz hasta el viernes 21",
--     "evidencia": {"noticias": [123], "peso": 5, "por_que": "Aviso del SENAMHI con fecha y zonas"},
--     "falta": ["Si la ABC cierra la ruta a Caranavi"],                     -- 0 a 4
--     "riesgo": {"nivel": "U3", "motivo": "Puede llevar a cancelar viajes por carretera"},
--     "sugerencia": {"decision": "publicar", "motivo": "Fuente oficial con fecha"},   -- publicar | esperar | no_publicar
--     "texto_prudente": "El SENAMHI prevé lluvias fuertes en el norte de La Paz hasta el viernes …",
--     "verificar_con": "SENAMHI"                                            -- opcional
--   }
CREATE OR REPLACE FUNCTION vigilante.guardar_ficha_aprobacion(p_cliente text, p_codigo text, p_ficha jsonb,
                                                             p_modelo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); s vigilante.signals;
  v_ev jsonb := p_ficha -> 'evidencia'; v_sug text := p_ficha #>> '{sugerencia,decision}';
  v_riesgo text := upper(p_ficha #>> '{riesgo,nivel}'); v_peso int; v_techo int;
  v_mias bigint[]; v_citadas bigint[]; v_falta jsonb; v_texto text := trim(coalesce(p_ficha ->> 'texto_prudente', ''));
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = p_codigo;
  IF NOT FOUND THEN RAISE EXCEPTION 'La señal % no existe', p_codigo; END IF;
  IF jsonb_typeof(p_ficha) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'La ficha debe ser un objeto JSON'; END IF;
  IF s.estado IN ('publicada', 'cerrada', 'descartada') THEN
    RAISE EXCEPTION 'La señal % ya está %: no necesita ficha', p_codigo, s.estado;
  END IF;

  IF coalesce(trim(p_ficha ->> 'afirmacion'), '') = '' THEN RAISE EXCEPTION 'Falta «afirmacion» (lo que la alerta diría, en una frase)'; END IF;

  -- Evidencia: noticias de la señal y peso dentro del techo de sus fuentes
  IF jsonb_typeof(v_ev) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Falta «evidencia» con «noticias», «peso» y «por_que»'; END IF;
  v_mias := vigilante._noticias_senal(s.id);
  v_citadas := ARRAY(SELECT DISTINCT x::bigint FROM jsonb_array_elements_text(
                       CASE WHEN jsonb_typeof(v_ev -> 'noticias') = 'array' THEN v_ev -> 'noticias' ELSE '[]' END) x
                      WHERE x ~ '^\d+$');
  IF cardinality(v_citadas) = 0 THEN RAISE EXCEPTION '«evidencia.noticias» necesita al menos un id de noticia de la señal'; END IF;
  IF NOT v_citadas <@ v_mias THEN
    RAISE EXCEPTION 'Estas noticias no son de la señal %: %. Usa solo los ids que te dio fichas_por_preparar',
      p_codigo, array_to_string(ARRAY(SELECT unnest(v_citadas) EXCEPT SELECT unnest(v_mias)), ', ');
  END IF;
  IF coalesce(v_ev ->> 'peso', '') !~ '^[1-5]$' THEN RAISE EXCEPTION '«evidencia.peso» debe ser un número del 1 al 5'; END IF;
  v_peso := (v_ev ->> 'peso')::int;
  SELECT max(vigilante._peso_fuente(src.tipo::text)) INTO v_techo
    FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE r.id = ANY (v_citadas);
  IF v_peso > v_techo THEN
    RAISE EXCEPTION 'El peso % es mayor que el de las fuentes citadas (máximo %: 5 oficial, 4 organismo internacional, 3 medio, 2 búsqueda, 1 no oficial)', v_peso, v_techo;
  END IF;
  IF coalesce(trim(v_ev ->> 'por_que'), '') = '' THEN RAISE EXCEPTION 'Falta «evidencia.por_que» (por qué ese peso)'; END IF;

  -- Riesgo y sugerencia
  IF v_riesgo IS NULL OR v_riesgo NOT IN ('U1', 'U2', 'U3', 'U4') OR coalesce(trim(p_ficha #>> '{riesgo,motivo}'), '') = '' THEN
    RAISE EXCEPTION '«riesgo» necesita «nivel» (U1, U2, U3 o U4) y «motivo»';
  END IF;
  IF v_sug IS NULL OR v_sug NOT IN ('publicar', 'esperar', 'no_publicar') OR coalesce(trim(p_ficha #>> '{sugerencia,motivo}'), '') = '' THEN
    RAISE EXCEPTION '«sugerencia» necesita «decision» (publicar, esperar o no_publicar) y «motivo»';
  END IF;
  IF v_sug = 'publicar' AND v_peso = 1 THEN
    RAISE EXCEPTION 'Un rumor (peso 1) no se sugiere publicar: sugiere «esperar» o «no_publicar»';
  END IF;
  IF v_sug = 'publicar' AND v_riesgo = 'U4' AND v_peso < 5 THEN
    RAISE EXCEPTION 'Regla de oro: con riesgo U4 solo se sugiere publicar con peso 5 (fuente oficial). Sugiere «esperar» y di en «falta» qué documento oficial lo cerraría';
  END IF;
  IF v_sug = 'publicar' AND v_riesgo = 'U3' AND v_peso < 4 THEN
    RAISE EXCEPTION 'Regla de oro: con riesgo U3 y peso menor que 4 no se sugiere publicar. Sugiere «esperar» y di en «falta» qué lo cerraría';
  END IF;

  -- Qué falta: obligatorio si no se sugiere publicar
  v_falta := (SELECT jsonb_agg(left(trim(x), 200)) FROM (SELECT jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(p_ficha -> 'falta') = 'array' THEN p_ficha -> 'falta' ELSE '[]' END) x LIMIT 4) q
              WHERE trim(x) <> '');
  IF v_sug = 'esperar' AND v_falta IS NULL THEN RAISE EXCEPTION 'Si sugieres «esperar», di en «falta» qué dato o documento lo cerraría'; END IF;

  -- Texto prudente: corto y sin afirmar seguridad sin fuente oficial
  IF v_texto = '' THEN RAISE EXCEPTION 'Falta «texto_prudente» (cómo contarlo sin alarmismo)'; END IF;
  IF length(v_texto) > 320 THEN RAISE EXCEPTION '«texto_prudente» tiene % caracteres: máximo 320', length(v_texto); END IF;
  IF v_peso < 5 AND v_texto ~* '(ya es seguro|sin (ning[uú]n )?(riesgo|peligro)|totalmente (seguro|habilitad)|est[aá] habilitad|se puede viajar con normalidad|oficialmente confirmad)' THEN
    RAISE EXCEPTION '«texto_prudente» da algo por seguro u oficial sin fuente oficial (peso %). Usa «según …», «podría» o «pendiente de confirmación»', v_peso;
  END IF;

  INSERT INTO vigilante.fichas_aprobacion (cliente_id, signal_id, estado) VALUES (v_cliente, s.id, 'preparando')
  ON CONFLICT (signal_id) DO NOTHING;
  UPDATE vigilante.fichas_aprobacion SET
    estado = 'lista', tomado_en = NULL,
    ficha = jsonb_strip_nulls(jsonb_build_object(
      'afirmacion', left(trim(p_ficha ->> 'afirmacion'), 200),
      'evidencia', jsonb_build_object('noticias', to_jsonb(v_citadas), 'peso', v_peso, 'peso_max', v_techo,
                                      'por_que', left(trim(v_ev ->> 'por_que'), 300)),
      'falta', v_falta,
      'riesgo', jsonb_build_object('nivel', v_riesgo, 'motivo', left(trim(p_ficha #>> '{riesgo,motivo}'), 300)),
      'sugerencia', jsonb_build_object('decision', v_sug, 'motivo', left(trim(p_ficha #>> '{sugerencia,motivo}'), 300)),
      'texto_prudente', v_texto,
      'verificar_con', nullif(left(trim(coalesce(p_ficha ->> 'verificar_con', '')), 200), ''))),
    sugerencia = v_sug, riesgo = v_riesgo, peso = v_peso,
    noticias_n = cardinality(v_mias),
    preparada_por = coalesce(p_modelo, 'hermes'), preparada_en = now(), version = version + 1
   WHERE signal_id = s.id;
  RETURN jsonb_build_object('ok', true, 'senal', p_codigo, 'sugerencia', v_sug);
END $$;

-- Lectura sin reservar (chat de AVIA: «¿publico SEN-0012?»)
CREATE OR REPLACE FUNCTION vigilante.ficha_senal_hermes(p_cliente text, p_codigo text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(vigilante._ficha_json(s.id),
                  jsonb_build_object('senal', s.codigo, 'sin_ficha', true,
                                     'motivo', CASE WHEN vigilante._ficha_candidata(s.id) THEN 'AVIA aún no la ha preparado'
                                                    ELSE 'Esta señal no lleva ficha (no es un riesgo vivo sin publicar, o es de prioridad baja)' END))
    FROM vigilante.signals s
   WHERE s.cliente_id = vigilante.id_cliente(p_cliente) AND s.codigo = p_codigo
$$;

REVOKE ALL ON FUNCTION vigilante.fichas_pendientes_hermes(text), vigilante.fichas_por_preparar(text, int),
                       vigilante.guardar_ficha_aprobacion(text, text, jsonb, text), vigilante.ficha_senal_hermes(text, text)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.fichas_pendientes_hermes(text), vigilante.fichas_por_preparar(text, int),
                          vigilante.guardar_ficha_aprobacion(text, text, jsonb, text), vigilante.ficha_senal_hermes(text, text)
  TO service_role;

-- 4. Para el panel (analistas y administradores con sesión) ------------------------------------
CREATE OR REPLACE FUNCTION vigilante.ficha_aprobacion(p_codigo text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint; v_fila vigilante.fichas_aprobacion;
BEGIN
  IF vigilante.cliente_actual() IS NULL OR NOT vigilante.es_staff() THEN RETURN NULL; END IF;
  SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo;
  IF v_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_fila FROM vigilante.fichas_aprobacion WHERE signal_id = v_id;
  IF v_fila.estado = 'lista' THEN RETURN vigilante._ficha_json(v_id); END IF;
  IF FOUND OR vigilante._ficha_candidata(v_id) THEN RETURN jsonb_build_object('senal', p_codigo, 'preparando', true); END IF;
  RETURN NULL;   -- no lleva ficha
END $$;
REVOKE ALL ON FUNCTION vigilante.ficha_aprobacion(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.ficha_aprobacion(text) TO authenticated, service_role;

-- 5. Telegram: la ficha va al grupo de analistas ------------------------------------------------
-- Con aprobación previa (18 + aprobacion_previa = true): como respuesta al aviso «Señal por aprobar».
-- Sin ella: solo si ficha_telegram_siempre = true, como mensaje propio. Una vez por versión de la ficha.
CREATE OR REPLACE FUNCTION vigilante.texto_ficha_tg(p_signal bigint)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT concat_ws(E'\n',
    '🧾 <b>Ficha de AVIA</b> · ' || s.codigo || CASE WHEN f.version > 1 THEN ' · actualizada' ELSE '' END,
    '<b>' || vigilante.html_tg(s.titulo) || '</b>',
    '',
    '1. <b>Afirmación:</b> ' || vigilante.html_tg(f.ficha ->> 'afirmacion'),
    '2. <b>Evidencia:</b> peso ' || f.peso || '/5 · ' || vigilante.html_tg(f.ficha #>> '{evidencia,por_que}'),
    '3. <b>Falta:</b> ' || vigilante.html_tg(coalesce((SELECT string_agg(x, '; ') FROM jsonb_array_elements_text(
                                    coalesce(f.ficha -> 'falta', '[]')) x), 'nada pendiente')),
    '4. <b>Riesgo:</b> ' || f.riesgo || ' · ' || vigilante.html_tg(f.ficha #>> '{riesgo,motivo}'),
    '5. <b>Sugerencia:</b> ' || CASE f.sugerencia WHEN 'publicar' THEN '✅ publicar' WHEN 'esperar' THEN '⏳ esperar'
                                                   ELSE '✖️ no publicar' END
                             || ' · ' || vigilante.html_tg(f.ficha #>> '{sugerencia,motivo}'),
    '6. <b>Texto prudente:</b> «' || vigilante.html_tg(f.ficha ->> 'texto_prudente') || '»',
    CASE WHEN f.ficha ? 'verificar_con' THEN 'Verificar con: ' || vigilante.html_tg(f.ficha ->> 'verificar_con') END,
    '<i>Sugerencia de AVIA: decide una persona.</i>')
    FROM vigilante.fichas_aprobacion f JOIN vigilante.signals s ON s.id = f.signal_id
   WHERE f.signal_id = p_signal AND f.estado = 'lista'
$$;
REVOKE ALL ON FUNCTION vigilante.texto_ficha_tg(bigint) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.avisar_fichas()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, extensions, pg_temp AS $$
DECLARE
  v_token text; x record; v_chat text; v_resp record; v_cuerpo jsonb; n_env int := 0; n_mal int := 0;
  v_hay_avisos boolean := to_regclass('vigilante.avisos_revision') IS NOT NULL;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'telegram_bot_token' LIMIT 1;
  EXCEPTION WHEN undefined_table OR invalid_schema_name THEN v_token := NULL;
  END;
  IF coalesce(v_token, '') = '' THEN RETURN jsonb_build_object('error', 'Falta el secreto telegram_bot_token en el Vault'); END IF;

  FOR x IN
    SELECT f.id, f.signal_id, f.version, f.cliente_id,
           CASE WHEN v_hay_avisos THEN (SELECT a.mensaje_id FROM vigilante.avisos_revision a
                                          WHERE a.signal_id = f.signal_id AND a.estado = 'enviado' AND a.mensaje_id IS NOT NULL
                                          ORDER BY a.id DESC LIMIT 1) END AS responder_a
      FROM vigilante.fichas_aprobacion f JOIN vigilante.signals s ON s.id = f.signal_id
     WHERE f.estado = 'lista' AND f.version IS DISTINCT FROM f.telegram_version
       AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion', 'confirmada')
       AND f.preparada_en > now() - interval '24 hours'
     ORDER BY f.preparada_en
     LIMIT 20
  LOOP
    v_chat := vigilante.param(x.cliente_id, 'telegram_analistas_chat') #>> '{}';
    CONTINUE WHEN coalesce(v_chat, '') = '';
    -- sin aviso abierto al que responder, solo si el cliente lo pide
    CONTINUE WHEN x.responder_a IS NULL
              AND NOT coalesce((vigilante.param(x.cliente_id, 'ficha_telegram_siempre') #>> '{}')::boolean, false);
    v_cuerpo := jsonb_build_object('chat_id', v_chat, 'text', vigilante.texto_ficha_tg(x.signal_id), 'parse_mode', 'HTML',
                                   'disable_web_page_preview', true);
    IF x.responder_a IS NOT NULL THEN
      v_cuerpo := v_cuerpo || jsonb_build_object('reply_parameters', jsonb_build_object('message_id', x.responder_a,
                                                                                       'allow_sending_without_reply', true));
    END IF;
    BEGIN
      SELECT * INTO v_resp FROM extensions.http_post('https://api.telegram.org/bot' || v_token || '/sendMessage',
                                                     v_cuerpo::text, 'application/json');
      IF v_resp.status = 200 THEN
        UPDATE vigilante.fichas_aprobacion SET telegram_version = x.version, telegram_error = NULL WHERE id = x.id;
        n_env := n_env + 1;
      ELSE
        UPDATE vigilante.fichas_aprobacion SET telegram_version = x.version,
               telegram_error = left(coalesce(v_resp.content::jsonb ->> 'description', 'HTTP ' || v_resp.status), 300)
         WHERE id = x.id;
        n_mal := n_mal + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      UPDATE vigilante.fichas_aprobacion SET telegram_version = x.version,
             telegram_error = left(replace(SQLERRM, v_token, '***'), 300) WHERE id = x.id;
      n_mal := n_mal + 1;
    END;
  END LOOP;
  RETURN jsonb_build_object('enviadas', n_env, 'fallidas', n_mal);
END $$;
REVOKE ALL ON FUNCTION vigilante.avisar_fichas() FROM public, anon, authenticated;

COMMIT;

-- 6. Tarea de pg_cron (fuera de la transacción; solo en Supabase) -----------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-fichas', '*/2 * * * *', 'SELECT vigilante.avisar_fichas()');
    RAISE NOTICE 'Tarea programada: vigilante-fichas (cada 2 minutos)';
  ELSE
    RAISE NOTICE 'pg_cron no está activo: Database → Extensions → pg_cron, y vuelve a ejecutar este archivo';
  END IF;
END $$;
