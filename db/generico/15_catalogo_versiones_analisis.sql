-- =============================================================================
-- AVIA Vigilante · Catálogo cerrado, versiones de documentos, análisis guardado,
-- oportunidades en dos niveles y tareas para el agente Hermes
-- Requiere 01 a 14. Se puede ejecutar más de una vez.
--
-- Por qué (revisión 2026-11-09): la IA hacía trabajo que conviene resolver con código.
-- Eso facilitaba que inventara fuentes, repitiera análisis y gastara tokens.
--
--   RECOGER (sin IA)  → el recolector lee SOLO fuentes del catálogo, cuando les toca según
--                       sources.proxima_revision_en; usa ETag / Last-Modified (304 = sin cambios).
--   DETECTAR CAMBIOS  → cada noticia es un DOCUMENTO (URL normalizada o id del proveedor) con
--   (sin IA)            VERSIONES (huella del texto útil). Si la huella no cambió, no llega a la IA.
--   ANALIZAR (IA breve)→ un modelo con instrucciones cortas clasifica en lote SOLO versiones nuevas.
--                       El resultado se guarda por versión (vigilante.analisis): abrir la web o
--                       recargar no vuelve a gastar tokens.
--                       La procedencia (fuente, enlace) la pone el PROGRAMA, nunca el modelo.
--   INVESTIGAR (Hermes)→ solo las tareas que lo necesitan (corroborar, contradicción, relacionar
--                       señales, oportunidad inferida): vigilante.tareas_agente.
--   PUBLICAR           → la web lee Supabase; vigilante.json se GENERA desde la base si hace falta.
--
-- Fuentes:
--   * Catálogo cerrado: una fuente que no está en vigilante.sources (ni en sus alias) NO se crea.
--     Va a vigilante.source_candidates, pendiente de que un administrador la apruebe.
--   * Alias controlados (vigilante.source_aliases) en lugar de juntar por dominio: un mismo sitio
--     puede tener varios canales legítimos.
--
-- Funciones nuevas para el VPS / n8n / Hermes (solo service_role):
--   lote_para_clasificar · guardar_clasificacion · proponer_fuente · guardar_oportunidad
--   tomar_tareas · terminar_tarea · crear_tarea · vigilante_json
-- Para la web (equipo con sesión):
--   candidatas_web · decidir_candidata (admin) · alias_fuente (admin) · oportunidades_web
-- Cambian (misma firma salvo guardar_comprobacion, que gana 3 parámetros opcionales):
--   insertar_noticias · fuentes_para_recolector · guardar_comprobacion · guardar_senal
--   fuente_canonica · sincronizar_vigilante · vigilante_bd
-- Limpieza opcional (dos pasos, como el 12):
--   select * from vigilante.propuestas_a_candidatas(false);  -- solo mira
--   select * from vigilante.propuestas_a_candidatas(true);   -- pasa las propuestas en pausa a candidatas
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Utilidades
-- -----------------------------------------------------------------------------
-- Identidad de un documento por su dirección: sin esquema ni «www.», dominio en minúsculas,
-- sin parámetros de seguimiento (utm_*, fbclid, gclid...), sin ancla y sin barra final.
-- La ruta conserva mayúsculas: en muchos sitios /Noticia/123 y /noticia/123 son distintas.
CREATE OR REPLACE FUNCTION vigilante.url_doc(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE u text := trim(coalesce(p, '')); host text; resto text; q text; partes text[];
BEGIN
  IF u = '' THEN RETURN ''; END IF;
  u := regexp_replace(u, '^https?://', '', 'i');
  u := regexp_replace(u, '#.*$', '');
  host := substring(u FROM '^[^/?]*');
  resto := substr(u, length(host) + 1);
  host := lower(regexp_replace(host, '^www\.', '', 'i'));
  IF position('?' IN resto) > 0 THEN
    q := substr(resto, position('?' IN resto) + 1);
    resto := substr(resto, 1, position('?' IN resto) - 1);
    partes := ARRAY(SELECT x FROM unnest(string_to_array(q, '&')) x
                     WHERE x <> '' AND x !~* '^(utm_[a-z]+|fbclid|gclid|mc_cid|mc_eid|ref|ref_src|igshid|_ga)(=|$)'
                     ORDER BY x);
    IF cardinality(partes) > 0 THEN resto := resto || '?' || array_to_string(partes, '&'); END IF;
  END IF;
  RETURN host || regexp_replace(resto, '/+$', '');
END $$;

CREATE OR REPLACE FUNCTION vigilante.sha(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex')
$$;

-- -----------------------------------------------------------------------------
-- 2. Fuentes: programación por fechas, cabeceras HTTP, alias y candidatas
-- -----------------------------------------------------------------------------
ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS proxima_revision_en timestamptz;
ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS etag text;
ALTER TABLE vigilante.sources ADD COLUMN IF NOT EXISTS last_modified text;
COMMENT ON COLUMN vigilante.sources.proxima_revision_en IS
  'Cuándo toca leerla. La calcula la base al guardar cada comprobación (frecuencia; más espaciada si falla)';
COMMENT ON COLUMN vigilante.sources.etag IS 'ETag de la última lectura: el recolector lo manda en If-None-Match';
COMMENT ON COLUMN vigilante.sources.last_modified IS 'Last-Modified de la última lectura: se manda en If-Modified-Since';
UPDATE vigilante.sources SET proxima_revision_en = ultima_consulta_en + make_interval(mins => frecuencia_minutos)
 WHERE proxima_revision_en IS NULL AND ultima_consulta_en IS NOT NULL;
CREATE INDEX IF NOT EXISTS sources_proxima_idx ON vigilante.sources (cliente_id, proxima_revision_en)
  WHERE activa AND eliminada_en IS NULL;

-- Otros nombres con los que se conoce una fuente del catálogo (códigos antiguos, variantes).
-- Solo los escribe un administrador (o la base al juntar fuentes en el 12).
CREATE TABLE IF NOT EXISTS vigilante.source_aliases (
  cliente_id  uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  alias       text NOT NULL CHECK (alias = lower(trim(alias)) AND alias <> ''),
  source_id   integer NOT NULL REFERENCES vigilante.sources(id) ON DELETE CASCADE,
  creado_por  text NOT NULL DEFAULT vigilante.actor_actual(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cliente_id, alias)
);
-- los códigos que el 12 juntó con otra fuente pasan a ser alias de la que se quedó
INSERT INTO vigilante.source_aliases (cliente_id, alias, source_id, creado_por)
SELECT s1.cliente_id, lower(s1.codigo), s2.id, 'migracion-15'
  FROM vigilante.sources s1
  JOIN vigilante.sources s2 ON s2.cliente_id = s1.cliente_id AND s2.codigo = s1.config ->> 'fusionada_en' AND s2.eliminada_en IS NULL
ON CONFLICT DO NOTHING;

-- Fuentes que alguien (AVIA, una búsqueda, la sincronización antigua) cree que habría que vigilar.
-- No se vigilan hasta que un administrador las aprueba; al aprobar se crea la fuente en el catálogo.
CREATE TABLE IF NOT EXISTS vigilante.source_candidates (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id     uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  nombre         text NOT NULL,
  url            text NOT NULL,
  url_doc        text NOT NULL,
  codigo_sugerido text,
  tipo_sugerido  text,
  motivo         text,
  evidencia      jsonb NOT NULL DEFAULT '[]',       -- ids de noticias o enlaces que justifican la propuesta
  propuesta_por  text NOT NULL DEFAULT 'avia',
  veces          integer NOT NULL DEFAULT 1,
  estado         text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'aprobada', 'rechazada')),
  decidida_por   text,
  decidida_en    timestamptz,
  nota           text,
  source_id      integer REFERENCES vigilante.sources(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS source_candidates_una_pendiente
  ON vigilante.source_candidates (cliente_id, url_doc) WHERE estado = 'pendiente';

-- -----------------------------------------------------------------------------
-- 3. Documentos y versiones
--    raw_items = el DOCUMENTO (identidad: id del proveedor o URL normalizada).
--    raw_item_versions = cada versión de su texto útil (huella sha256).
-- -----------------------------------------------------------------------------
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS url_doc text;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS id_externo text;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS hash_texto text;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS version integer NOT NULL DEFAULT 1;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS cambiado_en timestamptz;
ALTER TABLE vigilante.raw_items ADD COLUMN IF NOT EXISTS tipos_oportunidad text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN vigilante.raw_items.content_hash IS
  'Identidad del documento (desde el 15: sha256 de fuente + URL normalizada). La versión del texto va en hash_texto';
UPDATE vigilante.raw_items SET url_doc = vigilante.url_doc(url) WHERE url_doc IS NULL;
CREATE INDEX IF NOT EXISTS raw_items_url_doc_idx ON vigilante.raw_items (cliente_id, url_doc);
CREATE INDEX IF NOT EXISTS raw_items_id_externo_idx ON vigilante.raw_items (cliente_id, source_id, id_externo) WHERE id_externo IS NOT NULL;

CREATE TABLE IF NOT EXISTS vigilante.raw_item_versions (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id    uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  raw_item_id   bigint NOT NULL REFERENCES vigilante.raw_items(id) ON DELETE CASCADE,
  version       integer NOT NULL,
  hash_texto    text NOT NULL,
  titulo        text,
  contenido     text,
  recolectado_en timestamptz NOT NULL DEFAULT now(),
  ejecucion     text,
  UNIQUE (raw_item_id, version)
);
-- la versión 1 de lo que ya estaba
INSERT INTO vigilante.raw_item_versions (cliente_id, raw_item_id, version, hash_texto, titulo, contenido, recolectado_en, ejecucion)
SELECT r.cliente_id, r.id, 1, vigilante.sha(coalesce(r.titulo_norm, vigilante.texto_norm(r.titulo)) || '|' || vigilante.texto_norm(r.contenido)),
       r.titulo, r.contenido, r.recolectado_en, r.ejecucion
  FROM vigilante.raw_items r
 WHERE NOT EXISTS (SELECT 1 FROM vigilante.raw_item_versions v WHERE v.raw_item_id = r.id);
UPDATE vigilante.raw_items r SET hash_texto = v.hash_texto
  FROM vigilante.raw_item_versions v WHERE v.raw_item_id = r.id AND v.version = r.version AND r.hash_texto IS NULL;

-- -----------------------------------------------------------------------------
-- 4. Análisis guardado por versión (no se repite al recargar)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.analisis (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  raw_item_id     bigint NOT NULL REFERENCES vigilante.raw_items(id) ON DELETE CASCADE,
  version         integer NOT NULL,
  tipo            text NOT NULL DEFAULT 'clasificacion' CHECK (tipo IN ('clasificacion', 'agente')),
  modelo          text,
  prompt_version  text,
  salida          jsonb NOT NULL,
  relevante       boolean,
  signal_id       bigint REFERENCES vigilante.signals(id) ON DELETE SET NULL,
  tokens_entrada  integer,
  tokens_salida   integer,
  costo_usd       numeric(10,5),
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (raw_item_id, version, tipo)
);
CREATE INDEX IF NOT EXISTS analisis_signal_idx ON vigilante.analisis (signal_id);

-- -----------------------------------------------------------------------------
-- 5. Oportunidades en dos niveles
--    explícita: la fuente lo dice (convocatoria, licitación, feria, inscripción...)
--    inferida:  interpretación sobre evidencias (nueva ruta aérea → paquetes en un destino)
--    Cada una separa HECHO (lo que dice la fuente) de INTERPRETACIÓN, BENEFICIARIOS, ACCIÓN y EVIDENCIA.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.oportunidades (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  signal_id       bigint REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  nivel           text NOT NULL CHECK (nivel IN ('explicita', 'inferida')),
  tipo            text NOT NULL,             -- convocatoria, licitacion, evento, conectividad, financiamiento, formacion, normativa, demanda
  hecho           text NOT NULL,             -- qué dice la fuente (sin interpretar)
  interpretacion  text,                      -- qué podría aprovechar el sector (obligatoria si es inferida)
  beneficiarios   text[] NOT NULL DEFAULT '{}',
  accion          text,                      -- siguiente paso concreto
  plazo_hasta     timestamptz,
  importancia     smallint CHECK (importancia BETWEEN 1 AND 5),
  evidencias      bigint[] NOT NULL CHECK (cardinality(evidencias) > 0),  -- ids de raw_items
  creada_por      text NOT NULL DEFAULT vigilante.actor_actual(),
  estado          text NOT NULL DEFAULT 'propuesta' CHECK (estado IN ('propuesta', 'validada', 'descartada')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT oportunidad_inferida_explica CHECK (nivel = 'explicita' OR coalesce(trim(interpretacion), '') <> '')
);
CREATE UNIQUE INDEX IF NOT EXISTS oportunidades_una_por_tipo ON vigilante.oportunidades (signal_id, nivel, tipo);
CREATE INDEX IF NOT EXISTS oportunidades_cliente_idx ON vigilante.oportunidades (cliente_id, estado, plazo_hasta);

-- -----------------------------------------------------------------------------
-- 6. Tareas para el agente Hermes (solo lo que necesita investigar)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.tareas_agente (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id    uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  tipo          text NOT NULL CHECK (tipo IN ('corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida', 'radar')),
  signal_id     bigint REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  raw_item_ids  bigint[] NOT NULL DEFAULT '{}',
  motivo        text NOT NULL,
  creada_por    text NOT NULL DEFAULT vigilante.actor_actual(),
  estado        text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'en_curso', 'hecha', 'descartada')),
  resultado     jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  tomada_en     timestamptz,
  terminada_en  timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS tareas_agente_una_abierta
  ON vigilante.tareas_agente (cliente_id, tipo, coalesce(signal_id, 0)) WHERE estado IN ('pendiente', 'en_curso');

-- Permisos: el equipo lee; se escribe solo con las funciones de abajo
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['source_aliases', 'source_candidates', 'raw_item_versions', 'analisis', 'oportunidades', 'tareas_agente'] LOOP
    EXECUTE format('ALTER TABLE vigilante.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS equipo_lee ON vigilante.%I', t);
    EXECUTE format('CREATE POLICY equipo_lee ON vigilante.%I FOR SELECT TO authenticated USING (cliente_id = vigilante.cliente_actual())', t);
    EXECUTE format('REVOKE ALL ON vigilante.%I FROM anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON vigilante.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON vigilante.%I TO service_role', t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 7. Parámetros (valores de la plataforma; cada cliente los puede sobrescribir)
-- -----------------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'reglas_oportunidad', '{
     "convocatoria":   ["convocatoria", "postulacion", "postulaciones", "inscripciones abiertas", "fondo concursable", "concurso", "beca"],
     "licitacion":     ["licitacion", "proceso de contratacion", "invitacion publica", "sicoes"],
     "evento":         ["feria", "festival", "congreso", "expo", "carnaval", "fiesta patronal", "encuentro internacional", "rueda de negocios"],
     "conectividad":   ["nueva ruta", "nuevo vuelo", "nuevas frecuencias", "vuelo directo", "nueva conexion", "ruta aerea"],
     "financiamiento": ["credito", "financiamiento", "fideicomiso", "subvencion", "cooperacion", "donacion", "prestamo"],
     "formacion":      ["capacitacion", "curso", "taller", "diplomado", "formacion"],
     "normativa":      ["decreto supremo", "ley", "resolucion ministerial", "reglamento", "nueva norma"]
   }', 'Frases (sin tildes) que marcan una noticia como posible oportunidad EXPLÍCITA de cada tipo. Editable'),
  (NULL, 'ruido_url', '["/login", "/signup", "/signin", "/password", "/privacy", "/privacidad", "/cookies", "/aviso-legal",
     "/condiciones", "/author/", "/autor/", "/tag/", "/etiqueta/", "/category/", "/categoria/", "/newsletter", "/search", "/buscar",
     "/archive", "/faq", "/profile/", "/perfil/", "/empleo", "/trabaja-con-nosotros", "/page/", "/pagina/"]',
   'Partes de dirección que se descartan sin IA (portadas de sección, login, etiquetas, paginaciones). Editable'),
  (NULL, 'ruido_titulo_min', '15', 'Títulos más cortos que esto se descartan sin IA (menús, «Inicio», «Ver más»)'),
  (NULL, 'max_espera_fallos_min', '1440', 'Si una fuente falla, se espacia su revisión (frecuencia × 2^fallos) hasta este máximo')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 8. Catálogo cerrado
-- -----------------------------------------------------------------------------
-- Código del catálogo para lo que alguien llama «p_codigo» o «p_url». NULL si no está en el catálogo.
-- Ya no junta por dominio (un sitio puede tener varios canales legítimos): código, alias,
-- código fusionado o la misma dirección exacta.
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
        AND coalesce(p_url, '') <> '' AND vigilante.url_normal(url) = vigilante.url_normal(p_url)
      ORDER BY gestionada_web DESC, created_at LIMIT 1))
$$;

-- Apunta (o vuelve a apuntar) una fuente candidata. Nunca crea la fuente.
CREATE OR REPLACE FUNCTION vigilante.registrar_candidata(p_cliente uuid, p_nombre text, p_url text, p_motivo text,
                                                        p_codigo text DEFAULT NULL, p_tipo text DEFAULT NULL,
                                                        p_evidencia jsonb DEFAULT '[]', p_por text DEFAULT 'avia')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint; v_cod text;
BEGIN
  IF coalesce(p_url, '') !~* '^https?://' THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Hace falta una dirección web real (https://...) que se haya visto, no una inventada');
  END IF;
  v_cod := vigilante.fuente_canonica(p_cliente, p_codigo, p_url);
  IF v_cod IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Ya está en el catálogo', 'codigo', v_cod);
  END IF;
  UPDATE vigilante.source_candidates SET veces = veces + 1, updated_at = now(),
         evidencia = (SELECT coalesce(jsonb_agg(DISTINCT x), '[]') FROM jsonb_array_elements(evidencia || coalesce(p_evidencia, '[]')) x),
         motivo = coalesce(nullif(trim(p_motivo), ''), motivo)
   WHERE cliente_id = p_cliente AND url_doc = vigilante.url_doc(p_url) AND estado = 'pendiente'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    IF EXISTS (SELECT 1 FROM vigilante.source_candidates WHERE cliente_id = p_cliente AND url_doc = vigilante.url_doc(p_url)
                AND estado = 'rechazada' AND decidida_en > now() - interval '90 days') THEN
      RETURN jsonb_build_object('ok', false, 'motivo', 'Un administrador ya la rechazó en los últimos 90 días');
    END IF;
    INSERT INTO vigilante.source_candidates (cliente_id, nombre, url, url_doc, codigo_sugerido, tipo_sugerido, motivo, evidencia, propuesta_por)
    VALUES (p_cliente, left(coalesce(nullif(trim(p_nombre), ''), vigilante.dominio(p_url)), 200), trim(p_url), vigilante.url_doc(p_url),
            nullif(trim(p_codigo), ''), p_tipo, p_motivo, coalesce(p_evidencia, '[]'), coalesce(p_por, 'avia'))
    RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'nota', 'Queda como candidata: no se vigila hasta que un administrador la apruebe');
END $$;

-- Para Hermes (MCP): proponer una fuente nueva vista durante una investigación
CREATE OR REPLACE FUNCTION vigilante.proponer_fuente(p_cliente text, p_nombre text, p_url text, p_motivo text,
                                                    p_evidencia jsonb DEFAULT '[]', p_tipo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_ev jsonb;
BEGIN
  IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Explica por qué conviene vigilarla'; END IF;
  -- la evidencia tiene que ser de noticias que de verdad están en la base
  v_ev := (SELECT coalesce(jsonb_agg(r.id), '[]') FROM vigilante.raw_items r
            WHERE r.cliente_id = v_cliente
              AND r.id IN (SELECT x::bigint FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_evidencia) = 'array' THEN p_evidencia ELSE '[]' END) x WHERE x ~ '^\d+$'));
  IF jsonb_array_length(v_ev) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'Indica en evidencia los ids de las noticias donde viste esa fuente');
  END IF;
  RETURN vigilante.registrar_candidata(v_cliente, p_nombre, p_url, p_motivo, NULL, p_tipo, v_ev, 'avia');
END $$;

-- Web: candidatas pendientes y las decididas en los últimos 30 días
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
   ORDER BY c.estado <> 'pendiente', c.veces DESC, c.created_at DESC
$$;

-- Web (administrador): aprobar crea la fuente en el catálogo con alta_fuente (09); rechazar la archiva
CREATE OR REPLACE FUNCTION vigilante.decidir_candidata(p_id bigint, p_aprobar boolean, p_nota text DEFAULT NULL,
                                                      p_categoria text DEFAULT 'mercado', p_tipo text DEFAULT NULL,
                                                      p_metodo text DEFAULT 'http_html', p_frecuencia int DEFAULT 60)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v vigilante.source_candidates; v_quien text; v_codigo text;
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede aprobar o rechazar fuentes candidatas'; END IF;
  SELECT * INTO v FROM vigilante.source_candidates WHERE id = p_id AND cliente_id = vigilante.cliente_actual() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'La candidata no existe'; END IF;
  IF v.estado <> 'pendiente' THEN RAISE EXCEPTION 'Esta candidata ya se decidió'; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  IF p_aprobar THEN
    v_codigo := vigilante.alta_fuente(v.nombre, v.url, coalesce(p_categoria, 'mercado'),
                                      coalesce(p_tipo, v.tipo_sugerido, 'medio'), coalesce(p_metodo, 'http_html'),
                                      coalesce(p_frecuencia, 60), v.motivo, '{}');
  END IF;
  UPDATE vigilante.source_candidates SET estado = CASE WHEN p_aprobar THEN 'aprobada' ELSE 'rechazada' END,
         decidida_por = coalesce(v_quien, 'administrador'), decidida_en = now(), nota = nullif(trim(p_nota), ''),
         source_id = (SELECT id FROM vigilante.sources WHERE cliente_id = v.cliente_id AND codigo = v_codigo), updated_at = now()
   WHERE id = p_id;
  RETURN v_codigo;
END $$;

-- Web (administrador): otro nombre para una fuente del catálogo
CREATE OR REPLACE FUNCTION vigilante.alias_fuente(p_codigo text, p_alias text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_src integer;
BEGIN
  IF NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede añadir alias'; END IF;
  SELECT id INTO v_src FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL;
  IF v_src IS NULL THEN RAISE EXCEPTION 'La fuente % no existe', p_codigo; END IF;
  INSERT INTO vigilante.source_aliases (cliente_id, alias, source_id) VALUES (vigilante.cliente_actual(), lower(trim(p_alias)), v_src)
  ON CONFLICT (cliente_id, alias) DO UPDATE SET source_id = EXCLUDED.source_id;
END $$;

-- Limpieza: las «propuestas de AVIA» que el 09 dejó EN PAUSA dentro del catálogo pasan a candidatas.
-- Solo las que nunca se activaron y no tienen noticias ni señales. p_aplicar = false solo muestra.
CREATE OR REPLACE FUNCTION vigilante.propuestas_a_candidatas(p_aplicar boolean DEFAULT false)
RETURNS TABLE (cliente text, codigo text, nombre text, url text, accion text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT s.*, c.slug FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id
     WHERE s.eliminada_en IS NULL AND NOT s.activa AND coalesce((s.config ->> 'propuesta_avia')::boolean, false)
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
     ORDER BY c.slug, s.codigo
  LOOP
    cliente := r.slug; codigo := r.codigo; nombre := r.nombre; url := r.url;
    IF EXISTS (SELECT 1 FROM vigilante.raw_items WHERE source_id = r.id) OR EXISTS (SELECT 1 FROM vigilante.signals WHERE source_id = r.id) THEN
      accion := 'se queda (tiene noticias o señales): apruébala o elimínala en la web';
    ELSIF p_aplicar THEN
      IF r.url ~* '^https?://' THEN
        PERFORM vigilante.registrar_candidata(r.cliente_id, r.nombre, r.url, coalesce(r.notas, 'Propuesta antigua de AVIA'),
                                              r.codigo, r.tipo::text, '[]', 'migracion-15');
      END IF;
      UPDATE vigilante.sources SET eliminada_en = now(), config = config || '{"pasada_a_candidata": true}' WHERE id = r.id;
      accion := 'pasada a candidatas';
    ELSE
      accion := 'pasaría a candidatas';
    END IF;
    RETURN NEXT;
  END LOOP;
END $$;

-- Compatibilidad con vigilante.json: las fuentes que la base no conoce ya NO entran (ni en pausa):
-- se apuntan como candidatas y se quitan antes de sincronizar. Las conocidas se sincronizan como antes.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'vigilante' AND p.proname = 'sincronizar_vigilante_12') THEN
    ALTER FUNCTION vigilante.sincronizar_vigilante(text, jsonb) RENAME TO sincronizar_vigilante_12;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.sincronizar_vigilante_12(text, jsonb) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.sincronizar_vigilante(p_cliente text, p_json jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); f jsonb; v_cod text;
        v_conocidas jsonb := '[]'; n_rech int := 0; r jsonb;
BEGIN
  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(p_json -> 'fuentes', '[]')) LOOP
    CONTINUE WHEN coalesce(f ->> 'id', '') = '';
    v_cod := vigilante.fuente_canonica(v_cliente, f ->> 'id', f ->> 'url');
    IF v_cod IS NULL THEN
      PERFORM vigilante.registrar_candidata(v_cliente, f ->> 'nombre', f ->> 'url', 'Apareció en vigilante.json sin estar en el catálogo',
                                            f ->> 'id', f ->> 'tipo', '[]', 'sincronizacion');
      n_rech := n_rech + 1;
    ELSE
      v_conocidas := v_conocidas || jsonb_build_array(f || jsonb_build_object('id', v_cod));
    END IF;
  END LOOP;
  r := vigilante.sincronizar_vigilante_12(p_cliente, jsonb_set(p_json, '{fuentes}', v_conocidas));
  RETURN r || jsonb_build_object('fuentes_fuera_de_catalogo', n_rech);
END $$;
REVOKE ALL ON FUNCTION vigilante.sincronizar_vigilante(text, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.sincronizar_vigilante(text, jsonb) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. Recolector: qué leer, cuándo, y guardar con versiones
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.fuentes_para_recolector(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'cliente', c.slug,
    'generado', now(),
    'apify_disponible_usd', vigilante.apify_disponible(c.id),
    'fuentes', coalesce(jsonb_agg(jsonb_build_object(
        'codigo', s.codigo, 'nombre', s.nombre, 'url', s.url, 'tipo', s.tipo, 'metodo', s.metodo,
        'frecuencia_minutos', s.frecuencia_minutos,
        'palabras_clave', coalesce(s.config -> 'palabras_clave', '[]'::jsonb),
        'que_buscar', s.config ->> 'que_buscar',
        'query', coalesce(s.config ->> 'query', s.config ->> 'q'),
        'config', s.config - 'hist' - 'items' - 'estado',
        'apify_actor', s.config ->> 'apify_actor',
        'apify_input', s.config -> 'apify_input',
        'huella', s.config ->> 'huella',
        'etag', s.etag, 'last_modified', s.last_modified,
        'proxima_revision_en', s.proxima_revision_en,
        'nueva', s.ultima_consulta_en IS NULL OR s.ultima_consulta_en < (s.config ->> 'revisar_desde')::timestamptz,
        'toca', s.ultima_consulta_en IS NULL
                OR s.ultima_consulta_en < (s.config ->> 'revisar_desde')::timestamptz
                OR coalesce(s.proxima_revision_en,
                            s.ultima_consulta_en + make_interval(mins => greatest(s.frecuencia_minutos - 2, 3))) <= now()
      ) ORDER BY coalesce(s.proxima_revision_en, s.ultima_consulta_en) NULLS FIRST) FILTER (WHERE s.id IS NOT NULL), '[]'::jsonb)
  )
  FROM vigilante.clientes c
  LEFT JOIN vigilante.sources s ON s.cliente_id = c.id AND s.activa AND s.eliminada_en IS NULL
  WHERE c.slug = p_cliente AND c.activo
  GROUP BY c.id, c.slug
$$;

-- Guarda noticias: descarta ruido sin IA, identifica el documento, detecta versiones y puntúa.
-- p_items: [{"titulo", "url", "resumen", "publicado_en", "id" (guid del proveedor, opcional), "extra"}]
CREATE OR REPLACE FUNCTION vigilante.insertar_noticias(p_cliente uuid, p_source_id integer, p_busqueda_id bigint,
                                                       p_items jsonb, p_ejecucion text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  it jsonb; v_src vigilante.sources; v_doc vigilante.raw_items;
  v_titulo text; v_url text; v_urld text; v_ext text; v_resumen text; v_norm text; v_texto text; v_pub timestamptz; v_hash text;
  v_kw text[]; v_opp text[]; v_alerta text[]; v_ruido text[]; v_tmin int; v_umbral int; v_reglas jsonb; v_ter record;
  v_puntaje int; v_motivos text[]; v_ters int[]; v_tipos text[]; v_estado vigilante.estado_raw; v_frase text; v_tipo text; v_id bigint;
  v_ruido_motivo text;
  n_nuevas int := 0; n_desc int := 0; n_rep int := 0; n_act int := 0; n_ruido int := 0;
BEGIN
  IF p_source_id IS NOT NULL THEN SELECT * INTO v_src FROM vigilante.sources WHERE id = p_source_id; END IF;
  v_kw := CASE WHEN jsonb_typeof(v_src.config -> 'palabras_clave') = 'array'
               THEN ARRAY(SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_src.config -> 'palabras_clave') x
                          WHERE vigilante.texto_norm(x) <> '')
               ELSE '{}' END;
  v_opp := vigilante.lista_param(p_cliente, 'palabras_oportunidad');
  v_alerta := vigilante.lista_param(p_cliente, 'palabras_alerta');
  v_ruido := ARRAY(SELECT lower(x) FROM jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(vigilante.param(p_cliente, 'ruido_url')) = 'array' THEN vigilante.param(p_cliente, 'ruido_url') ELSE '[]' END) x);
  v_tmin := coalesce((vigilante.param(p_cliente, 'ruido_titulo_min') #>> '{}')::int, 15);
  v_umbral := coalesce((vigilante.param(p_cliente, 'umbral_previo') #>> '{}')::int, 30);
  v_reglas := CASE WHEN jsonb_typeof(vigilante.param(p_cliente, 'reglas_oportunidad')) = 'object'
                   THEN vigilante.param(p_cliente, 'reglas_oportunidad') ELSE '{}' END;

  FOR it IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]' END) LOOP
    v_titulo := left(nullif(trim(it ->> 'titulo'), ''), 500);
    v_url := nullif(trim(it ->> 'url'), '');
    CONTINUE WHEN v_titulo IS NULL OR v_url IS NULL;
    v_urld := vigilante.url_doc(v_url);
    v_ext := nullif(trim(it ->> 'id'), '');
    v_resumen := left(nullif(trim(it ->> 'resumen'), ''), 4000);
    v_norm := vigilante.texto_norm(v_titulo);
    v_pub := CASE WHEN (it ->> 'publicado_en') ~ '^\d{4}-\d{2}-\d{2}' THEN (it ->> 'publicado_en')::timestamptz END;
    v_hash := vigilante.sha(v_norm || '|' || vigilante.texto_norm(v_resumen));

    -- ¿qué documento es? 1) id del proveedor en la misma fuente 2) misma dirección
    -- 3) mismo título en la misma fuente en los últimos 3 días (agregadores con direcciones cambiantes)
    v_doc := NULL;
    IF v_ext IS NOT NULL THEN
      SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = p_cliente AND id_externo = v_ext
         AND source_id IS NOT DISTINCT FROM p_source_id ORDER BY id LIMIT 1;
    END IF;
    IF v_doc.id IS NULL THEN
      SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = p_cliente AND url_doc = v_urld ORDER BY id LIMIT 1;
    END IF;
    IF v_doc.id IS NULL AND p_source_id IS NOT NULL THEN
      SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = p_cliente AND source_id = p_source_id
         AND titulo_norm = v_norm AND recolectado_en > now() - interval '3 days' ORDER BY id LIMIT 1;
    END IF;

    IF v_doc.id IS NOT NULL THEN
      -- mismo texto (o sin texto nuevo que comparar): repetida, sin IA
      IF v_doc.hash_texto IS NULL THEN
        UPDATE vigilante.raw_items SET hash_texto = v_hash WHERE id = v_doc.id;
        n_rep := n_rep + 1; CONTINUE;
      END IF;
      IF v_doc.hash_texto = v_hash OR (v_norm = v_doc.titulo_norm AND v_resumen IS NULL) THEN
        n_rep := n_rep + 1; CONTINUE;
      END IF;
    END IF;

    -- ruido evidente, sin IA (portadas, login, etiquetas, paginaciones, títulos de menú)
    v_ruido_motivo := NULL;
    IF length(v_norm) < v_tmin THEN
      v_ruido_motivo := 'título demasiado corto';
    ELSIF regexp_replace(v_urld, '/(es|en|inicio|home|index\.(html?|php))?$', '') !~ '[/?]' THEN
      v_ruido_motivo := 'portada del sitio';
    ELSE
      SELECT 'dirección: ' || x INTO v_ruido_motivo FROM unnest(v_ruido) x WHERE position(x IN lower(v_urld)) > 0 LIMIT 1;
    END IF;

    -- puntaje previo (igual que en el 14) + tipos de oportunidad explícita por reglas
    v_texto := v_norm || ' ' || vigilante.texto_norm(v_resumen);
    v_puntaje := 10; v_motivos := '{}'; v_ters := '{}'; v_tipos := '{}';
    IF v_src.tipo IN ('oficial', 'organismo_internacional') THEN
      v_puntaje := v_puntaje + 15; v_motivos := v_motivos || 'fuente oficial'::text;
    END IF;
    FOREACH v_frase IN ARRAY v_kw LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 30; v_motivos := v_motivos || ('palabra clave: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    FOR v_ter IN SELECT id, nombre, datos FROM vigilante.territorios WHERE cliente_id = p_cliente AND nivel <> 'pais' LOOP
      IF vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.nombre))
         OR vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.datos ->> 'capital'))
         OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_ter.datos -> 'alias') = 'array' THEN v_ter.datos -> 'alias' ELSE '[]' END) a
                     WHERE vigilante.contiene(v_texto, vigilante.texto_norm(a))) THEN
        v_ters := v_ters || v_ter.id;
      END IF;
    END LOOP;
    IF cardinality(v_ters) > 0 THEN v_puntaje := v_puntaje + 25; v_motivos := v_motivos || 'menciona un territorio'::text; END IF;
    FOREACH v_frase IN ARRAY v_alerta LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 30; v_motivos := v_motivos || ('alerta: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    FOREACH v_frase IN ARRAY v_opp LOOP
      IF vigilante.contiene(v_texto, v_frase) THEN v_puntaje := v_puntaje + 20; v_motivos := v_motivos || ('oportunidad: ' || v_frase)::text; EXIT; END IF;
    END LOOP;
    FOR v_tipo IN SELECT jsonb_object_keys(v_reglas) LOOP
      IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_reglas -> v_tipo) = 'array' THEN v_reglas -> v_tipo ELSE '[]' END) f
                  WHERE vigilante.contiene(v_texto, vigilante.texto_norm(f))) THEN
        v_tipos := v_tipos || v_tipo;
      END IF;
    END LOOP;
    IF cardinality(v_tipos) > 0 AND NOT EXISTS (SELECT 1 FROM unnest(v_motivos) m WHERE m LIKE 'oportunidad:%') THEN
      v_puntaje := v_puntaje + 20; v_motivos := v_motivos || ('oportunidad explícita: ' || array_to_string(v_tipos, ', '))::text;
    END IF;
    IF p_busqueda_id IS NOT NULL THEN v_puntaje := v_puntaje + 20; v_motivos := v_motivos || 'búsqueda pedida por AVIA'::text; END IF;
    v_puntaje := least(v_puntaje, 100);
    v_estado := CASE WHEN v_ruido_motivo IS NOT NULL OR v_puntaje < v_umbral THEN 'descartado' ELSE 'nuevo' END;

    IF v_doc.id IS NOT NULL THEN
      -- NUEVA VERSIÓN de un documento conocido: vuelve a la IA solo si pasa el filtro
      INSERT INTO vigilante.raw_item_versions (cliente_id, raw_item_id, version, hash_texto, titulo, contenido, ejecucion)
      VALUES (p_cliente, v_doc.id, v_doc.version + 1, v_hash, v_titulo, v_resumen, p_ejecucion);
      UPDATE vigilante.raw_items SET
        version = v_doc.version + 1, hash_texto = v_hash, titulo = v_titulo, contenido = coalesce(v_resumen, contenido),
        titulo_norm = v_norm, cambiado_en = now(), puntaje_previo = v_puntaje, motivos = v_motivos,
        tipos_oportunidad = v_tipos, territorios_detectados = v_ters, menciona_territorio = cardinality(v_ters) > 0,
        estado = CASE WHEN v_estado = 'nuevo' THEN 'nuevo' ELSE estado END,
        payload = payload || jsonb_build_object('cambio', true)
      WHERE id = v_doc.id;
      n_act := n_act + 1;
      CONTINUE;
    END IF;

    INSERT INTO vigilante.raw_items (cliente_id, source_id, busqueda_id, url, url_doc, id_externo, content_hash, hash_texto, version,
                                     titulo, contenido, publicado_en, menciona_territorio, territorios_detectados, estado,
                                     motivo_descarte, ejecucion, payload, titulo_norm, puntaje_previo, motivos, tipos_oportunidad)
    VALUES (p_cliente, p_source_id, p_busqueda_id, v_url, v_urld, v_ext,
            vigilante.sha(coalesce(p_source_id::text, 'b' || p_busqueda_id) || '|' || coalesce(v_ext, v_urld)), v_hash, 1,
            v_titulo, v_resumen, v_pub, cardinality(v_ters) > 0, v_ters, v_estado,
            CASE WHEN v_ruido_motivo IS NOT NULL THEN 'ruido: ' || v_ruido_motivo
                 WHEN v_estado = 'descartado' THEN format('puntaje previo %s < %s', v_puntaje, v_umbral) END,
            p_ejecucion, coalesce(it -> 'extra', '{}'), v_norm, v_puntaje, v_motivos, v_tipos)
    ON CONFLICT (cliente_id, content_hash) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN n_rep := n_rep + 1;
    ELSE
      INSERT INTO vigilante.raw_item_versions (cliente_id, raw_item_id, version, hash_texto, titulo, contenido, ejecucion)
      VALUES (p_cliente, v_id, 1, v_hash, v_titulo, v_resumen, p_ejecucion);
      IF v_ruido_motivo IS NOT NULL THEN n_ruido := n_ruido + 1;
      ELSIF v_estado = 'nuevo' THEN n_nuevas := n_nuevas + 1;
      ELSE n_desc := n_desc + 1; END IF;
    END IF;
    v_id := NULL;
  END LOOP;
  RETURN jsonb_build_object('nuevas', n_nuevas, 'actualizadas', n_act, 'descartadas', n_desc, 'ruido', n_ruido, 'repetidas', n_rep);
END $$;

-- El recolector informa de una comprobación. Nuevo: p_etag, p_last_modified, p_no_modificado (respuesta 304).
-- La base calcula la próxima revisión: frecuencia normal, o espaciada si la fuente falla.
DROP FUNCTION IF EXISTS vigilante.guardar_comprobacion(text, text, text, text, jsonb, text, text);
CREATE OR REPLACE FUNCTION vigilante.guardar_comprobacion(p_cliente text, p_codigo text, p_estado text, p_info text,
                                                          p_items jsonb DEFAULT '[]', p_huella text DEFAULT NULL,
                                                          p_ejecucion text DEFAULT NULL, p_etag text DEFAULT NULL,
                                                          p_last_modified text DEFAULT NULL, p_no_modificado boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_src vigilante.sources; v_est text := upper(coalesce(p_estado, ''));
        r jsonb; v_hist jsonb; v_max int; v_espera int;
BEGIN
  IF v_est NOT IN ('OK', 'WARN', 'CRIT') THEN RAISE EXCEPTION 'Estado % no válido (OK, WARN o CRIT)', p_estado; END IF;
  SELECT * INTO v_src FROM vigilante.sources WHERE cliente_id = v_cliente AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % no está en el catálogo', p_codigo; END IF;
  PERFORM set_config('vigilante.actor', 'recolector', true);

  r := CASE WHEN v_est = 'CRIT' OR p_no_modificado THEN jsonb_build_object('nuevas', 0, 'actualizadas', 0, 'descartadas', 0, 'repetidas', 0)
            ELSE vigilante.insertar_noticias(v_cliente, v_src.id, NULL, p_items, p_ejecucion) END;
  v_hist := (SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') FROM (
               SELECT x, o FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_src.config -> 'hist') = 'array'
                                                          THEN v_src.config -> 'hist' ELSE '[]' END) WITH ORDINALITY AS h(x, o)
               ORDER BY o DESC LIMIT 11) t) || to_jsonb(v_est);
  v_max := coalesce((vigilante.param(v_cliente, 'max_espera_fallos_min') #>> '{}')::int, 1440);
  v_espera := CASE WHEN v_est = 'CRIT'
                   THEN least(v_src.frecuencia_minutos * power(2, least(v_src.errores_seguidos + 1, 6))::int, greatest(v_max, v_src.frecuencia_minutos))
                   ELSE v_src.frecuencia_minutos END;

  UPDATE vigilante.sources SET
    ultima_consulta_en = now(),
    proxima_revision_en = now() + make_interval(mins => v_espera),
    ultimo_exito_en = CASE WHEN v_est IN ('OK', 'WARN') THEN now() ELSE ultimo_exito_en END,
    errores_seguidos = CASE WHEN v_est = 'CRIT' THEN errores_seguidos + 1 ELSE 0 END,
    ultimo_error = CASE WHEN v_est = 'CRIT' THEN p_info ELSE ultimo_error END,
    -- si el servidor no manda cabeceras se conserva lo anterior (mandar uno viejo no hace daño: responde 200)
    etag = coalesce(nullif(p_etag, ''), etag),
    last_modified = coalesce(nullif(p_last_modified, ''), last_modified),
    notas = p_info,
    config = config || jsonb_strip_nulls(jsonb_build_object(
               'estado', v_est, 'items', (r ->> 'nuevas')::int + coalesce((r ->> 'actualizadas')::int, 0), 'hist', v_hist,
               'huella', p_huella, 'leida_por', 'recolector'))
  WHERE id = v_src.id;
  RETURN r || jsonb_build_object('proxima_revision_en', now() + make_interval(mins => v_espera));
END $$;

-- -----------------------------------------------------------------------------
-- 10. Señales: la procedencia la pone el programa
-- -----------------------------------------------------------------------------
-- Igual que en el 14, salvo:
--   * una señal NUEVA necesita al menos una noticia recogida (noticias = ids de raw_items);
--   * la fuente de la señal sale de sus noticias (se ignora «fuente_id» si lo manda el modelo);
--   * fuente_oficial = alguna noticia viene de una fuente oficial del catálogo;
--   * enlace_oficial solo se acepta si es la dirección de una de sus noticias o de una fuente del
--     catálogo; si no hay, queda vacío y la señal pide revisión de una persona.
CREATE OR REPLACE FUNCTION vigilante.guardar_senal(p_cliente text, p_senal jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); v_codigo text := nullif(trim(p_senal ->> 'codigo'), '');
  v_id bigint; v_src integer; v_cat text := coalesce(nullif(p_senal ->> 'categoria', ''), 'mercado');
  v_ids bigint[]; v_todas bigint[]; v_nuevo boolean := false; v_n int;
  v_oficial boolean; v_enlace text; v_enlace_pedido text := nullif(trim(p_senal ->> 'enlace_oficial'), '');
  v_revision boolean; v_motivo_rev text;
BEGIN
  IF coalesce(trim(p_senal ->> 'titulo'), '') = '' OR coalesce(trim(p_senal ->> 'resumen'), '') = '' THEN
    RAISE EXCEPTION 'La señal necesita titulo y resumen';
  END IF;
  PERFORM set_config('vigilante.actor', coalesce(nullif(current_setting('vigilante.actor', true), ''), 'hermes:mcp'), true);
  IF p_senal ? 'categoria' THEN
    INSERT INTO vigilante.categorias (cliente_id, codigo, nombre) VALUES (v_cliente, v_cat, v_cat) ON CONFLICT DO NOTHING;
  END IF;
  v_ids := CASE WHEN jsonb_typeof(p_senal -> 'noticias') = 'array'
                THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(p_senal -> 'noticias') x WHERE x ~ '^\d+$') ELSE '{}' END;
  v_ids := ARRAY(SELECT id FROM vigilante.raw_items WHERE cliente_id = v_cliente AND id = ANY (v_ids));

  IF v_codigo IS NOT NULL THEN
    SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = v_codigo;
    IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % no existe: para una nueva no mandes codigo', v_codigo; END IF;
  ELSE
    IF cardinality(v_ids) = 0 THEN
      RAISE EXCEPTION 'Una señal nueva necesita al menos una noticia recogida (noticias = ids de la base). No se crean señales sin evidencia';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtext('vigilante.signals.codigo:' || v_cliente));
    SELECT 'SEN-' || lpad((coalesce(max(substring(codigo FROM '^SEN-(\d+)$')::int), 0) + 1)::text, 4, '0')
      INTO v_codigo FROM vigilante.signals WHERE cliente_id = v_cliente;
    v_nuevo := true;
  END IF;

  -- todas las evidencias (las que ya tenía + las nuevas)
  v_todas := v_ids || ARRAY(SELECT raw_item_id FROM vigilante.signal_raw_items WHERE signal_id = v_id);
  -- fuente principal: la más oficial entre las evidencias
  SELECT s.id INTO v_src FROM vigilante.raw_items r JOIN vigilante.sources s ON s.id = r.source_id
   WHERE r.id = ANY (v_todas)
   ORDER BY (s.tipo IN ('oficial', 'organismo_internacional')) DESC, r.recolectado_en LIMIT 1;
  v_oficial := EXISTS (SELECT 1 FROM vigilante.raw_items r JOIN vigilante.sources s ON s.id = r.source_id
                        WHERE r.id = ANY (v_todas) AND s.tipo IN ('oficial', 'organismo_internacional'));
  -- enlace: solo uno comprobado
  IF v_enlace_pedido IS NOT NULL AND (
       EXISTS (SELECT 1 FROM vigilante.raw_items WHERE id = ANY (v_todas) AND url_doc = vigilante.url_doc(v_enlace_pedido))
    OR EXISTS (SELECT 1 FROM vigilante.sources WHERE cliente_id = v_cliente AND eliminada_en IS NULL
                AND vigilante.url_normal(url) = vigilante.url_normal(v_enlace_pedido))) THEN
    v_enlace := v_enlace_pedido;
  ELSE
    SELECT r.url INTO v_enlace FROM vigilante.raw_items r JOIN vigilante.sources s ON s.id = r.source_id
     WHERE r.id = ANY (v_todas) AND s.tipo IN ('oficial', 'organismo_internacional') ORDER BY r.recolectado_en DESC LIMIT 1;
  END IF;
  v_revision := coalesce((p_senal ->> 'requiere_revision')::boolean, false) OR NOT v_oficial OR v_enlace IS NULL
                OR coalesce((p_senal ->> 'es_escenario')::boolean, false)
                OR v_cat IN ('clima', 'salud', 'vial', 'seguridad');
  v_motivo_rev := CASE WHEN v_enlace IS NULL THEN 'Sin enlace oficial comprobado: verificar'
                       WHEN NOT v_oficial THEN 'Ninguna fuente oficial lo confirma todavía' END;

  IF v_nuevo THEN
    INSERT INTO vigilante.signals (cliente_id, codigo, source_id, raw_item_id, titulo, resumen, naturaleza, categoria, prioridad, estado)
    VALUES (v_cliente, v_codigo, v_src, v_ids[1], left(p_senal ->> 'titulo', 200), p_senal ->> 'resumen', 'mixta', v_cat, 'media', 'detectada')
    RETURNING id INTO v_id;
  END IF;

  UPDATE vigilante.signals SET
    source_id = coalesce(v_src, source_id),
    titulo = left(p_senal ->> 'titulo', 200),
    resumen = p_senal ->> 'resumen',
    recomendacion = coalesce(p_senal ->> 'recomendacion', recomendacion),
    naturaleza = CASE WHEN p_senal ->> 'naturaleza' IN ('riesgo', 'oportunidad', 'mixta') THEN (p_senal ->> 'naturaleza')::vigilante.naturaleza_senal ELSE naturaleza END,
    categoria = CASE WHEN p_senal ? 'categoria' OR v_nuevo THEN v_cat ELSE categoria END,
    prioridad = CASE WHEN p_senal ->> 'prioridad' IN ('baja', 'media', 'alta') THEN (p_senal ->> 'prioridad')::vigilante.prioridad ELSE prioridad END,
    motivos_prioridad = CASE WHEN jsonb_typeof(p_senal -> 'motivos_prioridad') = 'array'
                             THEN ARRAY(SELECT jsonb_array_elements_text(p_senal -> 'motivos_prioridad')) ELSE motivos_prioridad END,
    puntaje = CASE WHEN (p_senal ->> 'relevancia') ~ '^\d+(\.\d+)?$' THEN least((p_senal ->> 'relevancia')::numeric * 10, 100) ELSE puntaje END,
    confianza = CASE WHEN (p_senal ->> 'confianza') ~ '^[01](\.\d+)?$' THEN least((p_senal ->> 'confianza')::numeric, 1) ELSE confianza END,
    alcance_total = coalesce((p_senal ->> 'alcance_nacional')::boolean, alcance_total),
    es_escenario = coalesce((p_senal ->> 'es_escenario')::boolean, es_escenario),
    fuente_oficial = v_oficial,
    enlace_oficial = v_enlace,
    requiere_revision = v_revision OR (NOT v_nuevo AND requiere_revision AND NOT v_oficial),
    motivo_revision = coalesce(v_motivo_rev, motivo_revision),
    fecha_evento_inicio = CASE WHEN (p_senal ->> 'fecha_evento_inicio') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_inicio')::timestamptz ELSE fecha_evento_inicio END,
    fecha_evento_fin = CASE WHEN (p_senal ->> 'fecha_evento_fin') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_fin')::timestamptz ELSE fecha_evento_fin END,
    plazo_hasta = CASE WHEN (p_senal ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}$' THEN ((p_senal ->> 'plazo_hasta') || 'T23:59:59-04:00')::timestamptz
                       WHEN (p_senal ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}T' THEN (p_senal ->> 'plazo_hasta')::timestamptz
                       ELSE plazo_hasta END,
    modelo = coalesce(p_senal ->> 'modelo', modelo),
    salida_modelo = CASE WHEN v_nuevo THEN '{}'::jsonb ELSE coalesce(salida_modelo, '{}') - 'id' END
                    || (p_senal - 'contexto_vigilante' - 'id' - 'codigo' - 'fuente_id' - 'enlace_oficial'),
    contexto_vigilante = coalesce(p_senal -> 'contexto_vigilante', contexto_vigilante)
  WHERE id = v_id;

  IF jsonb_typeof(p_senal -> 'departamentos') = 'array' THEN
    INSERT INTO vigilante.signal_territorios (signal_id, cliente_id, territorio_id)
    SELECT v_id, v_cliente, t.id FROM vigilante.territorios t
     WHERE t.cliente_id = v_cliente
       AND vigilante.texto_norm(t.nombre) IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(p_senal -> 'departamentos') x)
    ON CONFLICT DO NOTHING;
  END IF;
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
  SELECT v_id, x, v_cliente FROM unnest(v_ids) x ON CONFLICT DO NOTHING;
  UPDATE vigilante.raw_items SET estado = 'procesado' WHERE id = ANY (v_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('codigo', v_codigo, 'nueva', v_nuevo, 'noticias_enlazadas', v_n,
                            'fuente_oficial', v_oficial, 'enlace_oficial', v_enlace, 'requiere_revision', v_revision,
                            'nota', 'Queda en «Detectada»: una persona la revisa y decide si se publica');
END $$;

-- -----------------------------------------------------------------------------
-- 11. Análisis breve en lote (modelo barato, NO Hermes)
-- -----------------------------------------------------------------------------
-- Versiones nuevas que pasaron el filtro y aún no tienen clasificación, agrupadas por título
-- (la misma noticia en varias fuentes = 1 elemento). Las marca «en_cola» 2 horas.
CREATE OR REPLACE FUNCTION vigilante.lote_para_clasificar(p_cliente text, p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  WITH cand AS (
    SELECT r.*, coalesce(s.codigo, 'busqueda') AS fcod, coalesce(s.nombre, 'Búsqueda: ' || b.consulta) AS fnom,
           coalesce(s.tipo::text, 'no_oficial') AS ftipo
      FROM vigilante.raw_items r
      LEFT JOIN vigilante.sources s ON s.id = r.source_id
      LEFT JOIN vigilante.busquedas b ON b.id = r.busqueda_id
     WHERE r.cliente_id = v_cliente
       AND (r.estado = 'nuevo' OR (r.estado = 'en_cola'
                                   AND coalesce((r.payload ->> 'en_cola_desde')::timestamptz, r.recolectado_en) < now() - interval '2 hours'))
       AND NOT EXISTS (SELECT 1 FROM vigilante.analisis a WHERE a.raw_item_id = r.id AND a.version = r.version AND a.tipo = 'clasificacion')
  ), grupos AS (
    SELECT titulo_norm,
           array_agg(id ORDER BY (ftipo IN ('oficial', 'organismo_internacional')) DESC, puntaje_previo DESC, id) AS ids,
           array_agg(DISTINCT fnom) AS fuentes, count(DISTINCT fcod) AS n_fuentes, max(puntaje_previo) AS puntaje
      FROM cand GROUP BY titulo_norm
     ORDER BY max(puntaje_previo) + 10 * (count(DISTINCT fcod) - 1) DESC, max(recolectado_en) DESC
     LIMIT greatest(least(coalesce(p_limite, 20), 40), 1)
  ), marcadas AS (
    UPDATE vigilante.raw_items r SET estado = 'en_cola', payload = r.payload || jsonb_build_object('en_cola_desde', now())
      FROM grupos g WHERE r.id = ANY (g.ids)
    RETURNING r.id
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'clave', c.id,
           'ids', g.ids,
           'version', c.version,
           'titulo', c.titulo,
           'texto', left(coalesce(c.contenido, ''), 1200),
           'fuente', c.fnom, 'fuente_tipo', c.ftipo,
           'otras_fuentes', g.fuentes, 'fuentes_que_coinciden', g.n_fuentes,
           'publicado_en', c.publicado_en,
           'motivos', to_jsonb(c.motivos),
           'oportunidad_candidata', to_jsonb(c.tipos_oportunidad),
           'territorios', (SELECT coalesce(jsonb_agg(t.nombre), '[]') FROM vigilante.territorios t WHERE t.id = ANY (c.territorios_detectados)),
           'es_actualizacion', c.version > 1,
           'senal_existente', (SELECT jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', left(s.resumen, 300))
                                 FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
                                WHERE sr.raw_item_id = ANY (g.ids) ORDER BY s.id DESC LIMIT 1)
         ) ORDER BY g.puntaje + 10 * (g.n_fuentes - 1) DESC), '[]')
    INTO v
    FROM grupos g JOIN cand c ON c.id = g.ids[1]
   WHERE (SELECT count(*) FROM marcadas) >= 0;
  RETURN v;
END $$;

-- Guarda lo que devolvió el clasificador y hace el resto con código:
--   * el análisis queda guardado por versión (no se repite);
--   * no relevante → noticia descartada con el motivo;
--   * relevante → crea o actualiza la señal (procedencia desde las noticias, no desde el modelo);
--   * oportunidad con «hecho» → vigilante.oportunidades (explícita si la regla la marcó; si no, inferida);
--   * necesita_agente, o señal de prioridad alta sin fuente oficial → tarea para Hermes.
-- p_resultados: [{"clave": id, "relevante": true, "motivo": "...", "titulo": "...", "resumen": "...",
--   "recomendacion": "...", "naturaleza": "...", "categoria": "...", "prioridad": "...", "motivos_prioridad": [],
--   "departamentos": [], "fecha_evento_inicio": null, "fecha_evento_fin": null, "plazo_hasta": null,
--   "es_escenario": false, "confianza": 0.7,
--   "oportunidad": {"tipo": "...", "hecho": "...", "interpretacion": "...", "beneficiarios": [], "accion": "...", "importancia": 3},
--   "necesita_agente": false, "tarea": {"tipo": "corroborar|contradiccion|relacionar|oportunidad_inferida", "motivo": "..."}}]
-- p_uso: {"tokens_entrada": n, "tokens_salida": n, "costo_usd": x} del lote completo (se reparte entre los elementos)
CREATE OR REPLACE FUNCTION vigilante.guardar_clasificacion(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL,
                                                           p_prompt_version text DEFAULT NULL, p_uso jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; v_doc vigilante.raw_items; v_ids bigint[];
  v_sig bigint; v_cod text; v_res jsonb; v_senal jsonb; v_op jsonb; v_nivel text; v_tarea jsonb; v_n int;
  n_desc int := 0; n_nuevas int := 0; n_act int := 0; n_opp int := 0; n_tareas int := 0; n_ignoradas int := 0;
BEGIN
  v_n := greatest(jsonb_array_length(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END), 1);
  PERFORM set_config('vigilante.actor', 'clasificador:' || coalesce(p_modelo, '?'), true);
  FOR x IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END) LOOP
    -- solo se acepta lo que se mandó a clasificar (clave = id de la noticia principal del grupo)
    SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = v_cliente AND id = (x ->> 'clave')::bigint AND estado IN ('en_cola', 'nuevo');
    IF v_doc.id IS NULL OR (x ->> 'clave') !~ '^\d+$' THEN n_ignoradas := n_ignoradas + 1; CONTINUE; END IF;
    -- el grupo: misma noticia en otras fuentes, también pendiente
    v_ids := ARRAY(SELECT id FROM vigilante.raw_items WHERE cliente_id = v_cliente AND titulo_norm = v_doc.titulo_norm
                     AND estado IN ('en_cola', 'nuevo') ORDER BY id);

    INSERT INTO vigilante.analisis (cliente_id, raw_item_id, version, tipo, modelo, prompt_version, salida, relevante,
                                    tokens_entrada, tokens_salida, costo_usd)
    VALUES (v_cliente, v_doc.id, v_doc.version, 'clasificacion', p_modelo, p_prompt_version, x,
            coalesce((x ->> 'relevante')::boolean, false),
            ((p_uso ->> 'tokens_entrada')::numeric / v_n)::int, ((p_uso ->> 'tokens_salida')::numeric / v_n)::int,
            (p_uso ->> 'costo_usd')::numeric / v_n)
    ON CONFLICT (raw_item_id, version, tipo) DO NOTHING;

    IF NOT coalesce((x ->> 'relevante')::boolean, false) THEN
      UPDATE vigilante.raw_items SET estado = 'descartado', motivo_descarte = 'IA: ' || coalesce(nullif(x ->> 'motivo', ''), 'no relevante')
       WHERE id = ANY (v_ids);
      n_desc := n_desc + 1; CONTINUE;
    END IF;

    -- ¿ya hay señal para este hecho? (una noticia del grupo ya enlazada, o el mismo título en 72 h)
    SELECT s.codigo INTO v_cod FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
     WHERE sr.raw_item_id = ANY (v_ids) ORDER BY s.id DESC LIMIT 1;
    IF v_cod IS NULL THEN
      SELECT s.codigo INTO v_cod FROM vigilante.raw_items r JOIN vigilante.signal_raw_items sr ON sr.raw_item_id = r.id
        JOIN vigilante.signals s ON s.id = sr.signal_id
       WHERE r.cliente_id = v_cliente AND r.titulo_norm = v_doc.titulo_norm AND r.recolectado_en > now() - interval '72 hours'
         AND s.estado NOT IN ('descartada', 'cerrada')
       ORDER BY s.id DESC LIMIT 1;
    END IF;

    v_senal := jsonb_strip_nulls(jsonb_build_object(
      'codigo', v_cod,
      'titulo', coalesce(nullif(x ->> 'titulo', ''), v_doc.titulo),
      'resumen', coalesce(nullif(x ->> 'resumen', ''), left(v_doc.contenido, 300), v_doc.titulo),
      'recomendacion', x ->> 'recomendacion', 'naturaleza', x ->> 'naturaleza', 'categoria', x ->> 'categoria',
      'prioridad', x ->> 'prioridad', 'motivos_prioridad', x -> 'motivos_prioridad', 'departamentos', x -> 'departamentos',
      'fecha_evento_inicio', x ->> 'fecha_evento_inicio', 'fecha_evento_fin', x ->> 'fecha_evento_fin',
      'plazo_hasta', x ->> 'plazo_hasta', 'es_escenario', x -> 'es_escenario', 'confianza', x -> 'confianza',
      'modelo', p_modelo, 'noticias', to_jsonb(v_ids),
      -- para la web (mismo formato que vigilante.json)
      'tipo_oportunidad', x #>> '{oportunidad,tipo}', 'actores', x #> '{oportunidad,beneficiarios}',
      'importancia', x #>> '{oportunidad,interpretacion}',
      'soluciones', CASE WHEN x #>> '{oportunidad,accion}' IS NOT NULL
                         THEN jsonb_build_array(jsonb_build_object('t', x #>> '{oportunidad,accion}')) END));
    v_res := vigilante.guardar_senal(p_cliente, v_senal);
    SELECT id INTO v_sig FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = v_res ->> 'codigo';
    UPDATE vigilante.analisis SET signal_id = v_sig WHERE raw_item_id = v_doc.id AND version = v_doc.version AND tipo = 'clasificacion';
    IF (v_res ->> 'nueva')::boolean THEN n_nuevas := n_nuevas + 1; ELSE n_act := n_act + 1; END IF;

    -- oportunidad
    v_op := x -> 'oportunidad';
    IF jsonb_typeof(v_op) = 'object' AND coalesce(trim(v_op ->> 'hecho'), '') <> '' AND coalesce(trim(v_op ->> 'tipo'), '') <> '' THEN
      v_nivel := CASE WHEN lower(v_op ->> 'tipo') = ANY (v_doc.tipos_oportunidad) THEN 'explicita' ELSE 'inferida' END;
      IF v_nivel = 'explicita' OR coalesce(trim(v_op ->> 'interpretacion'), '') <> '' THEN
        INSERT INTO vigilante.oportunidades (cliente_id, signal_id, nivel, tipo, hecho, interpretacion, beneficiarios, accion,
                                             plazo_hasta, importancia, evidencias, creada_por)
        VALUES (v_cliente, v_sig, v_nivel, lower(v_op ->> 'tipo'), v_op ->> 'hecho', nullif(trim(v_op ->> 'interpretacion'), ''),
                CASE WHEN jsonb_typeof(v_op -> 'beneficiarios') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_op -> 'beneficiarios')) ELSE '{}' END,
                v_op ->> 'accion', (SELECT plazo_hasta FROM vigilante.signals WHERE id = v_sig),
                CASE WHEN (v_op ->> 'importancia') ~ '^[1-5]$' THEN (v_op ->> 'importancia')::smallint END,
                v_ids, 'clasificador')
        ON CONFLICT (signal_id, nivel, tipo) DO UPDATE SET
          hecho = EXCLUDED.hecho, interpretacion = EXCLUDED.interpretacion, beneficiarios = EXCLUDED.beneficiarios,
          accion = EXCLUDED.accion, plazo_hasta = EXCLUDED.plazo_hasta, importancia = EXCLUDED.importancia,
          evidencias = ARRAY(SELECT DISTINCT unnest(vigilante.oportunidades.evidencias || EXCLUDED.evidencias)), updated_at = now();
        n_opp := n_opp + 1;
      END IF;
    END IF;

    -- tareas para Hermes
    v_tarea := x -> 'tarea';
    IF coalesce((x ->> 'necesita_agente')::boolean, false) AND jsonb_typeof(v_tarea) = 'object'
       AND v_tarea ->> 'tipo' IN ('corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida') THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, v_tarea ->> 'tipo', v_sig, v_ids,
                                                    coalesce(nullif(v_tarea ->> 'motivo', ''), 'Pedido por el clasificador'), 'clasificador') ->> 'nueva')::boolean::int;
    ELSIF x ->> 'prioridad' = 'alta' AND NOT (v_res ->> 'fuente_oficial')::boolean THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, 'corroborar', v_sig, v_ids,
                                                    'Prioridad alta sin fuente oficial: buscar confirmación', 'regla') ->> 'nueva')::boolean::int;
    END IF;
  END LOOP;

  IF coalesce((p_uso ->> 'costo_usd')::numeric, 0) > 0 OR coalesce((p_uso ->> 'tokens_entrada')::int, 0) > 0 THEN
    PERFORM vigilante.registrar_log(p_cliente, 'clasificador', 'info', format('Lote de %s noticias', v_n), p_uso || jsonb_build_object('modelo', p_modelo),
                                    (p_uso ->> 'costo_usd')::numeric, NULL);
  END IF;
  RETURN jsonb_build_object('descartadas', n_desc, 'senales_nuevas', n_nuevas, 'senales_actualizadas', n_act,
                            'oportunidades', n_opp, 'tareas_agente', n_tareas, 'ignoradas', n_ignoradas);
END $$;

-- -----------------------------------------------------------------------------
-- 12. Oportunidades y tareas del agente
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.crear_tarea(p_cliente uuid, p_tipo text, p_signal_id bigint, p_ids bigint[],
                                                 p_motivo text, p_por text DEFAULT 'regla')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO vigilante.tareas_agente (cliente_id, tipo, signal_id, raw_item_ids, motivo, creada_por)
  VALUES (p_cliente, p_tipo, p_signal_id, coalesce(p_ids, '{}'), p_motivo, p_por)
  ON CONFLICT (cliente_id, tipo, coalesce(signal_id, 0)) WHERE estado IN ('pendiente', 'en_curso') DO NOTHING
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'nueva', v_id IS NOT NULL);
END $$;

-- Hermes toma tareas (las que llevan más de 2 horas «en curso» vuelven a la cola)
CREATE OR REPLACE FUNCTION vigilante.tomar_tareas(p_cliente text, p_limite int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v jsonb;
BEGIN
  UPDATE vigilante.tareas_agente SET estado = 'pendiente' WHERE cliente_id = v_cliente AND estado = 'en_curso' AND tomada_en < now() - interval '2 hours';
  WITH t AS (
    SELECT id FROM vigilante.tareas_agente WHERE cliente_id = v_cliente AND estado = 'pendiente'
     ORDER BY CASE tipo WHEN 'contradiccion' THEN 0 WHEN 'corroborar' THEN 1 ELSE 2 END, created_at
     LIMIT greatest(least(coalesce(p_limite, 5), 20), 1) FOR UPDATE SKIP LOCKED
  ), u AS (
    UPDATE vigilante.tareas_agente a SET estado = 'en_curso', tomada_en = now() FROM t WHERE a.id = t.id RETURNING a.*
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'tipo', u.tipo, 'motivo', u.motivo,
           'senal', (SELECT jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen, 'categoria', s.categoria,
                                               'prioridad', s.prioridad, 'fuente_oficial', s.fuente_oficial, 'enlace_oficial', s.enlace_oficial)
                       FROM vigilante.signals s WHERE s.id = u.signal_id),
           'noticias', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'titulo', r.titulo, 'url', r.url, 'texto', left(r.contenido, 800),
                                                                     'fuente', coalesce(src.nombre, 'búsqueda'), 'fuente_tipo', coalesce(src.tipo::text, 'no_oficial'),
                                                                     'publicado_en', r.publicado_en, 'version', r.version)), '[]')
                          FROM vigilante.raw_items r LEFT JOIN vigilante.sources src ON src.id = r.source_id
                         WHERE r.id = ANY (u.raw_item_ids || ARRAY(SELECT raw_item_id FROM vigilante.signal_raw_items WHERE signal_id = u.signal_id)))
         ) ORDER BY u.id), '[]') INTO v FROM u;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION vigilante.terminar_tarea(p_cliente text, p_id bigint, p_estado text, p_resultado jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente);
BEGIN
  IF p_estado NOT IN ('hecha', 'descartada') THEN RAISE EXCEPTION 'Estado % no válido (hecha o descartada)', p_estado; END IF;
  UPDATE vigilante.tareas_agente SET estado = p_estado, resultado = coalesce(p_resultado, '{}'), terminada_en = now()
   WHERE id = p_id AND cliente_id = v_cliente AND estado IN ('pendiente', 'en_curso');
  IF NOT FOUND THEN RAISE EXCEPTION 'La tarea % no existe o ya está cerrada', p_id; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Hermes guarda una oportunidad (normalmente inferida) a partir de evidencias que existen en la base
CREATE OR REPLACE FUNCTION vigilante.guardar_oportunidad(p_cliente text, p_op jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_sig bigint; v_ids bigint[]; v_nivel text; v_id bigint;
BEGIN
  v_ids := ARRAY(SELECT r.id FROM vigilante.raw_items r WHERE r.cliente_id = v_cliente
                   AND r.id IN (SELECT x::bigint FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_op -> 'evidencias') = 'array' THEN p_op -> 'evidencias' ELSE '[]' END) x WHERE x ~ '^\d+$'));
  IF cardinality(v_ids) = 0 THEN RAISE EXCEPTION 'Una oportunidad necesita evidencias: ids de noticias que estén en la base'; END IF;
  IF coalesce(trim(p_op ->> 'hecho'), '') = '' OR coalesce(trim(p_op ->> 'tipo'), '') = '' THEN
    RAISE EXCEPTION 'Faltan tipo y hecho (lo que dice la fuente)';
  END IF;
  SELECT id INTO v_sig FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = p_op ->> 'senal';
  IF v_sig IS NULL THEN
    SELECT sr.signal_id INTO v_sig FROM vigilante.signal_raw_items sr WHERE sr.raw_item_id = ANY (v_ids) ORDER BY sr.signal_id DESC LIMIT 1;
  END IF;
  v_nivel := CASE WHEN p_op ->> 'nivel' = 'explicita' THEN 'explicita' ELSE 'inferida' END;
  IF v_nivel = 'inferida' AND coalesce(trim(p_op ->> 'interpretacion'), '') = '' THEN
    RAISE EXCEPTION 'Una oportunidad inferida necesita la interpretación (qué podría aprovechar el sector)';
  END IF;
  PERFORM set_config('vigilante.actor', 'hermes:mcp', true);
  INSERT INTO vigilante.oportunidades (cliente_id, signal_id, nivel, tipo, hecho, interpretacion, beneficiarios, accion,
                                       plazo_hasta, importancia, evidencias, creada_por)
  VALUES (v_cliente, v_sig, v_nivel, lower(p_op ->> 'tipo'), p_op ->> 'hecho', nullif(trim(p_op ->> 'interpretacion'), ''),
          CASE WHEN jsonb_typeof(p_op -> 'beneficiarios') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p_op -> 'beneficiarios')) ELSE '{}' END,
          p_op ->> 'accion',
          CASE WHEN (p_op ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}$' THEN ((p_op ->> 'plazo_hasta') || 'T23:59:59-04:00')::timestamptz END,
          CASE WHEN (p_op ->> 'importancia') ~ '^[1-5]$' THEN (p_op ->> 'importancia')::smallint END,
          v_ids, 'hermes')
  ON CONFLICT (signal_id, nivel, tipo) DO UPDATE SET
    hecho = EXCLUDED.hecho, interpretacion = EXCLUDED.interpretacion, beneficiarios = EXCLUDED.beneficiarios,
    accion = EXCLUDED.accion, plazo_hasta = coalesce(EXCLUDED.plazo_hasta, vigilante.oportunidades.plazo_hasta),
    importancia = EXCLUDED.importancia,
    evidencias = ARRAY(SELECT DISTINCT unnest(vigilante.oportunidades.evidencias || EXCLUDED.evidencias)), updated_at = now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'nivel', v_nivel, 'nota', 'Queda como «propuesta»: una persona la valida');
END $$;

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
     AND (o.plazo_hasta IS NULL OR o.plazo_hasta >= now() - interval '1 day')
$$;
REVOKE ALL ON FUNCTION vigilante._oportunidades_json(uuid) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.oportunidades_web()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante._oportunidades_json(vigilante.cliente_actual())
$$;

-- -----------------------------------------------------------------------------
-- 13. Publicación: la web lee la base; vigilante.json se genera desde aquí
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante._vigilante_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT p_cliente AS id)
  SELECT jsonb_build_object(
    'version', 1,
    'generado', now(),
    'origen', 'base',
    'noticias_revisadas', (SELECT count(*) FROM vigilante.raw_items r, c WHERE r.cliente_id = c.id AND r.recolectado_en > now() - interval '24 hours'),
    'ventana_horas', 24,
    'fuentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', s.codigo, 'nombre', s.nombre, 'canal', s.categorias[1], 'tipo', s.tipo, 'url', s.url,
                  'metodo', s.metodo, 'estado', CASE WHEN NOT s.activa THEN 'MANT' ELSE coalesce(s.config ->> 'estado', 'UNKNOWN') END,
                  'ultima', s.ultima_consulta_en, 'proxima', s.proxima_revision_en,
                  'items', coalesce((s.config ->> 'items')::int, 0), 'hist', coalesce(s.config -> 'hist', '[]'), 'info', s.notas)
                  ORDER BY s.nombre), '[]')
                  FROM vigilante.sources s, c
                 WHERE s.cliente_id = c.id AND s.eliminada_en IS NULL AND NOT coalesce((s.config ->> 'propuesta_avia')::boolean, false)),
    'senales', (SELECT coalesce(jsonb_agg(
                  CASE WHEN s.salida_modelo ? 'id' AND s.salida_modelo ? 'titulo'
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
                  END ORDER BY s.created_at DESC), '[]')
                  FROM (SELECT s.* FROM vigilante.signals s, c WHERE s.cliente_id = c.id AND s.created_at >= now() - interval '60 days'
                        ORDER BY s.created_at DESC LIMIT 300) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.vigilante_bd()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN vigilante.cliente_actual() IS NULL THEN NULL ELSE vigilante._vigilante_json(vigilante.cliente_actual()) END
$$;

-- Para el VPS / n8n: genera vigilante.json de un cliente desde la base (compatibilidad con la web antigua)
CREATE OR REPLACE FUNCTION vigilante.vigilante_json(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante._vigilante_json(vigilante.id_cliente(p_cliente))
$$;

-- -----------------------------------------------------------------------------
-- 14. Permisos de las funciones
-- -----------------------------------------------------------------------------
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'vigilante.registrar_candidata(uuid, text, text, text, text, text, jsonb, text)',
    'vigilante.proponer_fuente(text, text, text, text, jsonb, text)',
    'vigilante.insertar_noticias(uuid, integer, bigint, jsonb, text)',
    'vigilante.fuentes_para_recolector(text)',
    'vigilante.guardar_comprobacion(text, text, text, text, jsonb, text, text, text, text, boolean)',
    'vigilante.guardar_senal(text, jsonb)',
    'vigilante.lote_para_clasificar(text, int)',
    'vigilante.guardar_clasificacion(text, jsonb, text, text, jsonb)',
    'vigilante.crear_tarea(uuid, text, bigint, bigint[], text, text)',
    'vigilante.tomar_tareas(text, int)',
    'vigilante.terminar_tarea(text, bigint, text, jsonb)',
    'vigilante.guardar_oportunidad(text, jsonb)',
    'vigilante.vigilante_json(text)',
    'vigilante.propuestas_a_candidatas(boolean)'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
  FOREACH f IN ARRAY ARRAY[
    'vigilante.candidatas_web()',
    'vigilante.decidir_candidata(bigint, boolean, text, text, text, text, int)',
    'vigilante.alias_fuente(text, text)',
    'vigilante.oportunidades_web()',
    'vigilante.vigilante_bd()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM public, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;

COMMIT;
