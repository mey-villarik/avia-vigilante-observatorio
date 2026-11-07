-- =============================================================================
-- AVIA Vigilante · Esquema genérico multicliente (PostgreSQL 15+ / Supabase)
-- Derivado del esquema de ORBITA (observatorio/db/01_orbita_schema.sql).
--
-- Qué cambia respecto a ORBITA:
--   * Tabla `clientes`: cada vigilante (ORBITA turismo Bolivia, otro sector, otro
--     país...) es un cliente. Todas las tablas llevan `cliente_id`.
--   * `departamentos` pasa a `territorios`, configurable por cliente y con
--     jerarquía (país > región > ciudad...).
--   * Categorías, fuentes y parámetros son por cliente. Los parámetros sin
--     cliente son los valores por defecto de la plataforma.
--   * Las tablas hijas (revisiones, alertas, envíos...) heredan `cliente_id`
--     de su padre automáticamente: quien inserta no tiene que pasarlo, y la base
--     rechaza mezclar datos de dos clientes.
--   * RLS: cada usuario solo ve los datos de su cliente.
--   * `alta_cliente()` crea un vigilante nuevo copiando la configuración de otro.
--
-- Uso:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01_vigilante_schema.sql
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02_cliente_orbita_bolivia.sql   (ejemplo)
-- En Supabase: SQL Editor → pegar → Run; añadir `vigilante` en
-- Settings → API → Exposed schemas.
--
-- n8n y Hermes se conectan con service_role (o postgres), que salta RLS, y
-- siempre indican el cliente: en sources/categorías/territorios explícitamente;
-- en raw_items y signals se deduce de la fuente.
-- Para el historial: SET LOCAL vigilante.actor = 'hermes:skill-vigilante';
--
-- No es re-ejecutable: para empezar de cero, DROP SCHEMA vigilante CASCADE;
-- =============================================================================

BEGIN;

SET client_min_messages = warning;

-- -----------------------------------------------------------------------------
-- 0. Compatibilidad con Postgres propio (en Supabase ya existe todo esto)
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN BYPASSRLS;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'auth' AND p.proname = 'uid'
  ) THEN
    CREATE SCHEMA IF NOT EXISTS auth;
    EXECUTE $f$
      CREATE FUNCTION auth.uid() RETURNS uuid
      LANGUAGE sql STABLE AS
      'SELECT nullif(coalesce(current_setting(''request.jwt.claim.sub'', true),
                              current_setting(''request.jwt.claims'', true)::jsonb ->> ''sub''), '''')::uuid'
    $f$;
    GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
  END IF;
END
$$;

CREATE SCHEMA vigilante;
COMMENT ON SCHEMA vigilante IS 'AVIA Vigilante: vigilancia de oportunidades y riesgos, multicliente';

SET search_path = vigilante, public;

-- -----------------------------------------------------------------------------
-- 1. Tipos
-- -----------------------------------------------------------------------------
CREATE TYPE vigilante.rol_usuario         AS ENUM ('administrador', 'analista', 'visor');
CREATE TYPE vigilante.naturaleza_senal    AS ENUM ('riesgo', 'oportunidad', 'mixta');
CREATE TYPE vigilante.prioridad           AS ENUM ('baja', 'media', 'alta');
CREATE TYPE vigilante.estado_senal        AS ENUM ('detectada', 'en_analisis', 'en_verificacion',
                                                   'confirmada', 'publicada', 'cerrada', 'descartada');
CREATE TYPE vigilante.estado_raw          AS ENUM ('nuevo', 'en_cola', 'procesado', 'descartado', 'error');
CREATE TYPE vigilante.metodo_fuente       AS ENUM ('rss', 'google_news_rss', 'gdelt', 'http_html', 'apify',
                                                   'tavily', 'api', 'mcp_vigilante', 'manual');
CREATE TYPE vigilante.tipo_fuente         AS ENUM ('oficial', 'organismo_internacional', 'medio', 'no_oficial');
CREATE TYPE vigilante.decision_revision   AS ENUM ('pendiente', 'aprobada', 'editada', 'rechazada', 'vencida');
CREATE TYPE vigilante.estado_verificacion AS ENUM ('confirmada', 'en_verificacion');
CREATE TYPE vigilante.visibilidad         AS ENUM ('publica', 'privada');
CREATE TYPE vigilante.canal               AS ENUM ('telegram', 'whatsapp', 'email', 'web');
CREATE TYPE vigilante.estado_envio        AS ENUM ('pendiente', 'enviado', 'entregado', 'leido', 'fallido', 'omitido');
CREATE TYPE vigilante.tipo_seguimiento    AS ENUM ('plazo_convocatoria', 'evento', 'revision_alerta');
CREATE TYPE vigilante.nivel_log           AS ENUM ('debug', 'info', 'warn', 'error');

-- -----------------------------------------------------------------------------
-- 2. Utilidades comunes
-- -----------------------------------------------------------------------------
CREATE FUNCTION vigilante.tg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE FUNCTION vigilante.actor_actual() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('vigilante.actor', true), ''),
                  auth.uid()::text,
                  current_user::text)
$$;

-- Hereda cliente_id del registro padre. Argumentos: tabla padre, columna FK, tipo del id del padre.
-- Si quien inserta ya trae cliente_id, comprueba que coincida con el del padre.
CREATE FUNCTION vigilante.tg_heredar_cliente() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_padre_id text := to_jsonb(NEW) ->> TG_ARGV[1];
  v_cliente  uuid;
BEGIN
  IF v_padre_id IS NULL THEN
    RETURN NEW;  -- sin padre: cliente_id debe venir dado (NOT NULL lo exige)
  END IF;
  EXECUTE format('SELECT cliente_id FROM vigilante.%I WHERE id = $1::%s', TG_ARGV[0], TG_ARGV[2])
     INTO v_cliente USING v_padre_id;
  IF v_cliente IS NULL THEN
    RETURN NEW;  -- el padre no existe: la FK dará el error
  END IF;
  IF NEW.cliente_id IS NULL THEN
    NEW.cliente_id := v_cliente;
  ELSIF NEW.cliente_id <> v_cliente THEN
    RAISE EXCEPTION '%: cliente_id % no coincide con el de % %', TG_TABLE_NAME, NEW.cliente_id, TG_ARGV[0], v_padre_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- -----------------------------------------------------------------------------
-- 3. Clientes (un cliente = un vigilante)
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.clientes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  nombre        text NOT NULL,
  sector        text,                                  -- turismo, agro, tecnología...
  pais          text,                                  -- ISO 3166-1 alfa-2, p. ej. 'BO'
  zona_horaria  text NOT NULL DEFAULT 'UTC',
  idioma        text NOT NULL DEFAULT 'es',
  perfil        jsonb NOT NULL DEFAULT '{}',           -- palabras clave, ejes, competidores, hipótesis
  entidad_vigilante_id uuid,                           -- id de la entidad en el Vigilante n8n (MCP), si existe
  activo        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE vigilante.clientes IS 'Cada vigilante configurado (sector + territorio + perfil)';
COMMENT ON COLUMN vigilante.clientes.perfil IS 'Configuración para Hermes y el script de búsqueda: keywords, ejes, umbrales de puntaje';

-- -----------------------------------------------------------------------------
-- 4. Parámetros, territorios y categorías (por cliente)
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.parametros (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id   uuid REFERENCES vigilante.clientes(id) ON DELETE CASCADE,   -- NULL = valor por defecto de la plataforma
  clave        text NOT NULL,
  valor        jsonb NOT NULL,
  descripcion  text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX parametros_clave_unica ON vigilante.parametros (cliente_id, clave) NULLS NOT DISTINCT;
COMMENT ON TABLE vigilante.parametros IS 'Reglas operativas. Fila con cliente_id NULL = defecto; fila del cliente = lo sobrescribe';

-- Valor del parámetro para un cliente, o el de la plataforma si el cliente no lo define
CREATE FUNCTION vigilante.param(p_cliente uuid, p_clave text) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT valor FROM vigilante.parametros
   WHERE clave = p_clave AND (cliente_id = p_cliente OR cliente_id IS NULL)
   ORDER BY cliente_id NULLS LAST
   LIMIT 1
$$;

CREATE TABLE vigilante.territorios (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id  uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  codigo      text NOT NULL,                          -- p. ej. ISO 3166-2 'BO-L'
  nombre      text NOT NULL,
  nivel       text NOT NULL DEFAULT 'region',         -- pais, region, provincia, ciudad, zona...
  padre_id    integer REFERENCES vigilante.territorios(id) ON DELETE SET NULL,
  datos       jsonb NOT NULL DEFAULT '{}',            -- capital, coordenadas, alias para detectar menciones
  UNIQUE (cliente_id, codigo),
  UNIQUE (cliente_id, id)
);
COMMENT ON TABLE vigilante.territorios IS 'Sustituye a departamentos: cada cliente define su territorio y su jerarquía';

CREATE TABLE vigilante.categorias (
  cliente_id           uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  codigo               text NOT NULL,
  nombre               text NOT NULL,
  descripcion          text,
  revision_obligatoria boolean NOT NULL DEFAULT false,
  orden                smallint NOT NULL DEFAULT 0,
  activa               boolean NOT NULL DEFAULT true,
  PRIMARY KEY (cliente_id, codigo)
);

-- -----------------------------------------------------------------------------
-- 5. Usuarios, roles y preferencias
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cliente_id        uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  auth_user_id      uuid UNIQUE,                       -- una cuenta de login pertenece a un cliente
  nombre            text NOT NULL,
  email             text,
  telefono_whatsapp text,
  telegram_chat_id  bigint,
  organizacion      text,
  rol               vigilante.rol_usuario NOT NULL DEFAULT 'visor',
  activo            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, email),
  UNIQUE (cliente_id, telefono_whatsapp),
  UNIQUE (cliente_id, telegram_chat_id),
  CONSTRAINT users_telefono_e164 CHECK (telefono_whatsapp IS NULL OR telefono_whatsapp ~ '^\+[1-9][0-9]{7,14}$'),
  CONSTRAINT users_algun_contacto CHECK (num_nonnulls(auth_user_id, email, telefono_whatsapp, telegram_chat_id) > 0)
);
COMMENT ON COLUMN vigilante.users.rol IS 'administrador: configura su vigilante; analista: aprueba alertas; visor: recibe y consulta';

CREATE TABLE vigilante.user_preferences (
  user_id           uuid PRIMARY KEY REFERENCES vigilante.users(id) ON DELETE CASCADE,
  cliente_id        uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  canales           vigilante.canal[] NOT NULL DEFAULT '{telegram}',
  prioridad_minima  vigilante.prioridad NOT NULL DEFAULT 'media',
  naturalezas       vigilante.naturaleza_senal[] NOT NULL DEFAULT '{riesgo,oportunidad,mixta}',
  recibir_resumen   boolean NOT NULL DEFAULT true,
  recibir_urgentes  boolean NOT NULL DEFAULT true,
  silencio_desde    time,                              -- hora local del cliente
  silencio_hasta    time,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE vigilante.user_categorias (
  user_id     uuid REFERENCES vigilante.users(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL,
  categoria   text NOT NULL,
  PRIMARY KEY (user_id, categoria),
  FOREIGN KEY (cliente_id, categoria) REFERENCES vigilante.categorias(cliente_id, codigo) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE vigilante.user_territorios (
  user_id       uuid REFERENCES vigilante.users(id) ON DELETE CASCADE,
  cliente_id    uuid NOT NULL,
  territorio_id integer NOT NULL,
  PRIMARY KEY (user_id, territorio_id),
  FOREIGN KEY (cliente_id, territorio_id) REFERENCES vigilante.territorios(cliente_id, id) ON DELETE CASCADE
);

CREATE FUNCTION vigilante.rol_actual() RETURNS vigilante.rol_usuario
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT rol FROM vigilante.users WHERE auth_user_id = auth.uid() AND activo
$$;

CREATE FUNCTION vigilante.usuario_actual() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT id FROM vigilante.users WHERE auth_user_id = auth.uid() AND activo
$$;

CREATE FUNCTION vigilante.cliente_actual() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT u.cliente_id FROM vigilante.users u JOIN vigilante.clientes c ON c.id = u.cliente_id
   WHERE u.auth_user_id = auth.uid() AND u.activo AND c.activo
$$;

CREATE FUNCTION vigilante.es_staff() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(vigilante.rol_actual() IN ('administrador', 'analista'), false) $$;

CREATE FUNCTION vigilante.es_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(vigilante.rol_actual() = 'administrador', false) $$;

-- -----------------------------------------------------------------------------
-- 6. Fuentes y documentos crudos
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.sources (
  id                  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id          uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  codigo              text NOT NULL,
  nombre              text NOT NULL,
  institucion         text,
  url                 text NOT NULL,
  tipo                vigilante.tipo_fuente NOT NULL,
  metodo              vigilante.metodo_fuente NOT NULL,
  categorias          text[] NOT NULL DEFAULT '{}',
  frecuencia_minutos  integer NOT NULL DEFAULT 60 CHECK (frecuencia_minutos >= 5),
  rapida              boolean NOT NULL DEFAULT false,  -- entra en el ciclo de 30 minutos
  activa              boolean NOT NULL DEFAULT true,
  config              jsonb NOT NULL DEFAULT '{}',     -- query de Google News, filtros GDELT, selectores, actor de Apify...
  ultima_consulta_en  timestamptz,
  ultimo_exito_en     timestamptz,
  errores_seguidos    integer NOT NULL DEFAULT 0,
  ultimo_error        text,
  notas               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, codigo)
);
COMMENT ON COLUMN vigilante.sources.tipo IS 'Las fuentes no oficiales siempre pasan por revisión del analista';

CREATE TABLE vigilante.raw_items (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id       uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  source_id        integer NOT NULL REFERENCES vigilante.sources(id),
  url              text NOT NULL,
  content_hash     text NOT NULL,                      -- sha256 de título+contenido normalizados
  titulo           text,
  contenido        text,
  publicado_en     timestamptz,
  recolectado_en   timestamptz NOT NULL DEFAULT now(),
  idioma           text NOT NULL DEFAULT 'es',
  menciona_territorio boolean,
  territorios_detectados integer[] NOT NULL DEFAULT '{}',
  estado           vigilante.estado_raw NOT NULL DEFAULT 'nuevo',
  motivo_descarte  text,
  ejecucion        text,                               -- id de la ejecución del script / n8n
  payload          jsonb NOT NULL DEFAULT '{}',
  busqueda         tsvector GENERATED ALWAYS AS (
                     to_tsvector('spanish', coalesce(titulo, '') || ' ' || coalesce(contenido, ''))) STORED,
  -- dedupe por cliente: INSERT ... ON CONFLICT (cliente_id, content_hash) DO NOTHING
  CONSTRAINT raw_items_hash_unico UNIQUE (cliente_id, content_hash)
);
CREATE INDEX raw_items_url_idx          ON vigilante.raw_items (cliente_id, url);
CREATE INDEX raw_items_cola_idx         ON vigilante.raw_items (estado, recolectado_en) WHERE estado IN ('nuevo', 'en_cola');
CREATE INDEX raw_items_source_fecha_idx ON vigilante.raw_items (source_id, recolectado_en DESC);
CREATE INDEX raw_items_busqueda_idx     ON vigilante.raw_items USING gin (busqueda);

CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('sources', 'source_id', 'integer');

-- -----------------------------------------------------------------------------
-- 7. Señales e historial
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.signals (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id         uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  raw_item_id        bigint REFERENCES vigilante.raw_items(id) ON DELETE SET NULL,
  source_id          integer REFERENCES vigilante.sources(id),
  titulo             text NOT NULL,
  resumen            text NOT NULL,
  recomendacion      text,
  naturaleza         vigilante.naturaleza_senal NOT NULL,
  categoria          text NOT NULL,
  prioridad          vigilante.prioridad NOT NULL DEFAULT 'media',
  motivos_prioridad  text[] NOT NULL DEFAULT '{}',
  puntaje            numeric(5,2) CHECK (puntaje BETWEEN 0 AND 100),
  confianza          numeric(3,2) CHECK (confianza BETWEEN 0 AND 1),
  alcance_total      boolean NOT NULL DEFAULT false,   -- afecta a todo el territorio del cliente
  es_escenario       boolean NOT NULL DEFAULT false,
  fuente_oficial     boolean NOT NULL DEFAULT false,
  enlace_oficial     text,
  estado             vigilante.estado_senal NOT NULL DEFAULT 'detectada',
  requiere_revision  boolean NOT NULL DEFAULT false,
  motivo_revision    text,
  fecha_evento_inicio timestamptz,
  fecha_evento_fin   timestamptz,
  plazo_hasta        timestamptz,
  modelo             text,
  salida_modelo      jsonb,
  contexto_vigilante jsonb,                            -- lo que devolvió el MCP del Vigilante (macrotema, antecedentes)
  duplicado_de       bigint REFERENCES vigilante.signals(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  busqueda           tsvector GENERATED ALWAYS AS (
                       to_tsvector('spanish', titulo || ' ' || resumen)) STORED,
  FOREIGN KEY (cliente_id, categoria) REFERENCES vigilante.categorias(cliente_id, codigo) ON UPDATE CASCADE,
  CONSTRAINT signals_fechas_evento CHECK (fecha_evento_fin IS NULL OR fecha_evento_inicio IS NULL
                                          OR fecha_evento_fin >= fecha_evento_inicio)
);
CREATE INDEX signals_estado_idx     ON vigilante.signals (cliente_id, estado, prioridad DESC, created_at DESC);
CREATE INDEX signals_categoria_idx  ON vigilante.signals (cliente_id, categoria, created_at DESC);
CREATE INDEX signals_plazo_idx      ON vigilante.signals (plazo_hasta) WHERE plazo_hasta IS NOT NULL;
CREATE INDEX signals_evento_idx     ON vigilante.signals (fecha_evento_inicio) WHERE fecha_evento_inicio IS NOT NULL;
CREATE INDEX signals_raw_item_idx   ON vigilante.signals (raw_item_id);
CREATE INDEX signals_busqueda_idx   ON vigilante.signals USING gin (busqueda);

CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('sources', 'source_id', 'integer');

CREATE TABLE vigilante.signal_raw_items (
  signal_id   bigint REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  raw_item_id bigint REFERENCES vigilante.raw_items(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL,
  PRIMARY KEY (signal_id, raw_item_id)
);
CREATE INDEX signal_raw_items_raw_idx ON vigilante.signal_raw_items (raw_item_id);
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.signal_raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');
CREATE TRIGGER b_heredar_cliente_raw BEFORE INSERT ON vigilante.signal_raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('raw_items', 'raw_item_id', 'bigint');

CREATE TABLE vigilante.signal_territorios (
  signal_id     bigint REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id    uuid NOT NULL,
  territorio_id integer NOT NULL,
  PRIMARY KEY (signal_id, territorio_id),
  FOREIGN KEY (cliente_id, territorio_id) REFERENCES vigilante.territorios(cliente_id, id) ON DELETE CASCADE
);
CREATE INDEX signal_territorios_ter_idx ON vigilante.signal_territorios (territorio_id);
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.signal_territorios
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');

CREATE TABLE vigilante.signal_history (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id        bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id       uuid NOT NULL,
  entidad          text NOT NULL CHECK (entidad IN ('signal', 'alert')),
  estado_anterior  vigilante.estado_senal,
  estado_nuevo     vigilante.estado_senal,
  cambios          jsonb NOT NULL DEFAULT '{}',
  actor            text NOT NULL DEFAULT vigilante.actor_actual(),
  nota             text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX signal_history_signal_idx ON vigilante.signal_history (signal_id, created_at);
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.signal_history
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');

CREATE FUNCTION vigilante.jsonb_diff(p_antes jsonb, p_despues jsonb, p_ignorar text[] DEFAULT '{updated_at,busqueda}')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, jsonb_build_object('antes', p_antes -> k, 'despues', p_despues -> k)), '{}')
  FROM jsonb_object_keys(p_despues) AS k
  WHERE k <> ALL (p_ignorar) AND (p_antes -> k) IS DISTINCT FROM (p_despues -> k)
$$;

CREATE FUNCTION vigilante.transicion_valida(p_de vigilante.estado_senal, p_a vigilante.estado_senal)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_de = p_a OR p_a = 'descartada' OR (p_de, p_a) IN (
    ('detectada',       'en_analisis'),
    ('en_analisis',     'en_verificacion'),
    ('en_analisis',     'confirmada'),
    ('en_verificacion', 'confirmada'),
    ('en_verificacion', 'publicada'),
    ('confirmada',      'publicada'),
    ('publicada',       'en_verificacion'),
    ('publicada',       'cerrada'),
    ('confirmada',      'cerrada')
  )
$$;

CREATE FUNCTION vigilante.tg_signals_reglas() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_cat_obligatoria boolean;
  v_tipo_fuente     vigilante.tipo_fuente;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.cliente_id <> OLD.cliente_id THEN
    RAISE EXCEPTION 'No se puede mover una señal de cliente' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' AND NOT vigilante.transicion_valida(OLD.estado, NEW.estado) THEN
    RAISE EXCEPTION 'Transición de estado no permitida: % → % (señal %)', OLD.estado, NEW.estado, OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT revision_obligatoria INTO v_cat_obligatoria
    FROM vigilante.categorias WHERE cliente_id = NEW.cliente_id AND codigo = NEW.categoria;
  SELECT tipo INTO v_tipo_fuente FROM vigilante.sources WHERE id = NEW.source_id;

  IF TG_OP = 'INSERT' THEN
    NEW.fuente_oficial := coalesce(v_tipo_fuente IN ('oficial', 'organismo_internacional'), NEW.fuente_oficial);
  END IF;

  IF coalesce(v_cat_obligatoria, false) OR NOT NEW.fuente_oficial OR NEW.es_escenario THEN
    NEW.requiere_revision := true;
    NEW.motivo_revision := coalesce(NEW.motivo_revision,
      CASE WHEN v_cat_obligatoria THEN 'categoria_' || NEW.categoria
           WHEN NOT NEW.fuente_oficial THEN 'fuente_no_oficial'
           ELSE 'escenario' END);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER signals_reglas BEFORE INSERT OR UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_signals_reglas();
CREATE TRIGGER signals_updated_at BEFORE UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();

CREATE FUNCTION vigilante.tg_signals_historial() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cambios jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO vigilante.signal_history (signal_id, cliente_id, entidad, estado_nuevo, nota)
    VALUES (NEW.id, NEW.cliente_id, 'signal', NEW.estado, 'creada');
  ELSE
    v_cambios := vigilante.jsonb_diff(to_jsonb(OLD), to_jsonb(NEW));
    IF v_cambios <> '{}' THEN
      INSERT INTO vigilante.signal_history (signal_id, cliente_id, entidad, estado_anterior, estado_nuevo, cambios)
      VALUES (NEW.id, NEW.cliente_id, 'signal', OLD.estado, NEW.estado, v_cambios);
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER signals_historial AFTER INSERT OR UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_signals_historial();

-- -----------------------------------------------------------------------------
-- 8. Revisión humana (SLA y guardia por cliente)
-- -----------------------------------------------------------------------------
CREATE FUNCTION vigilante.calcular_vencimiento(p_cliente uuid, p_desde timestamptz DEFAULT now())
RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tz     text     := coalesce((SELECT zona_horaria FROM vigilante.clientes WHERE id = p_cliente), 'UTC');
  v_sla    interval := make_interval(mins => coalesce((vigilante.param(p_cliente, 'sla_revision_minutos') #>> '{}')::int, 15));
  v_ini    time     := coalesce((vigilante.param(p_cliente, 'guardia_inicio') #>> '{}')::time, '07:00');
  v_fin    time     := coalesce((vigilante.param(p_cliente, 'guardia_fin') #>> '{}')::time, '22:00');
  v_local  timestamp := p_desde AT TIME ZONE v_tz;
  v_inicio timestamp;
BEGIN
  IF v_local::time >= v_ini AND v_local::time < v_fin THEN
    RETURN p_desde + v_sla;
  END IF;
  v_inicio := CASE WHEN v_local::time < v_ini THEN v_local::date + v_ini
                   ELSE (v_local::date + 1) + v_ini END;
  RETURN (v_inicio AT TIME ZONE v_tz) + v_sla;
END $$;

CREATE TABLE vigilante.reviews (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id      bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id     uuid NOT NULL,
  motivo         text,
  analista_id    uuid REFERENCES vigilante.users(id),
  solicitado_en  timestamptz NOT NULL DEFAULT now(),
  vence_en       timestamptz NOT NULL,                  -- lo calcula el trigger con la guardia del cliente
  decision       vigilante.decision_revision NOT NULL DEFAULT 'pendiente',
  decidido_en    timestamptz,
  comentario     text,
  cambios        jsonb,
  mensaje_tarjeta_id text,
  CONSTRAINT reviews_decision_coherente CHECK ((decision = 'pendiente') = (decidido_en IS NULL))
);
CREATE UNIQUE INDEX reviews_una_pendiente ON vigilante.reviews (signal_id) WHERE decision = 'pendiente';
CREATE INDEX reviews_vencimiento_idx ON vigilante.reviews (vence_en) WHERE decision = 'pendiente';

CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.reviews
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');

CREATE FUNCTION vigilante.tg_reviews_vencimiento() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.vence_en IS NULL THEN
    NEW.vence_en := vigilante.calcular_vencimiento(NEW.cliente_id, NEW.solicitado_en);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER b_vencimiento BEFORE INSERT ON vigilante.reviews
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_reviews_vencimiento();

-- -----------------------------------------------------------------------------
-- 9. Alertas publicadas
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.alerts (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id            bigint NOT NULL UNIQUE REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id           uuid NOT NULL,
  titulo               text NOT NULL,
  texto                text NOT NULL,
  recomendacion        text,
  enlace_fuente        text,
  estado_verificacion  vigilante.estado_verificacion NOT NULL DEFAULT 'confirmada',
  visibilidad          vigilante.visibilidad NOT NULL DEFAULT 'publica',
  es_escenario         boolean NOT NULL DEFAULT false,
  aprobada_por         uuid REFERENCES vigilante.users(id),
  aprobada_en          timestamptz,
  publicada_en         timestamptz,
  vigente_hasta        timestamptz,
  cerrada_en           timestamptz,
  version              integer NOT NULL DEFAULT 1,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT alerts_aprobacion CHECK ((aprobada_por IS NULL) = (aprobada_en IS NULL)),
  CONSTRAINT alerts_en_verificacion_con_enlace CHECK (estado_verificacion = 'confirmada' OR enlace_fuente IS NOT NULL)
);
CREATE INDEX alerts_publicas_idx ON vigilante.alerts (cliente_id, publicada_en DESC)
  WHERE visibilidad = 'publica' AND publicada_en IS NOT NULL AND cerrada_en IS NULL;

CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.alerts
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');

CREATE FUNCTION vigilante.tg_alerts_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.titulo, NEW.texto, NEW.recomendacion, NEW.estado_verificacion)
     IS DISTINCT FROM (OLD.titulo, OLD.texto, OLD.recomendacion, OLD.estado_verificacion) THEN
    NEW.version := OLD.version + 1;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE FUNCTION vigilante.tg_alerts_historial() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cambios jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_cambios := jsonb_build_object('alerta_id', NEW.id, 'version', NEW.version,
                                    'estado_verificacion', NEW.estado_verificacion);
  ELSE
    v_cambios := vigilante.jsonb_diff(to_jsonb(OLD), to_jsonb(NEW));
  END IF;
  IF v_cambios <> '{}' THEN
    INSERT INTO vigilante.signal_history (signal_id, cliente_id, entidad, cambios, nota)
    VALUES (NEW.signal_id, NEW.cliente_id, 'alert', v_cambios, CASE WHEN TG_OP = 'INSERT' THEN 'alerta creada' END);
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER alerts_version BEFORE UPDATE ON vigilante.alerts
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_alerts_version();
CREATE TRIGGER alerts_historial AFTER INSERT OR UPDATE ON vigilante.alerts
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_alerts_historial();

-- -----------------------------------------------------------------------------
-- 10. Resumen diario
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.daily_digests (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id   uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  fecha        date NOT NULL,                           -- fecha local del cliente
  texto        text,
  sin_alertas  boolean NOT NULL DEFAULT false,
  generado_en  timestamptz NOT NULL DEFAULT now(),
  publicado_en timestamptz,
  UNIQUE (cliente_id, fecha)
);

CREATE TABLE vigilante.daily_digest_items (
  digest_id  bigint REFERENCES vigilante.daily_digests(id) ON DELETE CASCADE,
  cliente_id uuid NOT NULL,
  orden      smallint NOT NULL CHECK (orden BETWEEN 1 AND 20),   -- el máximo real lo fija el parámetro resumen_max_alertas
  alert_id   bigint NOT NULL REFERENCES vigilante.alerts(id) ON DELETE CASCADE,
  PRIMARY KEY (digest_id, orden),
  UNIQUE (digest_id, alert_id)
);
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.daily_digest_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('daily_digests', 'digest_id', 'bigint');
CREATE TRIGGER b_heredar_cliente_alerta BEFORE INSERT ON vigilante.daily_digest_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('alerts', 'alert_id', 'bigint');

-- -----------------------------------------------------------------------------
-- 11. Recordatorios
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.follow_ups (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id        bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id       uuid NOT NULL,
  tipo             vigilante.tipo_seguimiento NOT NULL,
  fecha_objetivo   timestamptz NOT NULL,
  dias_antes       smallint NOT NULL CHECK (dias_antes >= 0),
  programado_para  timestamptz NOT NULL,
  enviado_en       timestamptz,
  cancelado        boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signal_id, tipo, dias_antes)
);
CREATE INDEX follow_ups_pendientes_idx ON vigilante.follow_ups (programado_para)
  WHERE enviado_en IS NULL AND NOT cancelado;
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.follow_ups
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('signals', 'signal_id', 'bigint');

CREATE FUNCTION vigilante.programar_recordatorios(p_signal_id bigint) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  s       vigilante.signals;
  v_dias  int;
  v_n     int := 0;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal_id;
  IF s.plazo_hasta IS NOT NULL THEN
    FOR v_dias IN SELECT jsonb_array_elements_text(coalesce(vigilante.param(s.cliente_id, 'recordatorios_convocatoria_dias'), '[30,15,5]'))::int LOOP
      IF s.plazo_hasta - make_interval(days => v_dias) > now() THEN
        INSERT INTO vigilante.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
        VALUES (s.id, 'plazo_convocatoria', s.plazo_hasta, v_dias, s.plazo_hasta - make_interval(days => v_dias))
        ON CONFLICT DO NOTHING;
        v_n := v_n + 1;
      END IF;
    END LOOP;
  END IF;
  IF s.fecha_evento_inicio IS NOT NULL THEN
    FOR v_dias IN SELECT jsonb_array_elements_text(coalesce(vigilante.param(s.cliente_id, 'recordatorios_evento_dias'), '[90,60,30]'))::int LOOP
      IF s.fecha_evento_inicio - make_interval(days => v_dias) > now() THEN
        INSERT INTO vigilante.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
        VALUES (s.id, 'evento', s.fecha_evento_inicio, v_dias, s.fecha_evento_inicio - make_interval(days => v_dias))
        ON CONFLICT DO NOTHING;
        v_n := v_n + 1;
      END IF;
    END LOOP;
  END IF;
  RETURN v_n;
END $$;

-- -----------------------------------------------------------------------------
-- 12. Envíos
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.deliveries (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  user_id         uuid REFERENCES vigilante.users(id) ON DELETE SET NULL,
  canal           vigilante.canal NOT NULL,
  alert_id        bigint REFERENCES vigilante.alerts(id) ON DELETE CASCADE,
  digest_id       bigint REFERENCES vigilante.daily_digests(id) ON DELETE CASCADE,
  follow_up_id    bigint REFERENCES vigilante.follow_ups(id) ON DELETE CASCADE,
  alert_version   integer,
  estado          vigilante.estado_envio NOT NULL DEFAULT 'pendiente',
  plantilla       text,
  mensaje_externo_id text,
  error           text,
  costo_usd       numeric(8,4) NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  enviado_en      timestamptz,
  CONSTRAINT deliveries_un_objeto CHECK (num_nonnulls(alert_id, digest_id, follow_up_id) = 1)
);
CREATE UNIQUE INDEX deliveries_alerta_unica  ON vigilante.deliveries (alert_id, alert_version, user_id, canal) NULLS NOT DISTINCT
  WHERE alert_id IS NOT NULL;
CREATE UNIQUE INDEX deliveries_resumen_unico ON vigilante.deliveries (digest_id, user_id, canal) NULLS NOT DISTINCT
  WHERE digest_id IS NOT NULL;
CREATE UNIQUE INDEX deliveries_recordatorio_unico ON vigilante.deliveries (follow_up_id, user_id, canal) NULLS NOT DISTINCT
  WHERE follow_up_id IS NOT NULL;
CREATE INDEX deliveries_pendientes_idx ON vigilante.deliveries (created_at) WHERE estado = 'pendiente';
CREATE INDEX deliveries_user_idx ON vigilante.deliveries (user_id, created_at DESC);

CREATE TRIGGER a_heredar_cliente_alerta BEFORE INSERT ON vigilante.deliveries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('alerts', 'alert_id', 'bigint');
CREATE TRIGGER a_heredar_cliente_resumen BEFORE INSERT ON vigilante.deliveries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('daily_digests', 'digest_id', 'bigint');
CREATE TRIGGER a_heredar_cliente_seguimiento BEFORE INSERT ON vigilante.deliveries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('follow_ups', 'follow_up_id', 'bigint');
CREATE TRIGGER a_heredar_cliente_usuario BEFORE INSERT ON vigilante.deliveries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');

CREATE FUNCTION vigilante.tg_deliveries_whatsapp() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.canal = 'whatsapp' AND NEW.alert_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM vigilante.alerts WHERE id = NEW.alert_id AND aprobada_por IS NOT NULL) THEN
    RAISE EXCEPTION 'La alerta % no está aprobada por un analista: no puede enviarse por WhatsApp', NEW.alert_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.alert_id IS NOT NULL AND NEW.alert_version IS NULL THEN
    SELECT version INTO NEW.alert_version FROM vigilante.alerts WHERE id = NEW.alert_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER deliveries_whatsapp BEFORE INSERT ON vigilante.deliveries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_deliveries_whatsapp();

-- -----------------------------------------------------------------------------
-- 13. Feedback útil / no útil
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.feedback (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  alert_id    bigint NOT NULL REFERENCES vigilante.alerts(id) ON DELETE CASCADE,
  cliente_id  uuid NOT NULL,
  user_id     uuid REFERENCES vigilante.users(id) ON DELETE SET NULL,
  canal       vigilante.canal NOT NULL,
  util        boolean NOT NULL,
  comentario  text,
  visitante_hash text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT feedback_identificado CHECK (user_id IS NOT NULL OR visitante_hash IS NOT NULL)
);
CREATE UNIQUE INDEX feedback_un_voto_usuario   ON vigilante.feedback (alert_id, user_id)        WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX feedback_un_voto_visitante ON vigilante.feedback (alert_id, visitante_hash) WHERE user_id IS NULL;
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.feedback
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('alerts', 'alert_id', 'bigint');
CREATE TRIGGER b_heredar_cliente_usuario BEFORE INSERT ON vigilante.feedback
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');

-- -----------------------------------------------------------------------------
-- 14. Chat, logs y auditoría
-- -----------------------------------------------------------------------------
CREATE TABLE vigilante.chat_queries (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id   uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  user_id      uuid REFERENCES vigilante.users(id) ON DELETE SET NULL,
  canal        vigilante.canal NOT NULL,
  remitente    text,
  comando      text,
  texto        text NOT NULL,
  resultados   integer,
  respuesta    text,
  costo_usd    numeric(10,6),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_queries_fecha_idx ON vigilante.chat_queries (cliente_id, created_at DESC);
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.chat_queries
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');

CREATE TABLE vigilante.system_logs (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id   uuid REFERENCES vigilante.clientes(id) ON DELETE CASCADE,   -- NULL = plataforma
  nivel        vigilante.nivel_log NOT NULL DEFAULT 'info',
  proceso      text,                                   -- script de búsqueda, skill de Hermes, workflow...
  paso         text,
  ejecucion_id text,
  source_id    integer REFERENCES vigilante.sources(id) ON DELETE SET NULL,
  mensaje      text NOT NULL,
  detalle      jsonb,
  costo_usd    numeric(10,6),                          -- tokens de IA, Apify, etc.
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX system_logs_fecha_idx   ON vigilante.system_logs (created_at DESC);
CREATE INDEX system_logs_errores_idx ON vigilante.system_logs (created_at DESC) WHERE nivel IN ('warn', 'error');

CREATE TABLE vigilante.audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id  uuid,
  tabla       text NOT NULL,
  registro_id text NOT NULL,
  accion      text NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
  antes       jsonb,
  despues     jsonb,
  actor       text NOT NULL DEFAULT vigilante.actor_actual(),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_registro_idx ON vigilante.audit_log (tabla, registro_id, created_at);
CREATE INDEX audit_log_cliente_idx  ON vigilante.audit_log (cliente_id, created_at DESC);

CREATE FUNCTION vigilante.tg_auditar() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_fila jsonb := to_jsonb(coalesce(NEW, OLD));
BEGIN
  INSERT INTO vigilante.audit_log (cliente_id, tabla, registro_id, accion, antes, despues)
  VALUES (CASE WHEN TG_TABLE_NAME = 'clientes' THEN (v_fila ->> 'id')::uuid ELSE (v_fila ->> 'cliente_id')::uuid END,
          TG_TABLE_NAME,
          coalesce(v_fila ->> 'id', v_fila ->> 'codigo', v_fila ->> 'user_id', '?'), TG_OP,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

CREATE TRIGGER auditar_clientes    AFTER INSERT OR UPDATE OR DELETE ON vigilante.clientes    FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_users       AFTER INSERT OR UPDATE OR DELETE ON vigilante.users       FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_sources     AFTER INSERT OR UPDATE OR DELETE ON vigilante.sources     FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_parametros  AFTER INSERT OR UPDATE OR DELETE ON vigilante.parametros  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_categorias  AFTER INSERT OR UPDATE OR DELETE ON vigilante.categorias  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_territorios AFTER INSERT OR UPDATE OR DELETE ON vigilante.territorios FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();
CREATE TRIGGER auditar_reviews     AFTER UPDATE ON vigilante.reviews FOR EACH ROW EXECUTE FUNCTION vigilante.tg_auditar();

CREATE TRIGGER clientes_updated_at    BEFORE UPDATE ON vigilante.clientes         FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
CREATE TRIGGER users_updated_at       BEFORE UPDATE ON vigilante.users            FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
CREATE TRIGGER sources_updated_at     BEFORE UPDATE ON vigilante.sources          FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
CREATE TRIGGER parametros_updated_at  BEFORE UPDATE ON vigilante.parametros       FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();
CREATE TRIGGER preferences_updated_at BEFORE UPDATE ON vigilante.user_preferences FOR EACH ROW EXECUTE FUNCTION vigilante.tg_set_updated_at();

-- Tablas hijas de users: heredan el cliente del usuario
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.user_preferences
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.user_categorias
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');
CREATE TRIGGER a_heredar_cliente BEFORE INSERT ON vigilante.user_territorios
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_heredar_cliente('users', 'user_id', 'uuid');

-- -----------------------------------------------------------------------------
-- 15. Funciones de negocio (las llaman Hermes, el script de búsqueda o n8n)
-- -----------------------------------------------------------------------------
CREATE FUNCTION vigilante.solicitar_revision(p_signal_id bigint, p_motivo text DEFAULT NULL)
RETURNS vigilante.reviews LANGUAGE plpgsql AS $$
DECLARE r vigilante.reviews;
BEGIN
  UPDATE vigilante.signals SET estado = 'en_verificacion'
   WHERE id = p_signal_id AND estado IN ('detectada', 'en_analisis', 'publicada');
  INSERT INTO vigilante.reviews (signal_id, motivo)
  VALUES (p_signal_id, coalesce(p_motivo, (SELECT motivo_revision FROM vigilante.signals WHERE id = p_signal_id)))
  ON CONFLICT (signal_id) WHERE decision = 'pendiente' DO UPDATE SET motivo = EXCLUDED.motivo
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE FUNCTION vigilante.decidir_revision(p_review_id bigint, p_analista uuid,
                                           p_decision vigilante.decision_revision, p_comentario text DEFAULT NULL)
RETURNS vigilante.reviews LANGUAGE plpgsql AS $$
DECLARE r vigilante.reviews;
BEGIN
  IF p_decision IN ('pendiente', 'vencida') THEN
    RAISE EXCEPTION 'Decisión no válida para un analista: %', p_decision;
  END IF;
  -- el analista debe ser del mismo cliente que la revisión
  IF NOT EXISTS (SELECT 1 FROM vigilante.users u JOIN vigilante.reviews rv ON rv.cliente_id = u.cliente_id
                  WHERE u.id = p_analista AND rv.id = p_review_id
                    AND u.rol IN ('analista', 'administrador') AND u.activo) THEN
    RAISE EXCEPTION 'El usuario % no puede aprobar la revisión %', p_analista, p_review_id;
  END IF;

  UPDATE vigilante.reviews
     SET decision = p_decision, analista_id = p_analista, decidido_en = now(), comentario = p_comentario
   WHERE id = p_review_id AND decision IN ('pendiente', 'vencida')
  RETURNING * INTO r;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'La revisión % no existe o ya fue decidida', p_review_id;
  END IF;

  IF p_decision IN ('aprobada', 'editada') THEN
    UPDATE vigilante.signals SET estado = 'confirmada' WHERE id = r.signal_id AND estado = 'en_verificacion';
    UPDATE vigilante.alerts SET aprobada_por = p_analista, aprobada_en = now(), estado_verificacion = 'confirmada'
     WHERE signal_id = r.signal_id;
  ELSE
    UPDATE vigilante.signals SET estado = 'descartada' WHERE id = r.signal_id;
    UPDATE vigilante.alerts SET cerrada_en = now() WHERE signal_id = r.signal_id AND cerrada_en IS NULL;
  END IF;
  RETURN r;
END $$;

CREATE FUNCTION vigilante.vencer_revisiones()
RETURNS TABLE (cliente_id uuid, review_id bigint, signal_id bigint, accion text)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  WITH vencidas AS (
    UPDATE vigilante.reviews rv
       SET decision = 'vencida', decidido_en = now()
     WHERE rv.decision = 'pendiente' AND rv.vence_en <= now()
    RETURNING rv.id, rv.signal_id, rv.cliente_id
  )
  SELECT v.cliente_id, v.id, v.signal_id,
         CASE WHEN s.fuente_oficial AND s.enlace_oficial IS NOT NULL AND NOT s.es_escenario
              THEN 'publicar_en_verificacion' ELSE 'escalar_al_administrador' END
    FROM vencidas v JOIN vigilante.signals s ON s.id = v.signal_id;
END $$;

CREATE FUNCTION vigilante.destinatarios_alerta(p_alert_id bigint, p_canal vigilante.canal)
RETURNS TABLE (user_id uuid, nombre text, telegram_chat_id bigint, telefono_whatsapp text, email text)
LANGUAGE sql STABLE AS $$
  SELECT u.id, u.nombre, u.telegram_chat_id, u.telefono_whatsapp, u.email
    FROM vigilante.alerts a
    JOIN vigilante.signals s ON s.id = a.signal_id
    JOIN vigilante.users u ON u.activo AND u.cliente_id = a.cliente_id
    LEFT JOIN vigilante.user_preferences p ON p.user_id = u.id
   WHERE a.id = p_alert_id
     AND a.cerrada_en IS NULL
     AND p_canal = ANY (coalesce(p.canales, '{telegram}'))
     AND s.prioridad >= coalesce(p.prioridad_minima, 'media')
     AND s.naturaleza = ANY (coalesce(p.naturalezas, '{riesgo,oportunidad,mixta}'))
     AND (NOT s.es_escenario OR u.rol IN ('administrador', 'analista'))
     AND (a.visibilidad = 'publica' OR u.rol IN ('administrador', 'analista'))
     AND (NOT EXISTS (SELECT 1 FROM vigilante.user_categorias uc WHERE uc.user_id = u.id)
          OR EXISTS (SELECT 1 FROM vigilante.user_categorias uc WHERE uc.user_id = u.id AND uc.categoria = s.categoria))
     AND (s.alcance_total
          OR NOT EXISTS (SELECT 1 FROM vigilante.user_territorios ut WHERE ut.user_id = u.id)
          OR EXISTS (SELECT 1 FROM vigilante.user_territorios ut
                       JOIN vigilante.signal_territorios st ON st.territorio_id = ut.territorio_id
                      WHERE ut.user_id = u.id AND st.signal_id = s.id))
     AND (p_canal <> 'telegram' OR u.telegram_chat_id IS NOT NULL)
     AND (p_canal <> 'whatsapp' OR (u.telefono_whatsapp IS NOT NULL AND a.aprobada_por IS NOT NULL))
     AND (p_canal <> 'email' OR u.email IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM vigilante.deliveries d
                      WHERE d.alert_id = a.id AND d.alert_version = a.version
                        AND d.user_id = u.id AND d.canal = p_canal AND d.estado <> 'fallido')
$$;

-- Resumen diario de un cliente: alertas públicas de las últimas 24 h, máx. resumen_max_alertas
CREATE FUNCTION vigilante.generar_resumen_diario(p_cliente uuid, p_fecha date DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_id    bigint;
  v_tz    text := coalesce((SELECT zona_horaria FROM vigilante.clientes WHERE id = p_cliente), 'UTC');
  v_fecha date := coalesce(p_fecha, (now() AT TIME ZONE v_tz)::date);
  v_max   int  := least(coalesce((vigilante.param(p_cliente, 'resumen_max_alertas') #>> '{}')::int, 7), 20);
  v_n     int;
BEGIN
  INSERT INTO vigilante.daily_digests (cliente_id, fecha) VALUES (p_cliente, v_fecha)
  ON CONFLICT (cliente_id, fecha) DO UPDATE SET generado_en = now()
  RETURNING id INTO v_id;

  DELETE FROM vigilante.daily_digest_items WHERE digest_id = v_id;

  INSERT INTO vigilante.daily_digest_items (digest_id, orden, alert_id)
  SELECT v_id, row_number() OVER (ORDER BY s.prioridad DESC, s.puntaje DESC NULLS LAST, a.publicada_en DESC), a.id
    FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id
   WHERE a.cliente_id = p_cliente
     AND a.visibilidad = 'publica' AND NOT a.es_escenario AND a.cerrada_en IS NULL
     AND a.publicada_en >= now() - interval '24 hours'
   ORDER BY s.prioridad DESC, s.puntaje DESC NULLS LAST, a.publicada_en DESC
   LIMIT v_max;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE vigilante.daily_digests
     SET sin_alertas = (v_n = 0),
         texto = CASE WHEN v_n = 0 THEN coalesce(vigilante.param(p_cliente, 'mensaje_sin_alertas') #>> '{}',
                                                 'No hay alertas confirmadas en este momento') ELSE texto END
   WHERE id = v_id;
  RETURN v_id;
END $$;

-- Retención por cliente (parámetro retencion_meses). Ejecutar a diario.
CREATE FUNCTION vigilante.purgar_retencion()
RETURNS TABLE (tabla text, borrados bigint)
LANGUAGE plpgsql AS $$
DECLARE v_n bigint;
BEGIN
  DELETE FROM vigilante.signals s
   WHERE s.estado IN ('cerrada', 'descartada')
     AND s.updated_at < now() - make_interval(months => coalesce((vigilante.param(s.cliente_id, 'retencion_meses') #>> '{}')::int, 6));
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'signals'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.raw_items r
   WHERE r.recolectado_en < now() - make_interval(months => coalesce((vigilante.param(r.cliente_id, 'retencion_meses') #>> '{}')::int, 6))
     AND NOT EXISTS (SELECT 1 FROM vigilante.signals s WHERE s.raw_item_id = r.id);
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'raw_items'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.daily_digests d
   WHERE d.generado_en < now() - make_interval(months => coalesce((vigilante.param(d.cliente_id, 'retencion_meses') #>> '{}')::int, 6));
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'daily_digests'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.chat_queries c
   WHERE c.created_at < now() - make_interval(months => coalesce((vigilante.param(c.cliente_id, 'retencion_meses') #>> '{}')::int, 6));
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'chat_queries'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.system_logs l
   WHERE l.created_at < now() - make_interval(months => coalesce((vigilante.param(l.cliente_id, 'retencion_meses') #>> '{}')::int, 6));
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'system_logs'; borrados := v_n; RETURN NEXT;

  DELETE FROM vigilante.audit_log a
   WHERE a.created_at < now() - make_interval(months => coalesce((vigilante.param(a.cliente_id, 'retencion_meses') #>> '{}')::int, 6));
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'audit_log'; borrados := v_n; RETURN NEXT;
END $$;

-- Alta de un vigilante nuevo. Si se indica p_plantilla (slug de otro cliente), copia sus
-- categorías y parámetros; los territorios solo si es del mismo país. Las fuentes y los
-- usuarios se configuran después, porque dependen de cada cliente.
CREATE FUNCTION vigilante.alta_cliente(p_slug text, p_nombre text, p_sector text, p_pais text,
                                       p_zona_horaria text, p_plantilla text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_id      uuid;
  v_origen  vigilante.clientes;
BEGIN
  INSERT INTO vigilante.clientes (slug, nombre, sector, pais, zona_horaria)
  VALUES (p_slug, p_nombre, p_sector, p_pais, p_zona_horaria)
  RETURNING id INTO v_id;

  IF p_plantilla IS NOT NULL THEN
    SELECT * INTO v_origen FROM vigilante.clientes WHERE slug = p_plantilla;
    IF v_origen.id IS NULL THEN
      RAISE EXCEPTION 'No existe el cliente plantilla %', p_plantilla;
    END IF;

    INSERT INTO vigilante.categorias (cliente_id, codigo, nombre, descripcion, revision_obligatoria, orden, activa)
    SELECT v_id, codigo, nombre, descripcion, revision_obligatoria, orden, activa
      FROM vigilante.categorias WHERE cliente_id = v_origen.id;

    INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
    SELECT v_id, clave, valor, descripcion
      FROM vigilante.parametros WHERE cliente_id = v_origen.id;

    UPDATE vigilante.clientes SET perfil = v_origen.perfil WHERE id = v_id;

    IF v_origen.pais IS NOT DISTINCT FROM p_pais THEN
      INSERT INTO vigilante.territorios (cliente_id, codigo, nombre, nivel, datos)
      SELECT v_id, codigo, nombre, nivel, datos
        FROM vigilante.territorios WHERE cliente_id = v_origen.id;
      -- reconstruye la jerarquía por código
      UPDATE vigilante.territorios t
         SET padre_id = tn.id
        FROM vigilante.territorios o
        JOIN vigilante.territorios op ON op.id = o.padre_id
        JOIN vigilante.territorios tn ON tn.cliente_id = v_id AND tn.codigo = op.codigo
       WHERE t.cliente_id = v_id AND o.cliente_id = v_origen.id AND o.codigo = t.codigo;
    END IF;
  END IF;
  RETURN v_id;
END $$;

-- -----------------------------------------------------------------------------
-- 16. Vistas
-- -----------------------------------------------------------------------------

-- Web pública: la web de cada cliente filtra por cliente_slug.
CREATE VIEW vigilante.v_alertas_publicas WITH (security_barrier) AS
SELECT a.id,
       cl.slug AS cliente_slug,
       a.cliente_id,
       a.titulo,
       a.texto,
       a.recomendacion,
       a.enlace_fuente,
       a.estado_verificacion,
       CASE a.estado_verificacion WHEN 'en_verificacion' THEN 'En verificación' ELSE 'Confirmada' END AS etiqueta_verificacion,
       s.naturaleza,
       s.categoria,
       c.nombre AS categoria_nombre,
       s.prioridad,
       s.alcance_total,
       coalesce(array_agg(t.nombre ORDER BY t.nombre) FILTER (WHERE t.id IS NOT NULL), '{}') AS territorios,
       coalesce(array_agg(t.id ORDER BY t.nombre)     FILTER (WHERE t.id IS NOT NULL), '{}') AS territorio_ids,
       s.fecha_evento_inicio,
       s.fecha_evento_fin,
       s.plazo_hasta,
       a.publicada_en,
       a.updated_at AS actualizada_en,
       a.version
  FROM vigilante.alerts a
  JOIN vigilante.clientes cl  ON cl.id = a.cliente_id AND cl.activo
  JOIN vigilante.signals s    ON s.id = a.signal_id
  JOIN vigilante.categorias c ON c.cliente_id = s.cliente_id AND c.codigo = s.categoria
  LEFT JOIN vigilante.signal_territorios st ON st.signal_id = s.id
  LEFT JOIN vigilante.territorios t         ON t.id = st.territorio_id
 WHERE a.visibilidad = 'publica'
   AND a.publicada_en IS NOT NULL
   AND a.cerrada_en IS NULL
   AND NOT a.es_escenario
   AND (a.vigente_hasta IS NULL OR a.vigente_hasta > now())
 GROUP BY a.id, cl.slug, s.id, c.nombre;

CREATE VIEW vigilante.v_cola_revision WITH (security_invoker = true) AS
SELECT r.cliente_id, r.id AS review_id, r.signal_id, s.titulo, s.categoria, s.naturaleza, s.prioridad,
       s.fuente_oficial, s.enlace_oficial, r.motivo, r.solicitado_en, r.vence_en,
       round(extract(epoch FROM (r.vence_en - now())) / 60)::int AS minutos_restantes
  FROM vigilante.reviews r JOIN vigilante.signals s ON s.id = r.signal_id
 WHERE r.decision = 'pendiente'
 ORDER BY r.vence_en;

CREATE VIEW vigilante.v_metricas_diarias WITH (security_invoker = true) AS
WITH dias AS (
  SELECT c.id AS cliente_id, generate_series((now() - interval '30 days')::date, now()::date, '1 day')::date AS dia
    FROM vigilante.clientes c
)
SELECT d.cliente_id, d.dia,
  (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = d.cliente_id AND r.recolectado_en::date = d.dia) AS documentos,
  (SELECT count(*) FROM vigilante.signals s WHERE s.cliente_id = d.cliente_id AND s.created_at::date = d.dia)       AS senales,
  (SELECT count(*) FROM vigilante.alerts a WHERE a.cliente_id = d.cliente_id AND a.publicada_en::date = d.dia)      AS alertas_publicadas,
  (SELECT count(*) FROM vigilante.reviews r WHERE r.cliente_id = d.cliente_id AND r.decidido_en::date = d.dia AND r.decision = 'vencida') AS revisiones_vencidas,
  (SELECT round(avg(extract(epoch FROM (r.decidido_en - r.solicitado_en)) / 60)::numeric, 1)
     FROM vigilante.reviews r WHERE r.cliente_id = d.cliente_id AND r.decidido_en::date = d.dia
      AND r.decision IN ('aprobada', 'editada', 'rechazada')) AS minutos_medios_revision,
  (SELECT count(*) FILTER (WHERE f.util) FROM vigilante.feedback f WHERE f.cliente_id = d.cliente_id AND f.created_at::date = d.dia)     AS feedback_util,
  (SELECT count(*) FILTER (WHERE NOT f.util) FROM vigilante.feedback f WHERE f.cliente_id = d.cliente_id AND f.created_at::date = d.dia) AS feedback_no_util,
  (SELECT coalesce(sum(l.costo_usd), 0) FROM vigilante.system_logs l WHERE l.cliente_id = d.cliente_id AND l.created_at::date = d.dia)
  + (SELECT coalesce(sum(q.costo_usd), 0) FROM vigilante.chat_queries q WHERE q.cliente_id = d.cliente_id AND q.created_at::date = d.dia)
  + (SELECT coalesce(sum(e.costo_usd), 0) FROM vigilante.deliveries e WHERE e.cliente_id = d.cliente_id AND e.created_at::date = d.dia) AS costo_usd
FROM dias d
ORDER BY d.cliente_id, d.dia DESC;

CREATE VIEW vigilante.v_estado_fuentes WITH (security_invoker = true) AS
SELECT s.cliente_id, s.id, s.codigo, s.nombre, s.activa, s.rapida, s.metodo, s.frecuencia_minutos,
       s.ultima_consulta_en, s.ultimo_exito_en, s.errores_seguidos,
       (SELECT count(*) FROM vigilante.raw_items r WHERE r.source_id = s.id AND r.recolectado_en > now() - interval '7 days') AS documentos_7d,
       CASE WHEN NOT s.activa THEN 'inactiva'
            WHEN s.errores_seguidos >= 3 THEN 'fallando'
            WHEN s.ultimo_exito_en IS NULL OR s.ultimo_exito_en < now() - make_interval(mins => s.frecuencia_minutos * 3) THEN 'atrasada'
            ELSE 'ok' END AS salud
  FROM vigilante.sources s;

-- Fuentes que tocan en el ciclo actual (la usa el script de búsqueda cada 30 min)
CREATE VIEW vigilante.v_fuentes_pendientes WITH (security_invoker = true) AS
SELECT s.*
  FROM vigilante.sources s JOIN vigilante.clientes c ON c.id = s.cliente_id AND c.activo
 WHERE s.activa
   AND (s.ultima_consulta_en IS NULL OR s.ultima_consulta_en <= now() - make_interval(mins => s.frecuencia_minutos));

-- -----------------------------------------------------------------------------
-- 17. Seguridad: permisos y RLS (cada usuario solo ve su cliente)
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA vigilante TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA vigilante TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA vigilante TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA vigilante TO service_role;

GRANT SELECT ON vigilante.v_alertas_publicas TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA vigilante TO authenticated;  -- filtrado por RLS
GRANT USAGE ON ALL SEQUENCES IN SCHEMA vigilante TO authenticated;
GRANT INSERT ON vigilante.feedback TO anon;
GRANT USAGE ON SEQUENCE vigilante.feedback_id_seq TO anon;

-- Funciones operativas: solo plataforma (service_role / postgres)
REVOKE EXECUTE ON FUNCTION vigilante.purgar_retencion(), vigilante.vencer_revisiones(),
                           vigilante.generar_resumen_diario(uuid, date),
                           vigilante.alta_cliente(text, text, text, text, text, text) FROM PUBLIC;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'vigilante' LOOP
    EXECUTE format('ALTER TABLE vigilante.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Clientes: cada usuario ve su propio cliente; el administrador puede editar su perfil
CREATE POLICY ve_su_cliente   ON vigilante.clientes FOR SELECT TO authenticated USING (id = vigilante.cliente_actual());
CREATE POLICY admin_edita     ON vigilante.clientes FOR UPDATE TO authenticated
  USING (id = vigilante.cliente_actual() AND vigilante.es_admin())
  WITH CHECK (id = vigilante.cliente_actual() AND vigilante.es_admin());

-- Catálogos del cliente: lectura para sus usuarios; escritura de su administrador
CREATE POLICY lectura_cliente ON vigilante.territorios FOR SELECT TO authenticated USING (cliente_id = vigilante.cliente_actual());
CREATE POLICY lectura_cliente ON vigilante.categorias  FOR SELECT TO authenticated USING (cliente_id = vigilante.cliente_actual());
CREATE POLICY admin_escribe   ON vigilante.territorios FOR ALL TO authenticated
  USING (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin())
  WITH CHECK (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin());
CREATE POLICY admin_escribe   ON vigilante.categorias  FOR ALL TO authenticated
  USING (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin())
  WITH CHECK (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin());

-- Parámetros: el personal lee los del cliente y los de la plataforma; el administrador edita los de su cliente
CREATE POLICY staff_lee     ON vigilante.parametros FOR SELECT TO authenticated
  USING (vigilante.es_staff() AND (cliente_id = vigilante.cliente_actual() OR cliente_id IS NULL));
CREATE POLICY admin_escribe ON vigilante.parametros FOR ALL TO authenticated
  USING (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin())
  WITH CHECK (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin());

-- Usuarios: cada persona ve su ficha; el personal ve los de su cliente; el administrador gestiona los de su cliente
CREATE POLICY ve_su_ficha   ON vigilante.users FOR SELECT TO authenticated
  USING (auth_user_id = auth.uid() OR (vigilante.es_staff() AND cliente_id = vigilante.cliente_actual()));
CREATE POLICY admin_escribe ON vigilante.users FOR ALL TO authenticated
  USING (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin())
  WITH CHECK (cliente_id = vigilante.cliente_actual() AND vigilante.es_admin());

-- Preferencias: cada usuario las suyas; el personal, las de su cliente
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['user_preferences', 'user_categorias', 'user_territorios'] LOOP
    EXECUTE format('CREATE POLICY propias ON vigilante.%I FOR ALL TO authenticated
      USING (user_id = vigilante.usuario_actual()
             OR (vigilante.es_staff() AND cliente_id = vigilante.cliente_actual()))
      WITH CHECK (cliente_id = vigilante.cliente_actual()
                  AND (user_id = vigilante.usuario_actual() OR vigilante.es_staff()))', t);
  END LOOP;
END $$;

-- Alertas: el visor ve las públicas publicadas de su cliente
CREATE POLICY visor_lee_publicas ON vigilante.alerts FOR SELECT TO authenticated
  USING (cliente_id = vigilante.cliente_actual()
         AND visibilidad = 'publica' AND publicada_en IS NOT NULL AND NOT es_escenario);

-- Feedback: cualquiera vota (anon con visitante_hash); el usuario ve sus votos
CREATE POLICY anon_vota ON vigilante.feedback FOR INSERT TO anon
  WITH CHECK (user_id IS NULL AND visitante_hash IS NOT NULL
              AND EXISTS (SELECT 1 FROM vigilante.v_alertas_publicas v WHERE v.id = alert_id));
CREATE POLICY usuario_vota ON vigilante.feedback FOR INSERT TO authenticated
  WITH CHECK (user_id = vigilante.usuario_actual() AND cliente_id = vigilante.cliente_actual());
CREATE POLICY usuario_ve_sus_votos ON vigilante.feedback FOR SELECT TO authenticated
  USING (user_id = vigilante.usuario_actual());

-- Envíos y consultas propias
CREATE POLICY usuario_ve_sus_envios ON vigilante.deliveries FOR SELECT TO authenticated
  USING (user_id = vigilante.usuario_actual());
CREATE POLICY usuario_ve_sus_consultas ON vigilante.chat_queries FOR SELECT TO authenticated
  USING (user_id = vigilante.usuario_actual());

-- Personal (administrador y analista): acceso completo a las tablas operativas de SU cliente
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sources', 'raw_items', 'signals', 'signal_raw_items', 'signal_territorios',
                           'signal_history', 'reviews', 'alerts', 'daily_digests', 'daily_digest_items',
                           'follow_ups', 'deliveries', 'feedback', 'chat_queries', 'system_logs'] LOOP
    EXECUTE format('CREATE POLICY staff_todo ON vigilante.%I FOR ALL TO authenticated
                    USING (vigilante.es_staff() AND cliente_id = vigilante.cliente_actual())
                    WITH CHECK (vigilante.es_staff() AND cliente_id = vigilante.cliente_actual())', t);
  END LOOP;
END $$;

-- Auditoría: el administrador lee la de su cliente
CREATE POLICY admin_lee ON vigilante.audit_log FOR SELECT TO authenticated
  USING (vigilante.es_admin() AND cliente_id = vigilante.cliente_actual());

-- -----------------------------------------------------------------------------
-- 18. Parámetros por defecto de la plataforma (cada cliente puede sobrescribirlos)
-- -----------------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'sla_revision_minutos',            '15',          'Minutos que tiene el analista para aprobar'),
  (NULL, 'guardia_inicio',                  '"07:00"',     'Inicio del horario de guardia (hora local del cliente)'),
  (NULL, 'guardia_fin',                     '"22:00"',     'Fin del horario de guardia'),
  (NULL, 'resumen_max_alertas',             '7',           'Máximo de alertas en el resumen diario (tope 20)'),
  (NULL, 'resumen_hora',                    '"08:00"',     'Hora local del resumen diario'),
  (NULL, 'retencion_meses',                 '6',           'Meses que se conservan los datos'),
  (NULL, 'ciclo_busqueda_minutos',          '30',          'Frecuencia del ciclo de búsqueda en fuentes rápidas'),
  (NULL, 'umbral_hermes',                   '60',          'Puntaje mínimo (0-100) para que Hermes analice a fondo una novedad'),
  (NULL, 'plazo_urgente_dias',              '15',          'Convocatoria con plazo menor a esto = prioridad alta'),
  (NULL, 'recordatorios_convocatoria_dias', '[30, 15, 5]', 'Recordatorios antes del cierre de una convocatoria'),
  (NULL, 'recordatorios_evento_dias',       '[90, 60, 30]','Recordatorios antes de un evento'),
  (NULL, 'escenarios_publicos',             'false',       'Predicciones visibles al público'),
  (NULL, 'mensaje_sin_alertas',             '"No hay alertas confirmadas en este momento"', 'Respuesta cuando no hay alertas');

COMMIT;
