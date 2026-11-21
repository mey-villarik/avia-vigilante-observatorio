// Resumen del día de la web pública, siempre coherente con las tarjetas de la página.
//
// La base genera el resumen una vez al día (08:00, db/generico/16_tareas_programadas.sql)
// y lo deja congelado. Si a esa hora no había alertas guarda «No hay alertas confirmadas»;
// si después el equipo publica, las tarjetas aparecen pero el resumen seguía diciendo
// que no había nada. Aquí se arma con lo que hay ahora:
//   1. las alertas del resumen de las 08:00 que siguen a la vista;
//   2. más las publicadas después que aún no estaban;
// ordenadas por prioridad y, a igual prioridad, de la más reciente a la más antigua.
// «No hay alertas» solo sale cuando de verdad no hay ninguna tarjeta actual.
import type { AlertaPublica, Publicas } from '../services/publico';

export const MAX_RESUMEN = 7;
const PESO: Record<AlertaPublica['prioridad'], number> = { alta: 0, media: 1, baja: 2 };

export interface ResumenVisible {
  /** alertas a listar (máx. 7) */
  items: AlertaPublica[];
  /** alertas actuales que no entran en la lista */
  resto: number;
  /** cuántas se publicaron después del resumen de las 08:00 */
  nuevas: number;
  /** texto a mostrar cuando no hay ninguna alerta actual */
  vacio: string | null;
}

export function resumenVisible(d: Publicas): ResumenVisible {
  const actuales = d.alertas.filter((a) => a.actual);
  if (!actuales.length) {
    return { items: [], resto: 0, nuevas: 0, vacio: d.resumen?.texto || d.mensajeVacio };
  }
  const delResumen = new Set(d.resumen?.alertas ?? []);
  const orden = (x: AlertaPublica, y: AlertaPublica) => (PESO[x.prioridad] ?? 3) - (PESO[y.prioridad] ?? 3)
    || new Date(y.publicada_en).getTime() - new Date(x.publicada_en).getTime();
  // las del resumen que siguen a la vista y las publicadas después, todas por prioridad
  const previas = (d.resumen?.alertas ?? [])
    .map((id) => actuales.find((a) => a.id === id))
    .filter((a): a is AlertaPublica => Boolean(a));
  const nuevasL = actuales.filter((a) => !delResumen.has(a.id)).sort(orden);
  const todas = [...previas, ...nuevasL].sort(orden);
  const items = todas.slice(0, MAX_RESUMEN);
  return {
    items,
    resto: actuales.length - items.length,
    nuevas: d.resumen ? nuevasL.length : 0,
    vacio: null,
  };
}
