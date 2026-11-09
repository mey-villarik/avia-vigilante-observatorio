# Acceso con usuario y clave

La web del Vigilante solo deja entrar a personas dadas de alta. Cada una entra con su **correo** (usuario) y su **clave**, y ve y hace lo que permite su perfil:

| Perfil | Qué puede hacer |
| --- | --- |
| Visor | Consultar panorama, señales, oportunidades y bitácora |
| Analista | Lo anterior, y además verificar y decidir sobre señales |
| Administrador | Lo anterior, y además gestionar fuentes y el equipo (altas, bajas, perfiles, claves) |

## Cómo funciona

- Las cuentas y claves las guarda **Supabase Auth** (cifradas; nadie, ni el administrador, puede verlas).
- El perfil de cada persona está en la tabla `vigilante.users` (rol, cliente, activo). Quien tiene cuenta pero no tiene ficha activa ve «Sin acceso».
- El registro libre está desactivado: solo el administrador da de alta.
- Los datos de Hermes (`vigilante.json`) pasan a un almacenamiento privado de Supabase. Solo los puede leer quien tiene sesión y perfil activo. Mientras no se cierre la ruta pública del VPS (paso 6), los datos siguen siendo visibles para quien conozca esa URL.
- Si un administrador quita el acceso a alguien, esa persona queda fuera en menos de 5 minutos.

## Puesta en marcha (una sola vez)

Proyecto de Supabase: `acgidbtnbwtorzubcgtc`.

1. **Base de datos.** En Supabase → SQL Editor, ejecutar en orden (si el esquema `vigilante` no existe ya):
   - `db/generico/01_vigilante_schema.sql`
   - `db/generico/02_cliente_orbita_bolivia.sql`
   - `db/generico/03_acceso_web.sql` (este se puede repetir sin problema)
2. **Exponer el esquema.** Settings → API → Exposed schemas: añadir `vigilante`.
3. **Cerrar el registro libre.** Authentication → Sign In / Providers → desactivar «Allow new users to sign up». En Authentication → URL Configuration, poner la dirección de la web en «Site URL» y añadirla (y `http://localhost:5173`) en «Redirect URLs», para que funcionen los correos de invitación y de recuperar clave.
4. **Primer administrador.** Authentication → Users → Add user → correo y clave, marcando «Auto Confirm User». Después, en el SQL Editor:

   ```sql
   insert into vigilante.users (cliente_id, nombre, email, rol)
   select id, 'Tu nombre', 'tu@correo.com', 'administrador'
   from vigilante.clientes where slug = 'orbita-bolivia';
   ```

   La ficha se enlaza sola con la cuenta porque el correo coincide.
5. **Función para crear cuentas desde la web** (para que el administrador dé de alta sin entrar a Supabase). Con la [CLI de Supabase](https://supabase.com/docs/guides/cli):

   ```bash
   supabase login
   supabase functions deploy crear-usuario --project-ref acgidbtnbwtorzubcgtc
   ```

   Sin esta función, la web crea la ficha y avisa de que la cuenta hay que crearla a mano en Authentication → Users (con el mismo correo; se enlaza sola).
6. **Datos privados en el VPS.** Copiar `integraciones/hermes-web/subir_vigilante_json.sh` al VPS, crear `/etc/avia/supabase.env` (permisos 600) con `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` y `VIGILANTE_CLIENTE=orbita-bolivia`, y programarlo cada 5 minutos con cron (instrucciones en el propio script). Cuando la web ya lea del almacenamiento privado, cerrar la ruta pública en nginx:

   ```nginx
   location /data/ { return 404; }
   ```

   y dejar `VITE_DATA_URL=` vacío en la web.
7. **Web.** En `web/.env` (y en las variables del hosting cuando se publique):

   ```
   VITE_SUPABASE_URL=https://acgidbtnbwtorzubcgtc.supabase.co
   VITE_SUPABASE_ANON_KEY=<clave anon o publishable>
   ```

   La clave **anon / publishable** es pública por diseño y puede ir en la web. La **service_role** nunca: solo en el VPS (paso 6) y dentro de Supabase.

## Para el programador

- Sin `VITE_SUPABASE_URL` ni `VITE_SUPABASE_ANON_KEY`, `npm run dev` entra sin login y muestra el selector «Entrar como» para probar perfiles. Una versión publicada sin esas variables muestra «Acceso no configurado» y no deja entrar.
- Código: `web/src/services/auth.ts` (sesión y perfil), `web/src/components/Acceso.tsx` (pantallas de acceso), `web/src/services/equipo.ts` y `web/src/components/Equipo.tsx` (gestión del equipo), `supabase/functions/crear-usuario` (cuentas), `db/generico/03_acceso_web.sql` (enlace cuenta–ficha, reglas y almacenamiento privado).
- Las reglas de la base (RLS) son las que protegen de verdad: ocultar un botón en la web no basta, por eso cada permiso se comprueba también en Supabase.
