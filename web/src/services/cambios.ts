// Alertas de cambio: una noticia nueva cambia una señal que ya existía (db/generico/31_cambios_noticias.sql).
// «Viene un ciclón» → «el ciclón se desvió»; «feria el 5» → «feria el 12». La base y el clasificador lo
// detectan; AVIA (Hermes) lo interpreta después. Aquí se piden cada 30 segundos y se guarda quién ya los vio.
// Solo analistas y administradores: la base devuelve [] a un visor.
import { create } from 'zustand';
import { supabase, traducir } from './auth';
import type { Prioridad } from '../types';

export type TipoCambio = 'fecha' | 'plazo' | 'cancelado' | 'desviado' | 'resuelto' | 'agravado' | 'atenuado'
  | 'lugar' | 'desmentido' | 'confirmado' | 'naturaleza' | 'prioridad' | 'otro';

export interface SenalCorta {
  codigo: string; titulo: string; resumen?: string; naturaleza: 'riesgo' | 'oportunidad' | 'mixta';
  categoria: string; prioridad: Prioridad; estado: string;
  evento_inicio?: string; evento_fin?: string; plazo_hasta?: string; departamentos?: string[];
}

export interface NoticiaCambio {
  id: number; titulo: string; url?: string; fuente: string; fuente_tipo: string; publicado_en?: string; recolectado_en?: string;
}

export interface InterpretacionCambio {
  que_cambio: string;
  significado: string;
  a_quien_afecta?: string[];
  recomendacion: { accion: string; para_quien: string; cuando?: string; verificar_con?: string };
  falta_saber?: string[];
  importancia_motivo?: string;
}

export interface Cambio {
  codigo: string; tipo: TipoCambio;
  antes?: string; ahora: string;
  campos?: Record<string, { antes: string; ahora: string }>;
  importancia: Prioridad;
  origen: 'datos' | 'clasificador' | 'hermes';
  estado: 'por_interpretar' | 'interpretando' | 'interpretado';
  repeticiones: number;
  titular?: string; interpretacion?: InterpretacionCambio; interpretado_en?: string;
  detectado: string; actualizado: string;
  senal: SenalCorta;
  senal_nueva?: SenalCorta;
  /** la señal está publicada: la alerta pública aún dice lo de antes */
  publicada: boolean;
  eventos?: string[];
  noticias: NoticiaCambio[];
  /** sale como ventana con sonido (según la importancia mínima del cliente) */
  alerta: boolean;
  esperando_hermes: boolean;
  /** esta persona ya pulsó «Entendido» */
  visto: boolean;
}

export const TIPO_CAMBIO_TXT: Record<TipoCambio, string> = {
  fecha: 'Cambio de fecha',
  plazo: 'Cambio de plazo',
  cancelado: 'Cancelado',
  desviado: 'Cambió de rumbo o de zona',
  resuelto: 'Se resolvió',
  agravado: 'Empeora',
  atenuado: 'Mejora',
  lugar: 'Cambio de lugar',
  desmentido: 'Desmentido',
  confirmado: 'Ahora es oficial',
  naturaleza: 'Cambió de riesgo a oportunidad (o al revés)',
  prioridad: 'Cambio de prioridad',
  otro: 'Cambio',
};

/** cada cuánto se piden los cambios (más a menudo que los eventos: tienen que verse rápido) */
export const CAMBIOS_MS = 30 * 1000;

const rpc = (fn: string, args?: Record<string, unknown>) => {
  if (!supabase) throw new Error('El acceso no está configurado.');
  return supabase.schema('vigilante').rpc(fn, args);
};

const noInstalado = (m: string) => /cambios_recientes|marcar_cambio_visto|descartar_cambio/.test(m)
  && /(not find|no existe|does not exist|schema cache)/i.test(m);

// El sonido de los cambios viene ACTIVADO (es una alarma); se puede apagar en la lista.
const SONIDO_KEY = 'orbita.cambios.sonido';
function leerSonido(): boolean {
  try { return localStorage.getItem(SONIDO_KEY) !== '0'; } catch { return true; }
}

/** Alarma: tres tonos que suben, dos veces (distinta del aviso de eventos). Sin archivos de audio. */
export function sonarAlarma(): void {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    void ctx.resume?.();
    const tonos: [number, number][] = [[660, 0], [880, 0.16], [1100, 0.32], [660, 0.7], [880, 0.86], [1100, 1.02]];
    tonos.forEach(([f, t]) => {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.type = 'triangle'; o.frequency.value = f;
      g.gain.setValueAtTime(0.0001, ctx.currentTime + t);
      g.gain.exponentialRampToValueAtTime(0.25, ctx.currentTime + t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + t + 0.14);
      o.connect(g).connect(ctx.destination); o.start(ctx.currentTime + t); o.stop(ctx.currentTime + t + 0.15);
    });
    setTimeout(() => void ctx.close(), 1500);
  } catch { /* sin sonido */ }
}

interface CambiosState {
  cambios: Cambio[];
  /** false si la base aún no tiene el 31 */
  disponible: boolean;
  error: string | null;
  listaAbierta: boolean;
  sonido: boolean;
  /** ya se pidió una vez (para que al entrar suene si hay cambios sin ver) */
  cargadoUnaVez: boolean;
  cargar: () => Promise<void>;
  marcarVisto: (codigo: string | null) => Promise<void>;
  descartar: (codigo: string, motivo: string) => Promise<void>;
  setListaAbierta: (v: boolean) => void;
  setSonido: (v: boolean) => void;
}

export const useCambios = create<CambiosState>((set, get) => ({
  cambios: [],
  disponible: true,
  error: null,
  listaAbierta: false,
  sonido: leerSonido(),
  cargadoUnaVez: false,
  cargar: async () => {
    if (!supabase || !get().disponible) return;
    let data: unknown; let error: { message: string } | null;
    try { ({ data, error } = await rpc('cambios_recientes')); } catch (e) { set({ error: (e as Error).message }); return; }
    if (error) {
      if (noInstalado(error.message)) { set({ disponible: false, cambios: [] }); return; }
      set({ error: traducir(error.message) });
      return;
    }
    const antes = new Set(get().cambios.map((c) => c.codigo));
    const primera = !get().cargadoUnaVez;
    const cambios = (Array.isArray(data) ? data : []) as Cambio[];
    set({ cambios, error: null, cargadoUnaVez: true });
    // suena cuando aparece un cambio nuevo sin ver (y al entrar, si hay alguno pendiente)
    if (get().sonido && cambios.some((c) => c.alerta && !c.visto && (primera || !antes.has(c.codigo)))) sonarAlarma();
  },
  marcarVisto: async (codigo) => {
    // se oculta al momento; si la base falla, vuelve a salir en la siguiente consulta
    set({ cambios: get().cambios.map((c) => (codigo === null || c.codigo === codigo ? { ...c, visto: true } : c)) });
    try {
      const { error } = await rpc('marcar_cambio_visto', { p_codigo: codigo });
      if (error) set({ error: traducir(error.message) });
    } catch (e) { set({ error: (e as Error).message }); }
  },
  descartar: async (codigo, motivo) => {
    const { error } = await rpc('descartar_cambio', { p_codigo: codigo, p_motivo: motivo });
    if (error) throw new Error(traducir(error.message));
    set({ cambios: get().cambios.filter((c) => c.codigo !== codigo) });
  },
  setListaAbierta: (v) => set({ listaAbierta: v }),
  setSonido: (v) => {
    try { localStorage.setItem(SONIDO_KEY, v ? '1' : '0'); } catch { /* solo en esta sesión */ }
    set({ sonido: v });
    if (v) sonarAlarma();
  },
}));

/** El cambio sin ver más antiguo primero: se leen en el orden en que pasaron */
export const cambioPendiente = (cs: Cambio[]) => [...cs].reverse().find((c) => c.alerta && !c.visto) ?? null;
export const sinVer = (cs: Cambio[]) => cs.filter((c) => !c.visto).length;
