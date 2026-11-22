// Fuentes internacionales que afectan a Bolivia (db/generico/37_fuentes_internacionales.sql).
// OPS/OMS, CEPAL y prensa internacional (BBC Mundo, Reuters, AP). El analizador decide si cada
// noticia de fuera llega a Bolivia y por qué vía (impacto_bolivia); la base guarda a qué señales
// nacionales da contexto. Aquí se piden con vigilante.internacional_web() cada 5 minutos.
import { create } from 'zustand';
import { supabase, traducir } from './auth';
import type { Prioridad } from '../types';

export type Ambito = 'turismo' | 'salud' | 'economia' | 'clima' | 'infraestructura';

export interface ImpactoBolivia {
  hay_impacto: boolean;
  ambitos?: Ambito[];
  /** por dónde llega a Bolivia, en una frase */
  via?: string;
  nivel?: 'alto' | 'medio' | 'bajo';
  plazo?: 'inmediato' | 'semanas' | 'meses';
  evaluado_en?: string;
}

export interface SenalCorta {
  codigo: string; titulo: string; resumen?: string; naturaleza: 'riesgo' | 'oportunidad' | 'mixta';
  categoria: string; prioridad: Prioridad; estado: string; departamentos?: string[];
}

export interface SenalInternacional extends SenalCorta {
  /** false si un medio boliviano ya cuenta lo mismo (señal nacional con contexto de fuera) */
  internacional: boolean;
  impacto_bolivia?: ImpactoBolivia;
  detectada?: string;
  fuentes?: string[];
  enlace?: string;
  /** señales nacionales a las que da contexto */
  refuerza?: SenalCorta[];
}

export interface FuenteInternacional {
  codigo: string; nombre: string; institucion?: string; url: string; metodo: string; activa: boolean;
  ultima_consulta_en?: string; ultimo_exito_en?: string; errores_seguidos?: number; ultimo_error?: string;
  noticias_7d?: number; senales_30d?: number;
}

export interface ContextoInternacional {
  codigo: string; titulo: string; via?: string; nivel?: 'alto' | 'medio' | 'bajo'; ambitos?: Ambito[];
}

export interface DatosInternacional {
  fuentes: FuenteInternacional[];
  senales: SenalInternacional[];
  /** por código de señal nacional: las internacionales que le dan contexto */
  contexto: Record<string, ContextoInternacional[]>;
}

export const AMBITO_TXT: Record<Ambito, string> = {
  turismo: 'Turismo', salud: 'Salud', economia: 'Economía', clima: 'Clima', infraestructura: 'Infraestructura',
};
export const PLAZO_TXT = { inmediato: 'Ya', semanas: 'En semanas', meses: 'En meses' } as const;

/** Ejemplo para la demostración (sin acceso a la base). Datos inventados, como el resto de la demo. */
const DEMO: DatosInternacional = {
  fuentes: [
    { codigo: 'ops_alertas', nombre: 'OPS/OMS · alertas epidemiológicas de la región', institucion: 'Organización Panamericana de la Salud', url: 'https://www.paho.org/es/rss.xml', metodo: 'rss', activa: true, noticias_7d: 6, senales_30d: 2 },
    { codigo: 'cepal_comunicados', nombre: 'CEPAL · comunicados sobre la región y Bolivia', institucion: 'CEPAL', url: 'https://www.cepal.org/es/listado/cepal_pr', metodo: 'http_html', activa: true, noticias_7d: 3, senales_30d: 1 },
    { codigo: 'prensa_internacional', nombre: 'Prensa internacional · BBC Mundo, Reuters y AP sobre Bolivia', institucion: 'BBC Mundo / Reuters / AP', url: 'https://news.google.com/rss/search', metodo: 'google_news_rss', activa: true, noticias_7d: 14, senales_30d: 3 },
  ],
  senales: [
    { codigo: 'INT-EJ-1', titulo: 'OPS: alerta por dengue en América del Sur, con casos en tierras bajas de Bolivia', resumen: 'Ejemplo: la OPS informa del aumento de casos en Brasil, Paraguay y Bolivia y recomienda medidas a viajeros.',
      naturaleza: 'riesgo', categoria: 'salud', prioridad: 'alta', estado: 'en_verificacion', departamentos: ['Santa Cruz', 'Beni'], internacional: true,
      fuentes: ['OPS/OMS · alertas epidemiológicas de la región'],
      impacto_bolivia: { hay_impacto: true, ambitos: ['salud', 'turismo'], via: 'Brote regional con casos en Bolivia; afecta a visitantes que llegan desde Brasil y Paraguay', nivel: 'alto', plazo: 'inmediato' },
      refuerza: [{ codigo: 'SEN-0415', titulo: 'Actualización epidemiológica regional por dengue en tierras bajas', naturaleza: 'riesgo', categoria: 'salud', prioridad: 'alta', estado: 'en_verificacion' }] },
    { codigo: 'INT-EJ-2', titulo: 'BBC Mundo: El Niño traerá lluvias por encima de lo normal a los Andes', resumen: 'Ejemplo: los servicios meteorológicos de la región prevén más lluvias en el altiplano y los valles entre diciembre y marzo.',
      naturaleza: 'riesgo', categoria: 'clima', prioridad: 'media', estado: 'detectada', departamentos: ['La Paz'], internacional: true,
      fuentes: ['Prensa internacional · BBC Mundo, Reuters y AP sobre Bolivia'],
      impacto_bolivia: { hay_impacto: true, ambitos: ['clima', 'infraestructura', 'turismo'], via: 'Más lluvias en los Yungas y el altiplano: cortes de ruta y salidas por río suspendidas', nivel: 'medio', plazo: 'semanas' },
      refuerza: [{ codigo: 'SEN-0418', titulo: 'Alerta naranja por lluvias fuertes en Yungas y Rurrenabaque (4 al 6 nov)', naturaleza: 'riesgo', categoria: 'clima', prioridad: 'alta', estado: 'confirmada' }] },
    { codigo: 'INT-EJ-3', titulo: 'CEPAL: el turismo internacional en Sudamérica seguirá creciendo en 2027', resumen: 'Ejemplo: la CEPAL proyecta más llegadas de turistas a la región, con los destinos de naturaleza a la cabeza.',
      naturaleza: 'oportunidad', categoria: 'mercados', prioridad: 'baja', estado: 'detectada', internacional: true,
      fuentes: ['CEPAL · comunicados sobre la región y Bolivia'],
      impacto_bolivia: { hay_impacto: true, ambitos: ['turismo', 'economia'], via: 'Más demanda regional de destinos de naturaleza como Uyuni', nivel: 'bajo', plazo: 'meses' },
      refuerza: [{ codigo: 'SEN-0416', titulo: 'Búsquedas sobre el "efecto espejo" de Uyuni suben con la temporada de lluvias', naturaleza: 'mixta', categoria: 'mercado', prioridad: 'media', estado: 'en_analisis' }] },
  ],
  contexto: {},
};
for (const s of DEMO.senales) {
  for (const n of s.refuerza ?? []) {
    (DEMO.contexto[n.codigo] ??= []).push({ codigo: s.codigo, titulo: s.titulo, via: s.impacto_bolivia?.via, nivel: s.impacto_bolivia?.nivel, ambitos: s.impacto_bolivia?.ambitos });
  }
}

const VACIO: DatosInternacional = { fuentes: [], senales: [], contexto: {} };
export const INTERNACIONAL_MS = 5 * 60 * 1000;

interface Estado {
  datos: DatosInternacional;
  /** de dónde salen: la base, el ejemplo, o la base sin el SQL 37 */
  origen: 'base' | 'ejemplo' | 'sin_instalar' | 'error';
  error: string | null;
  cargado: boolean;
  cargar: (real: boolean) => Promise<void>;
}

export const useInternacional = create<Estado>((set) => ({
  datos: VACIO,
  origen: 'ejemplo',
  error: null,
  cargado: false,
  cargar: async (real) => {
    if (!real || !supabase) { set({ datos: DEMO, origen: 'ejemplo', error: null, cargado: true }); return; }
    const { data, error } = await supabase.schema('vigilante').rpc('internacional_web');
    if (error) {
      const sinInstalar = /internacional_web/.test(error.message) && /(not find|no existe|does not exist|schema cache)/i.test(error.message);
      set({ datos: VACIO, origen: sinInstalar ? 'sin_instalar' : 'error', error: sinInstalar ? null : traducir(error.message), cargado: true });
      return;
    }
    const d = (data ?? {}) as Partial<DatosInternacional>;
    set({ datos: { fuentes: d.fuentes ?? [], senales: d.senales ?? [], contexto: d.contexto ?? {} }, origen: 'base', error: null, cargado: true });
  },
}));

/** códigos de las señales que vienen de fuentes internacionales (para marcarlas en Señales) */
export const codigosInternacionales = (d: DatosInternacional): Set<string> =>
  new Set(d.senales.filter((s) => s.internacional).map((s) => s.codigo));
