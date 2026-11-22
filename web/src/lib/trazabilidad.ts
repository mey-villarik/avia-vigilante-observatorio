// Trazabilidad mínima por señal (mejora 5 de la PoC). La fuente es la base:
// vigilante.trazabilidad() en db/generico/23_trazabilidad.sql. Aquí solo se formatea y, para los
// datos de ejemplo o vigilante.json antiguos, se arma con lo que hay (sin inventar fechas).
import type { Senal, Trazabilidad } from '../types';
import { FUENTES_DEMO } from '../data/demo';
import { enBolivia } from './hora';

/** «12/11 14:05» en hora de Bolivia; solo «12/11/2026» si la fecha no trae hora */
export function fechaBolivia(f?: string | null): string {
  if (!f) return '—';
  if (/^\d{4}-\d{2}-\d{2}$/.test(f)) { const [a, m, d] = f.split('-'); return `${d}/${m}/${a}`; }
  return enBolivia(f, 'fechaHora');
}

export function trazaDe(s: Senal, ahora = Date.now()): Trazabilidad {
  if (s.traza) return s.traza;
  const demo = s.fuentes.map((id) => FUENTES_DEMO.find((f) => f.id === id)).filter((f): f is NonNullable<typeof f> => Boolean(f));
  const fuentes: Trazabilidad['fuentes'] = [
    ...demo.map((f) => ({ nombre: f.nombre, tipo: f.tipo, oficial: f.tipo === 'oficial', url: f.url })),
    ...(s.enlaces ?? []).map((e) => ({ nombre: e.nombre || 'Fuente', url: e.url, fecha: e.fecha,
      nota: 'fecha sin distinguir (dato antiguo): no se sabe si es publicación o recogida' })),
  ];
  const h = s.historial?.find((x) => ['en_verificacion', 'confirmada', 'publicada', 'descartada'].includes(x.a));
  return {
    detectada: new Date(ahora - s.min * 60000).toISOString(),
    fuentes,
    noticias: fuentes.length,
    ultima_verificacion: h ? { cuando: null, cuandoTexto: h.cuando, quien: h.quien, estado: h.a } : null,
  };
}
