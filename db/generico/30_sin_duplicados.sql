-- =============================================================================
-- AVIA Vigilante · Sin duplicados: ni fuentes ni noticias ni señales repetidas
-- Requiere 01 a 29 (como mínimo 14 y 15). Se puede ejecutar más de una vez.
--
-- Qué hace, en tres niveles y siempre en la base (no solo en Python), para que valga
-- aunque el recolector, Hermes y la web escriban a la vez:
--
--   1. FUENTES. Una dirección = una fuente. Índice único por cliente sobre la dirección
--      normalizada (sin http, www, barra final ni parámetros utm). Las fuentes que hoy
--      comparten dirección exacta se juntan solas al ejecutar este archivo (sus noticias
--      y señales pasan a la que se queda; el código viejo queda como alias).
--
--   2. NOTICIAS (raw_items). Un documento = una fila. Índice único por cliente sobre la
--      dirección del documento + disparador que, con un candado por dirección, descarta
--      en silencio la segunda copia si dos procesos la traen a la vez. Las copias que ya
--      existan se marcan «duplicada_de» (no se borra nada).
--
--   3. SEÑALES. Antes de crear una señal nueva, guardar_senal mira si ya hay una para el
--      mismo hecho: (a) alguna de sus noticias ya está en otra señal, o (b) el título se
--      parece mucho (pg_trgm, parámetro senal_parecido_min = 0,6) a una señal viva de los
--      últimos senal_repetida_dias = 7 días. Si la hay, añade las noticias como evidencia
--      a esa señal en vez de crear otra. Para no unir cosas distintas que se escriben
--      parecido: si los títulos citan departamentos distintos («lluvias en La Paz» frente a
--      «lluvias en Cochabamba») o cifras distintas («FIT 2026» frente a «FIT 2027»), no se unen.
--
--   Para las señales repetidas que ya existan (no se juntan solas):
--      select * from vigilante.senales_repetidas();      -- solo mira
--      select vigilante.juntar_senales_repetidas();       -- junta (la repetida pasa a «descartada»)
--
-- La misma noticia contada por DOS MEDIOS distintos (direcciones distintas) se guarda dos
-- veces a propósito: es corroboración (cuenta para la certeza), pero acaba en UNA sola señal.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'vigilante' AND table_name = 'raw_items' AND column_name = 'url_doc') THEN
    RAISE EXCEPTION 'Falta el 15 (catalogo_versiones_analisis): ejecútalo antes que este';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 0. Parecido de textos (pg_trgm). En Supabase va en el esquema «extensions».
-- -----------------------------------------------------------------------------
DO $$
DECLARE v_esq text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'extensions') THEN
      CREATE EXTENSION pg_trgm WITH SCHEMA extensions;
    ELSE
      CREATE EXTENSION pg_trgm;
    END IF;
  END IF;
  SELECT n.nspname INTO v_esq FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm';
  EXECUTE format($f$
    CREATE OR REPLACE FUNCTION vigilante.parecido(a text, b text) RETURNS real
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
    'SELECT CASE WHEN coalesce($1, '''') = '''' OR coalesce($2, '''') = '''' THEN 0::real ELSE %I.similarity($1, $2) END'
  $f$, v_esq);
END $$;
COMMENT ON FUNCTION vigilante.parecido(text, text) IS 'Parecido entre 0 y 1 de dos textos (trigramas). Pasarle textos ya normalizados';

INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'senal_parecido_min', '0.6',
   'Parecido de títulos (0 a 1) a partir del cual una señal nueva se une a una existente en vez de crearse. Más alto = une menos'),
  (NULL, 'senal_repetida_dias', '7',
   'Días hacia atrás en que se buscan señales vivas con título parecido antes de crear una nueva')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 1. FUENTES: una dirección, una fuente
-- -----------------------------------------------------------------------------
-- Dirección de una fuente para compararla: la del documento (15) en minúsculas
CREATE OR REPLACE FUNCTION vigilante.url_fuente(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT lower(vigilante.url_doc(p))
$$;

-- Fuentes vivas que comparten dirección (no cambia nada)
CREATE OR REPLACE FUNCTION vigilante.fuentes_misma_direccion()
RETURNS TABLE (cliente text, direccion text, se_queda text, se_juntan text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH g AS (
    SELECT s.*, c.slug, vigilante.url_fuente(s.url) AS dir,
           row_number() OVER (PARTITION BY s.cliente_id, vigilante.url_fuente(s.url)
                              ORDER BY s.gestionada_web DESC, s.activa DESC, s.created_at, s.id) AS orden,
           count(*) OVER (PARTITION BY s.cliente_id, vigilante.url_fuente(s.url)) AS n
      FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id
     WHERE s.eliminada_en IS NULL AND vigilante.url_fuente(s.url) ~ '[a-z0-9]\.[a-z]'
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
  )
  SELECT k.slug, k.dir, k.codigo,
         ARRAY(SELECT o.codigo FROM g o WHERE o.cliente_id = k.cliente_id AND o.dir = k.dir AND o.orden > 1 ORDER BY o.codigo)
    FROM g k WHERE k.orden = 1 AND k.n > 1
   ORDER BY k.slug, k.dir
$$;
REVOKE ALL ON FUNCTION vigilante.fuentes_misma_direccion() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_misma_direccion() TO authenticated, service_role;

-- Junta las fuentes con la misma dirección exacta. Lo de la repetida pasa a la que se queda.
CREATE OR REPLACE FUNCTION vigilante.juntar_fuentes_misma_direccion()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v_keep vigilante.sources; v_dup vigilante.sources; v_activa boolean; n_grupos int := 0; n_juntadas int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede juntar fuentes'; END IF;
  PERFORM set_config('vigilante.actor', 'limpieza:fuentes_misma_direccion', true);
  FOR r IN SELECT f.*, c.id AS cid FROM vigilante.fuentes_misma_direccion() f JOIN vigilante.clientes c ON c.slug = f.cliente LOOP
    SELECT * INTO v_keep FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = r.se_queda;
    SELECT coalesce(bool_or(activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)), false) INTO v_activa
      FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = ANY (r.se_juntan);
    FOR v_dup IN SELECT * FROM vigilante.sources WHERE cliente_id = r.cid AND codigo = ANY (r.se_juntan) LOOP
      UPDATE vigilante.raw_items         SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.signals           SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.system_logs       SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.source_events     SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.source_candidates SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.source_aliases    SET source_id = v_keep.id WHERE source_id = v_dup.id;
      UPDATE vigilante.source_proposals  SET estado = 'rechazada', decidida_por = 'limpieza', decidida_en = now(),
                                             nota = 'Fuente juntada con ' || v_keep.codigo
       WHERE source_id = v_dup.id AND estado = 'pendiente';
      INSERT INTO vigilante.source_aliases (cliente_id, alias, source_id, creado_por)
      VALUES (r.cid, lower(v_dup.codigo), v_keep.id, 'limpieza-30') ON CONFLICT DO NOTHING;
      UPDATE vigilante.sources SET activa = false, eliminada_en = now(),
             config = config || jsonb_build_object('fusionada_en', v_keep.codigo)
       WHERE id = v_dup.id;
      n_juntadas := n_juntadas + 1;
    END LOOP;
    -- sigue vigilándose si alguna de las juntadas estaba activa (y no era solo una propuesta)
    UPDATE vigilante.sources SET activa = activa OR v_activa,
           config = CASE WHEN v_activa THEN config - 'propuesta_avia' ELSE config END
     WHERE id = v_keep.id;
    n_grupos := n_grupos + 1;
  END LOOP;
  RETURN jsonb_build_object('direcciones', n_grupos, 'fuentes_juntadas', n_juntadas);
END $$;
REVOKE ALL ON FUNCTION vigilante.juntar_fuentes_misma_direccion() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.juntar_fuentes_misma_direccion() TO authenticated, service_role;

-- Primero se juntan las que ya están repetidas; después, el índice impide que vuelva a pasar
DO $$
DECLARE v jsonb;
BEGIN
  v := vigilante.juntar_fuentes_misma_direccion();
  IF (v ->> 'fuentes_juntadas')::int > 0 THEN RAISE NOTICE 'Fuentes con la misma dirección juntadas: %', v; END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS sources_una_por_direccion
  ON vigilante.sources (cliente_id, vigilante.url_fuente(url))
  WHERE eliminada_en IS NULL AND url <> '—' AND url <> '';

-- El catálogo reconoce también la dirección con parámetros de seguimiento o mayúsculas
CREATE OR REPLACE FUNCTION vigilante.fuente_canonica(p_cliente uuid, p_codigo text, p_url text)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(
    (SELECT codigo FROM vigilante.sources WHERE cliente_id = p_cliente AND codigo = p_codigo AND eliminada_en IS NULL),
    (SELECT s.codigo FROM vigilante.source_aliases a JOIN vigilante.sources s ON s.id = a.source_id AND s.eliminada_en IS NULL
      WHERE a.cliente_id = p_cliente AND a.alias = lower(trim(p_codigo))),
    (SELECT s2.codigo FROM vigilante.sources s1 JOIN vigilante.sources s2
        ON s2.cliente_id = s1.cliente_id AND s2.codigo = s1.config ->> 'fusionada_en' AND s2.eliminada_en IS NULL
      WHERE s1.cliente_id = p_cliente AND s1.codigo = p_codigo),
    (SELECT codigo FROM vigilante.sources WHERE cliente_id = p_cliente AND eliminada_en IS NULL
        AND coalesce(p_url, '') <> '' AND vigilante.url_fuente(url) = vigilante.url_fuente(p_url)
      ORDER BY gestionada_web DESC, created_at LIMIT 1))
$$;

-- Aviso claro (en vez del error técnico del índice) si alguien da de alta una dirección repetida
CREATE OR REPLACE FUNCTION vigilante.fuente_sin_repetir()
RETURNS trigger LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
DECLARE v_cod text;
BEGIN
  IF NEW.eliminada_en IS NOT NULL OR coalesce(NEW.url, '') IN ('', '—') THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND vigilante.url_fuente(NEW.url) = vigilante.url_fuente(OLD.url) AND OLD.eliminada_en IS NULL THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('vigilante.sources.url:' || NEW.cliente_id || ':' || vigilante.url_fuente(NEW.url)));
  SELECT codigo INTO v_cod FROM vigilante.sources
   WHERE cliente_id = NEW.cliente_id AND eliminada_en IS NULL AND id <> NEW.id
     AND vigilante.url_fuente(url) = vigilante.url_fuente(NEW.url)
   LIMIT 1;
  IF v_cod IS NOT NULL THEN
    RAISE EXCEPTION 'Esa dirección ya se vigila en la fuente «%»', v_cod USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_fuente_sin_repetir ON vigilante.sources;
CREATE TRIGGER b_fuente_sin_repetir BEFORE INSERT OR UPDATE OF url, eliminada_en ON vigilante.sources
  FOR EACH ROW EXECUTE FUNCTION vigilante.fuente_sin_repetir();

-- -----------------------------------------------------------------------------
-- 2. NOTICIAS: un documento, una fila
-- -----------------------------------------------------------------------------
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS duplicada_de bigint REFERENCES vigilante.raw_items(id) ON DELETE SET NULL;
COMMENT ON COLUMN vigilante.raw_items.duplicada_de IS
  'Copia de otra noticia con la misma dirección (anterior al 30). No se usa; se conserva por si estaba enlazada a una señal';

UPDATE vigilante.raw_items SET url_doc = vigilante.url_doc(url) WHERE url_doc IS NULL;

-- Las copias que ya existen: se marcan contra la más antigua y salen de la cola de la IA
WITH d AS (
  SELECT id, min(id) OVER (PARTITION BY cliente_id, url_doc) AS original
    FROM vigilante.raw_items WHERE duplicada_de IS NULL AND url_doc <> ''
)
UPDATE vigilante.raw_items r SET duplicada_de = d.original,
       estado = CASE WHEN r.estado IN ('nuevo', 'en_cola') THEN 'descartado' ELSE r.estado END,
       motivo_descarte = CASE WHEN r.estado IN ('nuevo', 'en_cola') THEN 'repetida de #' || d.original ELSE r.motivo_descarte END
  FROM d WHERE r.id = d.id AND d.id <> d.original;

CREATE UNIQUE INDEX IF NOT EXISTS raw_items_un_documento
  ON vigilante.raw_items (cliente_id, url_doc) WHERE duplicada_de IS NULL AND url_doc <> '';

-- Aunque dos procesos traigan la misma noticia a la vez, entra una sola:
-- la segunda espera al candado, ve la primera y no se inserta (insertar_noticias la cuenta como «repetida»).
CREATE OR REPLACE FUNCTION vigilante.noticia_sin_repetir()
RETURNS trigger LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  NEW.url_doc := coalesce(nullif(NEW.url_doc, ''), vigilante.url_doc(NEW.url));
  IF NEW.duplicada_de IS NOT NULL OR NEW.url_doc = '' THEN RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('vigilante.raw_items.url:' || NEW.cliente_id || ':' || NEW.url_doc));
  IF EXISTS (SELECT 1 FROM vigilante.raw_items WHERE cliente_id = NEW.cliente_id AND url_doc = NEW.url_doc AND duplicada_de IS NULL)
     OR (NEW.id_externo IS NOT NULL AND EXISTS (
          SELECT 1 FROM vigilante.raw_items WHERE cliente_id = NEW.cliente_id AND id_externo = NEW.id_externo
             AND source_id IS NOT DISTINCT FROM NEW.source_id AND duplicada_de IS NULL)) THEN
    RETURN NULL;   -- ya está: no se guarda otra vez
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_noticia_sin_repetir ON vigilante.raw_items;
CREATE TRIGGER b_noticia_sin_repetir BEFORE INSERT ON vigilante.raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.noticia_sin_repetir();

-- -----------------------------------------------------------------------------
-- 3. SEÑALES: un hecho, una señal
-- -----------------------------------------------------------------------------
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS repetidas_unidas integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN vigilante.signals.repetidas_unidas IS
  'Cuántas veces se intentó crear esta misma señal y se unió aquí en lugar de duplicarla (30)';

-- Cifras de un texto («FIT 2026, 300 expositores» → {2026, 300})
CREATE OR REPLACE FUNCTION vigilante.cifras(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(ARRAY(SELECT DISTINCT m[1] FROM regexp_matches(vigilante.texto_norm(p), '(\d+)', 'g') m ORDER BY 1), '{}')
$$;

-- Territorios (no país) que nombra un texto: por nombre, capital o alias
CREATE OR REPLACE FUNCTION vigilante.territorios_en(p_cliente uuid, p text)
RETURNS integer[] LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(ARRAY(
    SELECT t.id FROM vigilante.territorios t
     WHERE t.cliente_id = p_cliente AND t.nivel <> 'pais'
       AND (vigilante.contiene(vigilante.texto_norm(p), vigilante.texto_norm(t.nombre))
            OR vigilante.contiene(vigilante.texto_norm(p), vigilante.texto_norm(t.datos ->> 'capital'))
            OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(t.datos -> 'alias') = 'array' THEN t.datos -> 'alias' ELSE '[]' END) a
                        WHERE vigilante.contiene(vigilante.texto_norm(p), vigilante.texto_norm(a))))
     ORDER BY t.id), '{}')
$$;

-- ¿Dos títulos cuentan el mismo hecho? Parecido alto y sin cifras ni territorios que se contradigan.
CREATE OR REPLACE FUNCTION vigilante.mismo_hecho(p_cliente uuid, a text, b text, p_min real DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE na text := vigilante.texto_norm(a); nb text := vigilante.texto_norm(b);
        ca text[]; cb text[]; ta int[]; tb int[];
        v_min real := coalesce(p_min, (vigilante.param(p_cliente, 'senal_parecido_min') #>> '{}')::real, 0.6);
BEGIN
  IF na = '' OR nb = '' THEN RETURN false; END IF;
  IF na <> nb AND vigilante.parecido(na, nb) < v_min THEN RETURN false; END IF;
  ca := vigilante.cifras(na); cb := vigilante.cifras(nb);
  IF cardinality(ca) > 0 AND cardinality(cb) > 0 AND NOT (ca <@ cb OR cb <@ ca) THEN RETURN false; END IF;
  ta := vigilante.territorios_en(p_cliente, na); tb := vigilante.territorios_en(p_cliente, nb);
  IF cardinality(ta) > 0 AND cardinality(tb) > 0 AND NOT (ta && tb) THEN RETURN false; END IF;
  RETURN true;
END $$;

-- La señal que ya cuenta este hecho (o nada). Mira las noticias y el título.
CREATE OR REPLACE FUNCTION vigilante.senal_existente(p_cliente uuid, p_titulo text, p_noticias bigint[] DEFAULT '{}',
                                                    p_departamentos jsonb DEFAULT NULL)
RETURNS TABLE (signal_id bigint, codigo text, motivo text)
LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE v_dias int := coalesce((vigilante.param(p_cliente, 'senal_repetida_dias') #>> '{}')::int, 7);
        v_deps int[]; v_titulos text[];
BEGIN
  -- (a) alguna de sus noticias (o la misma dirección) ya está en otra señal
  RETURN QUERY
    SELECT s.id, s.codigo, 'misma noticia'::text
      FROM vigilante.raw_items r
      JOIN vigilante.raw_items r2 ON r2.cliente_id = r.cliente_id AND (r2.id = r.id OR (r.url_doc <> '' AND r2.url_doc = r.url_doc))
      JOIN vigilante.signal_raw_items sr ON sr.raw_item_id = r2.id
      JOIN vigilante.signals s ON s.id = sr.signal_id AND s.duplicado_de IS NULL
     WHERE r.cliente_id = p_cliente AND r.id = ANY (coalesce(p_noticias, '{}'))
     ORDER BY (s.estado NOT IN ('descartada', 'cerrada')) DESC, s.id
     LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  -- (b) título parecido a una señal viva reciente (o al de alguna de sus noticias)
  v_deps := CASE WHEN jsonb_typeof(p_departamentos) = 'array' THEN ARRAY(
              SELECT t.id FROM vigilante.territorios t WHERE t.cliente_id = p_cliente
                 AND vigilante.texto_norm(t.nombre) IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(p_departamentos) x))
            ELSE '{}' END;
  v_titulos := ARRAY[p_titulo] || ARRAY(SELECT titulo FROM vigilante.raw_items WHERE cliente_id = p_cliente AND id = ANY (coalesce(p_noticias, '{}')));
  RETURN QUERY
    SELECT s.id, s.codigo, format('título parecido (%s)', round(m.p::numeric, 2))
      FROM vigilante.signals s
      CROSS JOIN LATERAL (
        SELECT max(vigilante.parecido(vigilante.texto_norm(t), vigilante.texto_norm(o))) AS p,
               bool_or(vigilante.mismo_hecho(p_cliente, t, o)) AS mismo
          FROM unnest(v_titulos) t,
               unnest(ARRAY[s.titulo] || ARRAY(SELECT r.titulo FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                               WHERE sr.signal_id = s.id LIMIT 20)) o
      ) m
     WHERE s.cliente_id = p_cliente AND s.duplicado_de IS NULL
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND greatest(s.created_at, s.updated_at) > now() - make_interval(days => v_dias)
       AND m.mismo
       -- departamentos indicados que no coinciden: hechos distintos
       AND (cardinality(v_deps) = 0
            OR NOT EXISTS (SELECT 1 FROM vigilante.signal_territorios st WHERE st.signal_id = s.id)
            OR EXISTS (SELECT 1 FROM vigilante.signal_territorios st WHERE st.signal_id = s.id AND st.territorio_id = ANY (v_deps)))
     ORDER BY m.p DESC, s.id
     LIMIT 1;
END $$;

-- guardar_senal del 15 queda dentro; la de fuera evita crear una señal que ya existe
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'vigilante' AND p.proname = 'guardar_senal_15') THEN
    ALTER FUNCTION vigilante.guardar_senal(text, jsonb) RENAME TO guardar_senal_15;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.guardar_senal_15(text, jsonb) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.guardar_senal(p_cliente text, p_senal jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); v_ids bigint[]; v_s jsonb := p_senal; v_res jsonb;
  v_ex_id bigint; v_ex_cod text; v_ex_motivo text;
BEGIN
  IF nullif(trim(p_senal ->> 'codigo'), '') IS NULL AND coalesce(trim(p_senal ->> 'titulo'), '') <> '' THEN
    -- el mismo candado que usa la creación de códigos: dos señales iguales a la vez no pasan las dos
    PERFORM pg_advisory_xact_lock(hashtext('vigilante.signals.codigo:' || v_cliente));
    v_ids := CASE WHEN jsonb_typeof(p_senal -> 'noticias') = 'array'
                  THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(p_senal -> 'noticias') x WHERE x ~ '^\d+$') ELSE '{}' END;
    SELECT e.signal_id, e.codigo, e.motivo INTO v_ex_id, v_ex_cod, v_ex_motivo FROM vigilante.senal_existente(v_cliente, p_senal ->> 'titulo', v_ids, p_senal -> 'departamentos') e;
    IF v_ex_id IS NOT NULL THEN
      -- se une a la existente: suma las noticias como evidencia y conserva su título y resumen
      SELECT p_senal || jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen)
        INTO v_s FROM vigilante.signals s WHERE s.id = v_ex_id;
    END IF;
  END IF;

  v_res := vigilante.guardar_senal_15(p_cliente, v_s);

  IF v_ex_id IS NOT NULL THEN
    UPDATE vigilante.signals SET repetidas_unidas = repetidas_unidas + 1 WHERE id = v_ex_id;
    v_res := v_res || jsonb_build_object('repetida', true, 'unida_por', v_ex_motivo,
               'nota', format('Ya existía la señal %s para este hecho: las noticias se añadieron como evidencia, no se creó otra', v_ex_cod));
  END IF;
  RETURN v_res;
END $$;
REVOKE ALL ON FUNCTION vigilante.guardar_senal(text, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.guardar_senal(text, jsonb) TO service_role;

-- Señales repetidas que ya existen (no cambia nada). La que se queda: la publicada, si no la más antigua.
CREATE OR REPLACE FUNCTION vigilante.senales_repetidas(p_dias int DEFAULT 30)
RETURNS TABLE (cliente text, se_queda text, repetida text, titulo_se_queda text, titulo_repetida text, parecido numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH v AS (
    SELECT s.* FROM vigilante.signals s
     WHERE s.duplicado_de IS NULL AND s.estado NOT IN ('descartada', 'cerrada')
       AND greatest(s.created_at, s.updated_at) > now() - make_interval(days => p_dias)
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
  )
  SELECT c.slug, k.codigo, d.codigo, k.titulo, d.titulo,
         round(vigilante.parecido(vigilante.texto_norm(k.titulo), vigilante.texto_norm(d.titulo))::numeric, 2)
    FROM v k JOIN v d ON d.cliente_id = k.cliente_id AND d.id <> k.id
    JOIN vigilante.clientes c ON c.id = k.cliente_id
   WHERE d.estado <> 'publicada'                                   -- lo publicado no se toca solo
     AND ((k.estado = 'publicada') > (d.estado = 'publicada') OR ((k.estado = 'publicada') = (d.estado = 'publicada') AND k.id < d.id))
     AND (EXISTS (SELECT 1 FROM vigilante.signal_raw_items a JOIN vigilante.signal_raw_items b ON b.raw_item_id = a.raw_item_id
                   WHERE a.signal_id = k.id AND b.signal_id = d.id)
          OR vigilante.mismo_hecho(k.cliente_id, k.titulo, d.titulo))
   ORDER BY c.slug, k.codigo, d.codigo
$$;
REVOKE ALL ON FUNCTION vigilante.senales_repetidas(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.senales_repetidas(int) TO authenticated, service_role;

-- Junta las repetidas: sus noticias y departamentos pasan a la que se queda; la repetida queda «descartada»
CREATE OR REPLACE FUNCTION vigilante.juntar_senales_repetidas(p_dias int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v_k vigilante.signals; v_d vigilante.signals; n int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede juntar señales'; END IF;
  PERFORM set_config('vigilante.actor', 'limpieza:senales_repetidas', true);
  FOR r IN SELECT x.*, c.id AS cid FROM vigilante.senales_repetidas(p_dias) x JOIN vigilante.clientes c ON c.slug = x.cliente LOOP
    SELECT * INTO v_k FROM vigilante.signals WHERE cliente_id = r.cid AND codigo = r.se_queda;
    SELECT * INTO v_d FROM vigilante.signals WHERE cliente_id = r.cid AND codigo = r.repetida;
    -- en cadena (A≈B≈C): si una ya se juntó en esta vuelta, se salta
    CONTINUE WHEN v_k.duplicado_de IS NOT NULL OR v_d.duplicado_de IS NOT NULL OR v_d.estado = 'descartada';
    INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
    SELECT v_k.id, raw_item_id, r.cid FROM vigilante.signal_raw_items WHERE signal_id = v_d.id ON CONFLICT DO NOTHING;
    INSERT INTO vigilante.signal_territorios (signal_id, cliente_id, territorio_id)
    SELECT v_k.id, r.cid, territorio_id FROM vigilante.signal_territorios WHERE signal_id = v_d.id ON CONFLICT DO NOTHING;
    UPDATE vigilante.signals SET duplicado_de = v_k.id, estado = 'descartada',
           motivo_revision = 'Repetida de ' || v_k.codigo
     WHERE id = v_d.id;
    UPDATE vigilante.signals SET repetidas_unidas = repetidas_unidas + 1 + v_d.repetidas_unidas WHERE id = v_k.id;
    n := n + 1;
  END LOOP;
  RETURN jsonb_build_object('senales_juntadas', n);
END $$;
REVOKE ALL ON FUNCTION vigilante.juntar_senales_repetidas(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.juntar_senales_repetidas(int) TO authenticated, service_role;

COMMIT;
