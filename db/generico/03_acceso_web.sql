-- =============================================================================
-- AVIA Vigilante · Acceso a la web con usuario y clave (Supabase Auth)
-- Requiere 01_vigilante_schema.sql. Se ejecuta una vez en el SQL Editor de Supabase.
--
-- Cómo funciona:
--   * Las cuentas (correo + clave) viven en Supabase Auth (auth.users).
--   * El perfil (rol, cliente, activo) vive en vigilante.users. Solo entra a la
--     web quien tiene una ficha ACTIVA en vigilante.users enlazada a su cuenta.
--   * Una cuenta se enlaza sola con su ficha cuando el correo coincide.
--   * Los datos que genera Hermes (vigilante.json) se guardan en el bucket
--     privado `vigilante`, en la carpeta del cliente (<slug>/vigilante.json).
--     Solo los usuarios activos de ese cliente pueden leerlo.
--
-- En Supabase, además:
--   * Authentication → Sign In / Providers: desactivar «Allow new users to sign up»
--     (nadie puede crearse cuenta por su cuenta; las crea el administrador).
--   * Settings → API → Exposed schemas: añadir `vigilante`.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Perfil de quien ha iniciado sesión
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.mi_perfil()
RETURNS TABLE (id uuid, nombre text, email text, rol vigilante.rol_usuario,
               cliente_id uuid, cliente_slug text, cliente_nombre text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT u.id, u.nombre, u.email, u.rol, c.id, c.slug, c.nombre
    FROM vigilante.users u JOIN vigilante.clientes c ON c.id = u.cliente_id
   WHERE u.auth_user_id = auth.uid() AND u.activo AND c.activo
$$;
REVOKE ALL ON FUNCTION vigilante.mi_perfil() FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.mi_perfil() TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. Desde la web nadie toca el enlace con la cuenta de login
--    (solo service_role: la función crear-usuario o el enlace automático)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.tg_proteger_enlace_cuenta() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.auth_user_id := NULL;
    ELSIF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
      RAISE EXCEPTION 'El enlace con la cuenta de acceso no se cambia desde la web';
    END IF;
    -- un administrador no puede quitarse a sí mismo el rol ni desactivarse
    IF TG_OP = 'UPDATE' AND OLD.auth_user_id = auth.uid()
       AND (NEW.rol <> OLD.rol OR NOT NEW.activo) THEN
      RAISE EXCEPTION 'No puedes cambiar tu propio rol ni desactivarte';
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS a_proteger_enlace_cuenta ON vigilante.users;
CREATE TRIGGER a_proteger_enlace_cuenta BEFORE INSERT OR UPDATE ON vigilante.users
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_proteger_enlace_cuenta();

-- -----------------------------------------------------------------------------
-- 3. Enlace automático cuenta ↔ ficha por correo
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.enlazar_cuenta(p_auth_id uuid, p_email text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF p_email IS NULL OR EXISTS (SELECT 1 FROM vigilante.users WHERE auth_user_id = p_auth_id) THEN
    RETURN;
  END IF;
  -- solo si el correo pertenece a una única ficha sin enlazar
  IF (SELECT count(*) FROM vigilante.users WHERE lower(email) = lower(p_email) AND auth_user_id IS NULL) = 1 THEN
    UPDATE vigilante.users SET auth_user_id = p_auth_id
     WHERE lower(email) = lower(p_email) AND auth_user_id IS NULL;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.enlazar_cuenta(uuid, text) FROM public, anon, authenticated;

-- al crear una ficha con un correo que ya tiene cuenta
CREATE OR REPLACE FUNCTION vigilante.tg_enlazar_ficha() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_auth uuid;
BEGIN
  IF NEW.auth_user_id IS NULL AND NEW.email IS NOT NULL AND to_regclass('auth.users') IS NOT NULL THEN
    EXECUTE 'SELECT id FROM auth.users WHERE lower(email) = lower($1) LIMIT 1' INTO v_auth USING NEW.email;
    IF v_auth IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vigilante.users WHERE auth_user_id = v_auth) THEN
      NEW.auth_user_id := v_auth;
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS b_enlazar_ficha ON vigilante.users;
CREATE TRIGGER b_enlazar_ficha BEFORE INSERT ON vigilante.users
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_enlazar_ficha();

-- al crear una cuenta (o cambiar su correo) con una ficha ya preparada
DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE NOTICE 'auth.users no existe (no es Supabase): se omite el enlace automático desde las cuentas';
    RETURN;
  END IF;

  CREATE OR REPLACE FUNCTION vigilante.tg_cuenta_nueva() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $f$
  BEGIN
    PERFORM vigilante.enlazar_cuenta(NEW.id, NEW.email);
    RETURN NEW;
  END $f$;

  DROP TRIGGER IF EXISTS vigilante_enlazar_cuenta ON auth.users;
  CREATE TRIGGER vigilante_enlazar_cuenta AFTER INSERT OR UPDATE OF email ON auth.users
    FOR EACH ROW EXECUTE FUNCTION vigilante.tg_cuenta_nueva();

  -- enlazar las cuentas que ya existan
  PERFORM vigilante.enlazar_cuenta(a.id, a.email) FROM auth.users a;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Datos de Hermes en almacenamiento privado
--    Hermes sube <slug-del-cliente>/vigilante.json con service_role.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'storage no existe (no es Supabase): se omite el bucket privado';
    RETURN;
  END IF;

  INSERT INTO storage.buckets (id, name, public) VALUES ('vigilante', 'vigilante', false)
  ON CONFLICT (id) DO UPDATE SET public = false;

  DROP POLICY IF EXISTS vigilante_lee_su_cliente ON storage.objects;
  CREATE POLICY vigilante_lee_su_cliente ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'vigilante'
           AND (storage.foldername(name))[1] = (SELECT slug FROM vigilante.clientes WHERE id = vigilante.cliente_actual()));
END $$;

COMMIT;
