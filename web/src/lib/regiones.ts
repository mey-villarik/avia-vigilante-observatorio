// Ubica en un departamento cada señal, noticia, oportunidad, evento y cambio, para la vista Mapa.
// La base guarda el territorio de cada señal (signal_territorios → deps). Aquí solo se traduce el nombre:
// un departamento va a sí mismo; «Bolivia», «nacional» o «todo el país» van a «nacional»;
// un destino conocido (Uyuni, Copacabana…) va a su departamento. Lo que no se reconoce no se pinta.
import { DEPS } from '../data/demo';
import { DESTINOS_GEO } from '../data/mapaBolivia';
import type { Senal } from '../types';
import type { Oportunidad } from '../services/recolector';
import type { EventoCompuesto } from '../services/eventos';
import type { Cambio } from '../services/cambios';
import { scoreOf } from './util';
import { ACCION_ORDEN, accionDe } from './accion';

export const NACIONAL = 'nacional';

const sinTilde = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();

const ALIAS: Record<string, string> = {
  'el beni': 'Beni', 'departamento del beni': 'Beni', 'santa cruz de la sierra': 'Santa Cruz', sucre: 'Chuquisaca',
  trinidad: 'Beni', cobija: 'Pando', 'el alto': 'La Paz', 'sede de gobierno': 'La Paz',
  bolivia: NACIONAL, nacional: NACIONAL, 'todo el pais': NACIONAL, 'todo bolivia': NACIONAL, pais: NACIONAL, 'a nivel nacional': NACIONAL,
};
const INDICE = new Map<string, string>();
DEPS.forEach((d) => INDICE.set(sinTilde(d), d));
DESTINOS_GEO.forEach((d) => INDICE.set(sinTilde(d.nombre), d.dep));
Object.entries(ALIAS).forEach(([k, v]) => INDICE.set(k, v));

/** departamento (o «nacional») de un nombre de lugar; null si no se reconoce */
export function departamentoDe(lugar: string | null | undefined): string | null {
  if (!lugar) return null;
  const k = sinTilde(lugar).replace(/^(departamento de|depto\.? de|dpto\.? de)\s+/, '');
  if (INDICE.has(k)) return INDICE.get(k)!;
  // «Salar de Uyuni (Potosí)», «La Paz - El Alto»: probar cada trozo
  for (const t of k.split(/[(),/\-–]+/).map((x) => x.trim()).filter(Boolean)) if (INDICE.has(t)) return INDICE.get(t)!;
  return null;
}

/** departamentos de una lista de lugares, sin repetir */
export function departamentosDe(lugares: (string | null | undefined)[]): string[] {
  return [...new Set(lugares.map(departamentoDe).filter((x): x is string => Boolean(x)))];
}

/** departamentos de una señal: primero sus territorios; si no tiene, los de sus destinos */
export function regionesDeSenal(s: Pick<Senal, 'deps' | 'destinos'>): string[] {
  const r = departamentosDe(s.deps ?? []);
  return r.length ? r : departamentosDe(s.destinos ?? []);
}

export interface NoticiaRegion { titulo: string; url?: string; fuente?: string; fecha?: string; oficial?: boolean; senal: Senal }

export interface ResumenRegion {
  dep: string;
  senales: Senal[];
  oportunidades: Senal[];
  riesgos: Senal[];
  mixtas: Senal[];
  /** señales que afectan a todo el país (también cuentan aquí, aparte) */
  nacionales: Senal[];
  /** fichas de oportunidad guardadas en la base ligadas a señales de la región */
  fichas: Oportunidad[];
  eventos: EventoCompuesto[];
  cambios: Cambio[];
  noticias: NoticiaRegion[];
  destinos: { nombre: string; n: number }[];
  categorias: { c: string; n: number }[];
  /** señales de prioridad alta, para el color de alerta */
  altas: number;
  porRevisar: number;
}

const fechaDe = (n: { fecha?: string; publicada?: string; recogida?: string }) => n.publicada ?? n.fecha ?? n.recogida;

/** noticias de una señal: las de la trazabilidad (con fecha y si es oficial) o, si no hay, sus enlaces */
function noticiasDe(s: Senal): NoticiaRegion[] {
  const t = s.traza?.fuentes ?? [];
  if (t.length) return t.filter((f) => f.titulo || f.url).map((f) => ({ titulo: f.titulo ?? f.nombre, url: f.url, fuente: f.nombre, fecha: fechaDe(f), oficial: f.oficial, senal: s }));
  return (s.enlaces ?? []).map((e) => ({ titulo: e.nombre, url: e.url, fecha: e.fecha, senal: s }));
}

// riesgos y mixtas primero por acción (Actuar hoy → Preparar → Seguir); las oportunidades no la llevan
const rango = (s: Senal) => (s.naturaleza === 'oportunidad' ? { alta: 0, media: 1, baja: 2 }[s.prioridad] : ACCION_ORDEN[accionDe(s).accion]);
const ordenSenal = (a: Senal, b: Senal) => rango(a) - rango(b) || scoreOf(b) - scoreOf(a) || a.min - b.min;

export function resumenRegion(
  dep: string, senales: Senal[], fichas: Oportunidad[], eventos: EventoCompuesto[], cambios: Cambio[],
): ResumenRegion {
  const propias = senales.filter((s) => regionesDeSenal(s).includes(dep)).sort(ordenSenal);
  const nacionales = senales.filter((s) => { const r = regionesDeSenal(s); return r.includes(NACIONAL) && !r.includes(dep); }).sort(ordenSenal);
  const ids = new Set(propias.map((s) => s.id));
  const cuenta = (l: string[]) => [...l.reduce((m, x) => m.set(x, (m.get(x) ?? 0) + 1), new Map<string, number>())]
    .sort((a, b) => b[1] - a[1]);
  const vistos = new Set<string>();
  const noticias = propias.flatMap(noticiasDe)
    .filter((n) => { const k = n.url ?? n.titulo; if (vistos.has(k)) return false; vistos.add(k); return true; })
    .sort((a, b) => ordenSenal(a.senal, b.senal) || (Date.parse(b.fecha ?? '') || 0) - (Date.parse(a.fecha ?? '') || 0));
  return {
    dep,
    senales: propias,
    oportunidades: propias.filter((s) => s.naturaleza === 'oportunidad'),
    riesgos: propias.filter((s) => s.naturaleza === 'riesgo'),
    mixtas: propias.filter((s) => s.naturaleza === 'mixta'),
    nacionales,
    fichas: fichas.filter((o) => o.senal && ids.has(o.senal) && o.estado !== 'descartada'),
    eventos: eventos.filter((e) => departamentoDe(e.territorio) === dep),
    cambios: cambios.filter((c) => departamentosDe(c.senal.departamentos ?? []).includes(dep) || ids.has(c.senal.codigo)),
    noticias,
    destinos: cuenta(propias.flatMap((s) => s.destinos ?? [])).map(([nombre, n]) => ({ nombre, n })),
    categorias: cuenta(propias.map((s) => s.categoria)).map(([c, n]) => ({ c, n })),
    altas: propias.filter((s) => s.prioridad === 'alta').length,
    porRevisar: propias.filter((s) => ['detectada', 'en_analisis', 'en_verificacion'].includes(s.estado)).length,
  };
}

/** tono de un departamento en el mapa según lo que pesa más */
export type Tono = 'vacio' | 'oportunidad' | 'riesgo' | 'mixta';
export function tonoDe(r: Pick<ResumenRegion, 'oportunidades' | 'riesgos' | 'mixtas'>): Tono {
  const o = r.oportunidades.length, k = r.riesgos.length, m = r.mixtas.length;
  if (!o && !k && !m) return 'vacio';
  if (k > o && k >= m) return 'riesgo';
  if (o > k && o >= m) return 'oportunidad';
  return 'mixta';
}
