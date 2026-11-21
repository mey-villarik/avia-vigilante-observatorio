// Una sola hora en todo el panel: la de Bolivia (America/La_Paz, UTC−4, sin horario de verano),
// en formato 24 h. Da igual en qué país esté abierto el navegador. Toda fecha u hora que se
// muestre en la web pasa por aquí; no usar toLocaleString/toLocaleTimeString sueltos.

export const TZ_BOLIVIA = 'America/La_Paz';
const LOCALE = 'es-BO';

const fmt = (opts: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat(LOCALE, { ...opts, hour12: opts.hour ? false : undefined, timeZone: TZ_BOLIVIA });

const F = {
  hora: fmt({ hour: '2-digit', minute: '2-digit' }),
  fechaHora: fmt({ day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }),
  fechaHoraLarga: fmt({ day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }),
  diaHora: fmt({ weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }),
  fecha: fmt({ day: '2-digit', month: '2-digit', year: 'numeric' }),
  diaCorto: fmt({ day: 'numeric', month: 'short' }),
  diaLargo: fmt({ day: 'numeric', month: 'long' }),
  diaSemana: fmt({ weekday: 'short', day: 'numeric', month: 'short' }),
};
export type FormatoBolivia = keyof typeof F;

const SOLO_DIA = /^\d{4}-\d{2}-\d{2}$/;

/** instante de una fecha; «AAAA-MM-DD» sin hora se toma como mediodía en Bolivia (no cambia de día) */
function instante(f: string | number | Date): number {
  if (typeof f === 'number') return f;
  if (f instanceof Date) return f.getTime();
  return Date.parse(SOLO_DIA.test(f) ? `${f}T12:00:00-04:00` : f);
}

/** formatea en hora de Bolivia; «—» si no hay fecha, el texto tal cual si no se puede leer */
export function enBolivia(f: string | number | Date | null | undefined, formato: FormatoBolivia): string {
  if (f == null || f === '') return '—';
  const t = instante(f);
  if (Number.isNaN(t)) return String(f);
  return F[formato].format(t);
}

/** hora de Bolivia desplazada m minutos respecto a ahora («14:05») */
export const relojBolivia = (m = 0): string => F.hora.format(Date.now() + m * 60000);
