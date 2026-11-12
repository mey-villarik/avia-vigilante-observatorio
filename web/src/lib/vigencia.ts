// Qué se muestra en la web (regla de Meysel, 2026-11-12). Lo que no se muestra sigue guardado
// en la base hasta la retención; solo se oculta. La misma regla está en SQL
// (vigilante.senal_vigente, db/generico/19) para que el chat AVIA tampoco vea lo caducado.
//
// - Con fechas (evento de inicio a fin, o plazo para actuar): se ve hasta que termina el último
//   día, en Bolivia. Del 10 al 14 → el 11 se ve; solo el 10 → el 11 ya no.
// - Sin fechas: se ve 24 h desde la última noticia que la alimentó («noticia viva»).

const VIVA_MS = 24 * 3600000;

/** hoy en Bolivia (UTC−4), AAAA-MM-DD */
export const hoyBolivia = (ahora = Date.now()) => new Date(ahora - 4 * 3600000).toISOString().slice(0, 10);

/** AAAA-MM-DD de una fecha («2026-11-14» o ISO). Las fechas con hora se pasan a Bolivia. */
function dia(f?: string | null): string | null {
  if (!f) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(f)) return f;
  const t = Date.parse(f);
  return Number.isNaN(t) ? null : new Date(t - 4 * 3600000).toISOString().slice(0, 10);
}

/** true si el último día de esas fechas ya terminó; null si no hay ninguna fecha */
export function fechasVencidas(fechas: (string | null | undefined)[], ahora = Date.now()): boolean | null {
  const dias = fechas.map(dia).filter((x): x is string => Boolean(x));
  if (!dias.length) return null;
  return dias.sort()[dias.length - 1] < hoyBolivia(ahora);
}

/** true si la fecha (plazo de una ficha de oportunidad) ya pasó */
export const fechaVencida = (f?: string | null, ahora = Date.now()) => fechasVencidas([f], ahora) === true;

/** ¿se muestra? con fechas: hasta el último día; sin fechas: 24 h desde la última noticia */
export function vigente(fechas: (string | null | undefined)[], ultimaNoticia?: string | null, ahora = Date.now()): boolean {
  const v = fechasVencidas(fechas, ahora);
  if (v !== null) return !v;
  const t = ultimaNoticia ? Date.parse(ultimaNoticia) : NaN;
  return Number.isNaN(t) ? true : ahora - t <= VIVA_MS;
}
