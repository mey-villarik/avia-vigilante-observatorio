// Fuentes en la base de datos (db/generico/06_fuentes_hermes.sql).
// La web da de alta, pausa y reactiva; Hermes lee la lista activa antes de cada ronda.
import type { Fuente, FuenteBd } from '../types';
import { supabase, traducir } from './auth';
import { normCanal, normTipo } from './datos';

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

export type { FuenteBd };

export async function leerFuentesBd(): Promise<FuenteBd[]> {
  const { data, error } = await rpc('fuentes_web');
  if (error) throw new Error(traducir(error.message));
  return (data as FuenteBd[]) ?? [];
}

export const METODO_TXT: Record<string, string> = {
  http_html: 'Página web', rss: 'RSS', google_news_rss: 'Google News', gdelt: 'GDELT', apify: 'Apify', tavily: 'Buscador',
  api: 'API', mcp_vigilante: 'Vigilante AVIA', manual: 'Manual',
};

/**
 * Junta las fuentes del archivo de Hermes con las de la base:
 *  - las pausadas en la base se muestran «en mantenimiento»;
 *  - las que Hermes aún no ha mirado nunca se añaden como «pendiente de la primera comprobación».
 */
export function mezclarFuentes(json: Fuente[], bdTodas: FuenteBd[]): Fuente[] {
  // las eliminadas desaparecen aunque Hermes aún las tenga en su archivo
  const borradas = new Set(bdTodas.filter((f) => f.eliminada).map((f) => f.codigo));
  const bd = bdTodas.filter((f) => !f.eliminada);
  const porCodigo = new Map(bd.map((f) => [f.codigo, f]));
  const out = json.filter((f) => !borradas.has(f.id)).map((f) => {
    const b = porCodigo.get(f.id);
    if (!b) return f;
    // lo que se escribió en la web (nombre, dirección, canal…) manda sobre el archivo de Hermes
    const extra = {
      nombre: b.nombre, url: b.url, freq: b.frecuencia_minutos, enBd: true, bd: b,
      metodo: METODO_TXT[b.metodo] ?? b.metodo,
      tipo: normTipo(b.tipo === 'organismo_internacional' ? 'internacional' : b.tipo),
      ...(b.categorias[0] ? { canal: normCanal(b.categorias[0]) } : {}),
    };
    return b.activa ? { ...f, ...extra } : { ...f, ...extra, estado: 'MANT' as const, info: 'En pausa: AVIA no la vigila hasta que se reactive' };
  });
  const enJson = new Set(json.map((f) => f.id));
  // (las borradas ya no están en bd)
  bd.filter((b) => !enJson.has(b.codigo)).forEach((b) => {
    out.push({
      id: b.codigo, nombre: b.nombre, canal: normCanal(b.categorias[0]), tipo: normTipo(b.tipo === 'organismo_internacional' ? 'internacional' : b.tipo),
      url: b.url, metodo: METODO_TXT[b.metodo] ?? b.metodo, freq: b.frecuencia_minutos,
      estado: b.activa ? 'UNKNOWN' : 'MANT',
      info: b.activa
        ? `Pendiente de la primera comprobación de AVIA${b.alta_por ? ` · alta de ${b.alta_por}` : ''}${b.que_buscar ? ` · Buscar: ${b.que_buscar}` : ''}`
        : 'En pausa: AVIA no la vigila hasta que se reactive',
      lat: null, items: 0, hist: [], verif: '—', enBd: true, bd: b,
    });
  });
  return out;
}

export interface AltaFuente {
  nombre: string; url: string; canal: string; tipo: string; metodo: string; freq: number; queBuscar: string; palabras: string;
}

export async function altaFuente(a: AltaFuente): Promise<string> {
  const { data, error } = await rpc('alta_fuente', {
    p_nombre: a.nombre, p_url: a.url, p_categoria: a.canal, p_tipo: a.tipo, p_metodo: a.metodo, p_frecuencia: a.freq,
    p_que_buscar: a.queBuscar || null,
    p_palabras: a.palabras.split(',').map((x) => x.trim()).filter(Boolean),
  });
  if (error) throw new Error(traducir(error.message));
  return data as string;
}

export async function editarFuente(codigo: string, a: AltaFuente): Promise<void> {
  const { error } = await rpc('editar_fuente', {
    p_codigo: codigo, p_nombre: a.nombre, p_url: a.url, p_categoria: a.canal, p_tipo: a.tipo, p_metodo: a.metodo, p_frecuencia: a.freq,
    p_que_buscar: a.queBuscar || null,
    p_palabras: a.palabras.split(',').map((x) => x.trim()).filter(Boolean),
  });
  if (error) {
    if (/editar_fuente/.test(error.message) && /(not find|no existe|does not exist|schema cache)/i.test(error.message)) {
      throw new Error('falta ejecutar db/generico/08_editar_fuentes.sql en Supabase.');
    }
    throw new Error(traducir(error.message));
  }
}

export async function activarFuente(codigo: string, activa: boolean): Promise<void> {
  const { error } = await rpc('activar_fuente', { p_codigo: codigo, p_activa: activa });
  if (error) {
    if (/aún no está en la base/.test(error.message)) throw new Error('Esta fuente aún no está en la base de datos: falta activar la sincronización.');
    throw new Error(traducir(error.message));
  }
}

/** Quita la fuente de la web y de la lista de Hermes (solo administrador). */
export async function eliminarFuente(codigo: string): Promise<void> {
  const { error } = await rpc('eliminar_fuente', { p_codigo: codigo });
  if (error) {
    if (/eliminar_fuente/.test(error.message) && /(not find|no existe|does not exist|schema cache)/i.test(error.message)) {
      throw new Error('falta ejecutar db/generico/07_eliminar_fuentes.sql en Supabase.');
    }
    throw new Error(traducir(error.message));
  }
}
