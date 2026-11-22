// Plazos de cierre: UNA sola regla en panel, web pública y chat (CP1 y CP2 de Carlos, SQL 48).
//
// CP1 · Lo que se guarda es la FECHA de cierre (AAAA-MM-DD), nunca «quedan 12 días». Los días que
//       faltan se calculan en el momento de mirar: fecha de cierre − hoy, los dos en hora de Bolivia.
//       0 = cierra hoy, 1 = cierra mañana, negativo = ya cerró. Es la misma cuenta que
//       vigilante.dias_para() y vigilante.cierre() en la base y _dias_para_cierre() en avia_api.py.
// CP2 · La certeza del plazo va aparte de la certeza del evento. Un plazo solo es «confirmado» si la
//       fecha la da una fuente primaria (oficial o quien convoca) tal cual; si no, «pendiente de
//       verificar», aunque el evento esté confirmado.
import type { Senal } from '../types';
import { hoyBolivia } from './vigencia';
import { enBolivia } from './hora';

export type CertezaPlazo = 'confirmado' | 'pendiente de verificar';
export interface Cierre {
  /** AAAA-MM-DD en hora de Bolivia */
  fecha: string;
  certeza: CertezaPlazo;
  motivo?: string;
}

const SOLO_DIA = /^\d{4}-\d{2}-\d{2}$/;

/** AAAA-MM-DD del cierre en Bolivia, venga como fecha o como instante con hora */
export function fechaCierre(f?: string | null): string | null {
  if (!f) return null;
  if (SOLO_DIA.test(f)) return f;
  const t = Date.parse(f);
  return Number.isNaN(t) ? null : new Date(t - 4 * 3600000).toISOString().slice(0, 10);
}

/** días de calendario entre hoy (Bolivia) y el día de cierre; null sin fecha */
export function diasParaCierre(f?: string | null, ahora = Date.now()): number | null {
  const d = fechaCierre(f);
  if (!d) return null;
  return Math.round((Date.parse(`${d}T00:00:00Z`) - Date.parse(`${hoyBolivia(ahora)}T00:00:00Z`)) / 86400000);
}

/** «cierra hoy (22/11/2026)», «cierra mañana (23/11/2026)», «cierra el 30/11/2026, en 8 días», «cerró el 20/11/2026» */
export function cierreTexto(f?: string | null, ahora = Date.now()): string {
  const d = fechaCierre(f);
  const n = diasParaCierre(d, ahora);
  if (!d || n == null) return 'sin fecha de cierre';
  const fecha = enBolivia(d, 'fecha');
  if (n < 0) return `cerró el ${fecha}`;
  if (n === 0) return `cierra hoy (${fecha})`;
  if (n === 1) return `cierra mañana (${fecha})`;
  return `cierra el ${fecha}, en ${n} días`;
}

/** texto corto para etiquetas: «Hoy», «Mañana», «8 días», «Cerrado» */
export function diasCorto(n: number | null | undefined): string {
  if (n == null) return '';
  if (n < 0) return 'Cerrado';
  if (n === 0) return 'Hoy';
  if (n === 1) return 'Mañana';
  return `${n} días`;
}

/** certeza del plazo de una señal; sin dato de la base, «pendiente de verificar» (nunca se supone confirmado) */
export function certezaPlazo(s: Pick<Senal, 'cierre'>): { nivel: CertezaPlazo; motivo: string } {
  const c = s.cierre;
  if (c?.certeza === 'confirmado') return { nivel: 'confirmado', motivo: c.motivo || 'Lo da una fuente primaria' };
  return { nivel: 'pendiente de verificar', motivo: c?.motivo || 'Ninguna fuente primaria (oficial o quien convoca) da esta fecha todavía' };
}
