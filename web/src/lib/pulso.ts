// Pulso del observatorio: índices calculados con las señales reales que la web ya lee de Supabase.
//
// Los índices miden lo SERIAS que son las señales activas, no cuántas hay (la cantidad se muestra
// aparte, debajo de cada anillo). Sumar señales no sirve: con el volumen real (100+ señales en 48 h)
// cualquier suma se queda pegada en 100.
//
// 1. Cada señal activa (no descartada) recibe un peso de 0 a 1:
//    - riesgo: prioridad × respaldo × etapa (lo verificado pesa más que lo detectado), donde el
//      respaldo es 0,5 + 0,5 × la fiabilidad de la evidencia (0-100, paso 4: la calcula la base);
//    - oportunidad: valor (45 % relevancia turística, 25 % novedad, 30 % fiabilidad) × etapa, y 0 si el plazo venció.
//    Desde la mejora 9 el respaldo usa la fiabilidad definida y no la «confianza» antigua del modelo.
// 2. El índice es el peso medio, con K señales «vacías» de más para que 1 o 2 señales sueltas
//    no den un índice alto: índice = 100 · Σ pesos / (n + K).
//    Ej.: 1 riesgo alto confirmado y con respaldo completo ≈ 33; 10 así ≈ 83.
// 3. El nivel Normal/Vigilancia/Atención/Crítico sale del índice de riesgo, con dos mínimos por volumen:
//    un riesgo alto verificado → al menos Vigilancia; 5 o más → al menos Atención.
// 4. Las fuentes no entran en los índices (una fuente caída no es un riesgo turístico), pero se
//    informan como «cobertura» porque con fuentes caídas los índices pueden quedarse cortos.
import type { Etapa, Fuente, Prioridad, PulsoDia, Senal } from '../types';
import { puntuacionesDe } from './puntuaciones';
import { cifrasFuentes } from './contadores';

export const PESO_PRIORIDAD: Record<Prioridad, number> = { alta: 1, media: 0.5, baja: 0.2 };

/** cuánto cuenta la señal según lo verificada que está */
export const PESO_ETAPA: Record<Etapa, number> = {
  publicada: 1, confirmada: 1, en_verificacion: 0.85, en_analisis: 0.7, detectada: 0.7, descartada: 0,
};

/** señales «vacías» que se añaden al promedio para que pocas señales no den un índice alto */
export const K = 2;

export type NivelVigilancia = 'Normal' | 'Vigilancia' | 'Atención' | 'Crítico';

export interface Pulso {
  /** 0-100: cuánto deben preocupar los riesgos activos */
  riesgo: number;
  nivelRiesgo: 'Bajo' | 'Moderado' | 'Alto' | 'Muy alto';
  /** 0-100: cuánto hay para aprovechar ahora */
  oportunidad: number;
  nivelOportunidad: 'Sin señales' | 'Escasa' | 'Moderada' | 'Favorable';
  vigilancia: NivelVigilancia;
  /** cifras que explican los índices */
  datos: {
    activas: number;
    riesgos: number; riesgosAltos: number; riesgosSinDecidir: number; revisionVencida: number;
    oportunidades: number; plazoAbierto: number; plazoCorto: number; plazoVencido: number;
    /** % de señales activas que son riesgo (las mixtas cuentan como riesgo y oportunidad) */
    pctRiesgo: number;
    fuentesLeidas: number; fuentesSinLeer: number; fuentesTotal: number;
  };
  /** desglose para explicar el cálculo: lo que aporta cada señal a su índice (0-1) */
  aportes: Aporte[];
  /** suma de pesos y número de señales de cada índice (índice = 100 · suma / (n + K)) */
  sumas: { riesgo: number; nRiesgos: number; oportunidad: number; nOportunidades: number };
}

export interface Aporte {
  id: string; titulo: string; indice: 'riesgo' | 'oportunidad';
  peso: number;
  /** los factores que se multiplicaron, para mostrarlos */
  factores: { prioridad?: number; respaldo?: number; etapa?: number; valor?: number; mixta?: number; escenario?: number };
  /** señales de oportunidad con el plazo vencido no suman */
  excluida?: string;
}

const media = (suma: number, n: number) => Math.round((100 * suma) / (n + K));

/** respaldo de la señal: 0,5 con fiabilidad 0 y 1 con fiabilidad 100 (así una señal sin respaldo aún cuenta la mitad) */
export const respaldo = (s: Senal) => 0.5 + 0.5 * Math.max(0, Math.min(100, puntuacionesDe(s).fiabilidad.valor)) / 100;

export function calcularPulso(senales: Senal[], fuentes: Fuente[]): Pulso {
  const activas = senales.filter((s) => s.estado !== 'descartada');
  const riesgos = activas.filter((s) => s.naturaleza !== 'oportunidad');
  const opps = activas.filter((s) => s.naturaleza !== 'riesgo');

  // Riesgo: prioridad × confianza × etapa (las mixtas cuentan la mitad).
  // Un riesgo cuyo plazo de revisión venció sin decisión pesa como confirmado: nadie lo está mirando.
  let sumaRiesgo = 0;
  const aportes: Aporte[] = [];
  for (const s of riesgos) {
    const etapa = s.revisionVencida ? 1 : PESO_ETAPA[s.estado];
    const mixta = s.naturaleza === 'mixta' ? 0.5 : 1;
    const f = { prioridad: PESO_PRIORIDAD[s.prioridad], respaldo: respaldo(s), etapa, mixta };
    const peso = f.prioridad * f.respaldo * f.etapa * f.mixta;
    sumaRiesgo += peso;
    aportes.push({ id: s.id, titulo: s.titulo, indice: 'riesgo', peso, factores: f });
  }

  // Oportunidad: puntuación de AVIA (relevancia, novedad, confianza) × etapa, solo si el plazo sigue abierto.
  // Los escenarios (predicciones) cuentan la mitad.
  let sumaOpp = 0;
  let plazoAbierto = 0, plazoCorto = 0, plazoVencido = 0;
  for (const s of opps) {
    if (s.plazo != null && s.plazo < 0) {
      plazoVencido++;
      aportes.push({ id: s.id, titulo: s.titulo, indice: 'oportunidad', peso: 0, factores: {}, excluida: 'el plazo ya venció' });
      continue;
    }
    if (s.plazo != null) { plazoAbierto++; if (s.plazo < 15) plazoCorto++; }
    const resp = (respaldo(s) - 0.5) * 2;   // fiabilidad 0-1
    const valor = Math.max(0, Math.min(1, (s.rel * 0.45 + s.nov * 0.25 + resp * 10 * 0.3) / 10));
    const mixta = s.naturaleza === 'mixta' ? 0.5 : 1;
    const escenario = s.escenario ? 0.5 : 1;
    const peso = valor * PESO_ETAPA[s.estado] * mixta * escenario;
    sumaOpp += peso;
    aportes.push({ id: s.id, titulo: s.titulo, indice: 'oportunidad', peso, factores: { valor, etapa: PESO_ETAPA[s.estado], mixta, escenario } });
  }

  const riesgo = media(sumaRiesgo, riesgos.length);
  const oportunidad = media(sumaOpp, opps.length);
  const riesgosAltos = riesgos.filter((s) => s.prioridad === 'alta').length;

  let vigilancia: NivelVigilancia = riesgo >= 75 ? 'Crítico' : riesgo >= 50 ? 'Atención' : riesgo >= 25 ? 'Vigilancia' : 'Normal';
  // Mínimos por volumen: riesgos altos ya verificados no pueden quedar en un nivel bajo.
  const altosVerificados = riesgos.filter((s) => s.prioridad === 'alta' && s.naturaleza === 'riesgo' && ['confirmada', 'publicada'].includes(s.estado)).length;
  if (altosVerificados >= 5 && (vigilancia === 'Normal' || vigilancia === 'Vigilancia')) vigilancia = 'Atención';
  else if (altosVerificados >= 1 && vigilancia === 'Normal') vigilancia = 'Vigilancia';

  // la misma cifra de fuentes que el encabezado y la pestaña Fuentes (cifrasFuentes)
  const cf = cifrasFuentes(fuentes);
  return {
    riesgo,
    nivelRiesgo: riesgo >= 75 ? 'Muy alto' : riesgo >= 50 ? 'Alto' : riesgo >= 25 ? 'Moderado' : 'Bajo',
    oportunidad,
    nivelOportunidad: opps.length === 0 ? 'Sin señales' : oportunidad >= 55 ? 'Favorable' : oportunidad >= 30 ? 'Moderada' : 'Escasa',
    vigilancia,
    datos: {
      activas: activas.length,
      riesgos: riesgos.length,
      riesgosAltos,
      riesgosSinDecidir: riesgos.filter((s) => ['detectada', 'en_analisis', 'en_verificacion'].includes(s.estado)).length,
      revisionVencida: riesgos.filter((s) => s.revisionVencida).length,
      oportunidades: opps.length,
      plazoAbierto, plazoCorto, plazoVencido,
      pctRiesgo: activas.length ? Math.round((100 * riesgos.length) / activas.length) : 0,
      fuentesLeidas: cf.leidas,
      fuentesSinLeer: cf.sinLeer,
      fuentesTotal: cf.total,
    },
    aportes,
    sumas: { riesgo: sumaRiesgo, nRiesgos: riesgos.length, oportunidad: sumaOpp, nOportunidades: opps.length },
  };
}

/** posición (0-100) del marcador en la barra Normal · Vigilancia · Atención · Crítico */
export function posicionVigilancia(p: Pulso): number {
  const base: Record<NivelVigilancia, number> = { Normal: 0, Vigilancia: 25, Atención: 50, Crítico: 75 };
  // dentro de su tramo según el índice, pero nunca por debajo del tramo que marca la regla mínima
  return Math.max(base[p.vigilancia] + 2, Math.min(98, Math.max(2, p.riesgo)));
}

// ───────── Evolución a 7 y 30 días (DIANA 2.3, db/generico/46_pulso_evolucion.sql) ─────────
// La base guarda el Pulso de cada día (tarea «vigilante-pulso», cada hora) y reconstruye los días
// anteriores con el historial de las señales. Aquí se compara el Pulso de AHORA con el de ese día.

/** menos de estos puntos de diferencia = estable */
export const UMBRAL_ESTABLE = 5;

export type Sentido = 'mejora' | 'empeora' | 'estable';

export interface Tendencia {
  indice: 'riesgo' | 'oportunidad';
  /** valor de entonces y de ahora (0-100) */
  antes: number; ahora: number;
  /** ahora − antes, en puntos */
  delta: number;
  /** hacia dónde va el número */
  flecha: 'sube' | 'baja' | 'igual';
  /** si eso es bueno o malo: en riesgos, subir es empeorar; en oportunidades, subir es mejorar */
  sentido: Sentido;
  dia: string;
  reconstruido: boolean;
}

export function tendencia(indice: 'riesgo' | 'oportunidad', ahora: number, antes: PulsoDia | null | undefined,
                          umbral = UMBRAL_ESTABLE): Tendencia | null {
  if (!antes) return null;
  const valor = indice === 'riesgo' ? antes.riesgo : antes.oportunidad;
  const delta = ahora - valor;
  const flecha = Math.abs(delta) < umbral ? 'igual' : delta > 0 ? 'sube' : 'baja';
  const sentido: Sentido = flecha === 'igual' ? 'estable'
    : (flecha === 'sube') === (indice === 'oportunidad') ? 'mejora' : 'empeora';
  return { indice, antes: valor, ahora, delta, flecha, sentido, dia: antes.dia, reconstruido: Boolean(antes.reconstruido) };
}

export const SENTIDO_TXT: Record<Sentido, string> = { mejora: 'Mejora', empeora: 'Empeora', estable: 'Estable' };

/** «Empeora: de 31 a 50 (+19)» */
export function tendenciaTexto(t: Tendencia): string {
  const signo = t.delta > 0 ? '+' : t.delta < 0 ? '−' : '±';
  return `${SENTIDO_TXT[t.sentido]}: de ${t.antes} a ${t.ahora} (${signo}${Math.abs(t.delta)})`;
}

// ───────── Explicación del cálculo (mejora 9 de la PoC) ─────────
// Las mismas cifras que usa calcularPulso, escritas para una persona. Si cambias una regla arriba,
// cambia este texto, docs/pulso.md y EXPLICA_PULSO de hermes/avia-api/avia_api.py.

export const EXPLICA = {
  que: 'El Pulso mide lo SERIAS que son las señales activas, no cuántas hay. Con muchas señales de poca importancia el índice no sube; con pocas señales graves y confirmadas, sí.',
  riesgo: [
    'Cada riesgo activo pesa de 0 a 1: prioridad × respaldo × etapa.',
    'Prioridad: alta 1 · media 0,5 · baja 0,2.',
    'Respaldo: 0,5 + 0,5 × fiabilidad de la evidencia (0-100, la calcula la base: fuente oficial, fuentes distintas, revisión humana). Sin respaldo aún cuenta la mitad.',
    'Etapa: publicada o confirmada 1 · en verificación 0,85 · detectada o en análisis 0,7. Si el plazo de revisión venció sin decisión, cuenta como confirmada: nadie la está mirando. Las mixtas cuentan la mitad.',
  ],
  oportunidad: [
    'Cada oportunidad activa pesa de 0 a 1: valor × etapa.',
    'Valor: 45 % relevancia turística (0-10, la da AVIA) + 25 % novedad (0-10, la da AVIA) + 30 % fiabilidad de la evidencia.',
    'Etapa: igual que en riesgos. Las mixtas y los escenarios (predicciones) cuentan la mitad. Si el plazo ya venció, no suma.',
  ],
  indice: 'Índice = 100 × suma de pesos ÷ (número de señales + 2). Los 2 «vacíos» evitan que una o dos señales sueltas den un índice alto: 1 riesgo alto confirmado y con respaldo completo da ≈ 33; 10 dan ≈ 83.',
  niveles: [
    'Riesgo: Bajo menos de 25 · Moderado 25-49 · Alto 50-74 · Muy alto 75 o más.',
    'Oportunidad: Escasa menos de 30 · Moderada 30-54 · Favorable 55 o más.',
    'Nivel de vigilancia (barra): sale del índice de riesgo, Normal menos de 25 · Vigilancia 25-49 · Atención 50-74 · Crítico 75 o más. Con un riesgo alto ya verificado nunca baja de Vigilancia; con cinco o más, nunca de Atención.',
  ],
  noEntra: 'Las fuentes caídas no entran en los índices (una fuente caída no es un riesgo turístico), pero se avisa: con fuentes caídas el Pulso puede quedarse corto. Tampoco entran las señales descartadas.',
  evolucion: 'Evolución: el Pulso de ahora frente al de hace 7 y hace 30 días (el valor con que cerró ese día). Una diferencia de menos de 5 puntos es «estable». En «Atención a riesgos», subir es empeorar; en «Oportunidad», subir es mejorar. La base guarda el Pulso cada hora; los días anteriores a ese registro se reconstruyeron con el historial de las señales (el estado que tenían ese día, pero la prioridad y la fiabilidad de hoy) y van marcados con «≈». Si ese día aún no había señales, dice «sin datos».',
  limites: 'La relevancia y la novedad las estima AVIA y todavía no se han contrastado con casos reales; por eso el Pulso es una guía de atención, no una medida exacta.',
};

const fmt = (n: number) => n.toLocaleString('es-BO', { maximumFractionDigits: 2 });

/** Lo que más pesa en un índice, con los factores multiplicados */
export function masPesan(p: Pulso, indice: 'riesgo' | 'oportunidad', n = 3): Aporte[] {
  return p.aportes.filter((a) => a.indice === indice && a.peso > 0).sort((a, b) => b.peso - a.peso).slice(0, n);
}

export function factoresTexto(a: Aporte): string {
  const f = a.factores;
  if (a.indice === 'riesgo') return `prioridad ${fmt(f.prioridad ?? 0)} × respaldo ${fmt(f.respaldo ?? 0)} × etapa ${fmt(f.etapa ?? 0)}${f.mixta !== 1 ? ` × mixta ${fmt(f.mixta ?? 1)}` : ''}`;
  return `valor ${fmt(f.valor ?? 0)} × etapa ${fmt(f.etapa ?? 0)}${f.mixta !== 1 ? ` × mixta ${fmt(f.mixta ?? 1)}` : ''}${f.escenario !== 1 ? ` × escenario ${fmt(f.escenario ?? 1)}` : ''}`;
}

/** La explicación con los números de AHORA, en texto para el chat */
export function pulsoTexto(p: Pulso): string {
  const s = p.sumas;
  const lista = (i: 'riesgo' | 'oportunidad') => masPesan(p, i).map((a) => `  - ${a.id} ${a.titulo}: ${fmt(a.peso)} (${factoresTexto(a)})`).join('\n') || '  - Ninguna señal suma todavía';
  return [
    EXPLICA.que,
    `#### Atención a riesgos: ${p.riesgo}/100 (${p.nivelRiesgo})`,
    `${EXPLICA.riesgo.join(' ')}`,
    `Ahora: ${s.nRiesgos} riesgos suman ${fmt(s.riesgo)} → 100 × ${fmt(s.riesgo)} ÷ (${s.nRiesgos} + 2) = ${p.riesgo}. Los que más pesan:\n${lista('riesgo')}`,
    `#### Oportunidad: ${p.oportunidad}/100 (${p.nivelOportunidad})`,
    `${EXPLICA.oportunidad.join(' ')}`,
    `Ahora: ${s.nOportunidades} oportunidades suman ${fmt(s.oportunidad)} → 100 × ${fmt(s.oportunidad)} ÷ (${s.nOportunidades} + 2) = ${p.oportunidad}. Las que más pesan:\n${lista('oportunidad')}`,
    `#### Nivel de vigilancia: ${p.vigilancia}`,
    EXPLICA.niveles.join(' '),
    `#### Qué no entra y límites\n${EXPLICA.noEntra} ${EXPLICA.limites}`,
  ].join('\n');
}
