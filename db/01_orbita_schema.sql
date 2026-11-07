-- =============================================================================
-- ORBITA · Sistema de alertas turísticas de Bolivia (beta 30 días)
-- Migración 01: esquema completo para PostgreSQL 15+ (compatible con Supabase)
--
-- Uso:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01_orbita_schema.sql
--   (en Supabase: pegar en SQL Editor y ejecutar, o `supabase db push`)
--
-- Todo vive en el esquema `orbita` para no mezclarse con AVIA u otros proyectos
-- en la misma instancia. En Supabase, para que la web lea por la API REST,
-- añade `orbita` en Settings → API → Exposed schemas.
--
-- n8n se conecta con un usuario que salta RLS (postgres o service_role).
-- Para que el historial registre quién hizo un cambio, n8n puede ejecutar
--   SET LOCAL orbita.actor = 'n8n:analisis-hermes';
-- dentro de la misma transacción.
--
-- La migración no es re-ejecutable: para empezar de cero,
--   DROP SCHEMA orbita CASCADE;
-- =============================================================================

BEGIN;

SET client_min_messages = warning;

-- -----------------------------------------------------------------------------
-- 0. Compatibilidad: en Supabase ya existen los roles anon/authenticated/
--    service_role y la función auth.uid(). En un Postgres propio se crean
--    equivalentes mínimos para que RLS funcione igual.
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
    -- Lee el "sub" del JWT igual que Supabase (PostgREST lo deja en request.jwt.claim.sub)
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

CREATE SCHEMA orbita;
COMMENT ON SCHEMA orbita IS 'ORBITA: vigilancia de oportunidades y riesgos para el turismo en Bolivia';

SET search_path = orbita, public;

-- -----------------------------------------------------------------------------
-- 1. Tipos
-- -----------------------------------------------------------------------------
CREATE TYPE orbita.rol_usuario        AS ENUM ('administrador', 'analista', 'visor');
CREATE TYPE orbita.naturaleza_senal   AS ENUM ('riesgo', 'oportunidad', 'mixta');
CREATE TYPE orbita.prioridad          AS ENUM ('baja', 'media', 'alta');   -- el orden permite comparar (>=)
CREATE TYPE orbita.estado_senal       AS ENUM ('detectada', 'en_analisis', 'en_verificacion',
                                               'confirmada', 'publicada', 'cerrada', 'descartada');
CREATE TYPE orbita.estado_raw         AS ENUM ('nuevo', 'en_cola', 'procesado', 'descartado', 'error');
CREATE TYPE orbita.metodo_fuente      AS ENUM ('rss', 'http_html', 'apify', 'tavily', 'api', 'manual');
CREATE TYPE orbita.tipo_fuente        AS ENUM ('oficial', 'organismo_internacional', 'medio', 'no_oficial');
CREATE TYPE orbita.decision_revision  AS ENUM ('pendiente', 'aprobada', 'editada', 'rechazada', 'vencida');
CREATE TYPE orbita.estado_verificacion AS ENUM ('confirmada', 'en_verificacion');
CREATE TYPE orbita.visibilidad        AS ENUM ('publica', 'privada');
CREATE TYPE orbita.canal              AS ENUM ('telegram', 'whatsapp', 'email', 'web');
CREATE TYPE orbita.estado_envio       AS ENUM ('pendiente', 'enviado', 'entregado', 'leido', 'fallido', 'omitido');
CREATE TYPE orbita.tipo_seguimiento   AS ENUM ('plazo_convocatoria', 'evento', 'revision_alerta');
CREATE TYPE orbita.nivel_log          AS ENUM ('debug', 'info', 'warn', 'error');

-- -----------------------------------------------------------------------------
-- 2. Utilidades comunes
-- -----------------------------------------------------------------------------

-- Mantiene updated_at
CREATE FUNCTION orbita.tg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- Quién hace el cambio: usuario autenticado (Supabase) o etiqueta puesta por n8n
CREATE FUNCTION orbita.actor_actual() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(nullif(current_setting('orbita.actor', true), ''),
                  auth.uid()::text,
                  current_user::text)
$$;

-- -----------------------------------------------------------------------------
-- 3. Catálogos y parámetros
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.parametros (
  clave        text PRIMARY KEY,
  valor        jsonb NOT NULL,
  descripcion  text,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE orbita.parametros IS 'Reglas operativas editables por el administrador (SLA, guardia, retención, resumen)';

CREATE FUNCTION orbita.param(p_clave text) RETURNS jsonb
LANGUAGE sql STABLE AS $$ SELECT valor FROM orbita.parametros WHERE clave = p_clave $$;

CREATE TABLE orbita.departamentos (
  id        smallint PRIMARY KEY,             -- código INE
  codigo    text NOT NULL UNIQUE,             -- ISO 3166-2:BO
  nombre    text NOT NULL UNIQUE,
  capital   text NOT NULL
);

CREATE TABLE orbita.categorias (
  codigo               text PRIMARY KEY,
  nombre               text NOT NULL,
  descripcion          text,
  revision_obligatoria boolean NOT NULL DEFAULT false,  -- salud, clima, vial, seguridad
  orden                smallint NOT NULL DEFAULT 0,
  activa               boolean NOT NULL DEFAULT true
);

-- -----------------------------------------------------------------------------
-- 4. Usuarios, roles y preferencias
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.users (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id      uuid UNIQUE,                -- auth.users.id en Supabase (null si solo recibe por Telegram/WhatsApp)
  nombre            text NOT NULL,
  email             text UNIQUE,
  telefono_whatsapp text UNIQUE,                -- E.164, p. ej. +59171234567
  telegram_chat_id  bigint UNIQUE,
  organizacion      text,
  rol               orbita.rol_usuario NOT NULL DEFAULT 'visor',
  activo            boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_telefono_e164 CHECK (telefono_whatsapp IS NULL OR telefono_whatsapp ~ '^\+[1-9][0-9]{7,14}$'),
  CONSTRAINT users_algun_contacto CHECK (num_nonnulls(auth_user_id, email, telefono_whatsapp, telegram_chat_id) > 0)
);
COMMENT ON COLUMN orbita.users.rol IS 'administrador: gestiona y corrige; analista: aprueba alertas; visor: recibe y consulta';

CREATE TABLE orbita.user_preferences (
  user_id           uuid PRIMARY KEY REFERENCES orbita.users(id) ON DELETE CASCADE,
  canales           orbita.canal[] NOT NULL DEFAULT '{telegram}',
  prioridad_minima  orbita.prioridad NOT NULL DEFAULT 'media',
  naturalezas       orbita.naturaleza_senal[] NOT NULL DEFAULT '{riesgo,oportunidad,mixta}',
  recibir_resumen   boolean NOT NULL DEFAULT true,
  recibir_urgentes  boolean NOT NULL DEFAULT true,
  silencio_desde    time,                        -- hora local Bolivia; las alertas altas ignoran el silencio
  silencio_hasta    time,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Suscripción por tema y por departamento. Sin filas = todos.
CREATE TABLE orbita.user_categorias (
  user_id    uuid REFERENCES orbita.users(id) ON DELETE CASCADE,
  categoria  text REFERENCES orbita.categorias(codigo) ON UPDATE CASCADE,
  PRIMARY KEY (user_id, categoria)
);

CREATE TABLE orbita.user_departamentos (
  user_id         uuid REFERENCES orbita.users(id) ON DELETE CASCADE,
  departamento_id smallint REFERENCES orbita.departamentos(id),
  PRIMARY KEY (user_id, departamento_id)
);

-- Rol del usuario autenticado (para RLS). SECURITY DEFINER evita recursión de políticas.
CREATE FUNCTION orbita.rol_actual() RETURNS orbita.rol_usuario
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = orbita, pg_temp AS $$
  SELECT rol FROM orbita.users WHERE auth_user_id = auth.uid() AND activo
$$;

CREATE FUNCTION orbita.usuario_actual() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = orbita, pg_temp AS $$
  SELECT id FROM orbita.users WHERE auth_user_id = auth.uid() AND activo
$$;

CREATE FUNCTION orbita.es_staff() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(orbita.rol_actual() IN ('administrador', 'analista'), false) $$;

CREATE FUNCTION orbita.es_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(orbita.rol_actual() = 'administrador', false) $$;

-- -----------------------------------------------------------------------------
-- 5. Fuentes y documentos crudos
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.sources (
  id                  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo              text NOT NULL UNIQUE,               -- p. ej. 'senamhi_alertas'
  nombre              text NOT NULL,
  institucion         text,
  url                 text NOT NULL,
  tipo                orbita.tipo_fuente NOT NULL,
  metodo              orbita.metodo_fuente NOT NULL,
  categorias          text[] NOT NULL DEFAULT '{}',       -- categorías que suele cubrir (pista para el clasificador)
  frecuencia_minutos  integer NOT NULL DEFAULT 60 CHECK (frecuencia_minutos >= 5),
  semana_inicio       smallint NOT NULL DEFAULT 1 CHECK (semana_inicio BETWEEN 1 AND 52),
  activa              boolean NOT NULL DEFAULT true,
  config              jsonb NOT NULL DEFAULT '{}',        -- selectores CSS, actor de Apify, query de Tavily...
  ultima_consulta_en  timestamptz,
  ultimo_exito_en     timestamptz,
  errores_seguidos    integer NOT NULL DEFAULT 0,
  ultimo_error        text,
  notas               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
COMMENT ON COLUMN orbita.sources.tipo IS 'Las fuentes no oficiales siempre pasan por revisión del analista';

CREATE TABLE orbita.raw_items (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id        smallint NOT NULL REFERENCES orbita.sources(id),
  url              text NOT NULL,
  content_hash     text NOT NULL,                       -- sha256 de título+contenido normalizados (lo calcula n8n)
  titulo           text,
  contenido        text,
  publicado_en     timestamptz,
  recolectado_en   timestamptz NOT NULL DEFAULT now(),
  idioma           text NOT NULL DEFAULT 'es',
  menciona_bolivia boolean,
  departamentos_detectados smallint[] NOT NULL DEFAULT '{}',
  estado           orbita.estado_raw NOT NULL DEFAULT 'nuevo',
  motivo_descarte  text,
  ejecucion_n8n    text,
  payload          jsonb NOT NULL DEFAULT '{}',         -- respuesta cruda de la fuente
  busqueda         tsvector GENERATED ALWAYS AS (
                     to_tsvector('spanish', coalesce(titulo, '') || ' ' || coalesce(contenido, ''))) STORED,
  CONSTRAINT raw_items_hash_unico UNIQUE (content_hash)  -- dedupe: INSERT ... ON CONFLICT (content_hash) DO NOTHING
);
CREATE INDEX raw_items_url_idx          ON orbita.raw_items (url);
CREATE INDEX raw_items_cola_idx         ON orbita.raw_items (estado, recolectado_en) WHERE estado IN ('nuevo', 'en_cola');
CREATE INDEX raw_items_source_fecha_idx ON orbita.raw_items (source_id, recolectado_en DESC);
CREATE INDEX raw_items_busqueda_idx     ON orbita.raw_items USING gin (busqueda);

-- -----------------------------------------------------------------------------
-- 6. Señales (resultado del análisis) e historial
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.signals (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  raw_item_id        bigint REFERENCES orbita.raw_items(id) ON DELETE SET NULL,  -- documento principal
  source_id          smallint REFERENCES orbita.sources(id),
  titulo             text NOT NULL,
  resumen            text NOT NULL,
  recomendacion      text,                                -- qué debería hacer el sector turismo
  naturaleza         orbita.naturaleza_senal NOT NULL,
  categoria          text NOT NULL REFERENCES orbita.categorias(codigo) ON UPDATE CASCADE,
  prioridad          orbita.prioridad NOT NULL DEFAULT 'media',
  motivos_prioridad  text[] NOT NULL DEFAULT '{}',        -- p. ej. {senamhi_naranja, plazo_menor_15_dias}
  puntaje            numeric(5,2) CHECK (puntaje BETWEEN 0 AND 100),
  confianza          numeric(3,2) CHECK (confianza BETWEEN 0 AND 1),
  alcance_nacional   boolean NOT NULL DEFAULT false,
  es_escenario       boolean NOT NULL DEFAULT false,      -- predicción/prospectiva: se etiqueta como escenario
  fuente_oficial     boolean NOT NULL DEFAULT false,
  enlace_oficial     text,
  estado             orbita.estado_senal NOT NULL DEFAULT 'detectada',
  requiere_revision  boolean NOT NULL DEFAULT false,   -- el trigger lo activa según las reglas; n8n puede forzarlo a true
  motivo_revision    text,
  fecha_evento_inicio timestamptz,
  fecha_evento_fin   timestamptz,
  plazo_hasta        timestamptz,                         -- cierre de convocatoria/licitación
  modelo             text,                                -- p. ej. 'hermes-4-70b'
  salida_modelo      jsonb,                               -- JSON validado devuelto por Hermes
  duplicado_de       bigint REFERENCES orbita.signals(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  busqueda           tsvector GENERATED ALWAYS AS (
                       to_tsvector('spanish', titulo || ' ' || resumen)) STORED,
  CONSTRAINT signals_fechas_evento CHECK (fecha_evento_fin IS NULL OR fecha_evento_inicio IS NULL
                                          OR fecha_evento_fin >= fecha_evento_inicio)
);
CREATE INDEX signals_estado_idx     ON orbita.signals (estado, prioridad DESC, created_at DESC);
CREATE INDEX signals_categoria_idx  ON orbita.signals (categoria, created_at DESC);
CREATE INDEX signals_plazo_idx      ON orbita.signals (plazo_hasta) WHERE plazo_hasta IS NOT NULL;
CREATE INDEX signals_evento_idx     ON orbita.signals (fecha_evento_inicio) WHERE fecha_evento_inicio IS NOT NULL;
CREATE INDEX signals_raw_item_idx   ON orbita.signals (raw_item_id);
CREATE INDEX signals_busqueda_idx   ON orbita.signals USING gin (busqueda);

-- Documentos adicionales que corroboran la misma señal
CREATE TABLE orbita.signal_raw_items (
  signal_id   bigint REFERENCES orbita.signals(id) ON DELETE CASCADE,
  raw_item_id bigint REFERENCES orbita.raw_items(id) ON DELETE CASCADE,
  PRIMARY KEY (signal_id, raw_item_id)
);
CREATE INDEX signal_raw_items_raw_idx ON orbita.signal_raw_items (raw_item_id);

CREATE TABLE orbita.signal_departamentos (
  signal_id       bigint REFERENCES orbita.signals(id) ON DELETE CASCADE,
  departamento_id smallint REFERENCES orbita.departamentos(id),
  PRIMARY KEY (signal_id, departamento_id)
);
CREATE INDEX signal_departamentos_dep_idx ON orbita.signal_departamentos (departamento_id);

CREATE TABLE orbita.signal_history (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id        bigint NOT NULL REFERENCES orbita.signals(id) ON DELETE CASCADE,
  entidad          text NOT NULL CHECK (entidad IN ('signal', 'alert')),
  estado_anterior  orbita.estado_senal,
  estado_nuevo     orbita.estado_senal,
  cambios          jsonb NOT NULL DEFAULT '{}',   -- {"campo": {"antes": ..., "despues": ...}}
  actor            text NOT NULL DEFAULT orbita.actor_actual(),
  nota             text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX signal_history_signal_idx ON orbita.signal_history (signal_id, created_at);

-- Diferencia entre dos filas como jsonb (solo campos que cambiaron)
CREATE FUNCTION orbita.jsonb_diff(p_antes jsonb, p_despues jsonb, p_ignorar text[] DEFAULT '{updated_at,busqueda}')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(k, jsonb_build_object('antes', p_antes -> k, 'despues', p_despues -> k)), '{}')
  FROM jsonb_object_keys(p_despues) AS k
  WHERE k <> ALL (p_ignorar) AND (p_antes -> k) IS DISTINCT FROM (p_despues -> k)
$$;

-- Flujo de estados permitido
CREATE FUNCTION orbita.transicion_valida(p_de orbita.estado_senal, p_a orbita.estado_senal)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_de = p_a OR p_a = 'descartada' OR (p_de, p_a) IN (
    ('detectada',       'en_analisis'),
    ('en_analisis',     'en_verificacion'),
    ('en_analisis',     'confirmada'),      -- oportunidad de fuente oficial sin revisión obligatoria
    ('en_verificacion', 'confirmada'),
    ('en_verificacion', 'publicada'),       -- publicada "en verificación" al vencer el SLA
    ('confirmada',      'publicada'),
    ('publicada',       'en_verificacion'), -- actualización que vuelve a revisión
    ('publicada',       'cerrada'),
    ('confirmada',      'cerrada')
  )
$$;

-- BEFORE INSERT/UPDATE: reglas de revisión obligatoria y flujo de estados
CREATE FUNCTION orbita.tg_signals_reglas() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_cat_obligatoria boolean;
  v_tipo_fuente     orbita.tipo_fuente;
BEGIN
  IF TG_OP = 'UPDATE' AND NOT orbita.transicion_valida(OLD.estado, NEW.estado) THEN
    RAISE EXCEPTION 'Transición de estado no permitida: % → % (señal %)', OLD.estado, NEW.estado, OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT revision_obligatoria INTO v_cat_obligatoria FROM orbita.categorias WHERE codigo = NEW.categoria;
  SELECT tipo INTO v_tipo_fuente FROM orbita.sources WHERE id = NEW.source_id;

  IF TG_OP = 'INSERT' THEN
    NEW.fuente_oficial := coalesce(v_tipo_fuente IN ('oficial', 'organismo_internacional'), NEW.fuente_oficial);
  END IF;

  -- Revisión obligatoria: salud, clima, vial, seguridad, fuentes no oficiales, escenarios
  IF coalesce(v_cat_obligatoria, false) OR NOT NEW.fuente_oficial OR NEW.es_escenario THEN
    NEW.requiere_revision := true;
    NEW.motivo_revision := coalesce(NEW.motivo_revision,
      CASE WHEN v_cat_obligatoria THEN 'categoria_' || NEW.categoria
           WHEN NOT NEW.fuente_oficial THEN 'fuente_no_oficial'
           ELSE 'escenario' END);
  END IF;

  IF NEW.alcance_nacional IS NULL THEN NEW.alcance_nacional := false; END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER signals_reglas BEFORE INSERT OR UPDATE ON orbita.signals
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_signals_reglas();
CREATE TRIGGER signals_updated_at BEFORE UPDATE ON orbita.signals
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_set_updated_at();

-- AFTER INSERT/UPDATE: historial
CREATE FUNCTION orbita.tg_signals_historial() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cambios jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO orbita.signal_history (signal_id, entidad, estado_nuevo, nota)
    VALUES (NEW.id, 'signal', NEW.estado, 'creada');
  ELSE
    v_cambios := orbita.jsonb_diff(to_jsonb(OLD), to_jsonb(NEW));
    IF v_cambios <> '{}' THEN
      INSERT INTO orbita.signal_history (signal_id, entidad, estado_anterior, estado_nuevo, cambios)
      VALUES (NEW.id, 'signal', OLD.estado, NEW.estado, v_cambios);
    END IF;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER signals_historial AFTER INSERT OR UPDATE ON orbita.signals
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_signals_historial();

-- -----------------------------------------------------------------------------
-- 7. Revisión humana (SLA 15 min en horario de guardia)
-- -----------------------------------------------------------------------------

-- Vencimiento del SLA: dentro de la guardia = ahora + SLA; fuera = inicio de la próxima guardia + SLA
CREATE FUNCTION orbita.calcular_vencimiento(p_desde timestamptz DEFAULT now())
RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tz     text     := coalesce(orbita.param('zona_horaria') #>> '{}', 'America/La_Paz');
  v_sla    interval := make_interval(mins => coalesce((orbita.param('sla_revision_minutos') #>> '{}')::int, 15));
  v_ini    time     := coalesce((orbita.param('guardia_inicio') #>> '{}')::time, '07:00');
  v_fin    time     := coalesce((orbita.param('guardia_fin') #>> '{}')::time, '22:00');
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

CREATE TABLE orbita.reviews (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id      bigint NOT NULL REFERENCES orbita.signals(id) ON DELETE CASCADE,
  motivo         text,
  analista_id    uuid REFERENCES orbita.users(id),        -- quien decide
  solicitado_en  timestamptz NOT NULL DEFAULT now(),
  vence_en       timestamptz NOT NULL DEFAULT orbita.calcular_vencimiento(now()),
  decision       orbita.decision_revision NOT NULL DEFAULT 'pendiente',
  decidido_en    timestamptz,
  comentario     text,
  cambios        jsonb,                                   -- ediciones del analista sobre título/resumen/prioridad
  mensaje_tarjeta_id text,                                -- id del mensaje de Telegram con los botones
  CONSTRAINT reviews_decision_coherente CHECK ((decision = 'pendiente') = (decidido_en IS NULL))
);
-- Solo una revisión abierta por señal
CREATE UNIQUE INDEX reviews_una_pendiente ON orbita.reviews (signal_id) WHERE decision = 'pendiente';
CREATE INDEX reviews_vencimiento_idx ON orbita.reviews (vence_en) WHERE decision = 'pendiente';

-- -----------------------------------------------------------------------------
-- 8. Alertas publicadas
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.alerts (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id            bigint NOT NULL UNIQUE REFERENCES orbita.signals(id) ON DELETE CASCADE,
  titulo               text NOT NULL,
  texto                text NOT NULL,                     -- texto final que ve el usuario
  recomendacion        text,
  enlace_fuente        text,
  estado_verificacion  orbita.estado_verificacion NOT NULL DEFAULT 'confirmada',
  visibilidad          orbita.visibilidad NOT NULL DEFAULT 'publica',
  es_escenario         boolean NOT NULL DEFAULT false,
  aprobada_por         uuid REFERENCES orbita.users(id),
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
COMMENT ON COLUMN orbita.alerts.estado_verificacion IS '"en_verificacion" = publicada sin aprobación al vencer el SLA (solo con enlace a aviso oficial)';
COMMENT ON COLUMN orbita.alerts.es_escenario IS 'Predicción etiquetada como escenario; propuesta: privada al inicio';
CREATE INDEX alerts_publicas_idx ON orbita.alerts (publicada_en DESC)
  WHERE visibilidad = 'publica' AND publicada_en IS NOT NULL AND cerrada_en IS NULL;

-- Versión + historial de cambios de la alerta (en signal_history)
CREATE FUNCTION orbita.tg_alerts_version() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.titulo, NEW.texto, NEW.recomendacion, NEW.estado_verificacion)
     IS DISTINCT FROM (OLD.titulo, OLD.texto, OLD.recomendacion, OLD.estado_verificacion) THEN
    NEW.version := OLD.version + 1;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE FUNCTION orbita.tg_alerts_historial() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_cambios jsonb;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_cambios := jsonb_build_object('alerta_id', NEW.id, 'version', NEW.version,
                                    'estado_verificacion', NEW.estado_verificacion);
  ELSE
    v_cambios := orbita.jsonb_diff(to_jsonb(OLD), to_jsonb(NEW));
  END IF;
  IF v_cambios <> '{}' THEN
    INSERT INTO orbita.signal_history (signal_id, entidad, cambios, nota)
    VALUES (NEW.signal_id, 'alert', v_cambios, CASE WHEN TG_OP = 'INSERT' THEN 'alerta creada' END);
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER alerts_version BEFORE UPDATE ON orbita.alerts
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_alerts_version();
CREATE TRIGGER alerts_historial AFTER INSERT OR UPDATE ON orbita.alerts
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_alerts_historial();

-- -----------------------------------------------------------------------------
-- 9. Resumen diario (máximo 7 alertas)
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.daily_digests (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fecha        date NOT NULL UNIQUE,                     -- fecha local Bolivia
  texto        text,                                     -- mensaje único que se envía
  sin_alertas  boolean NOT NULL DEFAULT false,           -- "No hay alertas confirmadas en este momento"
  generado_en  timestamptz NOT NULL DEFAULT now(),
  publicado_en timestamptz
);

CREATE TABLE orbita.daily_digest_items (
  digest_id  bigint REFERENCES orbita.daily_digests(id) ON DELETE CASCADE,
  orden      smallint NOT NULL CHECK (orden BETWEEN 1 AND 7),   -- el límite de 7 lo garantiza la BD
  alert_id   bigint NOT NULL REFERENCES orbita.alerts(id) ON DELETE CASCADE,
  PRIMARY KEY (digest_id, orden),
  UNIQUE (digest_id, alert_id)
);

-- -----------------------------------------------------------------------------
-- 10. Recordatorios / seguimiento (convocatorias 30/15/5 días; eventos 90/60/30)
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.follow_ups (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id        bigint NOT NULL REFERENCES orbita.signals(id) ON DELETE CASCADE,
  tipo             orbita.tipo_seguimiento NOT NULL,
  fecha_objetivo   timestamptz NOT NULL,                 -- plazo o fecha del evento
  dias_antes       smallint NOT NULL CHECK (dias_antes >= 0),
  programado_para  timestamptz NOT NULL,
  enviado_en       timestamptz,
  cancelado        boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (signal_id, tipo, dias_antes)
);
CREATE INDEX follow_ups_pendientes_idx ON orbita.follow_ups (programado_para)
  WHERE enviado_en IS NULL AND NOT cancelado;

-- Crea los recordatorios de una señal según su plazo o fecha de evento
CREATE FUNCTION orbita.programar_recordatorios(p_signal_id bigint) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  s       orbita.signals;
  v_dias  int;
  v_n     int := 0;
BEGIN
  SELECT * INTO s FROM orbita.signals WHERE id = p_signal_id;
  IF s.plazo_hasta IS NOT NULL THEN
    FOR v_dias IN SELECT jsonb_array_elements_text(coalesce(orbita.param('recordatorios_convocatoria_dias'), '[30,15,5]'))::int LOOP
      IF s.plazo_hasta - make_interval(days => v_dias) > now() THEN
        INSERT INTO orbita.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
        VALUES (s.id, 'plazo_convocatoria', s.plazo_hasta, v_dias, s.plazo_hasta - make_interval(days => v_dias))
        ON CONFLICT DO NOTHING;
        v_n := v_n + 1;
      END IF;
    END LOOP;
  END IF;
  IF s.fecha_evento_inicio IS NOT NULL THEN
    FOR v_dias IN SELECT jsonb_array_elements_text(coalesce(orbita.param('recordatorios_evento_dias'), '[90,60,30]'))::int LOOP
      IF s.fecha_evento_inicio - make_interval(days => v_dias) > now() THEN
        INSERT INTO orbita.follow_ups (signal_id, tipo, fecha_objetivo, dias_antes, programado_para)
        VALUES (s.id, 'evento', s.fecha_evento_inicio, v_dias, s.fecha_evento_inicio - make_interval(days => v_dias))
        ON CONFLICT DO NOTHING;
        v_n := v_n + 1;
      END IF;
    END LOOP;
  END IF;
  RETURN v_n;
END $$;

-- -----------------------------------------------------------------------------
-- 11. Envíos (Telegram / WhatsApp / correo / web)
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.deliveries (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id         uuid REFERENCES orbita.users(id) ON DELETE SET NULL,  -- null = publicación en web/canal
  canal           orbita.canal NOT NULL,
  alert_id        bigint REFERENCES orbita.alerts(id) ON DELETE CASCADE,
  digest_id       bigint REFERENCES orbita.daily_digests(id) ON DELETE CASCADE,
  follow_up_id    bigint REFERENCES orbita.follow_ups(id) ON DELETE CASCADE,
  alert_version   integer,
  estado          orbita.estado_envio NOT NULL DEFAULT 'pendiente',
  plantilla       text,                                 -- nombre de plantilla de WhatsApp, si aplica
  mensaje_externo_id text,                              -- message_id de Telegram / wamid de WhatsApp
  error           text,
  costo_usd       numeric(8,4) NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  enviado_en      timestamptz,
  CONSTRAINT deliveries_un_objeto CHECK (num_nonnulls(alert_id, digest_id, follow_up_id) = 1)
);
-- No duplicar un envío al mismo usuario por el mismo canal (por versión de alerta)
CREATE UNIQUE INDEX deliveries_alerta_unica  ON orbita.deliveries (alert_id, alert_version, user_id, canal) NULLS NOT DISTINCT
  WHERE alert_id IS NOT NULL;
CREATE UNIQUE INDEX deliveries_resumen_unico ON orbita.deliveries (digest_id, user_id, canal) NULLS NOT DISTINCT
  WHERE digest_id IS NOT NULL;
CREATE UNIQUE INDEX deliveries_recordatorio_unico ON orbita.deliveries (follow_up_id, user_id, canal) NULLS NOT DISTINCT
  WHERE follow_up_id IS NOT NULL;
CREATE INDEX deliveries_pendientes_idx ON orbita.deliveries (created_at) WHERE estado = 'pendiente';
CREATE INDEX deliveries_user_idx ON orbita.deliveries (user_id, created_at DESC);

-- Todo lo que salga por WhatsApp debe estar aprobado por el analista
CREATE FUNCTION orbita.tg_deliveries_whatsapp() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.canal = 'whatsapp' AND NEW.alert_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM orbita.alerts WHERE id = NEW.alert_id AND aprobada_por IS NOT NULL) THEN
    RAISE EXCEPTION 'La alerta % no está aprobada por un analista: no puede enviarse por WhatsApp', NEW.alert_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.alert_id IS NOT NULL AND NEW.alert_version IS NULL THEN
    SELECT version INTO NEW.alert_version FROM orbita.alerts WHERE id = NEW.alert_id;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER deliveries_whatsapp BEFORE INSERT ON orbita.deliveries
  FOR EACH ROW EXECUTE FUNCTION orbita.tg_deliveries_whatsapp();

-- -----------------------------------------------------------------------------
-- 12. Feedback útil / no útil
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.feedback (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  alert_id    bigint NOT NULL REFERENCES orbita.alerts(id) ON DELETE CASCADE,
  user_id     uuid REFERENCES orbita.users(id) ON DELETE SET NULL,
  canal       orbita.canal NOT NULL,
  util        boolean NOT NULL,
  comentario  text,
  visitante_hash text,                                   -- web pública sin cuenta: hash anónimo de sesión
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT feedback_identificado CHECK (user_id IS NOT NULL OR visitante_hash IS NOT NULL)
);
CREATE UNIQUE INDEX feedback_un_voto_usuario   ON orbita.feedback (alert_id, user_id)        WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX feedback_un_voto_visitante ON orbita.feedback (alert_id, visitante_hash) WHERE user_id IS NULL;

-- -----------------------------------------------------------------------------
-- 13. Consultas por chat, logs y auditoría
-- -----------------------------------------------------------------------------
CREATE TABLE orbita.chat_queries (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id      uuid REFERENCES orbita.users(id) ON DELETE SET NULL,
  canal        orbita.canal NOT NULL,
  remitente    text,                                     -- chat_id / teléfono si no está registrado
  comando      text,                                     -- /alertas, /resumen, /departamento...
  texto        text NOT NULL,
  resultados   integer,
  respuesta    text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_queries_fecha_idx ON orbita.chat_queries (created_at DESC);

CREATE TABLE orbita.system_logs (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nivel        orbita.nivel_log NOT NULL DEFAULT 'info',
  workflow     text,                                     -- nombre del workflow n8n
  nodo         text,
  ejecucion_id text,
  source_id    smallint REFERENCES orbita.sources(id) ON DELETE SET NULL,
  mensaje      text NOT NULL,
  detalle      jsonb,
  costo_usd    numeric(10,6),                            -- tokens de Hermes, Apify, etc.
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX system_logs_fecha_idx  ON orbita.system_logs (created_at DESC);
CREATE INDEX system_logs_errores_idx ON orbita.system_logs (created_at DESC) WHERE nivel IN ('warn', 'error');

CREATE TABLE orbita.audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tabla       text NOT NULL,
  registro_id text NOT NULL,
  accion      text NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
  antes       jsonb,
  despues     jsonb,
  actor       text NOT NULL DEFAULT orbita.actor_actual(),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_registro_idx ON orbita.audit_log (tabla, registro_id, created_at);

CREATE FUNCTION orbita.tg_auditar() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = orbita, pg_temp AS $$
DECLARE v_fila jsonb := to_jsonb(coalesce(NEW, OLD));
BEGIN
  INSERT INTO orbita.audit_log (tabla, registro_id, accion, antes, despues)
  VALUES (TG_TABLE_NAME, coalesce(v_fila ->> 'id', v_fila ->> 'clave', v_fila ->> 'user_id', '?'), TG_OP,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

-- Auditoría de cambios administrativos (señales y alertas ya tienen signal_history)
CREATE TRIGGER auditar_users       AFTER INSERT OR UPDATE OR DELETE ON orbita.users       FOR EACH ROW EXECUTE FUNCTION orbita.tg_auditar();
CREATE TRIGGER auditar_sources     AFTER INSERT OR UPDATE OR DELETE ON orbita.sources     FOR EACH ROW EXECUTE FUNCTION orbita.tg_auditar();
CREATE TRIGGER auditar_parametros  AFTER INSERT OR UPDATE OR DELETE ON orbita.parametros  FOR EACH ROW EXECUTE FUNCTION orbita.tg_auditar();
CREATE TRIGGER auditar_categorias  AFTER INSERT OR UPDATE OR DELETE ON orbita.categorias  FOR EACH ROW EXECUTE FUNCTION orbita.tg_auditar();
CREATE TRIGGER auditar_reviews     AFTER UPDATE ON orbita.reviews FOR EACH ROW EXECUTE FUNCTION orbita.tg_auditar();

CREATE TRIGGER users_updated_at       BEFORE UPDATE ON orbita.users            FOR EACH ROW EXECUTE FUNCTION orbita.tg_set_updated_at();
CREATE TRIGGER sources_updated_at     BEFORE UPDATE ON orbita.sources          FOR EACH ROW EXECUTE FUNCTION orbita.tg_set_updated_at();
CREATE TRIGGER parametros_updated_at  BEFORE UPDATE ON orbita.parametros       FOR EACH ROW EXECUTE FUNCTION orbita.tg_set_updated_at();
CREATE TRIGGER preferences_updated_at BEFORE UPDATE ON orbita.user_preferences FOR EACH ROW EXECUTE FUNCTION orbita.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- 14. Funciones de negocio que llama n8n
-- -----------------------------------------------------------------------------

-- Abre la revisión de una señal y la pasa a en_verificacion (workflow 4)
CREATE FUNCTION orbita.solicitar_revision(p_signal_id bigint, p_motivo text DEFAULT NULL)
RETURNS orbita.reviews LANGUAGE plpgsql AS $$
DECLARE r orbita.reviews;
BEGIN
  UPDATE orbita.signals SET estado = 'en_verificacion'
   WHERE id = p_signal_id AND estado IN ('detectada', 'en_analisis', 'publicada');
  INSERT INTO orbita.reviews (signal_id, motivo)
  VALUES (p_signal_id, coalesce(p_motivo, (SELECT motivo_revision FROM orbita.signals WHERE id = p_signal_id)))
  ON CONFLICT (signal_id) WHERE decision = 'pendiente' DO UPDATE SET motivo = EXCLUDED.motivo
  RETURNING * INTO r;
  RETURN r;
END $$;

-- Registra la decisión del analista (botones de la tarjeta)
CREATE FUNCTION orbita.decidir_revision(p_review_id bigint, p_analista uuid,
                                        p_decision orbita.decision_revision, p_comentario text DEFAULT NULL)
RETURNS orbita.reviews LANGUAGE plpgsql AS $$
DECLARE r orbita.reviews;
BEGIN
  IF p_decision IN ('pendiente', 'vencida') THEN
    RAISE EXCEPTION 'Decisión no válida para un analista: %', p_decision;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orbita.users WHERE id = p_analista AND rol IN ('analista', 'administrador') AND activo) THEN
    RAISE EXCEPTION 'El usuario % no puede aprobar alertas', p_analista;
  END IF;

  UPDATE orbita.reviews
     SET decision = p_decision, analista_id = p_analista, decidido_en = now(), comentario = p_comentario
   WHERE id = p_review_id AND decision IN ('pendiente', 'vencida')
  RETURNING * INTO r;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'La revisión % no existe o ya fue decidida', p_review_id;
  END IF;

  IF p_decision IN ('aprobada', 'editada') THEN
    UPDATE orbita.signals SET estado = 'confirmada' WHERE id = r.signal_id AND estado = 'en_verificacion';
    UPDATE orbita.alerts SET aprobada_por = p_analista, aprobada_en = now(), estado_verificacion = 'confirmada'
     WHERE signal_id = r.signal_id;
  ELSE
    UPDATE orbita.signals SET estado = 'descartada' WHERE id = r.signal_id;
    UPDATE orbita.alerts SET cerrada_en = now() WHERE signal_id = r.signal_id AND cerrada_en IS NULL;
  END IF;
  RETURN r;
END $$;

-- Marca como vencidas las revisiones fuera de SLA e indica qué hacer con cada una.
-- Regla (ajuste propuesto): publicar "en verificación" solo si hay aviso oficial con enlace; si no, escalar.
CREATE FUNCTION orbita.vencer_revisiones()
RETURNS TABLE (review_id bigint, signal_id bigint, accion text)
LANGUAGE plpgsql AS $$
BEGIN
  RETURN QUERY
  WITH vencidas AS (
    UPDATE orbita.reviews rv
       SET decision = 'vencida', decidido_en = now()
     WHERE rv.decision = 'pendiente' AND rv.vence_en <= now()
    RETURNING rv.id, rv.signal_id
  )
  SELECT v.id, v.signal_id,
         CASE WHEN s.fuente_oficial AND s.enlace_oficial IS NOT NULL AND NOT s.es_escenario
              THEN 'publicar_en_verificacion' ELSE 'escalar_al_administrador' END
    FROM vencidas v JOIN orbita.signals s ON s.id = v.signal_id;
END $$;

-- Usuarios que deben recibir una alerta por un canal (por tema, departamento, naturaleza y prioridad)
CREATE FUNCTION orbita.destinatarios_alerta(p_alert_id bigint, p_canal orbita.canal)
RETURNS TABLE (user_id uuid, nombre text, telegram_chat_id bigint, telefono_whatsapp text, email text)
LANGUAGE sql STABLE AS $$
  SELECT u.id, u.nombre, u.telegram_chat_id, u.telefono_whatsapp, u.email
    FROM orbita.alerts a
    JOIN orbita.signals s ON s.id = a.signal_id
    JOIN orbita.users u ON u.activo
    LEFT JOIN orbita.user_preferences p ON p.user_id = u.id
   WHERE a.id = p_alert_id
     AND a.cerrada_en IS NULL
     AND p_canal = ANY (coalesce(p.canales, '{telegram}'))
     AND s.prioridad >= coalesce(p.prioridad_minima, 'media')
     AND s.naturaleza = ANY (coalesce(p.naturalezas, '{riesgo,oportunidad,mixta}'))
     AND (NOT s.es_escenario OR u.rol IN ('administrador', 'analista'))
     AND (a.visibilidad = 'publica' OR u.rol IN ('administrador', 'analista'))
     AND (NOT EXISTS (SELECT 1 FROM orbita.user_categorias uc WHERE uc.user_id = u.id)
          OR EXISTS (SELECT 1 FROM orbita.user_categorias uc WHERE uc.user_id = u.id AND uc.categoria = s.categoria))
     AND (s.alcance_nacional
          OR NOT EXISTS (SELECT 1 FROM orbita.user_departamentos ud WHERE ud.user_id = u.id)
          OR EXISTS (SELECT 1 FROM orbita.user_departamentos ud
                       JOIN orbita.signal_departamentos sd ON sd.departamento_id = ud.departamento_id
                      WHERE ud.user_id = u.id AND sd.signal_id = s.id))
     AND (p_canal <> 'telegram' OR u.telegram_chat_id IS NOT NULL)
     AND (p_canal <> 'whatsapp' OR (u.telefono_whatsapp IS NOT NULL AND a.aprobada_por IS NOT NULL))
     AND (p_canal <> 'email' OR u.email IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM orbita.deliveries d
                      WHERE d.alert_id = a.id AND d.alert_version = a.version
                        AND d.user_id = u.id AND d.canal = p_canal AND d.estado <> 'fallido')
$$;

-- Genera el resumen diario: alertas públicas de las últimas 24 h, máx. 7, por prioridad y puntaje
CREATE FUNCTION orbita.generar_resumen_diario(p_fecha date DEFAULT (now() AT TIME ZONE 'America/La_Paz')::date)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_id    bigint;
  v_max   int := coalesce((orbita.param('resumen_max_alertas') #>> '{}')::int, 7);
  v_n     int;
BEGIN
  INSERT INTO orbita.daily_digests (fecha) VALUES (p_fecha)
  ON CONFLICT (fecha) DO UPDATE SET generado_en = now()
  RETURNING id INTO v_id;

  DELETE FROM orbita.daily_digest_items WHERE digest_id = v_id;

  INSERT INTO orbita.daily_digest_items (digest_id, orden, alert_id)
  SELECT v_id, row_number() OVER (ORDER BY s.prioridad DESC, s.puntaje DESC NULLS LAST, a.publicada_en DESC), a.id
    FROM orbita.alerts a JOIN orbita.signals s ON s.id = a.signal_id
   WHERE a.visibilidad = 'publica' AND NOT a.es_escenario AND a.cerrada_en IS NULL
     AND a.publicada_en >= now() - interval '24 hours'
   ORDER BY s.prioridad DESC, s.puntaje DESC NULLS LAST, a.publicada_en DESC
   LIMIT least(v_max, 7);

  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE orbita.daily_digests
     SET sin_alertas = (v_n = 0),
         texto = CASE WHEN v_n = 0 THEN 'No hay alertas confirmadas en este momento' ELSE texto END
   WHERE id = v_id;
  RETURN v_id;
END $$;

-- Retención: borra lo que supera N meses (por defecto 6). Ejecutar a diario (pg_cron o n8n).
CREATE FUNCTION orbita.purgar_retencion()
RETURNS TABLE (tabla text, borrados bigint)
LANGUAGE plpgsql AS $$
DECLARE
  v_limite timestamptz := now() - make_interval(months => coalesce((orbita.param('retencion_meses') #>> '{}')::int, 6));
  v_n bigint;
BEGIN
  DELETE FROM orbita.signals s
   WHERE s.updated_at < v_limite AND s.estado IN ('cerrada', 'descartada');
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'signals'; borrados := v_n; RETURN NEXT;

  DELETE FROM orbita.raw_items r
   WHERE r.recolectado_en < v_limite
     AND NOT EXISTS (SELECT 1 FROM orbita.signals s WHERE s.raw_item_id = r.id);
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'raw_items'; borrados := v_n; RETURN NEXT;

  DELETE FROM orbita.daily_digests d WHERE d.generado_en < v_limite;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'daily_digests'; borrados := v_n; RETURN NEXT;

  DELETE FROM orbita.chat_queries c WHERE c.created_at < v_limite;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'chat_queries'; borrados := v_n; RETURN NEXT;

  DELETE FROM orbita.system_logs l WHERE l.created_at < v_limite;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'system_logs'; borrados := v_n; RETURN NEXT;

  DELETE FROM orbita.audit_log a WHERE a.created_at < v_limite;
  GET DIAGNOSTICS v_n = ROW_COUNT; tabla := 'audit_log'; borrados := v_n; RETURN NEXT;
END $$;

-- -----------------------------------------------------------------------------
-- 15. Vistas
-- -----------------------------------------------------------------------------

-- Web pública: solo alertas públicas, publicadas, vigentes y que no son escenario.
-- Se ejecuta con permisos del dueño a propósito, para que anon no necesite leer las tablas base.
CREATE VIEW orbita.v_alertas_publicas WITH (security_barrier) AS
SELECT a.id,
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
       s.alcance_nacional,
       coalesce(array_agg(d.nombre ORDER BY d.id) FILTER (WHERE d.id IS NOT NULL), '{}') AS departamentos,
       coalesce(array_agg(d.id ORDER BY d.id)     FILTER (WHERE d.id IS NOT NULL), '{}') AS departamento_ids,
       s.fecha_evento_inicio,
       s.fecha_evento_fin,
       s.plazo_hasta,
       a.publicada_en,
       a.updated_at AS actualizada_en,
       a.version
  FROM orbita.alerts a
  JOIN orbita.signals s      ON s.id = a.signal_id
  JOIN orbita.categorias c   ON c.codigo = s.categoria
  LEFT JOIN orbita.signal_departamentos sd ON sd.signal_id = s.id
  LEFT JOIN orbita.departamentos d         ON d.id = sd.departamento_id
 WHERE a.visibilidad = 'publica'
   AND a.publicada_en IS NOT NULL
   AND a.cerrada_en IS NULL
   AND NOT a.es_escenario
   AND (a.vigente_hasta IS NULL OR a.vigente_hasta > now())
 GROUP BY a.id, s.id, c.nombre;

-- Cola del analista con minutos restantes de SLA
CREATE VIEW orbita.v_cola_revision WITH (security_invoker = true) AS
SELECT r.id AS review_id, r.signal_id, s.titulo, s.categoria, s.naturaleza, s.prioridad,
       s.fuente_oficial, s.enlace_oficial, r.motivo, r.solicitado_en, r.vence_en,
       round(extract(epoch FROM (r.vence_en - now())) / 60)::int AS minutos_restantes
  FROM orbita.reviews r JOIN orbita.signals s ON s.id = r.signal_id
 WHERE r.decision = 'pendiente'
 ORDER BY r.vence_en;

-- Métricas de la beta por día (revisión semanal)
CREATE VIEW orbita.v_metricas_diarias WITH (security_invoker = true) AS
WITH dias AS (
  SELECT generate_series((now() - interval '30 days')::date, now()::date, '1 day')::date AS dia
)
SELECT d.dia,
  (SELECT count(*) FROM orbita.raw_items r WHERE r.recolectado_en::date = d.dia)                       AS documentos,
  (SELECT count(*) FROM orbita.signals s WHERE s.created_at::date = d.dia)                             AS senales,
  (SELECT count(*) FROM orbita.alerts a WHERE a.publicada_en::date = d.dia)                            AS alertas_publicadas,
  (SELECT count(*) FROM orbita.reviews r WHERE r.decidido_en::date = d.dia AND r.decision = 'vencida') AS revisiones_vencidas,
  (SELECT round(avg(extract(epoch FROM (r.decidido_en - r.solicitado_en)) / 60)::numeric, 1)
     FROM orbita.reviews r WHERE r.decidido_en::date = d.dia AND r.decision IN ('aprobada', 'editada', 'rechazada')) AS minutos_medios_revision,
  (SELECT count(*) FILTER (WHERE f.util) FROM orbita.feedback f WHERE f.created_at::date = d.dia)      AS feedback_util,
  (SELECT count(*) FILTER (WHERE NOT f.util) FROM orbita.feedback f WHERE f.created_at::date = d.dia)  AS feedback_no_util,
  (SELECT coalesce(sum(l.costo_usd), 0) FROM orbita.system_logs l WHERE l.created_at::date = d.dia)
  + (SELECT coalesce(sum(e.costo_usd), 0) FROM orbita.deliveries e WHERE e.created_at::date = d.dia) AS costo_usd
FROM dias d
ORDER BY d.dia DESC;

-- Salud de las fuentes
CREATE VIEW orbita.v_estado_fuentes WITH (security_invoker = true) AS
SELECT s.id, s.codigo, s.nombre, s.activa, s.metodo, s.frecuencia_minutos,
       s.ultima_consulta_en, s.ultimo_exito_en, s.errores_seguidos,
       (SELECT count(*) FROM orbita.raw_items r WHERE r.source_id = s.id AND r.recolectado_en > now() - interval '7 days') AS documentos_7d,
       CASE WHEN NOT s.activa THEN 'inactiva'
            WHEN s.errores_seguidos >= 3 THEN 'fallando'
            WHEN s.ultimo_exito_en IS NULL OR s.ultimo_exito_en < now() - make_interval(mins => s.frecuencia_minutos * 3) THEN 'atrasada'
            ELSE 'ok' END AS salud
  FROM orbita.sources s;

-- -----------------------------------------------------------------------------
-- 16. Seguridad: RLS y permisos
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA orbita TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES    IN SCHEMA orbita TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA orbita TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA orbita TO service_role;

GRANT SELECT ON orbita.v_alertas_publicas, orbita.departamentos, orbita.categorias TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orbita TO authenticated;  -- filtrado por RLS
GRANT USAGE ON ALL SEQUENCES IN SCHEMA orbita TO authenticated;
GRANT INSERT ON orbita.feedback TO anon;
GRANT USAGE ON SEQUENCE orbita.feedback_id_seq TO anon;

-- Funciones operativas solo para n8n (service_role/postgres) y personal interno
REVOKE EXECUTE ON FUNCTION orbita.purgar_retencion(), orbita.vencer_revisiones(),
                           orbita.generar_resumen_diario(date) FROM PUBLIC;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'orbita' LOOP
    EXECUTE format('ALTER TABLE orbita.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
END $$;

-- Catálogos: lectura para todos; escritura del administrador
CREATE POLICY lectura_publica ON orbita.departamentos FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY lectura_publica ON orbita.categorias    FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY admin_escribe   ON orbita.categorias    FOR ALL    TO authenticated USING (orbita.es_admin()) WITH CHECK (orbita.es_admin());

-- Parámetros y usuarios: el administrador gestiona; cada persona ve su propia ficha
CREATE POLICY staff_lee     ON orbita.parametros FOR SELECT TO authenticated USING (orbita.es_staff());
CREATE POLICY admin_escribe ON orbita.parametros FOR ALL    TO authenticated USING (orbita.es_admin()) WITH CHECK (orbita.es_admin());

CREATE POLICY ve_su_ficha   ON orbita.users FOR SELECT TO authenticated USING (auth_user_id = auth.uid() OR orbita.es_staff());
CREATE POLICY admin_escribe ON orbita.users FOR ALL    TO authenticated USING (orbita.es_admin()) WITH CHECK (orbita.es_admin());

-- Preferencias y suscripciones: cada usuario las suyas; el personal, todas
CREATE POLICY propias ON orbita.user_preferences   FOR ALL TO authenticated
  USING (user_id = orbita.usuario_actual() OR orbita.es_staff()) WITH CHECK (user_id = orbita.usuario_actual() OR orbita.es_staff());
CREATE POLICY propias ON orbita.user_categorias    FOR ALL TO authenticated
  USING (user_id = orbita.usuario_actual() OR orbita.es_staff()) WITH CHECK (user_id = orbita.usuario_actual() OR orbita.es_staff());
CREATE POLICY propias ON orbita.user_departamentos FOR ALL TO authenticated
  USING (user_id = orbita.usuario_actual() OR orbita.es_staff()) WITH CHECK (user_id = orbita.usuario_actual() OR orbita.es_staff());

-- Alertas: visor ve las públicas publicadas; personal ve y edita todo
CREATE POLICY visor_lee_publicas ON orbita.alerts FOR SELECT TO authenticated
  USING (visibilidad = 'publica' AND publicada_en IS NOT NULL AND NOT es_escenario);

-- Feedback: cualquiera puede votar (anon con visitante_hash); usuario ve los suyos
CREATE POLICY anon_vota ON orbita.feedback FOR INSERT TO anon
  WITH CHECK (user_id IS NULL AND visitante_hash IS NOT NULL
              AND EXISTS (SELECT 1 FROM orbita.v_alertas_publicas v WHERE v.id = alert_id));
CREATE POLICY usuario_vota ON orbita.feedback FOR INSERT TO authenticated
  WITH CHECK (user_id = orbita.usuario_actual());
CREATE POLICY usuario_ve_sus_votos ON orbita.feedback FOR SELECT TO authenticated
  USING (user_id = orbita.usuario_actual());

-- Envíos: el usuario ve los suyos
CREATE POLICY usuario_ve_sus_envios ON orbita.deliveries FOR SELECT TO authenticated
  USING (user_id = orbita.usuario_actual());

-- Personal interno (administrador y analista): acceso completo a las tablas operativas
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['sources', 'raw_items', 'signals', 'signal_raw_items', 'signal_departamentos',
                           'signal_history', 'reviews', 'alerts', 'daily_digests', 'daily_digest_items',
                           'follow_ups', 'deliveries', 'feedback', 'chat_queries', 'system_logs'] LOOP
    EXECUTE format('CREATE POLICY staff_todo ON orbita.%I FOR ALL TO authenticated
                    USING (orbita.es_staff()) WITH CHECK (orbita.es_staff())', t);
  END LOOP;
END $$;

-- Auditoría: solo lectura del administrador
CREATE POLICY admin_lee ON orbita.audit_log FOR SELECT TO authenticated USING (orbita.es_admin());

-- -----------------------------------------------------------------------------
-- 17. Datos semilla
-- -----------------------------------------------------------------------------
INSERT INTO orbita.parametros (clave, valor, descripcion) VALUES
  ('zona_horaria',                    '"America/La_Paz"', 'Zona horaria de Bolivia (UTC-4)'),
  ('sla_revision_minutos',            '15',               'Minutos que tiene el analista para aprobar'),
  ('guardia_inicio',                  '"07:00"',          'Inicio del horario de guardia (ajuste propuesto)'),
  ('guardia_fin',                     '"22:00"',          'Fin del horario de guardia (ajuste propuesto)'),
  ('resumen_max_alertas',             '7',                'Máximo de alertas en el resumen diario'),
  ('resumen_hora',                    '"08:00"',          'Hora del resumen diario (pendiente de confirmar)'),
  ('retencion_meses',                 '6',                'Meses que se conservan los datos'),
  ('anticipacion_horas',              '24',               'Anticipación objetivo de las alertas'),
  ('plazo_urgente_dias',              '15',               'Convocatoria con plazo menor a esto = prioridad alta'),
  ('recordatorios_convocatoria_dias', '[30, 15, 5]',      'Recordatorios antes del cierre de una convocatoria'),
  ('recordatorios_evento_dias',       '[90, 60, 30]',     'Recordatorios antes de un evento'),
  ('escenarios_publicos',             'false',            'Predicciones visibles al público (ajuste propuesto: no al inicio)'),
  ('mensaje_sin_alertas',             '"No hay alertas confirmadas en este momento"', 'Respuesta cuando no hay alertas');

INSERT INTO orbita.departamentos (id, codigo, nombre, capital) VALUES
  (1, 'BO-H', 'Chuquisaca', 'Sucre'),
  (2, 'BO-L', 'La Paz',     'La Paz'),
  (3, 'BO-C', 'Cochabamba', 'Cochabamba'),
  (4, 'BO-O', 'Oruro',      'Oruro'),
  (5, 'BO-P', 'Potosí',     'Potosí'),
  (6, 'BO-T', 'Tarija',     'Tarija'),
  (7, 'BO-S', 'Santa Cruz', 'Santa Cruz de la Sierra'),
  (8, 'BO-B', 'Beni',       'Trinidad'),
  (9, 'BO-N', 'Pando',      'Cobija');

-- 8 tipos de vigilancia (editables por el administrador)
INSERT INTO orbita.categorias (codigo, nombre, descripcion, revision_obligatoria, orden) VALUES
  ('clima',          'Clima y desastres',          'Alertas SENAMHI, inundaciones, sequías, heladas, incendios',            true,  1),
  ('salud',          'Salud y epidemiología',      'Alertas epidemiológicas, brotes, requisitos sanitarios',                true,  2),
  ('vial',           'Vías y transporte terrestre','Cortes de ruta, bloqueos, transitabilidad (ABC)',                       true,  3),
  ('seguridad',      'Seguridad del visitante',    'Conflictos, conmoción, riesgos para la integridad del turista',         true,  4),
  ('conectividad',   'Conectividad aérea',         'Nuevas rutas, cancelaciones, cierres de aeropuerto (DGAC)',             false, 5),
  ('eventos',        'Eventos y festividades',     'Ferias, festivales, congresos, fechas culturales',                      false, 6),
  ('financiamiento', 'Financiamiento y convocatorias', 'Fondos, licitaciones, cooperación (CAF, BID, PNUD)',               false, 7),
  ('mercados',       'Mercados y normativa',       'Demanda, tendencias, inversión, normas (Gaceta Oficial)',               false, 8);

INSERT INTO orbita.sources (codigo, nombre, institucion, url, tipo, metodo, categorias, frecuencia_minutos, semana_inicio, activa, notas) VALUES
  -- Semana 1
  ('senamhi_alertas', 'SENAMHI · alertas hidrológicas y meteorológicas', 'SENAMHI', 'https://senamhi.gob.bo',
     'oficial', 'apify', '{clima}', 30, 1, true, 'La página carga con JavaScript: usar Apify'),
  ('minsalud',        'Ministerio de Salud · comunicados y boletines epidemiológicos', 'Ministerio de Salud y Deportes', 'https://www.minsalud.gob.bo',
     'oficial', 'http_html', '{salud}', 60, 1, true, NULL),
  ('ops_alertas',     'OPS/OMS · alertas y actualizaciones epidemiológicas', 'OPS/OMS', 'https://www.paho.org/es/alertas-actualizaciones-epidemiologicas',
     'organismo_internacional', 'http_html', '{salud}', 180, 1, true, NULL),
  ('minculturas',     'Ministerio de Turismo y Culturas', 'Ministerio de Culturas, Descolonización y Despatriarcalización', 'https://www.minculturas.gob.bo',
     'oficial', 'http_html', '{eventos,mercados,financiamiento}', 180, 1, true, 'Verificar URL del ministerio vigente'),
  ('orbita',          'ORBITA', 'SDSN Bolivia', 'https://orbita.bo',
     'organismo_internacional', 'http_html', '{financiamiento,mercados}', 360, 1, true, NULL),
  -- Semanas 3–4 (inactivas hasta su alta)
  ('senamhi_noticias', 'SENAMHI · noticias', 'SENAMHI', 'https://senamhi.gob.bo',
     'oficial', 'apify', '{clima}', 180, 3, false, NULL),
  ('conoce_bolivia',  'Conoce Bolivia', 'Viceministerio de Turismo', 'https://conocebolivia.travel',
     'oficial', 'http_html', '{eventos}', 720, 3, false, 'Verificar URL'),
  ('caf',             'CAF · convocatorias', 'CAF', 'https://www.caf.com',
     'organismo_internacional', 'http_html', '{financiamiento}', 720, 3, false, NULL),
  ('bid',             'BID · adquisiciones y convocatorias', 'BID', 'https://www.iadb.org',
     'organismo_internacional', 'http_html', '{financiamiento}', 720, 3, false, NULL),
  ('pnud_licitaciones','PNUD · licitaciones', 'PNUD', 'https://procurement-notices.undp.org',
     'organismo_internacional', 'http_html', '{financiamiento}', 720, 3, false, 'Filtrar por país = Bolivia'),
  ('abc_caminos',     'ABC · transitabilidad de caminos', 'Administradora Boliviana de Carreteras', 'https://www.abc.gob.bo',
     'oficial', 'http_html', '{vial}', 30, 3, false, NULL),
  ('dgac',            'DGAC · aeropuertos y conectividad', 'Dirección General de Aeronáutica Civil', 'https://www.dgac.gob.bo',
     'oficial', 'http_html', '{conectividad}', 180, 3, false, NULL),
  ('gaceta_oficial',  'Gaceta Oficial de Bolivia', 'Gaceta Oficial del Estado Plurinacional', 'https://www.gacetaoficialdebolivia.gob.bo',
     'oficial', 'http_html', '{mercados}', 1440, 4, false, NULL),
  ('tavily',          'Tavily · búsqueda abierta', 'Tavily', 'https://api.tavily.com/search',
     'no_oficial', 'tavily', '{eventos,mercados,seguridad,conectividad}', 360, 4, false, 'Resultados no oficiales: siempre a revisión');

COMMIT;
