// Lo que guardan el recolector y AVIA directamente en la base (db/generico/14_recolector_mcp.sql).
// - vigilante_bd(): fuentes del catálogo, señales (mismo formato que vigilante.json) y oportunidades.
//   Desde el 15 es la fuente principal de la web; el archivo del VPS solo se usa si la base no tiene datos.
// - Propuestas de AVIA sobre cómo leer una fuente: el administrador las aprueba o las rechaza.
// - Fuentes candidatas (no se vigilan hasta que un administrador las aprueba) y oportunidades (15).
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
 * (Ya no se usa en la carga normal: se conserva por si hace falta comparar archivo y base.)
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

// ---------------------------------------------------------------------------
// Fuentes candidatas y oportunidades (db/generico/15_catalogo_versiones_analisis.sql)
// ---------------------------------------------------------------------------
const falta15 = (m: string, fn: string) => falta14(m, fn) ? new Error('falta ejecutar db/generico/15_catalogo_versiones_analisis.sql en Supabase.') : null;

export interface Evidencia { id: number; titulo: string | null; url: string; fuente?: string }

/** Fuente que AVIA o la sincronización vieron y que no está en el catálogo: no se vigila hasta que un administrador la aprueba */
export interface Candidata {
  id: number; nombre: string; url: string; motivo: string | null; propuesta_por: string; veces: number;
  evidencia: Evidencia[]; estado: 'pendiente' | 'aprobada' | 'rechazada'; propuesta_en: string;
  decidida_por: string | null; decidida_en: string | null; nota: string | null; codigo: string | null;
}

export async function leerCandidatas(): Promise<Candidata[]> {
  if (!supabase) return [];
  const { data, error } = await rpc('candidatas_web');
  if (error) return [];
  return (data as Candidata[]) ?? [];
}

export interface AltaCandidata { categoria?: string; tipo?: string; metodo?: string; frecuencia?: number }

/** aprobar = crear la fuente en el catálogo (empieza a vigilarse en la próxima ronda); devuelve su código */
export async function decidirCandidata(id: number, aprobar: boolean, nota?: string, alta: AltaCandidata = {}): Promise<string | null> {
  const { data, error } = await rpc('decidir_candidata', {
    p_id: id, p_aprobar: aprobar, p_nota: nota || null,
    p_categoria: alta.categoria ?? 'mercado', p_tipo: alta.tipo ?? null,
    p_metodo: alta.metodo ?? 'http_html', p_frecuencia: alta.frecuencia ?? 60,
  });
  if (error) throw falta15(error.message, 'decidir_candidata') ?? new Error(traducir(error.message));
  return (data as string | null) ?? null;
}

export type EstadoOportunidad = 'propuesta' | 'validada' | 'descartada';

/** Oportunidad separada en hecho (lo que dice la fuente) e interpretación (lo que podría aprovecharse) */
export interface Oportunidad {
  id: number; nivel: 'explicita' | 'inferida'; tipo: string; hecho: string; interpretacion?: string;
  beneficiarios?: string[]; accion?: string; importancia?: number; plazo_hasta?: string;
  estado: EstadoOportunidad; senal?: string; creada_por?: string; creada?: string; evidencias?: Evidencia[];
}

export async function decidirOportunidad(id: number, estado: EstadoOportunidad): Promise<void> {
  const { error } = await rpc('decidir_oportunidad', { p_id: id, p_estado: estado });
  if (error) throw falta15(error.message, 'decidir_oportunidad') ?? new Error(traducir(error.message));
}
