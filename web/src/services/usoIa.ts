// Uso de tokens de IA (db/generico/52_uso_tokens.sql) y saldo de la cuenta del modelo (avia_api /saldo).
// Solo para analistas y administradores: la base devuelve null a un visor y la web pública no lo pide.
//   · tokens: lo que anotan el clasificador y el chat/análisis de AVIA en vigilante.system_logs;
//   · saldo: lo que DeepSeek dice que le queda a la cuenta (incluye lo que Hermes gasta por su lado).
// «Lo que queda» del presupuesto solo existe si hay ia_presupuesto_usd_mes o ia_tope_tokens_mes en parámetros.
import { create } from 'zustand';
import { supabase, traducir } from './auth';
import { aviaConectado, remoto, type SaldoModelo } from './avia';

export interface UsoPeriodo {
  llamadas: number; entrada: number; salida: number; tokens: number; costo_usd: number;
  desde?: string | null; ultimo?: string | null;
}

export interface UsoTokens {
  hoy: UsoPeriodo;
  mes: UsoPeriodo;
  acumulado: UsoPeriodo;
  por_proceso: (UsoPeriodo & { proceso: string })[];
  serie_14d: { dia: string; tokens: number; costo_usd: number }[];
  tarifa: { entrada_usd_millon: number | null; salida_usd_millon: number | null } | null;
  costo_estimado: boolean;
  presupuesto_usd_mes: number | null;
  restante_usd_mes: number | null;
  tope_tokens_mes: number | null;
  restante_tokens_mes: number | null;
  generado: string;
}

export const PROCESO_TXT: Record<string, string> = {
  clasificador: 'Clasificador de noticias',
  'avia-chat': 'Chat con AVIA',
  'avia-analisis': 'Análisis de AVIA',
  'avia-evaluar': 'Evaluar una noticia',
};

interface Estado {
  uso: UsoTokens | null;
  saldo: SaldoModelo | null;
  /** false si la base aún no tiene el 52 */
  disponible: boolean;
  cargando: boolean;
  error: string | null;
  cargar: () => Promise<void>;
}

const noInstalado = (m: string) => /uso_tokens/.test(m) && /(not find|no existe|does not exist|schema cache)/i.test(m);

export const useUsoIa = create<Estado>((set, get) => ({
  uso: null,
  saldo: null,
  disponible: true,
  cargando: false,
  error: null,
  cargar: async () => {
    if (!supabase || get().cargando) return;
    set({ cargando: true });
    const [u, sal] = await Promise.allSettled([
      get().disponible ? supabase.schema('vigilante').rpc('uso_tokens') : Promise.resolve({ data: null, error: null }),
      aviaConectado ? remoto.saldo() : Promise.resolve(null),
    ]);
    const cambios: Partial<Estado> = { cargando: false, error: null };
    if (u.status === 'fulfilled') {
      const { data, error } = u.value as { data: unknown; error: { message: string } | null };
      if (error) {
        if (noInstalado(error.message)) cambios.disponible = false;
        else cambios.error = traducir(error.message);
      } else if (data && typeof data === 'object' && 'hoy' in data) {
        cambios.uso = data as UsoTokens;
      }
    } else cambios.error = (u.reason as Error)?.message ?? 'No se pudo leer el uso de IA';
    cambios.saldo = sal.status === 'fulfilled' ? sal.value : { disponible: null, motivo: 'No se pudo consultar el saldo del modelo' };
    set(cambios);
  },
}));

// ───────── Formato ─────────

/** 1234 → «1234», 12 345 → «12,3 mil», 1 234 567 → «1,23 M» */
export function tokensCorto(n: number | null | undefined): string {
  const v = Number(n ?? 0);
  if (v >= 1e6) return `${(v / 1e6).toLocaleString('es-BO', { maximumFractionDigits: v >= 1e7 ? 1 : 2 })} M`;
  if (v >= 1e4) return `${(v / 1e3).toLocaleString('es-BO', { maximumFractionDigits: 1 })} mil`;
  return v.toLocaleString('es-BO');
}

export const tokensLargo = (n: number | null | undefined) => Number(n ?? 0).toLocaleString('es-BO');

export function dinero(n: number | null | undefined, moneda = 'USD'): string {
  const v = Number(n ?? 0);
  const dec = v !== 0 && Math.abs(v) < 0.1 ? 4 : 2;
  return `${moneda} ${v.toLocaleString('es-BO', { minimumFractionDigits: 2, maximumFractionDigits: dec })}`;
}

/** lo que queda del mes: por presupuesto en USD o por tope de tokens (null si no hay límite guardado) */
export function restanteMes(u: UsoTokens | null): { usado: number; limite: number; queda: number; texto: string; unidad: 'usd' | 'tokens' } | null {
  if (!u) return null;
  if (u.presupuesto_usd_mes != null && u.presupuesto_usd_mes > 0) {
    const usado = Number(u.mes.costo_usd), limite = Number(u.presupuesto_usd_mes);
    const queda = Number(u.restante_usd_mes ?? Math.max(limite - usado, 0));
    return { usado, limite, queda, unidad: 'usd', texto: `Quedan ${dinero(queda)} de ${dinero(limite)} este mes` };
  }
  if (u.tope_tokens_mes != null && u.tope_tokens_mes > 0) {
    const usado = Number(u.mes.tokens), limite = Number(u.tope_tokens_mes);
    const queda = Number(u.restante_tokens_mes ?? Math.max(limite - usado, 0));
    return { usado, limite, queda, unidad: 'tokens', texto: `Quedan ${tokensCorto(queda)} de ${tokensCorto(limite)} tokens este mes` };
  }
  return null;
}
