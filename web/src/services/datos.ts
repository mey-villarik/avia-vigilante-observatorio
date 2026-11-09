// Datos reales: el archivo vigilante.json que genera Hermes en el VPS.
// 1) Con login (Supabase): se lee del almacenamiento privado, bucket `vigilante`,
//    archivo <slug-del-cliente>/vigilante.json. Solo lo pueden leer usuarios activos.
// 2) Si no está ahí (o no hay login) y VITE_DATA_URL tiene valor, se pide esa URL
//    (por defecto /data/vigilante.json; en desarrollo Vite reenvía /data al VPS, ver vite.config.ts).
//    Deja VITE_DATA_URL vacío cuando Hermes ya suba al almacenamiento privado.
// Si nada responde, la web sigue con los datos de ejemplo de src/data/demo.ts.
import type {
  CategoriaId, Enlace, EstadoFuente, Etapa, Evento, Fuente, Naturaleza, Prioridad, Senal, Serie, Tema, TipoEvento,
} from '../types';
import { CATS } from '../data/demo';
import { supabase, type Perfil } from './auth';
import type { Oportunidad } from './recolector';

const URL_ENV = import.meta.env.VITE_DATA_URL as string | undefined;
/** URL pública de respaldo; vacía = desactivada */
export const DATA_URL = URL_ENV === undefined ? '/data/vigilante.json' : URL_ENV.trim();
export const BUCKET = 'vigilante';
/** cada cuánto se vuelve a pedir el archivo */
export const REFRESCO_MS = 5 * 60 * 1000;

// ───────── Formato de vigilante.json (versión 1) ─────────

interface JFuente {
  id: string; nombre: string; canal?: string | null; tipo?: string | null; url?: string | null; info?: string | null;
  items?: number | null; metodo?: string | null; estado?: string | null; ultima?: string | null; hist?: string[] | null;
}
interface JSenal {
  id: string; titulo: string; resumen?: string | null; naturaleza?: string | null; categoria?: string | null;
  deps?: string[] | null; destinos?: string[] | null; estado?: string | null; prioridad?: string | null;
  rel?: number | null; nov?: number | null; conf?: number | null; enlaces?: Enlace[] | null;
  fecha_limite?: string | null; tipoOpp?: string | null; actores?: string[] | null; importancia?: string | null;
  soluciones?: { t: string; d?: string | null }[] | null; revision?: string | null; actualizacion?: string | null;
  detectada?: string | null;
}
interface JBitacora { cuando?: string | null; k?: string | null; w?: string | null; d?: string | null }
export interface VigilanteJson {
  version: number;
  generado?: string;
  construido?: string;
  ventana_horas?: number;
  noticias_revisadas?: number;
  sintesis?: { frase?: string; texto?: string };
  fuentes?: JFuente[];
  senales?: JSenal[];
  temas?: Tema[];
  serie?: Serie;
  bitacora?: JBitacora[];
  /** desde el 15: oportunidades guardadas en la base (hecho, interpretación, beneficiarios, acción, evidencias) */
  oportunidades?: Oportunidad[];
}

export interface DatosVps {
  fuentes: Fuente[];
  senales: Senal[];
  temas: Tema[];
  serie: Serie | null;
  eventos: Evento[];
  sintesis: { frase: string; texto: string } | null;
  generado: string | null;
  ventanaHoras: number | null;
  noticiasRevisadas: number | null;
  oportunidades?: Oportunidad[];
}

// ───────── Normalización ─────────

const sinTildes = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').trim();

/** El canal de las fuentes llega como texto libre ("vías terrestres", "estadísticas"…) */
const CANAL: Record<string, CategoriaId | string> = {
  'vias terrestres': 'vial', carretera: 'vial', transporte: 'vial',
  aerolineas: 'conectividad',
  inversion: 'financiacion', economia: 'mercado',
  estadisticas: 'estadísticas', politica: 'política', pais: 'país',
  prensa: 'prensa', medios: 'prensa',
};
export function normCanal(c?: string | null): string {
  if (!c) return '—';
  const k = sinTildes(c);
  if (k in CATS) return k;
  return CANAL[k] ?? c;
}
export function normTipo(t?: string | null): string {
  if (!t) return '—';
  const k = sinTildes(t);
  return k === 'media' ? 'medio' : k;
}

const ESTADOS: EstadoFuente[] = ['OK', 'WARN', 'CRIT', 'UNKNOWN', 'MANT'];
const estado = (e?: string | null): EstadoFuente => (ESTADOS.includes(e as EstadoFuente) ? (e as EstadoFuente) : 'UNKNOWN');
const ETAPAS: Etapa[] = ['detectada', 'en_analisis', 'en_verificacion', 'confirmada', 'publicada', 'descartada'];
const NATS: Naturaleza[] = ['oportunidad', 'riesgo', 'mixta'];
const PRIOS: Prioridad[] = ['alta', 'media', 'baja'];

/** minutos transcurridos desde una fecha ISO; null si no hay fecha válida */
function minutosDesde(iso?: string | null, ahora = Date.now()): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isNaN(t) ? null : Math.max(0, (ahora - t) / 60000);
}

/** días que faltan hasta una fecha AAAA-MM-DD (fin de ese día en Bolivia, UTC-4) */
export function diasHasta(fecha?: string | null, ahora = Date.now()): number | null {
  if (!fecha) return null;
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(fecha) ? `${fecha}T23:59:59-04:00` : fecha);
  if (Number.isNaN(t)) return null;
  return Math.max(0, Math.ceil((t - ahora) / 86400000));
}

export function convertir(j: VigilanteJson, ahora = Date.now()): DatosVps {
  if (j.version !== 1) throw new Error(`Versión de vigilante.json no reconocida: ${j.version}`);

  const fuentes: Fuente[] = (j.fuentes ?? []).map((f) => ({
    id: f.id,
    nombre: f.nombre,
    canal: normCanal(f.canal),
    tipo: normTipo(f.tipo),
    url: f.url || '—',
    metodo: f.metodo || '—',
    estado: estado(f.estado),
    info: f.info || '',
    lat: null,
    items: f.items ?? 0,
    hist: (f.hist ?? []).map(estado),
    verif: '—',
    last: minutosDesde(f.ultima, ahora) ?? undefined,
  }));

  const senales: Senal[] = (j.senales ?? []).map((s) => {
    const enlaces = (s.enlaces ?? []).filter((e) => e && e.url);
    const sol = (s.soluciones ?? []).map((x) => ({ t: x.t, d: x.d ?? '' }));
    return {
      id: s.id,
      titulo: s.titulo,
      resumen: s.resumen ?? '',
      naturaleza: NATS.includes(s.naturaleza as Naturaleza) ? (s.naturaleza as Naturaleza) : 'mixta',
      categoria: (s.categoria && s.categoria in CATS ? s.categoria : 'mercado') as CategoriaId,
      deps: s.deps ?? [],
      destinos: s.destinos ?? [],
      estado: ETAPAS.includes(s.estado as Etapa) ? (s.estado as Etapa) : 'detectada',
      prioridad: PRIOS.includes(s.prioridad as Prioridad) ? (s.prioridad as Prioridad) : 'media',
      rel: s.rel ?? 0,
      nov: s.nov ?? 0,
      conf: s.conf ?? 0,
      fuentes: [],
      enlaces,
      corr: enlaces.length,
      min: minutosDesde(s.detectada, ahora) ?? 0,
      plazo: diasHasta(s.fecha_limite, ahora),
      tipoOpp: s.tipoOpp ?? undefined,
      actores: s.actores?.length ? s.actores : undefined,
      importancia: s.importancia ?? '',
      soluciones: sol.length ? sol : [{ t: 'Revisar la señal', d: '' }],
      revision: s.revision ?? undefined,
      actualizacion: s.actualizacion ?? undefined,
    };
  });

  const TIPOS_EV: TipoEvento[] = [...ESTADOS, 'spark', 'check'];
  const eventos: Evento[] = (j.bitacora ?? []).map((b) => ({
    t: -(minutosDesde(b.cuando, ahora) ?? 0),
    k: TIPOS_EV.includes(b.k as TipoEvento) ? (b.k as TipoEvento) : 'UNKNOWN',
    w: b.w ?? '',
    d: b.d ?? '',
  }));

  const serie = j.serie && Array.isArray(j.serie.labels) && j.serie.labels.length > 1 ? j.serie : null;

  return {
    fuentes,
    senales,
    temas: j.temas ?? [],
    serie,
    eventos,
    sintesis: j.sintesis?.frase || j.sintesis?.texto ? { frase: j.sintesis.frase ?? '', texto: j.sintesis.texto ?? '' } : null,
    generado: j.generado ?? null,
    ventanaHoras: j.ventana_horas ?? null,
    oportunidades: j.oportunidades ?? [],
    noticiasRevisadas: j.noticias_revisadas ?? null,
  };
}

async function desdeAlmacen(p: Perfil): Promise<VigilanteJson> {
  if (!supabase) throw new Error('Sin acceso configurado');
  const { data, error } = await supabase.storage.from(BUCKET).download(`${p.clienteSlug}/vigilante.json`);
  if (error || !data) throw new Error('Aún no hay datos en el almacenamiento privado');
  return JSON.parse(await data.text()) as VigilanteJson;
}

async function desdeUrl(signal?: AbortSignal): Promise<VigilanteJson> {
  const r = await fetch(DATA_URL, { headers: { Accept: 'application/json' }, cache: 'no-cache', signal });
  if (!r.ok) throw new Error(`El VPS respondió ${r.status}`);
  const tipo = r.headers.get('content-type') ?? '';
  if (!tipo.includes('json')) throw new Error('El VPS no devolvió JSON');
  return await r.json() as VigilanteJson;
}

export async function cargarVps(perfil?: Perfil | null, signal?: AbortSignal): Promise<DatosVps> {
  if (perfil && supabase) {
    try {
      return convertir(await desdeAlmacen(perfil));
    } catch (e) {
      if (!DATA_URL) throw e;
    }
  }
  if (!DATA_URL) throw new Error('No hay origen de datos configurado');
  return convertir(await desdeUrl(signal));
}
