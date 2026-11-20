// Tres puntuaciones separadas por señal (mejora 4 de la PoC). La fuente es la base:
// vigilante.puntuaciones() en db/generico/22_puntuaciones.sql. Aquí se repiten las mismas reglas
// solo para los datos de ejemplo y para vigilante.json antiguos que no las traen.
import type { Puntuaciones, Senal } from '../types';
import { FUENTES_DEMO } from '../data/demo';

export const EXPLICA = {
  fiabilidad: 'Cuánto respaldo tiene la señal. La calcula la base, sin IA: fuente oficial +50; fuentes distintas 1 → +15, 2 → +30, 3 o más → +40; confirmada por una persona +10 (tope 100). Alta ≥ 70, media 40-69, baja < 40.',
  probabilidad: 'Qué tan probable es que pase o siga pasando. En las señales confirmadas la calcula la base al confirmarlas (fuente × 0,5 + número de fuentes × 0,3 + cuántas de su categoría se confirmaron × 0,2) y AVIA la ajusta como mucho ±20 puntos con la época, la zona y el historial, con su razón. En las demás, solo si AVIA la justifica; si no, «sin datos». Nunca se inventa.',
  impacto: 'Cuánto afecta al turismo (alto, medio o bajo) y por qué. Si AVIA no lo valoró, se deduce de su relevancia turística (1-10) y se dice.',
};

const NIVEL_FIA = (v: number) => (v >= 70 ? 'alta' : v >= 40 ? 'media' : 'baja');

/** Las de la base si llegaron; si no, las mismas reglas con lo que hay en la señal */
export function puntuacionesDe(s: Senal): Puntuaciones {
  if (s.puntos) return s.puntos;
  return { ...puntuacionesEjemplo(s), probabilidad: probabilidadEjemplo(s) };
}

/** Datos de ejemplo: en las confirmadas, el mismo cálculo base del 33 (sin historial: tasa 0,5) */
function probabilidadEjemplo(s: Senal): Puntuaciones['probabilidad'] {
  if (s.estado !== 'confirmada' && s.estado !== 'publicada') {
    return { valor: null, nivel: 'sin datos', justificacion: 'No hay datos para estimar si pasará; no se inventa' };
  }
  const tipos = s.fuentes.map((id) => FUENTES_DEMO.find((f) => f.id === id)?.tipo).filter(Boolean);
  const peso = tipos.includes('oficial') ? 5 : tipos.includes('organismo_internacional') ? 4 : tipos.includes('medio') ? 3 : tipos.length ? 1 : 2;
  const n = Math.max(1, s.corr, tipos.length);
  const v = Math.min(0.95, Math.max(0.05, Math.round((peso / 5 * 0.5 + Math.min(n, 4) / 4 * 0.3 + 0.5 * 0.2) * 100) / 100));
  return {
    valor: v, nivel: v >= 0.7 ? 'alta' : v >= 0.4 ? 'media' : 'baja', origen: 'base', base: v,
    justificacion: `Cálculo base (datos de ejemplo): fuente de peso ${peso}/5 y ${n} ${n === 1 ? 'fuente' : 'fuentes distintas'}.`,
  };
}

/** Las tres puntuaciones con las reglas del 22, para datos de ejemplo o vigilante.json antiguos */
function puntuacionesEjemplo(s: Senal): Puntuaciones {
  const fuentes = s.fuentes.map((id) => FUENTES_DEMO.find((f) => f.id === id)).filter(Boolean);
  const oficial = fuentes.some((f) => f!.tipo === 'oficial');
  const n = Math.max(s.corr, fuentes.length, s.enlaces?.length ?? 0);
  const persona = s.estado === 'confirmada' || s.estado === 'publicada';
  const pts = n >= 3 ? 40 : n === 2 ? 30 : n === 1 ? 15 : 0;
  const valor = Math.min(100, (oficial ? 50 : 0) + pts + (persona ? 10 : 0));
  const rel = s.rel || null;
  return {
    fiabilidad: {
      valor, nivel: NIVEL_FIA(valor), noticias: n, fuentes: n, oficial,
      motivos: [
        oficial ? 'Fuente oficial (+50)' : 'Ninguna fuente oficial (+0)',
        n ? `${n} ${n === 1 ? 'fuente' : 'fuentes distintas'} (+${pts})` : 'Sin noticias enlazadas (+0)',
        persona ? 'Confirmada por una persona (+10)' : 'Sin confirmar por una persona (+0)',
      ],
    },
    probabilidad: { valor: null, nivel: 'sin datos', justificacion: 'No hay datos para estimar si pasará; no se inventa' },
    impacto: rel == null
      ? { nivel: s.prioridad === 'alta' ? 'alto' : s.prioridad === 'media' ? 'medio' : 'bajo', motivo: `Deducido de la prioridad que dio AVIA (${s.prioridad})`, origen: 'prioridad' }
      : { nivel: rel >= 7 ? 'alto' : rel >= 4 ? 'medio' : 'bajo', motivo: `Deducido de la relevancia turística que dio AVIA (${rel}/10)`, origen: 'relevancia' },
  };
}
