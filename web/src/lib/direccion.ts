// Vista Dirección (P1 de la auditoría para la Dirección de Turismo, 2026-11-22).
//
// La premisa del observatorio es anticipar, verificar y actuar sobre TRES ejes; aquí se pasan las
// categorías técnicas de AVIA (clima, salud, vial…) a esos ejes y se saca de ellos:
//   · el estado de cada eje (Normal / Atención / Acción) y el semáforo de Bolivia,
//   · el semáforo de cada departamento con su motivo en una frase y qué se recomienda,
//   · la ficha fija de cada señal: Acción recomendada · Responsable sugerido · Plazo · Cómo verificar,
//   · las 3 decisiones más urgentes,
//   · «Lo que viene»: lo que ocurre en las próximas 24 h, 72 h o 7 días, por fecha de ocurrencia.
//
// La fuente es la base (db/generico/49_vista_direccion.sql: vigilante.eje_de(), vigilante.ficha_direccion()
// y vigilante.direccion()). Si vigilante.json trae «direccion», la web la usa tal cual; si no (datos de
// ejemplo o base sin el 49), aplica aquí las MISMAS reglas.
import type { EjeDireccion, FichaAccion, NivelCerteza, Senal } from '../types';
import { norm } from './util';
import { accionDe, type Accion } from './accion';
import { recoDe } from './recomendacion';
import { certezaDe } from './certeza';
import { hoyBolivia } from './vigencia';
import { cierreTexto, diasParaCierre, fechaCierre } from './plazo';
import { enBolivia } from './hora';
import { DEPS } from '../data/demo';
import { NACIONAL, regionesDeSenal } from './regiones';

// ───────── 1. Los tres ejes ─────────

export type Eje = EjeDireccion;
export type { FichaAccion };
export const EJES: Eje[] = ['movilidad', 'servicios', 'atencion'];
export const EJE_TXT: Record<Eje, string> = {
  movilidad: 'Movilidad',
  servicios: 'Servicios esenciales',
  atencion: 'Atención turística',
};
export const EJE_AYUDA: Record<Eje, string> = {
  movilidad: 'Rutas, seguridad del visitante, conflictos sociales (bloqueos, marchas, paros) y clima que afecta a las rutas.',
  servicios: 'Salud, agua, energía, combustible y telecomunicaciones (internet y telefonía).',
  atencion: 'Eventos, demanda de visitantes, aeropuertos y vuelos, y alojamiento.',
};
/** responsable sugerido si el cliente no puso uno (parámetros responsable_movilidad, _servicios, _atencion) */
export const RESPONSABLE_DEFECTO: Record<Eje | 'otros', string> = {
  movilidad: 'Responsable de movilidad y seguridad del visitante',
  servicios: 'Responsable de enlace con servicios esenciales',
  atencion: 'Responsable de atención al turista',
  otros: 'Analista de turno',
};

// Palabras sin tildes, igual que en vigilante.eje_de() (49)
const CONFLICTO = /\b(bloqueo|bloqueos|bloquean|marcha|marchas|paro|paros|huelga|protesta|protestas|movilizacion|movilizaciones|conflicto social|cerco|enfrentamiento|toma de)\b/;
const SERVICIOS = /\b(agua|potable|sequia|racionamiento|electricidad|energia electrica|suministro electrico|apagon\w*|corte de luz|cortes de luz|corte de energia|cortes de energia|combustible|gasolina|diesel|desabastec\w*|gnv|garrafa|internet|telefon\w*|telecomunicac\w*|conectividad movil|senal movil|hospital\w*|sanitari\w*)\b/;
const ATENCION = /\b(aeropuerto|aeropuertos|vuelo|vuelos|aerolinea\w*|hotel\w*|alojamiento\w*|hosped\w*|reserva\w*|ocupacion|visitantes|turistas|demanda|feria|festival|fiesta|carnaval|entrada folklorica)\b/;

/** eje de una señal; null = no entra en ninguno (financiación, normativa o economía sin efecto directo) */
export function ejeDe(s: Pick<Senal, 'categoria' | 'titulo' | 'resumen'> & { direccion?: Senal['direccion'] }): Eje | null {
  if (s.direccion && 'eje' in s.direccion) return s.direccion.eje ?? null;
  const t = norm(`${s.titulo} ${s.resumen ?? ''}`);
  const c = s.categoria as string;
  if (c === 'salud') return 'servicios';
  if (c === 'vial' || c === 'seguridad') return 'movilidad';
  if (c === 'clima') return SERVICIOS.test(t) ? 'servicios' : 'movilidad';   // clima en rutas, salvo sequía, cortes…
  if (CONFLICTO.test(t)) return 'movilidad';
  if (['eventos', 'conectividad', 'turismo', 'mercado', 'mercados'].includes(c)) return 'atencion';
  if (SERVICIOS.test(t)) return 'servicios';
  if (ATENCION.test(t)) return 'atencion';
  return null;
}

// ───────── 2. Estado: Normal / Atención / Acción ─────────

export type EstadoEje = 'normal' | 'atencion' | 'accion';
export const ESTADO_TXT: Record<EstadoEje, string> = { normal: 'Normal', atencion: 'Atención', accion: 'Acción' };
export const ESTADO_COLOR: Record<EstadoEje, string> = { normal: 'verde', atencion: 'amarillo', accion: 'rojo' };
export const ESTADO_AYUDA: Record<EstadoEje, string> = {
  normal: 'Nada que pida medidas: AVIA sigue vigilando.',
  atencion: 'Algo puede crecer o está sin confirmar: preparar medidas y avisos.',
  accion: 'Hay un riesgo grave o en curso y confirmado: decidir hoy.',
};
const ORDEN_ESTADO: Record<EstadoEje, number> = { accion: 0, atencion: 1, normal: 2 };
export const peorEstado = (l: EstadoEje[]): EstadoEje => l.reduce<EstadoEje>((a, b) => (ORDEN_ESTADO[b] < ORDEN_ESTADO[a] ? b : a), 'normal');

const SIN_CONFIRMAR: NivelCerteza[] = ['posible', 'rumor'];

/** cuánto pesa una señal en el semáforo. Solo riesgos y mixtas; lo no confirmado no pasa de Atención. */
export function estadoDeSenal(s: Senal): EstadoEje {
  if (s.estado === 'descartada' || s.naturaleza === 'oportunidad') return 'normal';
  const a: Accion = s.direccion?.accion ?? accionDe(s).accion;
  if (a === 'seguir') return 'normal';
  if (a === 'actuar' && !SIN_CONFIRMAR.includes(certezaDe(s).nivel)) return 'accion';
  return 'atencion';
}

// ───────── 3. Ficha fija: Acción recomendada · Responsable · Plazo · Cómo verificar ─────────

const dmy = (d: string) => enBolivia(d, 'diaCorto');

/** fecha de cierre: la guardada (48) o, en datos antiguos o de ejemplo, hoy + los días que trae */
export function cierreDe(s: Senal, ahora = Date.now()): string | null {
  if (s.cierre?.fecha) return s.cierre.fecha;
  if (s.plazo == null) return null;
  return new Date(Date.parse(`${hoyBolivia(ahora)}T12:00:00Z`) + s.plazo * 864e5).toISOString().slice(0, 10);
}
const sumarDias = (d: string, n: number) => new Date(Date.parse(`${d}T12:00:00Z`) + n * 864e5).toISOString().slice(0, 10);

export function fichaDe(s: Senal, responsables: Partial<Record<Eje | 'otros', string>> = {}, ahora = Date.now()): FichaAccion {
  if (s.direccion?.ficha) return s.direccion.ficha;
  const r = recoDe(s);
  const eje = ejeDe(s);
  const hoy = hoyBolivia(ahora);
  const responsable = responsables[eje ?? 'otros'] || RESPONSABLE_DEFECTO[eje ?? 'otros'];
  const accion = r.afirma_sin_verificar
    ? `Comprobar con ${r.verificar_con} antes de avisar a nadie: no hay dato oficial de las últimas 24 h`
    : (r.texto ?? s.soluciones[0]?.t ?? 'Seguir la evolución').replace(/\.$/, '');

  // plazo: el riesgo según su acción; la oportunidad según su cierre o su fecha
  let plazo: string; let plazo_fecha: string | null;
  const inicio = fechaCierre(s.evento?.inicio);
  const cierre = cierreDe(s, ahora);
  if (s.naturaleza === 'oportunidad') {
    if (cierre && (diasParaCierre(cierre, ahora) ?? -1) >= 0) {
      plazo = `Antes del cierre: ${cierreTexto(cierre, ahora)}${s.cierre?.certeza === 'confirmado' ? '' : ' (fecha pendiente de verificar)'}`;
      plazo_fecha = cierre;
    } else if (inicio && inicio >= hoy) { plazo = `Antes del ${dmy(inicio)}, cuando empieza`; plazo_fecha = inicio; }
    else { plazo = 'Esta semana'; plazo_fecha = sumarDias(hoy, 7); }
  } else {
    const a = s.direccion?.accion ?? accionDe(s).accion;
    if (a === 'actuar') { plazo = 'Hoy'; plazo_fecha = hoy; }
    else if (a === 'preparar') {
      // si empieza antes de 72 h, preparar para la víspera
      const limite = inicio && inicio > hoy && inicio <= sumarDias(hoy, 3) ? sumarDias(inicio, -1) : sumarDias(hoy, 3);
      plazo = limite === hoy ? 'Hoy' : `Antes del ${dmy(limite)}`;
      plazo_fecha = limite;
    } else { plazo = 'Revisar en 7 días'; plazo_fecha = sumarDias(hoy, 7); }
  }
  const verificar = `Con ${r.verificar_con}${r.falta_saber[0] ? `. Falta saber: ${r.falta_saber[0].replace(/\.$/, '').toLowerCase()}` : ''}`;
  return { accion, responsable, afecta: r.para_quien, plazo, plazo_fecha, verificar, sin_verificar: r.afirma_sin_verificar || undefined };
}

// ───────── 4. Ejes, semáforo de Bolivia y top 3 decisiones ─────────

export interface ResumenEje {
  eje: Eje;
  estado: EstadoEje;
  /** una frase: qué lo pone así */
  motivo: string;
  responsable: string;
  /** señales del eje, primero las que más pesan */
  senales: Senal[];
  cuenta: { accion: number; atencion: number; oportunidades: number };
}

const ordenSenal = (a: Senal, b: Senal) =>
  ORDEN_ESTADO[estadoDeSenal(a)] - ORDEN_ESTADO[estadoDeSenal(b)] || a.min - b.min;

export function resumenEjes(senales: Senal[], responsables: Partial<Record<Eje | 'otros', string>> = {}): ResumenEje[] {
  const activas = senales.filter((s) => s.estado !== 'descartada');
  return EJES.map((eje) => {
    const l = activas.filter((s) => ejeDe(s) === eje).sort(ordenSenal);
    const accion = l.filter((s) => estadoDeSenal(s) === 'accion');
    const atencion = l.filter((s) => estadoDeSenal(s) === 'atencion');
    const opp = l.filter((s) => s.naturaleza === 'oportunidad');
    const estado: EstadoEje = accion.length ? 'accion' : atencion.length ? 'atencion' : 'normal';
    const top = accion[0] ?? atencion[0];
    const motivo = top
      ? `${top.titulo}${(accion.length + atencion.length) > 1 ? ` y ${accion.length + atencion.length - 1} más` : ''}`
      : opp.length ? `Sin riesgos que pidan medidas; ${opp.length} oportunidad(es) abiertas` : 'Sin riesgos que pidan medidas';
    return {
      eje, estado, motivo, senales: l,
      responsable: responsables[eje] || RESPONSABLE_DEFECTO[eje],
      cuenta: { accion: accion.length, atencion: atencion.length, oportunidades: opp.length },
    };
  });
}

export function semaforoBolivia(ejes: ResumenEje[]): { estado: EstadoEje; motivo: string } {
  const estado = peorEstado(ejes.map((e) => e.estado));
  const malos = ejes.filter((e) => e.estado === estado && estado !== 'normal').map((e) => EJE_TXT[e.eje].toLowerCase());
  const motivo = estado === 'normal'
    ? 'Ningún eje pide medidas ahora.'
    : `${ESTADO_TXT[estado]} en ${malos.join(' y ')}.`;
  return { estado, motivo };
}

/** las 3 decisiones de hoy: riesgos para actuar, oportunidades que cierran en 7 días, riesgos para preparar */
export function topDecisiones(senales: Senal[], n = 3, ahora = Date.now()): Senal[] {
  const rango = (s: Senal): number => {
    const e = estadoDeSenal(s);
    if (e === 'accion') return 0;
    if (s.naturaleza !== 'riesgo' && cierreDe(s, ahora)) {
      const d = diasParaCierre(cierreDe(s, ahora), ahora);
      if (d != null && d >= 0 && d <= 7) return 1;
    }
    if (e === 'atencion') return 2;
    if (s.naturaleza !== 'riesgo' && s.prioridad === 'alta') return 3;
    return 9;
  };
  return senales
    .filter((s) => s.estado !== 'descartada' && ejeDe(s) && rango(s) < 9)
    .sort((a, b) => rango(a) - rango(b) || (diasParaCierre(cierreDe(a, ahora), ahora) ?? 99) - (diasParaCierre(cierreDe(b, ahora), ahora) ?? 99) || a.min - b.min)
    .slice(0, n);
}

// ───────── 5. Semáforo por departamento ─────────

export interface SemaforoDep {
  dep: string;
  estado: EstadoEje;
  /** una frase con el motivo */
  motivo: string;
  /** qué se recomienda (acción de la señal que más pesa) */
  recomendacion: string | null;
  senal: Senal | null;
}

export function semaforoDepartamentos(senales: Senal[], responsables: Partial<Record<Eje | 'otros', string>> = {}): Record<string, SemaforoDep> {
  const activas = senales.filter((s) => s.estado !== 'descartada' && ejeDe(s)).sort(ordenSenal);
  const por: Record<string, SemaforoDep> = {};
  DEPS.forEach((dep) => {
    const l = activas.filter((s) => regionesDeSenal(s).includes(dep));
    const top = l.find((s) => estadoDeSenal(s) !== 'normal') ?? null;
    const estado = top ? estadoDeSenal(top) : 'normal';
    const otras = l.filter((s) => estadoDeSenal(s) !== 'normal').length - 1;
    por[dep] = {
      dep, estado, senal: top,
      motivo: top
        ? `${EJE_TXT[ejeDe(top)!]}: ${top.titulo}${otras > 0 ? ` (y ${otras} más)` : ''}`
        : l.length ? `Sin riesgos que pidan medidas (${l.length} señal(es) en seguimiento)` : 'Sin señales propias',
      recomendacion: top ? fichaDe(top, responsables).accion : null,
    };
  });
  return por;
}

/** señales nacionales que pesan en el semáforo (no pintan todos los departamentos para no teñir el mapa) */
export const nacionalesConPeso = (senales: Senal[]) =>
  senales.filter((s) => s.estado !== 'descartada' && ejeDe(s) && regionesDeSenal(s).includes(NACIONAL) && estadoDeSenal(s) !== 'normal').sort(ordenSenal);

// ───────── 6. Lo que viene ─────────

export type TipoViene = 'conflicto' | 'pronostico' | 'evento' | 'plazo';
export const TIPO_VIENE_TXT: Record<TipoViene, string> = {
  conflicto: 'Marcha, paro o bloqueo', pronostico: 'Pronóstico o aviso', evento: 'Evento', plazo: 'Plazo de convocatoria',
};
export interface ItemViene {
  senal: Senal;
  tipo: TipoViene;
  /** AAAA-MM-DD de ocurrencia (Bolivia) */
  fecha: string;
  fin?: string | null;
  /** días desde hoy: 0 hoy */
  dias: number;
  eje: Eje | null;
}
export type Ventana = 1 | 3 | 7;
export const VENTANA_TXT: Record<Ventana, string> = { 1: '24 h', 3: '72 h', 7: '7 días' };

/** lo que ocurre de hoy a hoy + 7 días, por fecha de ocurrencia (no de detección) */
export function loQueViene(senales: Senal[], dias: Ventana = 7, ahora = Date.now()): ItemViene[] {
  const hoy = hoyBolivia(ahora);
  const hasta = sumarDias(hoy, dias);
  const out: ItemViene[] = [];
  for (const s of senales) {
    if (s.estado === 'descartada') continue;
    const t = norm(`${s.titulo} ${s.resumen ?? ''}`);
    const ini = fechaCierre(s.evento?.inicio);
    const fin = fechaCierre(s.evento?.fin);
    // lo que empieza en la ventana (o ya empezó y sigue: se pone hoy)
    if (ini && ini <= hasta && (ini >= hoy || (fin && fin >= hoy))) {
      const fecha = ini < hoy ? hoy : ini;
      const tipo: TipoViene = CONFLICTO.test(t) ? 'conflicto' : s.categoria === 'clima' ? 'pronostico' : 'evento';
      out.push({ senal: s, tipo, fecha, fin, dias: diasParaCierre(fecha, ahora) ?? 0, eje: ejeDe(s) });
    }
    const c = cierreDe(s, ahora);
    if (c && s.naturaleza !== 'riesgo' && c >= hoy && c <= hasta && c !== ini) {
      out.push({ senal: s, tipo: 'plazo', fecha: c, dias: diasParaCierre(c, ahora) ?? 0, eje: ejeDe(s) });
    }
  }
  return out.sort((a, b) => a.fecha.localeCompare(b.fecha) || ORDEN_ESTADO[estadoDeSenal(a.senal)] - ORDEN_ESTADO[estadoDeSenal(b.senal)]);
}
