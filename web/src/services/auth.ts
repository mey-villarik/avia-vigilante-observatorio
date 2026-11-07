// Acceso con usuario (correo) y clave mediante Supabase Auth.
// El perfil (rol y cliente) sale de vigilante.users con la función vigilante.mi_perfil()
// (ver db/generico/03_acceso_web.sql). Quien no tiene una ficha activa no entra.
//
// En el navegador solo va la clave pública (anon / publishable). La service_role nunca.
import { createClient, type Session, type SupabaseClient } from '@supabase/supabase-js';
import type { Rol } from '../types';

const URL = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
const KEY = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();

/** true si la web tiene Supabase configurado (y por tanto exige login) */
export const accesoConfigurado = Boolean(URL && KEY);

/** Sin Supabase, solo en `npm run dev` se permite entrar sin login (para el programador). */
export const sinLoginPermitido = !accesoConfigurado && import.meta.env.DEV;

export const supabase: SupabaseClient | null = accesoConfigurado
  ? createClient(URL!, KEY!, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : null;

/** rol de la base → rol de la web */
const ROL_WEB: Record<string, Rol> = { administrador: 'admin', analista: 'analista', visor: 'visor' };
export const ROL_DB: Record<Rol, string> = { admin: 'administrador', analista: 'analista', visor: 'visor' };

export interface Perfil {
  id: string;
  nombre: string;
  email: string | null;
  rol: Rol;
  clienteId: string;
  clienteSlug: string;
  clienteNombre: string;
}

export async function leerPerfil(): Promise<Perfil | null> {
  if (!supabase) return null;
  const { data, error } = await supabase.schema('vigilante').rpc('mi_perfil');
  if (error) throw new Error(traducir(error.message));
  const p = (Array.isArray(data) ? data[0] : data) as Record<string, string> | undefined;
  if (!p) return null;
  return {
    id: p.id, nombre: p.nombre, email: p.email ?? null, rol: ROL_WEB[p.rol] ?? 'visor',
    clienteId: p.cliente_id, clienteSlug: p.cliente_slug, clienteNombre: p.cliente_nombre,
  };
}

export async function sesionActual(): Promise<Session | null> {
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session;
}

export async function entrar(email: string, clave: string): Promise<void> {
  if (!supabase) throw new Error('El acceso no está configurado.');
  const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: clave });
  if (error) throw new Error(traducir(error.message));
}

export async function salir(): Promise<void> {
  await supabase?.auth.signOut();
}

/** Envía el correo para crear una clave nueva. Vuelve a esta misma página. */
export async function recuperarClave(email: string): Promise<void> {
  if (!supabase) throw new Error('El acceso no está configurado.');
  const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: location.origin + location.pathname });
  if (error) throw new Error(traducir(error.message));
}

export async function cambiarClave(clave: string): Promise<void> {
  if (!supabase) throw new Error('El acceso no está configurado.');
  const { error } = await supabase.auth.updateUser({ password: clave });
  if (error) throw new Error(traducir(error.message));
}

/** Mensajes de Supabase en lenguaje claro */
export function traducir(m: string): string {
  const s = m.toLowerCase();
  if (s.includes('invalid login credentials')) return 'Correo o clave incorrectos.';
  if (s.includes('email not confirmed')) return 'Falta confirmar el correo. Revisa tu bandeja de entrada.';
  if (s.includes('rate limit') || s.includes('too many')) return 'Demasiados intentos. Espera unos minutos y vuelve a probar.';
  if (s.includes('password should be') || s.includes('weak')) return 'La clave es demasiado débil: usa al menos 8 caracteres.';
  if (s.includes('same password') || s.includes('different from the old')) return 'La clave nueva tiene que ser distinta de la anterior.';
  if (s.includes('failed to fetch') || s.includes('network')) return 'No hay conexión con el servidor de acceso.';
  if (s.includes('schema') && s.includes('vigilante')) return 'Supabase no expone el esquema vigilante (Settings → API → Exposed schemas).';
  if (s.includes('mi_perfil')) return 'Falta instalar db/generico/03_acceso_web.sql en Supabase.';
  return m;
}
