// Cliente de AVIA (el asistente). Hermes Agent es el motor interno; la web nunca lo llama
// directamente ni guarda claves: habla con un backend propio definido por VITE_AVIA_API_URL.
//
// Contrato propuesto para ese backend (ver docs/api-avia.md):
//   POST /chat     { mensajes: [{role, content}], rol }           -> { texto, comandos?: Comando[] }
//   POST /analisis { tipo, territorio, pregunta?, senales: [...] } -> { texto }   (markdown sencillo)
//   POST /evaluar  { texto }                                      -> Evaluacion
//
// Sin VITE_AVIA_API_URL la web funciona en modo local: reglas sencillas, sin IA.
import type { Evaluacion, Senal, TipoAnalisis } from '../types';
import { CATS, DEPS } from '../data/demo';
import { norm, scoreOf } from '../lib/util';

const API = (import.meta.env.VITE_AVIA_API_URL as string | undefined)?.replace(/\/$/, '');
export const aviaConectado = Boolean(API);

async function post<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
  const r = await fetch(API + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'include', // la sesión (login de AVIA) viaja en cookie, nunca una clave en el navegador
    body: JSON.stringify(body),
    signal,
  });
  if (!r.ok) throw new Error(`AVIA respondió ${r.status}`);
  return r.json() as Promise<T>;
}

/** Órdenes que AVIA puede devolver para mover la interfaz (abrir una vista, cambiar el tablero…) */
export type Comando =
  | { tipo: 'abrir'; vista?: string; senal?: string; fuente?: string }
  | { tipo: 'tablero'; accion: 'agregar' | 'quitar'; panel: string };

export const AN_TYPES: Record<TipoAnalisis, [string, string]> = {
  panorama: ['Panorama ejecutivo', 'Qué pasa, qué importa y qué hacer, en un párrafo por tema.'],
  destino: ['Oportunidades por destino', 'Qué puede aprovechar cada destino o departamento.'],
  cruce: ['Cruce riesgo–oportunidad', 'Dónde un riesgo y una oportunidad se tocan.'],
  foda: ['FODA del territorio', 'Fortalezas, debilidades, oportunidades y amenazas.'],
  noticia: ['Evaluar una noticia', 'Pega un texto y AVIA lo clasifica y valora.'],
  libre: ['Pregunta libre', 'Cualquier pregunta sobre las señales.'],
};

/** Versión compacta de una señal para enviar al modelo */
export const compact = (s: Senal) => ({
  id: s.id, titulo: s.titulo, resumen: s.resumen, naturaleza: s.naturaleza, categoria: s.categoria,
  departamentos: s.deps, destinos: s.destinos, estado: s.estado, prioridad: s.prioridad,
  relevancia: s.rel, novedad: s.nov, confianza: s.conf, fuentes: s.corr, plazo_dias: s.plazo ?? null,
  importancia: s.importancia, acciones: s.soluciones.map((x) => x.t),
});

// ───────── Llamadas al backend ─────────

export const remoto = {
  chat: (mensajes: { role: 'user' | 'assistant'; content: string }[], rol: string, signal?: AbortSignal) =>
    post<{ texto: string; comandos?: Comando[] }>('/chat', { mensajes, rol }, signal),
  analisis: (tipo: TipoAnalisis, territorio: string, senales: Senal[], pregunta: string | undefined, signal?: AbortSignal) =>
    post<{ texto: string }>('/analisis', { tipo, territorio, pregunta, senales: senales.map(compact) }, signal),
  evaluar: (texto: string, signal?: AbortSignal) => post<Evaluacion>('/evaluar', { texto }, signal),
};

// ───────── Modo local (reglas, sin IA) ─────────

export function evaluarLocal(text: string): Evaluacion {
  const t = norm(text);
  const has = (w: string[]) => w.some((x) => t.includes(x));
  const cat = has(['lluvia', 'granizo', 'helada', 'senamhi', 'incendio', 'humo', 'inunda']) ? 'clima'
    : has(['dengue', 'salud', 'epidem', 'brote']) ? 'salud'
      : has(['carretera', 'bloqueo', 'abc', 'tramo']) ? 'vial'
        : has(['vuelo', 'aerolinea', 'aeropuerto', 'ruta aerea']) ? 'conectividad'
          : has(['convocatoria', 'fondo', 'licitacion', 'financ']) ? 'financiacion'
            : has(['festival', 'feria', 'evento']) ? 'eventos'
              : has(['decreto', 'ley', 'norma']) ? 'normativa' : 'mercado';
  const risk = has(['alerta', 'riesgo', 'bloqueo', 'cierre', 'brote', 'corte', 'emergencia']);
  const opp = has(['convocatoria', 'fondo', 'nueva', 'festival', 'feria', 'crece', 'aumento', 'ruta']);
  const deps = DEPS.filter((d) => t.includes(norm(d)));
  return {
    naturaleza: risk && opp ? 'mixta' : risk ? 'riesgo' : 'oportunidad',
    categoria: cat,
    departamentos: deps.length ? deps : ['Por confirmar'],
    titulo: text.slice(0, 90) + (text.length > 90 ? '…' : ''),
    relevancia: Math.min(10, 4 + deps.length * 2 + (risk || opp ? 2 : 0)),
    novedad: 6,
    confianza: 0.4,
    importancia: `Clasificada como ${CATS[cat as keyof typeof CATS].toLowerCase()} por las palabras del texto. Falta corroborar con una fuente oficial.`,
    acciones: ['Buscar una segunda fuente independiente', 'Revisar si afecta a un destino con visitantes en los próximos 7 días', 'Decidir si pasa a verificación'],
    verificar: 'Comparar con la fuente oficial del canal correspondiente.',
  };
}

export function cruces(l: Senal[]): string[] {
  const res: string[] = [];
  l.filter((s) => s.naturaleza === 'riesgo').forEach((r) => {
    l.filter((s) => s.naturaleza !== 'riesgo').forEach((o) => {
      const d = r.deps.filter((x) => o.deps.includes(x));
      if (d.length) res.push(`${d.join(', ')}: **${r.id}** (riesgo) se cruza con **${o.id}** (${o.naturaleza})`);
    });
  });
  return res.slice(0, 6);
}

/** Análisis local en markdown sencillo (mismo formato que devuelve el backend) */
export function analisisLocal(tipo: TipoAnalisis, territorio: string, l: Senal[]): string {
  const o = l.filter((s) => s.naturaleza !== 'riesgo');
  const r = l.filter((s) => s.naturaleza === 'riesgo');
  const top = [...o].sort((a, b) => scoreOf(b) - scoreOf(a)).slice(0, 3);
  const tr = [...r].sort((a, b) => scoreOf(b) - scoreOf(a)).slice(0, 3);
  const byDep = DEPS.map((d) => [d, l.filter((s) => s.deps.includes(d)).length] as const).filter((x) => x[1]).sort((a, b) => b[1] - a[1]);
  const out: string[] = [
    '#### Resumen',
    `${l.length} señales en ${territorio === 'all' ? 'todo Bolivia' : territorio}: ${o.length} oportunidades o mixtas y ${r.length} riesgos.`,
  ];
  if (top.length) out.push('#### Oportunidades con mejor puntuación', ...top.map((s) => `- **${s.id}** · ${s.titulo}${s.plazo ? ` (${s.plazo} días)` : ''} → ${s.soluciones[0].t}`));
  if (tr.length) out.push('#### Riesgos a vigilar', ...tr.map((s) => `- **${s.id}** · ${s.titulo} → ${s.soluciones[0].t}`));
  if (byDep.length) out.push('#### Territorios con más señales', byDep.slice(0, 4).map(([d, n]) => `${d} (${n})`).join(', ') + '.');
  if (tipo === 'cruce') {
    const c = cruces(l);
    out.push('#### Cruces detectados', ...(c.length ? c.map((x) => `- ${x}`) : ['- No hay riesgo y oportunidad en el mismo destino.']));
  }
  return out.join('\n');
}
