// Tres puntuaciones separadas por señal (mejora 4 de la PoC). La fuente es la base:
// vigilante.puntuaciones() en db/generico/22_puntuaciones.sql. Aquí se repiten las mismas reglas
// solo para los datos de ejemplo y para vigilante.json antiguos que no las traen.
import type { Puntuaciones, Senal } from '../types';
import { FUENTES_DEMO } from '../data/demo';

/** Cómo se calcula cada número (documentación). Desde el 36 el ratón ya no muestra esto, sino el porqué de AVIA (porqueAvia). */
export const EXPLICA = {
  fiabilidad: 'Cuánto respaldo tiene la señal. La calcula la base, sin IA: fuente oficial +50; fuentes distintas 1 → +15, 2 → +30, 3 o más → +40; confirmada por una persona +10 (tope 100). Alta ≥ 70, media 40-69, baja < 40.',
  probabilidad: 'Qué tan probable es que pase o siga pasando. En las señales confirmadas la calcula la base al confirmarlas (fuente × 0,5 + número de fuentes × 0,3 + cuántas de su categoría se confirmaron × 0,2) y AVIA la ajusta como mucho ±20 puntos con la época, la zona y el historial, con su razón. En las demás, solo si AVIA la justifica; si no, «sin datos». Nunca se inventa.',
  impacto: 'Cuánto afecta al turismo (alto, medio o bajo) y por qué. Si AVIA no lo valoró, se deduce de su relevancia turística (1-10) y se dice.',
};

/** Palabras con las que suele empezar una razón: se pasan a minúscula tras «porque» (los nombres propios no) */
const COMUNES = new Set(['el', 'la', 'los', 'las', 'lo', 'un', 'una', 'es', 'son', 'hay', 'solo', 'sólo', 'en', 'se', 'ya', 'no',
  'este', 'esta', 'estos', 'estas', 'ese', 'esa', 'aviso', 'bloqueo', 'según', 'cada', 'casi', 'tras', 'durante', 'dos', 'tres', 'varias', 'varios']);

/** Lo que va tras «porque»: sin «porque» repetido ni punto final */
function porque(r: string): string {
  const t = r.trim().replace(/^porque\s+/i, '').replace(/[.\s]+$/, '');
  return COMUNES.has(t.split(/[\s,;]/)[0].toLowerCase()) ? t[0].toLowerCase() + t.slice(1) : t;
}

/** La razón de AVIA como frase suelta: «Porque es plena temporada de lluvias…» */
export function porqueFrase(r: string): string {
  return `Porque ${porque(r)}.`;
}

/**
 * Lo que sale al pasar el ratón (36): la interpretación de AVIA en texto, no la fórmula.
 * «AVIA determina que la fiabilidad es del 65 % porque lo avisa el SENAMHI…».
 * Si AVIA aún no lo explicó, solo el número.
 */
export function porqueAvia(que: 'fiabilidad' | 'probabilidad' | 'impacto', p: Puntuaciones): string {
  if (que === 'fiabilidad') {
    const num = `${p.fiabilidad.valor}\u00a0%`;
    return p.fiabilidad.avia ? `AVIA determina que la fiabilidad es del ${num} porque ${porque(p.fiabilidad.avia)}.` : `Fiabilidad: ${num}`;
  }
  if (que === 'probabilidad') {
    const v = p.probabilidad.valor;
    if (v == null) return 'Probabilidad: sin datos';
    const num = `${Math.round(v * 100)}\u00a0%`;
    return p.probabilidad.avia ? `AVIA determina que la probabilidad de que ocurra es del ${num} porque ${porque(p.probabilidad.avia)}.` : `Probabilidad: ${num}`;
  }
  const n = p.impacto.nivel;
  if (n === 'sin datos') return 'Impacto turístico: sin datos';
  return p.impacto.avia ? `AVIA determina que el impacto turístico es ${n} porque ${porque(p.impacto.avia)}.` : `Impacto turístico: ${n}`;
}

const NIVEL_FIA = (v: number) => (v >= 70 ? 'alta' : v >= 40 ? 'media' : 'baja');

/** Razones de ejemplo de AVIA (36) para ver el tooltip en la demo: probabilidad, fiabilidad, impacto */
const RAZONES_DEMO: Record<string, [string, string, string]> = {
  'SEN-0418': ['es plena temporada de lluvias en Los Yungas y el norte de La Paz, y el aviso trae fechas y zonas concretas',
    'lo avisa el SENAMHI, que es la fuente oficial del clima, y la prensa lo repite',
    'coincide con un fin de semana largo en Coroico y con las salidas por río de Rurrenabaque'],
  'SEN-0413': ['la aerolínea ya lo anunció con fecha, aunque la DGAC todavía no lo publicó y las rutas nuevas a veces se retrasan',
    'solo lo cuentan medios de prensa y una búsqueda web, sin documento oficial de la DGAC',
    'una ruta diaria con Lima abre paquetes combinados con las Misiones jesuíticas en temporada alta'],
  'SEN-0410': ['el decreto ya está publicado en la Gaceta Oficial y los feriados trasladados casi siempre se cumplen',
    'sale de la Gaceta Oficial, aunque por ahora es la única fuente',
    'un fin de semana de tres días mueve turismo interno hacia destinos cercanos como Torotoro y Sucre'],
};

/** Las de la base si llegaron; si no, las mismas reglas con lo que hay en la señal */
export function puntuacionesDe(s: Senal): Puntuaciones {
  if (s.puntos) return s.puntos;
  const p = { ...puntuacionesEjemplo(s), probabilidad: probabilidadEjemplo(s) };
  const r = RAZONES_DEMO[s.id];
  if (!r || p.probabilidad.valor == null) return p;
  return {
    fiabilidad: { ...p.fiabilidad, avia: r[1] },
    probabilidad: { ...p.probabilidad, origen: 'avia', avia: r[0], justificacion: r[0] },
    impacto: { ...p.impacto, avia: r[2] },
  };
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
