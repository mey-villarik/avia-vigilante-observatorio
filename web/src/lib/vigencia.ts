// Oportunidades caducadas: cuando su plazo ya pasó no se muestran en ningún lugar de la web
// (panel, Señales, Oportunidades, buscador, chat del navegador ni web pública). Siguen guardadas
// en la base durante el periodo de retención; solo se ocultan.
import type { Naturaleza } from '../types';

/** true si la fecha ya pasó. AAAA-MM-DD cuenta hasta el final de ese día en Bolivia (UTC−4). */
export function fechaVencida(fecha?: string | null, ahora = Date.now()): boolean {
  if (!fecha) return false;
  const t = Date.parse(/^\d{4}-\d{2}-\d{2}$/.test(fecha) ? `${fecha}T23:59:59-04:00` : fecha);
  return !Number.isNaN(t) && t < ahora;
}

/** Oportunidad (o mixta) cuyo plazo para actuar ya pasó. Los riesgos no caducan por plazo. */
export const oportunidadVencida = (naturaleza: Naturaleza | string | null | undefined, plazo?: string | null, ahora = Date.now()) =>
  naturaleza !== 'riesgo' && fechaVencida(plazo, ahora);
