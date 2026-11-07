// Función de Supabase (Edge Function) «crear-usuario».
// La web la llama desde la ficha Equipo. Solo la puede usar un administrador activo,
// y solo para personas de su mismo cliente que ya tengan ficha en vigilante.users.
//
//   POST { accion: 'crear', email, clave? }  → crea la cuenta (con clave) o envía invitación (sin clave)
//   POST { accion: 'clave', email, clave }   → pone una clave nueva a una cuenta existente
//
// Usa la service_role, que Supabase da a la función como variable de entorno.
// Nunca sale de aquí ni va en el navegador.
//
// Despliegue:  supabase functions deploy crear-usuario --project-ref <ref>
import { createClient } from 'npm:@supabase/supabase-js@2.99.3';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'Método no permitido' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return responder({ error: 'Falta la sesión' }, 401);

  // 1. ¿Quién llama? Debe ser administrador activo.
  const comoUsuario = createClient(url, anon, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: perfiles, error: ePerfil } = await comoUsuario.schema('vigilante').rpc('mi_perfil');
  const yo = Array.isArray(perfiles) ? perfiles[0] : perfiles;
  if (ePerfil || !yo) return responder({ error: 'Sin perfil activo' }, 403);
  if (yo.rol !== 'administrador') return responder({ error: 'Solo un administrador puede gestionar cuentas' }, 403);

  let body: { accion?: string; email?: string; clave?: string };
  try { body = await req.json(); } catch { return responder({ error: 'Cuerpo no válido' }, 400); }
  const email = (body.email ?? '').trim().toLowerCase();
  const clave = body.clave ?? '';
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return responder({ error: 'Correo no válido' }, 400);
  if (clave && clave.length < 8) return responder({ error: 'La clave necesita al menos 8 caracteres' }, 400);

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  // 2. La persona tiene que tener ficha en el cliente del administrador.
  const { data: fichas, error: eFicha } = await admin.schema('vigilante').from('users')
    .select('id, auth_user_id').eq('cliente_id', yo.cliente_id).ilike('email', email).limit(1);
  if (eFicha) return responder({ error: eFicha.message }, 500);
  const ficha = fichas?.[0];
  if (!ficha) return responder({ error: 'Esa persona no tiene ficha en tu equipo' }, 404);

  if (body.accion === 'clave') {
    if (!clave) return responder({ error: 'Falta la clave' }, 400);
    if (!ficha.auth_user_id) return responder({ error: 'Esa persona aún no tiene cuenta de acceso' }, 409);
    const { error } = await admin.auth.admin.updateUserById(ficha.auth_user_id, { password: clave });
    return error ? responder({ error: error.message }, 400) : responder({ ok: true });
  }

  if (body.accion !== 'crear') return responder({ error: 'Acción no reconocida' }, 400);
  if (ficha.auth_user_id) return responder({ ok: true, aviso: 'Ya tenía cuenta: puede entrar con su clave' });

  const origen = req.headers.get('origin') ?? undefined;
  const r = clave
    ? await admin.auth.admin.createUser({ email, password: clave, email_confirm: true })
    : await admin.auth.admin.inviteUserByEmail(email, { redirectTo: origen });
  if (r.error) return responder({ error: r.error.message }, 400);

  // el disparador de la base ya enlaza por correo; esto lo asegura
  const id = r.data.user?.id;
  if (id) await admin.schema('vigilante').from('users').update({ auth_user_id: id }).eq('id', ficha.id).is('auth_user_id', null);
  return responder({ ok: true });
});
