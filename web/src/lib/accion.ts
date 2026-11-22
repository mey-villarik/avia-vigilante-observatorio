// Etiqueta de acción para los riesgos (Dirección): «Actuar hoy», «Preparar» o «Seguir».
// Sustituye a la «puntuación» compuesta (relevancia, novedad, confianza) que en la lista de
// riesgos daba 1,8-2,7 a un derrumbe grave: esa cifra mide lo nueva y respaldada que es una
// noticia, no lo grave que es. La acción sale de la gravedad: prioridad, impacto turístico valorado por AVIA y
// palabras de daño grave en el título o el resumen. Gana siempre el nivel más alto.
import type { Senal } from '../types';
import { norm, scoreOf } from './util';
import { puntuacionesDe } from './puntuaciones';

export type Accion = 'actuar' | 'preparar' | 'seguir';

export const ACCION_TXT: Record<Accion, string> = { actuar: 'Actuar hoy', preparar: 'Preparar', seguir: 'Seguir' };
export const ACCION_AYUDA: Record<Accion, string> = {
  actuar: 'Riesgo grave o en curso: decidir hoy medidas, avisos y responsables.',
  preparar: 'Riesgo que puede crecer: preparar medidas y avisos por si se confirma o empeora.',
  seguir: 'Riesgo leve o lejano: seguirlo, sin medidas por ahora.',
};
/** para ordenar: primero lo urgente */
export const ACCION_ORDEN: Record<Accion, number> = { actuar: 0, preparar: 1, seguir: 2 };

/** daño grave a personas, rutas o servicios: nunca puede quedar en «Seguir» ni en «Preparar» */
const GRAVE = ['alerta roja', 'emergencia', 'desastre', 'catastrofe', 'derrumbe', 'deslizamiento', 'mazamorra', 'riada',
  'desborde', 'inundacion', 'fallecid', 'muert', 'herid', 'desaparecid', 'evacua', 'cierre total', 'bloqueo total',
  'incomunicad', 'colapso', 'brote', 'epidemia'];
/** aviso serio sin daño confirmado: como mínimo «Preparar» */
const SERIO = ['alerta naranja', 'bloqueo', 'cierre', 'corte', 'paro', 'huelga', 'suspension', 'cancelacion', 'restriccion',
  'granizada', 'helada', 'incendio', 'sequia', 'alerta'];

const contiene = (txt: string, l: string[]) => l.find((p) => txt.includes(p));

/** acción y el porqué en una frase, para el título al pasar el ratón */
export function accionDe(s: Senal): { accion: Accion; motivo: string } {
  const txt = norm(`${s.titulo} ${s.resumen ?? ''}`);
  // solo cuenta el impacto que AVIA valoró de verdad; el deducido de la relevancia no mide gravedad
  const imp = puntuacionesDe(s).impacto;
  const impacto = imp.origen === 'modelo' ? imp.nivel : 'sin datos';
  const grave = contiene(txt, GRAVE);
  const serio = contiene(txt, SERIO);
  let accion: Accion = 'seguir';
  let motivo = 'prioridad baja y sin señales de daño grave';
  if (s.prioridad === 'alta') { accion = 'actuar'; motivo = 'AVIA le dio prioridad alta'; }
  else if (impacto === 'alto') { accion = 'actuar'; motivo = 'AVIA valoró el impacto turístico como alto'; }
  else if (grave) { accion = 'actuar'; motivo = `habla de «${grave}»`; }
  else if (s.prioridad === 'media') { accion = 'preparar'; motivo = 'AVIA le dio prioridad media'; }
  else if (impacto === 'medio') { accion = 'preparar'; motivo = 'AVIA valoró el impacto turístico como medio'; }
  else if (serio) { accion = 'preparar'; motivo = `habla de «${serio}»`; }
  // un escenario es una predicción, no un hecho: se prepara, no se actúa
  if (s.escenario && accion === 'actuar') { accion = 'preparar'; motivo += ', pero es un escenario (predicción)'; }
  return { accion, motivo };
}

/** texto del ratón: la acción, qué significa y por qué; la cifra antigua solo como dato técnico */
export function accionTitulo(s: Senal): string {
  const { accion, motivo } = accionDe(s);
  return `${ACCION_TXT[accion]}: ${ACCION_AYUDA[accion]} Porque ${motivo}. (Puntuación técnica de la noticia: ${scoreOf(s)}; no mide gravedad.)`;
}

/** orden de riesgos: acción, luego lo más reciente */
export const ordenAccion = (a: Senal, b: Senal) =>
  ACCION_ORDEN[accionDe(a).accion] - ACCION_ORDEN[accionDe(b).accion] || a.min - b.min;
