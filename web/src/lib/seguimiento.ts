// Seguimiento de recomendaciones (P2 de la auditoría para la Dirección, 2026-11-22): de cada
// recomendación de AVIA queda qué se recomendó, qué se hizo y qué pasó. Mismas reglas que
// db/generico/50_seguimiento_recomendaciones.sql:
//   · cuatro estados: pendiente, en curso, resuelta, sin efecto; sin dato guardado = pendiente;
//   · para cerrar (resuelta o sin efecto) hace falta una nota;
//   · «por atender» = riesgos en Acción o Atención y oportunidades que cierran o empiezan en 7 días;
//   · el resumen enseña eso, lo que está en curso y lo cerrado en los últimos 7 días.
import type { EstadoSeguimiento, Senal, Seguimiento } from '../types';
import { cierreDe, estadoDeSenal } from './direccion';
import { hoyBolivia } from './vigencia';

export const ESTADOS_SEG: EstadoSeguimiento[] = ['pendiente', 'en_curso', 'resuelta', 'sin_efecto'];
export const SEG_TXT: Record<EstadoSeguimiento, string> = {
  pendiente: 'Pendiente', en_curso: 'En curso', resuelta: 'Resuelta', sin_efecto: 'Sin efecto',
};
export const SEG_AYUDA: Record<EstadoSeguimiento, string> = {
  pendiente: 'Nadie la ha tomado todavía',
  en_curso: 'Alguien está actuando',
  resuelta: 'Se actuó y quedó resuelto',
  sin_efecto: 'No hizo falta, no se pudo o no sirvió',
};
/** para cerrar hace falta contar qué pasó */
export const pideNota = (e: EstadoSeguimiento) => e === 'resuelta' || e === 'sin_efecto';
export const cerrada = (e: EstadoSeguimiento) => e === 'resuelta' || e === 'sin_efecto';

export const seguimientoDe = (s: Senal): Seguimiento => s.seguimiento ?? { estado: 'pendiente' };

const enDias = (fecha: string | null | undefined, hoy: string, n: number) => {
  if (!fecha) return false;
  const d = Math.round((Date.parse(`${fecha.slice(0, 10)}T12:00:00Z`) - Date.parse(`${hoy}T12:00:00Z`)) / 864e5);
  return d >= 0 && d <= n;
};

/** la recomendación pesa para la Dirección y debería tener a alguien encima */
export function pesa(s: Senal, ahora = Date.now()): boolean {
  if (s.estado === 'descartada') return false;
  const e = estadoDeSenal(s);
  if (e === 'accion' || e === 'atencion') return true;
  if (s.naturaleza === 'riesgo') return false;
  const hoy = hoyBolivia(ahora);
  return enDias(cierreDe(s, ahora), hoy, 7) || enDias(s.evento?.inicio, hoy, 7);
}

export interface ResumenSeguimiento {
  cuenta: Record<EstadoSeguimiento, number>;
  /** en curso primero, luego pendientes (Acción antes que Atención), luego lo cerrado en 7 días */
  items: Senal[];
}

export function resumenSeguimiento(senales: Senal[], ahora = Date.now()): ResumenSeguimiento {
  const hace7 = ahora - 7 * 864e5;
  const items = senales.filter((s) => {
    if (s.estado === 'descartada') return false;
    const g = seguimientoDe(s);
    if (g.estado === 'en_curso') return true;
    if (g.estado === 'pendiente') return pesa(s, ahora);
    return g.cuando ? Date.parse(g.cuando) >= hace7 : true;
  });
  const ord = (s: Senal) => ['en_curso', 'pendiente', 'resuelta', 'sin_efecto'].indexOf(seguimientoDe(s).estado);
  const dir = (s: Senal) => ({ accion: 0, atencion: 1, normal: 2 })[estadoDeSenal(s)];
  items.sort((a, b) => ord(a) - ord(b) || dir(a) - dir(b)
    || (Date.parse(seguimientoDe(b).cuando ?? '') || 0) - (Date.parse(seguimientoDe(a).cuando ?? '') || 0));
  const cuenta = { pendiente: 0, en_curso: 0, resuelta: 0, sin_efecto: 0 } as Record<EstadoSeguimiento, number>;
  items.forEach((s) => { cuenta[seguimientoDe(s).estado] += 1; });
  return { cuenta, items };
}
