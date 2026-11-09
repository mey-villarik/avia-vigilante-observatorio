// Lo que guardan el recolector y AVIA directamente en la base (db/generico/14_recolector_mcp.sql).
// - vigilante_bd(): fuentes leídas por el recolector y señales con el mismo formato que vigilante.json.
//   La web lo mezcla con el archivo del VPS; cuando el archivo deje de existir, lo usa solo.
// - Propuestas de AVIA sobre cómo leer una fuente: el administrador las aprueba o las rechaza.
import type { DatosVps, VigilanteJson } from './datos';
import { supabase, traducir } from './auth';
import type { Fuente, Senal } from '../types';

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

const falta14 = (m: string, fn: string) => new RegExp(fn).test(m) && /(not find|no existe|does not exist|schema cache)/i.test(m);

/** null si la base aún no tiene el 14 o no hay sesión */
export async function leerVigilanteBd(): Promise<VigilanteJson | null> {
  if (!supabase) return null;
  const { data, error } = await rpc('vigilante_bd');
  if (error) {
    if (!falta14(error.message, 'vigilante_bd')) console.warn('vigilante_bd:', error.message);
    return null;
  }
  return (data as VigilanteJson) ?? null;
}

/**
 * Junta lo del archivo con lo de la base:
 *  - señales: se añaden las que solo están en la base (las que guardó AVIA por el MCP);
 *  - fuentes: si el recolector la leyó después que el archivo, manda lo del recolector.
 */
export function mezclarBd(archivo: DatosVps, bd: DatosVps): DatosVps {
  const ids = new Set(archivo.senales.map((s) => s.id));
  const nuevas: Senal[] = bd.senales.filter((s) => !ids.has(s.id));
  const porId = new Map(bd.fuentes.map((f) => [f.id, f]));
  const usadas = new Set<string>();
  const fuentes: Fuente[] = archivo.fuentes.map((f) => {
    const b = porId.get(f.id);
    if (!b) return f;
    usadas.add(f.id);
    // «last» = minutos desde la última comprobación: menos = más reciente
    return (b.last ?? Infinity) <= (f.last ?? Infinity)
      ? { ...f, estado: b.estado, info: b.info, items: b.items, hist: b.hist.length ? b.hist : f.hist, last: b.last, metodo: b.metodo }
      : f;
  });
  bd.fuentes.forEach((f) => { if (!usadas.has(f.id)) fuentes.push(f); });
  return {
    ...archivo,
    fuentes,
    senales: [...nuevas, ...archivo.senales].sort((a, b) => a.min - b.min),
    noticiasRevisadas: archivo.noticiasRevisadas ?? bd.noticiasRevisadas,
  };
}

export interface Propuesta {
  id: number; codigo: string; nombre: string; metodo_actual: string; metodo_propuesto: string;
  config: Record<string, unknown>; motivo: string; estado: 'pendiente' | 'aprobada' | 'rechazada';
  propuesta_en: string; decidida_por: string | null; decidida_en: string | null; nota: string | null;
}

export async function leerPropuestas(): Promise<Propuesta[]> {
  if (!supabase) return [];
  const { data, error } = await rpc('propuestas_web');
  if (error) return [];
  return (data as Propuesta[]) ?? [];
}

export async function decidirPropuesta(id: number, aprobar: boolean, nota?: string): Promise<void> {
  const { error } = await rpc('decidir_propuesta', { p_id: id, p_aprobar: aprobar, p_nota: nota || null });
  if (error) {
    if (falta14(error.message, 'decidir_propuesta')) throw new Error('falta ejecutar db/generico/14_recolector_mcp.sql en Supabase.');
    throw new Error(traducir(error.message));
  }
}
