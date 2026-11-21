// Alertas emergentes: eventos compuestos (db/generico/28_eventos_compuestos.sql).
// La base detecta que 2 o más señales coinciden en territorio y fechas; Hermes (AVIA) escribe qué
// significan, a quién afectan y qué hacer. Aquí se piden cada 30 segundos y se guarda quién ya los vio.
// Desde el 34 (eventos dinámicos) cada evento nuevo salta con alarma al momento, sin esperar a AVIA,
// y se ve 24 h en la ventana de Eventos; después sigue guardado en la base.
// Solo analistas y administradores: la base devuelve [] a un visor.
import { create } from 'zustand';
import { supabase, traducir } from './auth';
import type { Prioridad } from '../types';

export type TipoEvento = 'riesgo_acumulado' | 'oportunidad_combinada' | 'confluencia';

export interface SenalEvento {
  codigo: string; titulo: string; resumen?: string; naturaleza: 'riesgo' | 'oportunidad' | 'mixta';
  categoria: string; prioridad: Prioridad; estado: string; certeza?: { nivel: string; motivo?: string } | null;
  nacional?: boolean; evento_inicio?: string; evento_fin?: string;
}

export interface Interpretacion {
  significado: string;
  a_quien_afecta: string[];
  impacto?: { nivel: 'alto' | 'medio' | 'bajo'; motivo: string };
  recomendacion: { accion: string; para_quien: string; cuando?: string; verificar_con?: string };
  escenarios?: { si: string; entonces: string }[];
  falta_saber?: string[];
  prioridad_motivo?: string;
}

export interface EventoCompuesto {
  codigo: string; tipo: TipoEvento; territorio: string;
  ventana_inicio: string; ventana_fin: string;
  puntaje: number; prioridad: Prioridad; prioridad_calculada: Prioridad; prioridad_hermes: Prioridad | null;
  calculo: { regla?: string; senales?: number; categorias_distintas?: number; proximidad?: number; fuente_oficial?: number } | null;
  /** 38: los cerrados (sus señales dejaron de coincidir) y descartados también llegan sus 24 h, sin alarma */
  estado: 'por_interpretar' | 'interpretando' | 'interpretado' | 'cerrado' | 'descartado';
  version: number; titular: string | null; interpretacion: Interpretacion | null;
  interpretado_en: string | null; detectado: string; actualizado: string;
  senales: SenalEvento[];
  /** sale como ventana con alarma (34: todos al momento; 28: solo prioridad alta e interpretados) */
  alerta: boolean;
  esperando_hermes: boolean;
  /** esta persona ya pulsó «Entendido» en esta versión */
  visto: boolean;
  /** 34: esta persona no lo ha visto en ninguna versión (si no, es una actualización) */
  nuevo?: boolean;
  /** 34: cuándo se detectó o entraron señales nuevas, y cuándo deja de mostrarse en el panel */
  version_en?: string;
  oculta_en?: string;
  /** 38: por qué se cerró o descartó, quién lo descartó y cuándo */
  motivo_cierre?: string | null;
  descartado_por?: string | null;
  cerrado_en?: string;
}

export const abierto = (e: EventoCompuesto) => e.estado !== 'cerrado' && e.estado !== 'descartado';

export const TIPO_TXT: Record<TipoEvento, string> = {
  riesgo_acumulado: 'Riesgo acumulado',
  oportunidad_combinada: 'Oportunidad combinada',
  confluencia: 'Confluencia riesgo + oportunidad',
};

/** cada cuánto se piden los eventos (como los cambios: tienen que verse rápido) */
export const EVENTOS_MS = 30 * 1000;

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

const noInstalado = (m: string) => /eventos_emergentes|marcar_evento_visto|descartar_evento/.test(m)
  && /(not find|no existe|does not exist|schema cache)/i.test(m);

// La alarma de eventos viene ACTIVADA (como la de cambios); se puede apagar en la lista de Eventos.
const SONIDO_KEY = 'orbita.eventos.sonido';
function leerSonido(): boolean {
  try { return localStorage.getItem(SONIDO_KEY) !== '0'; } catch { return true; }
}

/** Alarma de evento: tono alto-bajo tres veces, como una sirena corta (distinta de la de cambios, que sube).
 *  Sin archivos de audio. Si el navegador la bloquea (aún no se ha tocado la página), no pasa nada. */
export function sonarAviso(): void {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    void ctx.resume?.();
    const tonos: [number, number][] = [[988, 0], [740, 0.2], [988, 0.4], [740, 0.6], [988, 0.8], [740, 1.0]];
    tonos.forEach(([f, t]) => {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.type = 'square'; o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(0.12, ctx.currentTime + t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t + 0.18);
      o.connect(g).connect(ctx.destination); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.19);
    });
    setTimeout(() => void ctx.close(), 1500);
  } catch { /* sin sonido */ }
}

// Alertas que la persona cerró haciendo clic fuera de la ventana («luego lo miro»): no vuelven a saltar
// en esta sesión, pero siguen sin ver (el botón «Eventos N nuevos» sigue encendido). Si el evento
// recibe señales nuevas (otra versión), vuelve a saltar.
const POSPUESTOS_KEY = 'orbita.eventos.pospuestos';
function leerPospuestos(): string[] {
  try { const v = JSON.parse(sessionStorage.getItem(POSPUESTOS_KEY) ?? '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
}
export const claveAlerta = (e: EventoCompuesto) => `${e.codigo}:${e.version}`;

interface EventosState {
  /** abiertos de las últimas 24 h (lo que cuentan el botón, el mapa y los paneles) */
  eventos: EventoCompuesto[];
  /** 38: cerrados o descartados de las últimas 24 h (solo informativos, en la lista) */
  cerrados: EventoCompuesto[];
  /** alertas cerradas con clic fuera: codigo:version */
  pospuestos: string[];
  /** false si la base aún no tiene el 28 */
  disponible: boolean;
  error: string | null;
  /** lista abierta desde la barra superior, y el evento elegido en ella */
  listaAbierta: boolean;
  listaSel: string | null;
  sonido: boolean;
  /** ya se pidió una vez (para que al entrar suene si hay eventos sin ver) */
  cargadoUnaVez: boolean;
  cargar: () => Promise<void>;
  /** null = todos los que se ven en el panel */
  marcarVisto: (codigo: string | null) => Promise<void>;
  descartar: (codigo: string, motivo: string) => Promise<void>;
  /** cierra todas las alertas pendientes sin marcarlas como vistas */
  posponer: () => void;
  setListaAbierta: (v: boolean, codigo?: string | null) => void;
  setSonido: (v: boolean) => void;
}

export const useEventos = create<EventosState>((set, get) => ({
  eventos: [],
  cerrados: [],
  pospuestos: leerPospuestos(),
  disponible: true,
  error: null,
  listaAbierta: false,
  listaSel: null,
  sonido: leerSonido(),
  cargadoUnaVez: false,
  cargar: async () => {
    if (!supabase || !get().disponible) return;
    let data: unknown; let error: { message: string } | null;
    try { ({ data, error } = await rpc('eventos_emergentes')); } catch (e) { set({ error: (e as Error).message }); return; }
    if (error) {
      if (noInstalado(error.message)) { set({ disponible: false, eventos: [] }); return; }
      set({ error: traducir(error.message) });
      return;
    }
    const antes = new Set(get().eventos.filter((e) => e.alerta).map((e) => e.codigo + ':' + e.version));
    const primera = !get().cargadoUnaVez;
    const todos = visibles((Array.isArray(data) ? data : []) as EventoCompuesto[]);
    const eventos = todos.filter(abierto);
    set({ eventos, cerrados: todos.filter((e) => !abierto(e)), error: null, cargadoUnaVez: true });
    // suena cuando se detecta un evento nuevo (o le entran señales nuevas), y al entrar si hay alguno sin ver
    const pos = new Set(get().pospuestos);
    if (get().sonido && eventos.some((e) => e.alerta && !e.visto && !pos.has(claveAlerta(e))
      && (primera || !antes.has(e.codigo + ':' + e.version)))) sonarAviso();
  },
  marcarVisto: async (codigo) => {
    // se oculta al momento; si la base falla, vuelve a salir en la siguiente consulta
    set({ eventos: get().eventos.map((e) => (codigo === null || e.codigo === codigo ? { ...e, visto: true } : e)) });
    try {
      const { error } = await rpc('marcar_evento_visto', { p_codigo: codigo });
      if (error) set({ error: traducir(error.message) });
    } catch (e) { set({ error: (e as Error).message }); }
  },
  descartar: async (codigo, motivo) => {
    const { error } = await rpc('descartar_evento', { p_codigo: codigo, p_motivo: motivo });
    if (error) throw new Error(traducir(error.message));
    set({ eventos: get().eventos.filter((e) => e.codigo !== codigo) });
    void get().cargar(); // vuelve como descartado, con su motivo
  },
  posponer: () => {
    const pos = new Set(get().pospuestos);
    get().eventos.forEach((e) => { if (e.alerta && !e.visto) pos.add(claveAlerta(e)); });
    // solo se guardan las de eventos que aún se ven
    const vivos = new Set(get().eventos.map(claveAlerta));
    const pospuestos = [...pos].filter((k) => vivos.has(k));
    try { sessionStorage.setItem(POSPUESTOS_KEY, JSON.stringify(pospuestos)); } catch { /* solo en memoria */ }
    set({ pospuestos });
  },
  setListaAbierta: (v, codigo = null) => set({ listaAbierta: v, listaSel: v ? codigo : null }),
  setSonido: (v) => {
    try { localStorage.setItem(SONIDO_KEY, v ? '1' : '0'); } catch { /* solo en esta sesión */ }
    set({ sonido: v });
    if (v) sonarAviso();
  },
}));

/** Fuera los que ya pasaron sus 24 h en el panel (la base ya los quita; esto cubre el rato entre consultas) */
const visibles = (ev: EventoCompuesto[]) => ev.filter((e) => !e.oculta_en || Date.parse(e.oculta_en) > Date.now());

/** La alerta sin ver más antigua primero: se leen en el orden en que se detectaron (la base da la más reciente primero) */
export const alertaPendiente = (ev: EventoCompuesto[], pospuestos: string[] = []) =>
  [...ev].reverse().find((e) => e.alerta && !e.visto && !pospuestos.includes(claveAlerta(e))) ?? null;
export const eventosSinVer = (ev: EventoCompuesto[]) => ev.filter((e) => !e.visto).length;
