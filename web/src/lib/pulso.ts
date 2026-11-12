// Pulso del observatorio: índices calculados con las señales reales que la web ya lee de Supabase.
//
// Antes la fórmula sumaba puntos fijos (38 + 14 por fuente caída + 8 por riesgo alto…) y llegaba
// a 100 con muy pocas señales, así que casi siempre mostraba «100 de 100». Ahora:
//
// 1. Cada señal activa (no descartada) pesa según su prioridad, la confianza de AVIA y su etapa.
// 2. Los pesos se suman y se convierten a 0-100 con una curva que crece rápido al principio y
//    se acerca a 100 sin tocarlo de golpe: índice = 100 · (1 − e^(−suma / escala)).
//    Así una señal leve mueve poco, varias señales graves suben mucho, y nunca se queda fijo en 100.
// 3. Las fuentes no entran en los índices (una fuente caída no es un riesgo turístico), pero se
//    informan como «cobertura» porque con fuentes caídas los índices pueden quedarse cortos.
import type { Etapa, Fuente, Prioridad, Senal } from '../types';

const PESO_PRIORIDAD: Record<Prioridad, number> = { alta: 1, media: 0.5, baja: 0.2 };

/** cuánto cuenta la señal según lo verificada que está */
const PESO_ETAPA: Record<Etapa, number> = {
  publicada: 1, confirmada: 1, en_verificacion: 0.8, en_analisis: 0.6, detectada: 0.6, descartada: 0,
};

/** escala de la curva: con esta suma de pesos el índice llega a ~63 */
const ESCALA_RIESGO = 3;   // p. ej. 3 riesgos altos confirmados ≈ 63
const ESCALA_OPORTUNIDAD = 6; // hay más oportunidades que riesgos: 10 oportunidades normales ≈ 67

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
    fuentesOk: number; fuentesTotal: number;
  };
}

const curva = (suma: number, escala: number) => Math.round(100 * (1 - Math.exp(-suma / escala)));

const confianza = (s: Senal) => 0.5 + 0.5 * Math.max(0, Math.min(1, s.conf ?? 0));

export function calcularPulso(senales: Senal[], fuentes: Fuente[]): Pulso {
  const activas = senales.filter((s) => s.estado !== 'descartada');
  const riesgos = activas.filter((s) => s.naturaleza !== 'oportunidad');
  const opps = activas.filter((s) => s.naturaleza !== 'riesgo');

  // Riesgo: prioridad × confianza × etapa (las mixtas cuentan la mitad).
  // Un riesgo cuyo plazo de revisión venció sin decisión pesa como confirmado: nadie lo está mirando.
  let sumaRiesgo = 0;
  for (const s of riesgos) {
    const etapa = s.revisionVencida ? 1 : PESO_ETAPA[s.estado];
    const mixta = s.naturaleza === 'mixta' ? 0.5 : 1;
    sumaRiesgo += PESO_PRIORIDAD[s.prioridad] * confianza(s) * etapa * mixta;
  }

  // Oportunidad: puntuación de AVIA (relevancia, novedad, confianza) × etapa, solo si el plazo sigue abierto.
  // Los escenarios (predicciones) cuentan la mitad.
  let sumaOpp = 0;
  let plazoAbierto = 0, plazoCorto = 0, plazoVencido = 0;
  for (const s of opps) {
    if (s.plazo != null && s.plazo < 0) { plazoVencido++; continue; }
    if (s.plazo != null) { plazoAbierto++; if (s.plazo < 15) plazoCorto++; }
    const valor = (s.rel * 0.45 + s.nov * 0.25 + (s.conf ?? 0) * 10 * 0.3) / 10;
    const mixta = s.naturaleza === 'mixta' ? 0.5 : 1;
    const escenario = s.escenario ? 0.5 : 1;
    sumaOpp += Math.max(0, Math.min(1, valor)) * PESO_ETAPA[s.estado] * mixta * escenario;
  }

  const riesgo = curva(sumaRiesgo, ESCALA_RIESGO);
  const oportunidad = curva(sumaOpp, ESCALA_OPORTUNIDAD);
  const riesgosAltos = riesgos.filter((s) => s.prioridad === 'alta').length;

  let vigilancia: NivelVigilancia = riesgo >= 75 ? 'Crítico' : riesgo >= 50 ? 'Atención' : riesgo >= 25 ? 'Vigilancia' : 'Normal';
  // Regla mínima: un riesgo alto ya verificado nunca deja el nivel en «Normal».
  if (vigilancia === 'Normal' && riesgos.some((s) => s.prioridad === 'alta' && ['confirmada', 'publicada'].includes(s.estado))) vigilancia = 'Vigilancia';

  const conLectura = fuentes.filter((f) => f.estado !== 'MANT');
  return {
    riesgo,
    nivelRiesgo: riesgo >= 75 ? 'Muy alto' : riesgo >= 50 ? 'Alto' : riesgo >= 25 ? 'Moderado' : 'Bajo',
    oportunidad,
    nivelOportunidad: opps.length === 0 ? 'Sin señales' : oportunidad >= 60 ? 'Favorable' : oportunidad >= 30 ? 'Moderada' : 'Escasa',
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
      fuentesOk: conLectura.filter((f) => f.estado === 'OK').length,
      fuentesTotal: conLectura.length,
    },
  };
}

/** posición (0-100) del marcador en la barra Normal · Vigilancia · Atención · Crítico */
export function posicionVigilancia(p: Pulso): number {
  const base: Record<NivelVigilancia, number> = { Normal: 0, Vigilancia: 25, Atención: 50, Crítico: 75 };
  // dentro de su tramo según el índice, pero nunca por debajo del tramo que marca la regla mínima
  return Math.max(base[p.vigilancia] + 2, Math.min(98, Math.max(2, p.riesgo)));
}
