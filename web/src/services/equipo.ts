// Gestión del equipo (solo administradores). Las reglas de la base (RLS) limitan
// cada administrador a las personas de su propio cliente.
// Crear la cuenta de acceso (correo + clave) necesita la función de Supabase
// `crear-usuario` (supabase/functions/crear-usuario), porque requiere la service_role,
// que nunca va en el navegador.
import type { Rol } from '../types';
import { ROL_DB, supabase, traducir, type Perfil } from './auth';

export interface Persona {
  id: string;
  nombre: string;
  email: string | null;
  rol: Rol;
  activo: boolean;
  conCuenta: boolean;
}

const ROL_WEB: Record<string, Rol> = { administrador: 'admin', analista: 'analista', visor: 'visor' };

const tabla = () => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').from('users');
};

export async function listarEquipo(): Promise<Persona[]> {
  const { data, error } = await tabla().select('id, nombre, email, rol, activo, auth_user_id').order('nombre');
  if (error) throw new Error(traducir(error.message));
  return (data ?? []).map((u) => ({
    id: u.id as string, nombre: u.nombre as string, email: (u.email as string | null) ?? null,
    rol: ROL_WEB[u.rol as string] ?? 'visor', activo: Boolean(u.activo), conCuenta: Boolean(u.auth_user_id),
  }));
}

export async function actualizarPersona(id: string, cambios: { rol?: Rol; activo?: boolean }): Promise<void> {
  const fila: Record<string, unknown> = {};
  if (cambios.rol) fila.rol = ROL_DB[cambios.rol];
  if (cambios.activo !== undefined) fila.activo = cambios.activo;
  const { error } = await tabla().update(fila).eq('id', id);
  if (error) throw new Error(traducir(error.message));
}

/** Llama a la función crear-usuario. Sin clave, Supabase envía una invitación por correo. */
async function funcion(cuerpo: Record<string, unknown>): Promise<void> {
  if (!supabase) throw new Error('El acceso no está configurado.');
  // Se prueban los dos nombres: «crear_usuario» (como lo guarda el panel de Supabase) y «crear-usuario».
  // Si la función no existe, el navegador a veces ve un fallo de conexión (la comprobación previa da 404)
  // en lugar de un 404, así que cualquier error sin respuesta propia pasa al otro nombre.
  const sinRespuestaPropia = (e: unknown) => { const c = (e as { context?: Response })?.context; return !c || c.status === 404; };
  let { data, error } = await supabase.functions.invoke('crear_usuario', { body: cuerpo });
  if (error && sinRespuestaPropia(error)) {
    const alt = await supabase.functions.invoke('crear-usuario', { body: cuerpo });
    if (!(alt.error && sinRespuestaPropia(alt.error))) ({ data, error } = alt);
  }
  if (error) {
    // el detalle viene en el cuerpo de la respuesta
    let msg = error.message;
    const ctx = (error as { context?: Response }).context;
    let texto = '';
    try { texto = (await ctx?.clone().text()) ?? ''; } catch { /* sin cuerpo */ }
    let propio = '';
    try { propio = JSON.parse(texto)?.error ?? ''; } catch { /* no es JSON */ }
    if (propio) msg = propio;
    else if (ctx?.status === 404) msg = 'Supabase no encuentra la función crear-usuario (ni crear_usuario)';
    else if (!ctx) msg = 'no se pudo conectar con la función de Supabase (¿el código pegado es el de index.ts?)';
    else msg = `la función respondió ${ctx.status}: ${texto.slice(0, 160) || error.message}`;
    throw new Error(msg);
  }
  if (data?.error) throw new Error(String(data.error));
}

export interface Alta { nombre: string; email: string; rol: Rol; clave: string }

/**
 * Da de alta a una persona: crea su ficha (rol y cliente) y su cuenta de acceso.
 * Devuelve un aviso si la ficha se creó pero la cuenta no (función sin desplegar).
 */
export async function altaPersona(a: Alta, yo: Perfil): Promise<string | null> {
  const email = a.email.trim().toLowerCase();
  const { error } = await tabla().insert({ cliente_id: yo.clienteId, nombre: a.nombre.trim(), email, rol: ROL_DB[a.rol] });
  if (error) {
    if (error.code === '23505') throw new Error('Ya hay una persona con ese correo.');
    throw new Error(traducir(error.message));
  }
  try {
    await funcion({ accion: 'crear', email, clave: a.clave || undefined });
    return null;
  } catch (e) {
    const m = e instanceof Error ? e.message : String(e);
    return `La ficha está creada, pero no la cuenta de acceso (${m}). Créala en Supabase → Authentication → Add user con el mismo correo: se enlaza sola.`;
  }
}

/** Crea la cuenta de acceso de una ficha que aún no la tiene. Sin clave, envía invitación. */
export async function crearCuenta(email: string, clave?: string): Promise<void> {
  await funcion({ accion: 'crear', email: email.trim().toLowerCase(), clave: clave || undefined });
}

export async function ponerClave(email: string, clave: string): Promise<void> {
  await funcion({ accion: 'clave', email: email.trim().toLowerCase(), clave });
}
