import type { Rol, Senal } from '../types';

/** minúsculas y sin tildes, para buscar */
export const norm = (s: unknown): string =>
  String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

export const ago = (m: number): string =>
  m < 1 ? 'ahora'
    : m < 60 ? `hace ${Math.round(m)} min`
      : m < 1440 ? `hace ${Math.round(m / 60)} h`
        : `hace ${Math.round(m / 1440)} d`;

/** hora local desplazada m minutos respecto a ahora */
export const clock = (m: number): string =>
  new Date(Date.now() + m * 60000).toLocaleTimeString('es-BO', { hour: '2-digit', minute: '2-digit' });

/** puntuación compuesta: relevancia 45 %, novedad 25 %, confianza 30 % */
export const scoreOf = (s: Senal): number =>
  Math.round((s.rel * 0.45 + s.nov * 0.25 + s.conf * 10 * 0.3) * 10) / 10;

export const ROLE_NAME: Record<Rol, string> = { visor: 'Visor', analista: 'Analista', admin: 'Administrador' };

const PREFIX = 'orbita-vig-';
export const storage = {
  get<T>(k: string, fallback: T): T {
    try {
      const v = JSON.parse(localStorage.getItem(PREFIX + k) ?? 'null');
      return (v ?? fallback) as T;
    } catch {
      return fallback;
    }
  },
  set(k: string, v: unknown): void {
    try { localStorage.setItem(PREFIX + k, JSON.stringify(v)); } catch { /* sin almacenamiento */ }
  },
};

/** «12 min», «3 h 20 min» o «2 días» para el plazo de revisión */
export function plazoTexto(min: number): string {
  if (min < 60) return `${min} min`;
  if (min < 1440) { const h = Math.floor(min / 60), m = min % 60; return m ? `${h} h ${m} min` : `${h} h`; }
  const d = Math.round(min / 1440); return d === 1 ? '1 día' : `${d} días`;
}

/** Vista por defecto del panel: últimos días, plazos abiertos y lo que espera decisión */
/** la señal espera la aprobación de una persona (18_aprobacion_analista.sql) */
export function porRevisar(s: { sla?: number | null; revisionVencida?: boolean; estado: string }): boolean {
  return (Boolean(s.sla) || Boolean(s.revisionVencida)) && ['detectada', 'en_analisis', 'en_verificacion'].includes(s.estado);
}

export function esReciente(s: { min: number; plazo?: number | null; estado: string }, dias = 7): boolean {
  return s.min <= dias * 1440 || (s.plazo != null && s.plazo >= 0)
    || ['detectada', 'en_analisis', 'en_verificacion'].includes(s.estado);
}
