// Alertas emergentes: eventos compuestos (db/generico/28_eventos_compuestos.sql).
// La base detecta que 2 o más señales coinciden en territorio y fechas; Hermes (AVIA) escribe qué
// significan, a quién afectan y qué hacer. Aquí se piden cada minuto y se guarda quién ya los vio.
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
  estado: 'por_interpretar' | 'interpretando' | 'interpretado';
  version: number; titular: string | null; interpretacion: Interpretacion | null;
  interpretado_en: string | null; detectado: string; actualizado: string;
  senales: SenalEvento[];
  /** prioridad alta y (interpretado, o Hermes tarda más de lo previsto) */
  alerta: boolean;
  esperando_hermes: boolean;
  /** esta persona ya pulsó «Entendido» en esta versión */
  visto: boolean;
}

export const TIPO_TXT: Record<TipoEvento, string> = {
  riesgo_acumulado: 'Riesgo acumulado',
  oportunidad_combinada: 'Oportunidad combinada',
  confluencia: 'Confluencia riesgo + oportunidad',
};

/** cada cuánto se piden los eventos */
export const EVENTOS_MS = 60 * 1000;

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

const noInstalado = (m: string) => /eventos_emergentes|marcar_evento_visto|descartar_evento/.test(m)
  && /(not find|no existe|does not exist|schema cache)/i.test(m);

const SONIDO_KEY = 'orbita.eventos.sonido';
function leerSonido(): boolean {
  try { return localStorage.getItem(SONIDO_KEY) === '1'; } catch { return false; }
}

/** Un aviso corto de dos tonos (sin archivos de audio). Si el navegador lo bloquea, no pasa nada. */
export function sonarAviso(): void {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    [[880, 0], [660, 0.18]].forEach(([f, t]) => {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.type = 'sine'; o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(0.18, ctx.currentTime + t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t + 0.16);
      o.connect(g).connect(ctx.destination); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.18);
    });
    setTimeout(() => void ctx.close(), 600);
  } catch { /* sin sonido */ }
}

interface EventosState {
  eventos: EventoCompuesto[];
  /** false si la base aún no tiene el 28 */
  disponible: boolean;
  error: string | null;
  /** lista abierta desde la barra superior */
  listaAbierta: boolean;
  sonido: boolean;
  cargar: () => Promise<void>;
  marcarVisto: (codigo: string) => Promise<void>;
  descartar: (codigo: string, motivo: string) => Promise<void>;
  setListaAbierta: (v: boolean) => void;
  setSonido: (v: boolean) => void;
}

export const useEventos = create<EventosState>((set, get) => ({
  eventos: [],
  disponible: true,
  error: null,
  listaAbierta: false,
  sonido: leerSonido(),
  cargar: async () => {
    if (!supabase || !get().disponible) return;
    let data: unknown; let error: { message: string } | null;
    try { ({ data, error } = await rpc('eventos_emergentes')); } catch (e) { set({ error: (e as Error).message }); return; }
    if (error) {
      if (noInstalado(error.message)) { set({ disponible: false, eventos: [] }); return; }
      set({ error: traducir(error.message) });
      return;
    }
    const antes = new Set(get().eventos.filter((e) => e.alerta && !e.visto).map((e) => e.codigo + ':' + e.version));
    const eventos = (Array.isArray(data) ? data : []) as EventoCompuesto[];
    set({ eventos, error: null });
    // suena solo cuando aparece una alerta nueva (no en cada consulta)
    if (get().sonido && eventos.some((e) => e.alerta && !e.visto && !antes.has(e.codigo + ':' + e.version))) sonarAviso();
  },
  marcarVisto: async (codigo) => {
    // se oculta al momento; si la base falla, vuelve a salir en la siguiente consulta
    set({ eventos: get().eventos.map((e) => (e.codigo === codigo ? { ...e, visto: true } : e)) });
    try {
      const { error } = await rpc('marcar_evento_visto', { p_codigo: codigo });
      if (error) set({ error: traducir(error.message) });
    } catch (e) { set({ error: (e as Error).message }); }
  },
  descartar: async (codigo, motivo) => {
    const { error } = await rpc('descartar_evento', { p_codigo: codigo, p_motivo: motivo });
    if (error) throw new Error(traducir(error.message));
    set({ eventos: get().eventos.filter((e) => e.codigo !== codigo) });
  },
  setListaAbierta: (v) => set({ listaAbierta: v }),
  setSonido: (v) => {
    try { localStorage.setItem(SONIDO_KEY, v ? '1' : '0'); } catch { /* solo en esta sesión */ }
    set({ sonido: v });
    if (v) sonarAviso();
  },
}));

/** La primera alerta sin ver (la de más puntaje: la base ya las ordena) */
export const alertaPendiente = (ev: EventoCompuesto[]) => ev.find((e) => e.alerta && !e.visto) ?? null;
