-- =============================================================================
-- AVIA Vigilante · Fuentes: «Reconocer problema» guardado y cambios en la Bitácora
-- Requiere 01, 03, 06, 07, 08 y 09. Se puede ejecutar más de una vez.
--
--   * vigilante.reconocer_fuente(codigo, nota) → analista o administrador. Queda guardado
--     quién y cuándo, y todo el equipo lo ve. Se borra solo cuando la fuente vuelve a OK.
--   * vigilante.source_events: cada cambio que hace una PERSONA en una fuente (alta, edición,
--     pausa, reactivación, aprobación, eliminación, recuperación, reconocimiento).
--     Lo rellena un disparador; los cambios de la sincronización con Hermes no se apuntan.
--   * vigilante.bitacora_fuentes(limite) → la web lo muestra en la Bitácora.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS vigilante.source_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id  uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  source_id   integer REFERENCES vigilante.sources(id) ON DELETE SET NULL,
  codigo      text NOT NULL,
  nombre      text NOT NULL,
  accion      text NOT NULL CHECK (accion IN ('alta', 'editada', 'pausada', 'reactivada', 'aprobada',
                                              'eliminada', 'recuperada', 'reconocida')),
  quien       text NOT NULL,
  detalle     text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS source_events_cliente_idx ON vigilante.source_events (cliente_id, created_at DESC);
ALTER TABLE vigilante.source_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS equipo_lee ON vigilante.source_events;
CREATE POLICY equipo_lee ON vigilante.source_events FOR SELECT TO authenticated
  USING (cliente_id = vigilante.cliente_actual());
REVOKE ALL ON vigilante.source_events FROM anon, authenticated;
GRANT SELECT ON vigilante.source_events TO authenticated;
GRANT ALL ON vigilante.source_events TO service_role;

-- Apunta lo que hace una persona (con sesión en la web); ignora a Hermes y al sistema
CREATE OR REPLACE FUNCTION vigilante.tg_bitacora_fuente()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_quien text; v_accion text; v_detalle text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();
  IF v_quien IS NULL THEN RETURN NULL; END IF;

  IF TG_OP = 'INSERT' THEN
    v_accion := 'alta'; v_detalle := NEW.url;
  ELSIF OLD.eliminada_en IS NULL AND NEW.eliminada_en IS NOT NULL THEN
    v_accion := 'eliminada';
  ELSIF OLD.eliminada_en IS NOT NULL AND NEW.eliminada_en IS NULL THEN
    v_accion := 'recuperada'; v_detalle := NEW.url;
  ELSIF NOT OLD.activa AND NEW.activa THEN
    v_accion := CASE WHEN OLD.config ? 'propuesta_avia' THEN 'aprobada' ELSE 'reactivada' END;
  ELSIF OLD.activa AND NOT NEW.activa THEN
    v_accion := 'pausada';
  ELSIF (NEW.config ->> 'reconocida_en') IS DISTINCT FROM (OLD.config ->> 'reconocida_en') AND NEW.config ? 'reconocida_en' THEN
    v_accion := 'reconocida'; v_detalle := nullif(NEW.config ->> 'reconocida_nota', '');
  ELSIF (NEW.nombre, NEW.url, NEW.tipo, NEW.metodo, NEW.categorias, NEW.frecuencia_minutos,
         NEW.config -> 'que_buscar', NEW.config -> 'palabras_clave')
        IS DISTINCT FROM
        (OLD.nombre, OLD.url, OLD.tipo, OLD.metodo, OLD.categorias, OLD.frecuencia_minutos,
         OLD.config -> 'que_buscar', OLD.config -> 'palabras_clave') THEN
    v_accion := 'editada';
    v_detalle := concat_ws(', ',
      CASE WHEN NEW.nombre <> OLD.nombre THEN 'nombre' END,
      CASE WHEN NEW.url <> OLD.url THEN 'dirección' END,
      CASE WHEN NEW.metodo <> OLD.metodo THEN 'cómo se lee' END,
      CASE WHEN NEW.frecuencia_minutos <> OLD.frecuencia_minutos THEN 'frecuencia' END,
      CASE WHEN NEW.categorias <> OLD.categorias THEN 'canal' END,
      CASE WHEN NEW.tipo <> OLD.tipo THEN 'tipo' END,
      CASE WHEN (NEW.config -> 'que_buscar') IS DISTINCT FROM (OLD.config -> 'que_buscar') THEN 'qué buscar' END,
      CASE WHEN (NEW.config -> 'palabras_clave') IS DISTINCT FROM (OLD.config -> 'palabras_clave') THEN 'palabras clave' END);
  ELSE
    RETURN NULL;
  END IF;

  INSERT INTO vigilante.source_events (cliente_id, source_id, codigo, nombre, accion, quien, detalle)
  VALUES (NEW.cliente_id, NEW.id, NEW.codigo, NEW.nombre, v_accion, v_quien, v_detalle);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS z_bitacora_fuente ON vigilante.sources;
CREATE TRIGGER z_bitacora_fuente AFTER INSERT OR UPDATE ON vigilante.sources
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_bitacora_fuente();

-- Cuando la fuente vuelve a OK, el reconocimiento ya no hace falta
CREATE OR REPLACE FUNCTION vigilante.tg_limpiar_reconocimiento()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.config ? 'reconocida_en' AND upper(coalesce(NEW.config ->> 'estado', '')) = 'OK'
     AND upper(coalesce(OLD.config ->> 'estado', '')) <> 'OK' THEN
    NEW.config := NEW.config - 'reconocida_por' - 'reconocida_en' - 'reconocida_nota';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS c_limpiar_reconocimiento ON vigilante.sources;
CREATE TRIGGER c_limpiar_reconocimiento BEFORE UPDATE ON vigilante.sources
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_limpiar_reconocimiento();

-- Reconocer un problema (analista o administrador). SECURITY DEFINER porque la tabla
-- solo la escribe el administrador; aquí solo se tocan las marcas de reconocimiento.
CREATE OR REPLACE FUNCTION vigilante.reconocer_fuente(p_codigo text, p_nota text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede reconocer problemas'; END IF;
  UPDATE vigilante.sources SET config = config || jsonb_build_object(
           'reconocida_por', (SELECT nombre FROM vigilante.users WHERE id = vigilante.usuario_actual()),
           'reconocida_en', now(),
           'reconocida_nota', nullif(trim(coalesce(p_nota, '')), ''))
   WHERE cliente_id = vigilante.cliente_actual() AND codigo = p_codigo AND eliminada_en IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'La fuente % aún no está en la base de datos', p_codigo; END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.reconocer_fuente(text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.reconocer_fuente(text, text) TO authenticated;

-- Bitácora de fuentes para la web
CREATE OR REPLACE FUNCTION vigilante.bitacora_fuentes(p_limite int DEFAULT 50)
RETURNS TABLE (cuando timestamptz, codigo text, nombre text, accion text, quien text, detalle text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT created_at, codigo, nombre, accion, quien, detalle FROM vigilante.source_events
   WHERE cliente_id = vigilante.cliente_actual()
   ORDER BY created_at DESC
   LIMIT least(greatest(p_limite, 1), 200)
$$;
REVOKE ALL ON FUNCTION vigilante.bitacora_fuentes(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.bitacora_fuentes(int) TO authenticated;

-- La web: añade quién reconoció el problema y cuándo
DROP FUNCTION IF EXISTS vigilante.fuentes_web();
CREATE FUNCTION vigilante.fuentes_web()
RETURNS TABLE (codigo text, nombre text, url text, tipo vigilante.tipo_fuente, metodo vigilante.metodo_fuente,
               categorias text[], frecuencia_minutos int, activa boolean, ultima_consulta_en timestamptz,
               que_buscar text, alta_por text, eliminada boolean, palabras_clave text[],
               creada_en timestamptz, editada_por text, editada_en timestamptz,
               propuesta boolean, errores_seguidos int, ultimo_exito_en timestamptz, ultimo_error text,
               reconocida_por text, reconocida_en timestamptz, reconocida_nota text)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
  SELECT codigo, nombre, url, tipo, metodo, categorias, frecuencia_minutos, activa, ultima_consulta_en,
         config ->> 'que_buscar', config ->> 'alta_por', eliminada_en IS NOT NULL,
         CASE WHEN jsonb_typeof(config -> 'palabras_clave') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(config -> 'palabras_clave')) ELSE '{}'::text[] END,
         created_at, config ->> 'editada_por', (config ->> 'editada_en')::timestamptz,
         coalesce((config ->> 'propuesta_avia')::boolean, false), errores_seguidos, ultimo_exito_en, ultimo_error,
         config ->> 'reconocida_por', (config ->> 'reconocida_en')::timestamptz, config ->> 'reconocida_nota'
    FROM vigilante.sources WHERE cliente_id = vigilante.cliente_actual()
$$;
GRANT EXECUTE ON FUNCTION vigilante.fuentes_web() TO authenticated;

COMMIT;
