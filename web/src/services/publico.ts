// Web pública: alertas que una persona del equipo publicó desde el panel.
// Se lee sin iniciar sesión con la clave pública (anon / publishable) y la función
// vigilante.alertas_publicas (ver db/generico/13_publicar_senales.sql).
import { createClient } from '@supabase/supabase-js';
import type { Naturaleza } from '../types';
import { SENALES_DEMO, catName } from '../data/demo';

const URL = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
const KEY = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();
export const CLIENTE = ((import.meta.env.VITE_CLIENTE_PUBLICO as string | undefined)?.trim()) || 'orbita-bolivia';

const sb = URL && KEY ? createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } }) : null;

export interface AlertaPublica {
  id: number;
  codigo: string;
  titulo: string;
  texto: string;
  importancia: string | null;
  recomendacion: string | null;
  enlace: string | null;
  verificacion: 'confirmada' | 'en_verificacion';
  naturaleza: Naturaleza;
  categoria: string;
  categoria_nombre: string | null;
  prioridad: 'baja' | 'media' | 'alta';
  deps: string[];
  destinos: string[];
  plazo_hasta: string | null;
  publicada_en: string;
  util: number;
  no_util: number;
}

export interface Publicas {
  nombre: string;
  telegramUrl: string | null;
  alertas: AlertaPublica[];
  ejemplo: boolean;
}

function demo(): Publicas {
  const ahora = Date.now();
  return {
    nombre: 'Observatorio (ejemplo)',
    telegramUrl: null,
    ejemplo: true,
    alertas: SENALES_DEMO.filter((s) => s.estado === 'publicada' || s.estado === 'confirmada').map((s, i) => ({
      id: -(i + 1), codigo: s.id, titulo: s.titulo, texto: s.resumen, importancia: s.importancia || null,
      recomendacion: s.soluciones[0]?.t ?? null, enlace: null,
      verificacion: s.estado === 'publicada' ? 'confirmada' : 'en_verificacion',
      naturaleza: s.naturaleza, categoria: s.categoria, categoria_nombre: catName(s.categoria), prioridad: s.prioridad,
      deps: s.deps, destinos: s.destinos,
      plazo_hasta: s.plazo != null ? new Date(ahora + s.plazo * 864e5).toISOString() : null,
      publicada_en: new Date(ahora - s.min * 6e4).toISOString(), util: 0, no_util: 0,
    })),
  };
}

export async function leerPublicas(): Promise<Publicas> {
  if (!sb) return demo();
  const { data, error } = await sb.schema('vigilante').rpc('alertas_publicas', { p_cliente: CLIENTE });
  if (error) throw new Error(error.message);
  const d = (data ?? {}) as { nombre?: string; telegram_url?: string | null; alertas?: AlertaPublica[] };
  return {
    nombre: d.nombre || 'Observatorio',
    telegramUrl: d.telegram_url || null,
    ejemplo: false,
    alertas: (d.alertas ?? []).map((a) => ({ ...a, deps: a.deps ?? [], destinos: a.destinos ?? [] })),
  };
}

/** Identificador anónimo de este navegador (solo para no contar dos veces el mismo voto) */
function visitante(): string {
  try {
    let v = localStorage.getItem('avia-visitante');
    if (!v) { v = crypto.randomUUID(); localStorage.setItem('avia-visitante', v); }
    return v;
  } catch {
    return 'sin-almacenamiento-' + Math.random().toString(36).slice(2);
  }
}

export function votoGuardado(id: number): boolean | null {
  try { const v = localStorage.getItem('avia-voto-' + id); return v == null ? null : v === '1'; } catch { return null; }
}

export async function votar(id: number, util: boolean): Promise<void> {
  if (sb && id > 0) {
    const { error } = await sb.schema('vigilante').rpc('votar_alerta', { p_alerta: id, p_util: util, p_visitante: visitante() });
    if (error) throw new Error(error.message);
  }
  try { localStorage.setItem('avia-voto-' + id, util ? '1' : '0'); } catch { /* sin almacenamiento */ }
}
