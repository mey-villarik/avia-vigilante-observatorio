// Estado de las señales en la base de datos (db/generico/04_sincronizar_vigilante.sql).
// El contenido de cada señal sigue llegando en vigilante.json; aquí se guarda y se lee
// lo que deciden las personas: en qué etapa está cada una y quién la movió.
import type { Etapa, Evento } from '../types';
import { STL } from '../data/demo';
import { supabase, traducir } from './auth';

/** Mismas reglas que vigilante.transicion_valida() en la base de datos */
const PASOS: Record<Etapa, Etapa[]> = {
  detectada: ['en_analisis'],
  en_analisis: ['en_verificacion', 'confirmada'],
  en_verificacion: ['confirmada', 'publicada'],
  confirmada: ['publicada', 'en_analisis'],
  publicada: ['en_verificacion', 'confirmada'],
  descartada: [],
};
export const transicionValida = (de: Etapa, a: Etapa) => de === a || a === 'descartada' || PASOS[de].includes(a);
export const siguientesPasos = (de: Etapa) => PASOS[de].map((e) => STL[e]).join(' o ') || 'ninguna';

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

/** la base usa también «cerrada», que la web muestra como publicada */
const aEtapa = (e: string): Etapa => (e === 'cerrada' ? 'publicada' : e) as Etapa;

export async function leerEstados(): Promise<Map<string, Etapa>> {
  const { data, error } = await rpc('estados_senales');
  if (error) throw new Error(traducir(error.message));
  return new Map((data as { codigo: string; estado: string }[] ?? []).map((r) => [r.codigo, aEtapa(r.estado)]));
}

export async function moverSenal(codigo: string, estado: Etapa, nota?: string): Promise<void> {
  const { error } = await rpc('mover_senal', { p_codigo: codigo, p_estado: estado, p_nota: nota || null });
  if (error) {
    const m = error.message;
    if (/aún no está en la base/.test(m)) throw new Error(`${codigo} aún no está en la base de datos: falta activar la sincronización en el VPS.`);
    throw new Error(traducir(m.replace(/_/g, ' ')));
  }
}

/** Las tres columnas de la pestaña Señales (pedido de Meysel, 19-11-2026) */
export type Columna = 'detectadas' | 'confirmadas' | 'publicadas';
export const COLUMNAS: [Columna, string, string][] = [
  ['detectadas', 'Detectadas', 'AVIA las encontró y las está evaluando'],
  ['confirmadas', 'Confirmadas', 'Listas para publicar. «Verificada» si las respalda una fuente oficial o 2 o más fuentes distintas; si no, «Sin verificar»'],
  ['publicadas', 'Publicadas', 'Ya salen en la web pública y en Telegram'],
];
/** columna en la que se ve cada etapa; descartadas no se muestra */
export function columnaDe(e: Etapa): Columna | null {
  if (e === 'detectada' || e === 'en_analisis' || e === 'en_verificacion') return 'detectadas';
  if (e === 'confirmada') return 'confirmadas';
  if (e === 'publicada') return 'publicadas';
  return null;
}

/** Destino de un pase: la etapa con la que se entra en cada columna */
export type Destino = 'en_analisis' | 'confirmada' | 'publicada';
export const DESTINO: Record<Columna, Destino> = { detectadas: 'en_analisis', confirmadas: 'confirmada', publicadas: 'publicada' };
const NUM: Record<Columna, number> = { detectadas: 1, confirmadas: 2, publicadas: 3 };

/**
 * Por qué una señal NO puede pasar a «a» (null = sí puede). Mismas reglas que
 * vigilante.pasar_senales() (db/generico/29_pase_en_bloque.sql): ya no hay aprobación
 * previa; solo un escenario nunca se publica.
 */
export function motivoNoPasa(s: { estado: Etapa; escenario?: boolean }, a: Destino): string | null {
  const col = columnaDe(s.estado);
  if (!col) return 'está descartada';
  if (col === columnaDe(a)) return 'ya está en esa columna';
  if (a === 'publicada' && s.escenario) return 'es un escenario: no se publica';
  return null;
}

export interface ResultadoPase { movidas: string[]; omitidas: { codigo: string; motivo: string }[] }

/** etapas que recorre una señal hasta «a», sin saltarse ninguna (en los dos sentidos) */
export function pasosHasta(de: Etapa, a: Destino): Etapa[] {
  const pasos: Etapa[] = [];
  let e = de;
  for (let i = 0; i < 4; i++) {
    const c = columnaDe(e), fin = columnaDe(a);
    if (!c || !fin || c === fin) break;
    e = NUM[c] < NUM[fin]
      ? (e === 'detectada' ? 'en_analisis' : c === 'detectadas' ? 'confirmada' : 'publicada')
      : (c === 'publicadas' ? 'confirmada' : 'en_analisis');
    pasos.push(e);
  }
  return pasos;
}

/**
 * Pasa varias señales a Confirmadas o Publicadas en una sola llamada.
 * Si la base aún no tiene el 29, las mueve una a una con mover_senal (mismo resultado, más lento).
 */
export async function pasarSenales(senales: { id: string; estado: Etapa }[], a: Destino, nota = 'Pase en bloque'): Promise<ResultadoPase> {
  const { data, error } = await rpc('pasar_senales', { p_codigos: senales.map((s) => s.id), p_a: a, p_nota: nota });
  if (!error) {
    const r = data as ResultadoPase;
    return { movidas: r?.movidas ?? [], omitidas: r?.omitidas ?? [] };
  }
  if (!(/pasar_senales/.test(error.message) && /(not find|no existe|does not exist|schema cache)/i.test(error.message))) {
    throw new Error(traducir(error.message.replace(/_/g, ' ')));
  }
  const res: ResultadoPase = { movidas: [], omitidas: [] };
  for (const s of senales) {
    try {
      for (const paso of pasosHasta(s.estado, a)) await moverSenal(s.id, paso, nota);
      res.movidas.push(s.id);
    } catch (e) {
      res.omitidas.push({ codigo: s.id, motivo: e instanceof Error ? e.message : String(e) });
    }
  }
  return res;
}

export interface Decision { ok: boolean; estado: Etapa | 'confirmada_publicada'; mensaje: string }

/** Aprobar (y publicar) o rechazar una señal que espera revisión (db/generico/18_aprobacion_analista.sql) */
export async function decidirSenal(codigo: string, aprobar: boolean, nota?: string): Promise<Decision> {
  const { data, error } = await rpc(aprobar ? 'aprobar_senal' : 'rechazar_senal', { p_codigo: codigo, p_nota: nota || null });
  if (error) {
    const m = error.message;
    if (/(aprobar|rechazar)_senal/.test(m) && /(not find|no existe|does not exist|schema cache)/i.test(m)) {
      throw new Error('falta ejecutar db/generico/18_aprobacion_analista.sql en Supabase.');
    }
    if (/aún no está en la base/.test(m)) throw new Error(`${codigo} aún no está en la base de datos.`);
    throw new Error(traducir(m.replace(/_/g, ' ')));
  }
  return data as Decision;
}

/** Movimientos hechos por personas, como eventos para la Bitácora */
export async function leerMovimientos(ahora = Date.now()): Promise<Evento[]> {
  const { data, error } = await rpc('movimientos_senales', { p_limite: 50 });
  if (error) throw new Error(traducir(error.message));
  return (data as { cuando: string; codigo: string; titulo: string; a: string; quien: string; nota: string | null }[] ?? []).map((m) => ({
    t: -Math.max(0, (ahora - Date.parse(m.cuando)) / 60000),
    k: 'check',
    w: `${m.quien} movió ${m.codigo} a «${STL[aEtapa(m.a)] ?? m.a}»`,
    d: m.titulo + (m.nota ? ` · Nota: ${m.nota}` : ''),
  }));
}

export interface VotoPublicacion { codigo: string; publicada_en: string | null; retirada_en: string | null; util: number; no_util: number }

/** Votos útil / no útil de cada señal publicada (vigilante.publicaciones, del 13) */
export async function leerVotos(): Promise<VotoPublicacion[]> {
  const { data, error } = await rpc('publicaciones');
  if (error) throw new Error(traducir(error.message));
  return ((data ?? []) as VotoPublicacion[]).map((v) => ({ ...v, util: Number(v.util) || 0, no_util: Number(v.no_util) || 0 }));
}
