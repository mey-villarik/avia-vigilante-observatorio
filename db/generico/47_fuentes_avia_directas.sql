-- =============================================================================
-- 47. Fuentes que encuentra AVIA: sin duplicados y sin aprobación manual
-- =============================================================================
-- Qué pidió Meysel (2026-11-22): las fuentes que AVIA encuentra se añaden solas, sin pasar por
-- «Aprobar / Rechazar», pero nunca repetidas. Ejemplo real: SENAMHI ya estaba en el catálogo
-- (senamhi.gob.bo/alertas3.php) y aun así aparecían dos candidatas más del mismo sitio
-- (senamhi.gob.bo/alertas.php y senamhi.gob.bo/api/alertas/active-alerts). El usuario puede
-- eliminar cualquier fuente, y la tabla dice cuáles puso el usuario y cuáles sugirió AVIA.
--
-- Por qué salían repetidas: desde el 30, «fuente_canonica» solo reconoce la MISMA dirección
-- (el paso «mismo sitio web» del 12 se quitó para no confundir códigos al sincronizar). Así,
-- otra página del mismo sitio parecía una fuente nueva.
--
-- Qué hace este script:
--   1. sources.origen: 'usuario' (alta en la web o catálogo inicial) o 'avia' (la encontró AVIA).
--      Se rellena para las que ya existen: las que fueron propuesta o candidata de AVIA = 'avia'.
--   2. vigilante.sitio(url): el sitio de una dirección para comparar («www.senamhi.gob.bo/x» y
--      «alertas.senamhi.gob.bo/y» → «senamhi.gob.bo»). En los agregadores (Google News, redes…)
--      cada dirección sigue siendo una fuente distinta, como en el 12.
--   3. registrar_candidata (la usan proponer_fuente de Hermes y la sincronización con
--      vigilante.json) ya NO deja la fuente pendiente: si es nueva de verdad, la da de alta y
--      activa al momento (origen 'avia'). NO la añade si:
--        · ya hay en el catálogo una fuente de ese mismo sitio (activa o en pausa);
--        · un usuario eliminó una fuente de ese sitio (AVIA no vuelve a meterla);
--        · se rechazó en los últimos 90 días (decisiones anteriores al 47).
--      La candidata queda como registro: 'aprobada' (añadida, con su código) o 'duplicada'.
--   4. Limpieza al instalar: las candidatas pendientes y las «propuestas de AVIA» en pausa
--      (del 11) se activan con las mismas reglas; las repetidas se marcan 'duplicada' (las de
--      la tabla de candidatas) o se eliminan (las que estaban en pausa en el catálogo).
--   5. fuentes_web() devuelve «origen» para la columna nueva de la pestaña Fuentes.
--   6. decidir_candidata se mantiene solo por compatibilidad (ya no quedan pendientes).
--
-- Cómo se elige lo que AVIA no sabe:
--   · tipo: el que diga Hermes; si no, 'oficial' para .gob.bo / .gov / .gob.xx / .mil.bo,
--     'organismo_internacional' para OPS/OMS, ONU, CEPAL, CAF, BID, Banco Mundial…; si no, 'no_oficial'
--     (las no oficiales siempre pasan por revisión del analista).
--   · canal: la categoría más frecuente de las señales de sus noticias de respaldo; si no hay, 'turismo'.
--   · cómo se lee: RSS si la dirección parece un feed; si no, página web. Cada 60 minutos.
--   El usuario puede cambiar todo esto (o eliminarla) desde la ficha de la fuente.
--
-- Necesita del 15 en adelante (probado sobre 01..46). Pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT origen, count(*) FROM vigilante.sources WHERE eliminada_en IS NULL GROUP BY 1;
-- Prueba: 99_prueba_fuentes_avia.sql (termina en ROLLBACK). Se puede ejecutar más de una vez.
-- =============================================================================
BEGIN;

-- 1. Origen de cada fuente -------------------------------------------------------------
ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS origen text NOT NULL DEFAULT 'usuario';
ALTER TABLE vigilante.sources DROP CONSTRAINT IF EXISTS sources_origen_check;
ALTER TABLE vigilante.sources ADD CONSTRAINT sources_origen_check CHECK (origen IN ('usuario', 'avia'));
COMMENT ON COLUMN vigilante.sources.origen IS
  'usuario = la dio de alta una persona (o venía en el catálogo inicial); avia = la encontró AVIA y se añadió sola';

UPDATE vigilante.sources s SET origen = 'avia'
 WHERE origen = 'usuario'
   AND (s.config ? 'propuesta_avia'
        OR EXISTS (SELECT 1 FROM vigilante.source_candidates c WHERE c.source_id = s.id AND c.estado = 'aprobada')
        OR EXISTS (SELECT 1 FROM vigilante.source_events e WHERE e.source_id = s.id AND e.accion = 'aprobada'));

-- La candidata puede quedar «duplicada» (no se añadió porque ese sitio ya se vigila)
ALTER TABLE vigilante.source_candidates DROP CONSTRAINT IF EXISTS source_candidates_estado_check;
ALTER TABLE vigilante.source_candidates ADD CONSTRAINT source_candidates_estado_check
  CHECK (estado IN ('pendiente', 'aprobada', 'rechazada', 'duplicada'));

-- 2. Sitio de una dirección ------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.sitio(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
    WHEN h IS NULL OR h = '' THEN d
    -- agregador: dominio() ya devolvió la dirección entera, cada una es una fuente
    WHEN d <> h THEN d
    -- sitios donde cada subdominio es de otro dueño
    WHEN h ~ '\.(blogspot\.com|wordpress\.com|github\.io|gitlab\.io|substack\.com|wixsite\.com|weebly\.com|netlify\.app|vercel\.app)$' THEN h
    WHEN h ~ '^[0-9.]+$' THEN h
    -- dominios de segundo nivel de país: gob.bo, com.bo, org.bo, gov.br, co.uk…
    WHEN h ~ '\.(gob|gov|com|org|net|edu|mil|int|co|ac|nom|web|info|tv)\.[a-z]{2}$' THEN substring(h FROM '([^.]+\.[^.]+\.[^.]+)$')
    ELSE coalesce(substring(h FROM '([^.]+\.[^.]+)$'), h) END
  FROM (SELECT vigilante.dominio(p) AS d,
               substring(lower(trim(coalesce(p, ''))) FROM '^(?:https?://)?(?:www\.)?([^/:?#]+)') AS h) x
$$;
COMMENT ON FUNCTION vigilante.sitio(text) IS
  'Sitio de una dirección para no repetir fuentes: «alertas.senamhi.gob.bo/x» → «senamhi.gob.bo». Agregadores: la dirección entera';

-- Fuente del catálogo que ya cubre ese sitio (viva, o eliminada por una persona). NULL si no hay.
CREATE OR REPLACE FUNCTION vigilante.fuente_mismo_sitio(p_cliente uuid, p_url text, p_excluir integer DEFAULT NULL)
RETURNS TABLE (codigo text, nombre text, eliminada boolean)
LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT s.codigo, s.nombre, s.eliminada_en IS NOT NULL
    FROM vigilante.sources s
   WHERE s.cliente_id = p_cliente AND coalesce(p_url, '') <> '' AND s.url NOT IN ('', '—')
     AND (p_excluir IS NULL OR s.id <> p_excluir)
     AND vigilante.sitio(s.url) = vigilante.sitio(p_url)
     AND (s.eliminada_en IS NULL
          -- eliminada por una persona (no las juntadas ni las que el 15 pasó a candidatas)
          OR (s.config ? 'eliminada_por' AND NOT s.config ? 'fusionada_en' AND NOT s.config ? 'pasada_a_candidata'))
   ORDER BY s.eliminada_en IS NOT NULL, s.activa DESC, s.gestionada_web DESC, s.created_at
   LIMIT 1
$$;
REVOKE ALL ON FUNCTION vigilante.fuente_mismo_sitio(uuid, text, integer) FROM public, anon;

-- Tipo y canal que AVIA pone cuando nadie se los dice
CREATE OR REPLACE FUNCTION vigilante._tipo_fuente_avia(p_url text, p_tipo text)
RETURNS vigilante.tipo_fuente LANGUAGE sql IMMUTABLE SET search_path = vigilante, pg_temp AS $$
  SELECT CASE
    WHEN p_tipo IN ('oficial', 'organismo_internacional', 'medio', 'no_oficial') THEN p_tipo::vigilante.tipo_fuente
    WHEN vigilante.sitio(p_url) ~ '(^|\.)(gob|gov|mil)\.[a-z]{2}$' OR vigilante.sitio(p_url) ~ '\.gov$' THEN 'oficial'
    WHEN vigilante.sitio(p_url) ~ '^(paho\.org|who\.int|un\.org|cepal\.org|caf\.com|iadb\.org|worldbank\.org|undp\.org|unwto\.org|untourism\.int|fao\.org|unicef\.org|imf\.org|oas\.org|wmo\.int|unesco\.org|ilo\.org)$'
      OR vigilante.sitio(p_url) ~ '\.int$' THEN 'organismo_internacional'
    ELSE 'no_oficial' END
$$;

CREATE OR REPLACE FUNCTION vigilante._canal_fuente_avia(p_cliente uuid, p_evidencia jsonb)
RETURNS text LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT coalesce(
    (SELECT sg.categoria FROM vigilante.signals sg
      WHERE sg.cliente_id = p_cliente
        AND sg.raw_item_id IN (SELECT x::bigint FROM jsonb_array_elements_text(
                                 CASE WHEN jsonb_typeof(p_evidencia) = 'array' THEN p_evidencia ELSE '[]' END) x WHERE x ~ '^\d+$')
      GROUP BY sg.categoria ORDER BY count(*) DESC, sg.categoria LIMIT 1),
    'turismo')
$$;

-- 3. Alta directa de lo que encuentra AVIA ---------------------------------------------------
-- Crea y activa la fuente (o explica por qué no). No comprueba permisos: solo la llaman
-- registrar_candidata (Hermes / sincronización) y la limpieza de abajo.
CREATE OR REPLACE FUNCTION vigilante._alta_fuente_avia(p_cliente uuid, p_nombre text, p_url text, p_motivo text,
                                                      p_codigo text, p_tipo text, p_evidencia jsonb, p_por text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cod text; v_dup record; v_base text; v_codigo text; n int := 1; v_canal text; v_id integer; v_nombre text;
BEGIN
  IF coalesce(p_url, '') !~* '^https?://[^/\s]+\.[a-z]' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Hace falta una dirección web real (https://...) que se haya visto, no una inventada');
  END IF;
  -- dos rondas a la vez no pueden añadir el mismo sitio
  PERFORM pg_advisory_xact_lock(hashtext('vigilante.sitio:' || p_cliente || ':' || vigilante.sitio(p_url)));

  v_cod := vigilante.fuente_canonica(p_cliente, p_codigo, p_url);
  IF v_cod IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'duplicada', true, 'motivo', 'Ya está en el catálogo', 'codigo', v_cod);
  END IF;
  SELECT * INTO v_dup FROM vigilante.fuente_mismo_sitio(p_cliente, p_url);
  IF FOUND THEN
    RETURN jsonb_build_object('ok', false, 'duplicada', true, 'codigo', v_dup.codigo,
      'motivo', CASE WHEN v_dup.eliminada
                     THEN format('Un usuario eliminó la fuente «%s» de ese mismo sitio: AVIA no la vuelve a añadir', v_dup.nombre)
                     ELSE format('Ese sitio ya se vigila en la fuente «%s»', v_dup.nombre) END);
  END IF;
  IF EXISTS (SELECT 1 FROM vigilante.source_candidates WHERE cliente_id = p_cliente AND url_doc = vigilante.url_doc(p_url)
              AND estado = 'rechazada' AND decidida_en > now() - interval '90 days') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Un administrador la rechazó en los últimos 90 días');
  END IF;

  v_nombre := left(coalesce(nullif(trim(p_nombre), ''), vigilante.sitio(p_url)), 200);
  v_canal := vigilante._canal_fuente_avia(p_cliente, p_evidencia);
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre) VALUES (p_cliente, v_canal, v_canal) ON CONFLICT DO NOTHING;
  v_base := left(trim(both '_' from regexp_replace(lower(translate(coalesce(nullif(trim(p_codigo), ''), v_nombre),
                 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')), '[^a-z0-9]+', '_', 'g')), 40);
  v_base := coalesce(nullif(v_base, ''), 'fuente_avia');
  v_codigo := v_base;
  WHILE EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = p_cliente AND codigo = v_codigo) LOOP
    n := n + 1; v_codigo := v_base || '_' || n;
  END LOOP;

  PERFORM set_config('vigilante.actor', 'avia', true);
  INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, origen, notas, config)
  VALUES (p_cliente, v_codigo, v_nombre, trim(p_url), vigilante._tipo_fuente_avia(p_url, p_tipo),
          CASE WHEN p_url ~* '(\.xml|\.rss|/rss|/feed|/atom)([/?#]|$)' THEN 'rss' ELSE 'http_html' END::vigilante.metodo_fuente,
          ARRAY[v_canal], 60, true, 'avia', nullif(trim(p_motivo), ''),
          jsonb_build_object('alta_por', 'AVIA', 'propuesta_por', coalesce(p_por, 'avia'), 'estado', 'UNKNOWN', 'revisar_desde', now()))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'codigo', v_codigo, 'source_id', v_id, 'canal', v_canal,
                            'nota', 'Añadida al catálogo: AVIA la vigila desde su próxima ronda. El usuario puede eliminarla');
END $$;
REVOKE ALL ON FUNCTION vigilante._alta_fuente_avia(uuid, text, text, text, text, text, jsonb, text) FROM public, anon, authenticated;

-- Misma firma que en el 15: Hermes (proponer_fuente) y la sincronización la siguen llamando igual.
CREATE OR REPLACE FUNCTION vigilante.registrar_candidata(p_cliente uuid, p_nombre text, p_url text, p_motivo text,
                                                        p_codigo text DEFAULT NULL, p_tipo text DEFAULT NULL,
                                                        p_evidencia jsonb DEFAULT '[]', p_por text DEFAULT 'avia')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r jsonb; v_estado text;
BEGIN
  r := vigilante._alta_fuente_avia(p_cliente, p_nombre, p_url, p_motivo, p_codigo, p_tipo, p_evidencia, p_por);
  v_estado := CASE WHEN (r ->> 'ok')::boolean THEN 'aprobada' WHEN (r ->> 'duplicada')::boolean THEN 'duplicada' END;
  -- registro de lo que AVIA encontró (una fila por dirección; si se repite, suma «veces»)
  IF v_estado IS NOT NULL THEN
    UPDATE vigilante.source_candidates SET veces = veces + 1, updated_at = now()
     WHERE cliente_id = p_cliente AND url_doc = vigilante.url_doc(p_url) AND estado = v_estado
       AND (v_estado = 'duplicada' OR source_id = (r ->> 'source_id')::int);
    IF NOT FOUND THEN
      INSERT INTO vigilante.source_candidates (cliente_id, nombre, url, url_doc, codigo_sugerido, tipo_sugerido, motivo, evidencia,
                                               propuesta_por, estado, decidida_por, decidida_en, nota, source_id)
      VALUES (p_cliente, left(coalesce(nullif(trim(p_nombre), ''), vigilante.sitio(p_url)), 200), trim(p_url), vigilante.url_doc(p_url),
              nullif(trim(p_codigo), ''), p_tipo, p_motivo, coalesce(p_evidencia, '[]'), coalesce(p_por, 'avia'),
              v_estado, 'AVIA (automático)', now(), r ->> 'motivo',
              (SELECT id FROM vigilante.sources WHERE cliente_id = p_cliente AND codigo = r ->> 'codigo'));
    END IF;
  END IF;
  RETURN r;
END $$;

-- 4. Limpieza al instalar: lo pendiente se activa o se marca repetido -------------------------
CREATE OR REPLACE FUNCTION vigilante.activar_fuentes_avia_pendientes(p_aplicar boolean DEFAULT false)
RETURNS TABLE (cliente text, nombre text, url text, accion text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v jsonb; v_dup record; v_vistos text[] := '{}';
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede hacer esta limpieza'; END IF;
  -- a) propuestas de AVIA que el 11 dejó en pausa dentro del catálogo
  FOR r IN
    SELECT s.*, c.slug FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id
     WHERE s.eliminada_en IS NULL AND NOT s.activa AND s.config ? 'propuesta_avia'
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
     ORDER BY c.slug, s.created_at, s.id
  LOOP
    cliente := r.slug; nombre := r.nombre; url := r.url;
    SELECT * INTO v_dup FROM vigilante.fuente_mismo_sitio(r.cliente_id, r.url, r.id);
    IF FOUND THEN
      accion := format('repetida de «%s»: %s', v_dup.codigo, CASE WHEN p_aplicar THEN 'eliminada' ELSE 'se eliminaría' END);
      IF p_aplicar THEN
        UPDATE vigilante.sources SET eliminada_en = now(), origen = 'avia',
               config = (config - 'propuesta_avia') || jsonb_build_object('repetida_de', v_dup.codigo)
         WHERE id = r.id;
      END IF;
    ELSE
      accion := CASE WHEN p_aplicar THEN 'activada' ELSE 'se activaría' END;
      IF p_aplicar THEN
        UPDATE vigilante.sources SET activa = true, origen = 'avia',
               config = (config - 'propuesta_avia') || jsonb_build_object('alta_por', 'AVIA', 'revisar_desde', now())
         WHERE id = r.id;
      END IF;
    END IF;
    RETURN NEXT;
  END LOOP;
  -- b) candidatas pendientes (las más vistas primero: si dos son del mismo sitio, se queda esa)
  FOR r IN
    SELECT k.*, c.slug FROM vigilante.source_candidates k JOIN vigilante.clientes c ON c.id = k.cliente_id
     WHERE k.estado = 'pendiente' AND (vigilante.cliente_actual() IS NULL OR k.cliente_id = vigilante.cliente_actual())
     ORDER BY c.slug, k.veces DESC, k.created_at, k.id
  LOOP
    cliente := r.slug; nombre := r.nombre; url := r.url;
    IF NOT p_aplicar THEN
      SELECT * INTO v_dup FROM vigilante.fuente_mismo_sitio(r.cliente_id, r.url);
      accion := CASE WHEN vigilante.fuente_canonica(r.cliente_id, r.codigo_sugerido, r.url) IS NOT NULL THEN 'ya está en el catálogo'
                     WHEN FOUND THEN format('repetida de «%s»', v_dup.codigo)
                     WHEN r.cliente_id || ':' || vigilante.sitio(r.url) = ANY (v_vistos) THEN 'repetida de otra candidata de este sitio'
                     ELSE 'se activaría' END;
      v_vistos := v_vistos || (r.cliente_id || ':' || vigilante.sitio(r.url));
    ELSE
      v := vigilante._alta_fuente_avia(r.cliente_id, r.nombre, r.url, r.motivo, r.codigo_sugerido, r.tipo_sugerido, r.evidencia, r.propuesta_por);
      UPDATE vigilante.source_candidates SET
             estado = CASE WHEN (v ->> 'ok')::boolean THEN 'aprobada' WHEN (v ->> 'duplicada')::boolean THEN 'duplicada' ELSE 'rechazada' END,
             decidida_por = 'AVIA (automático)', decidida_en = now(), nota = v ->> 'motivo', updated_at = now(),
             source_id = (SELECT id FROM vigilante.sources WHERE cliente_id = r.cliente_id AND codigo = v ->> 'codigo')
       WHERE id = r.id;
      accion := CASE WHEN (v ->> 'ok')::boolean THEN 'activada como ' || (v ->> 'codigo') ELSE v ->> 'motivo' END;
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION vigilante.activar_fuentes_avia_pendientes(boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.activar_fuentes_avia_pendientes(boolean) TO authenticated, service_role;

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM vigilante.activar_fuentes_avia_pendientes(true) LOOP
    RAISE NOTICE '% · % (%) → %', r.cliente, r.nombre, r.url, r.accion;
  END LOOP;
END $$;

-- 5. La web: origen de cada fuente ----------------------------------------------------------
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz,
               propuesta boolean, errores_seguidos int, ultimo_exito_en timestamptz, ultimo_error text,
               reconocida_por text, reconocida_en timestamptz, reconocida_nota text,
               revision_pedida_en timestamptz, revision_pedida_por text, fusionada_en text,
               origen text, motivo_avia text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz,
         coalesce((config ->> 'propuesta_avia')::boolean, false), errores_seguidos, ultimo_exito_en, ultimo_error,
         config ->> 'reconocida_por', (config ->> 'reconocida_en')::timestamptz, config ->> 'reconocida_nota',
         (config ->> 'revision_pedida_en')::timestamptz, config ->> 'revision_pedida_por', config ->> 'fusionada_en',
         origen, CASE WHEN origen = 'avia' THEN notas END
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

-- candidatas_web: solo las últimas 30 días que AVIA añadió o descartó por repetidas (ya no hay pendientes)
CREATE OR REPLACE FUNCTION vigilante.candidatas_web()
RETURNS TABLE (id bigint, nombre text, url text, motivo text, propuesta_por text, veces int, evidencia jsonb,
               estado text, propuesta_en timestamptz, decidida_por text, decidida_en timestamptz, nota text, codigo text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT c.id, c.nombre, c.url, c.motivo, c.propuesta_por, c.veces,
         (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'titulo', r.titulo, 'url', r.url)), '[]')
            FROM vigilante.raw_items r WHERE r.id IN (SELECT x::bigint FROM jsonb_array_elements_text(c.evidencia) x WHERE x ~ '^\d+$')),
         c.estado, c.created_at, c.decidida_por, c.decidida_en, c.nota, s.codigo
    FROM vigilante.source_candidates c LEFT JOIN vigilante.sources s ON s.id = c.source_id
   WHERE c.cliente_id = vigilante.cliente_actual() AND (c.estado = 'pendiente' OR c.decidida_en > now() - interval '30 days')
   ORDER BY c.estado <> 'pendiente', c.decidida_en DESC NULLS LAST, c.created_at DESC
$$;

COMMIT;
