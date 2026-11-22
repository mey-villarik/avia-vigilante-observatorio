// Contadores del panel con definiciones fijas (mejora 1 de la PoC: «panel y AVIA cuentan lo mismo»).
//
// La fuente única es la base: vigilante.contadores() en db/generico/21_contadores_unicos.sql. La web
// muestra esos números tal cual y AVIA recibe los mismos. contar() repite las definiciones aquí
// solo para los datos de ejemplo y para el momento entre un cambio hecho en pantalla y la recarga.
// Si cambias una definición, cámbiala en los dos sitios (y en docs/contadores.md).
import type { Senal } from '../types';
import { enBolivia } from './hora';
import { esConfirmada, esVerificada, respaldoDe } from './verificada';

export interface Contadores {
  /** hora del cálculo (ISO) */
  actualizado: string;
  /** visibles que no están descartadas */
  senales_activas: number;
  /** activas de naturaleza oportunidad / riesgo / mixta (las tres suman las activas) */
  oportunidades: number;
  riesgos: number;
  mixtas: number;
  /** activas que no son riesgo y cuyo plazo vence en menos de 15 días */
  plazo_corto: number;
  /** riesgos de prioridad alta */
  riesgos_altos: number;
  /** activas que cumplen la regla única de lib/verificada.ts (40): confirmadas o publicadas, no
   *  escenario, con fuente oficial o 2 o más fuentes distintas */
  verificadas: number;
  /** verificadas con noticias de 2 o más fuentes distintas */
  verificadas_2_fuentes: number;
  /** verificadas con menos de 2 fuentes pero con fuente oficial. Las dos suman «verificadas».
   *  Desde el 39; ausente si la base aún no lo tiene (useContadores lo completa). */
  verificadas_oficial?: number;
  /** obsoleto desde el 40 (siempre 0): esas señales ya no son verificadas, van en confirmadas_sin_verificar */
  verificadas_una_fuente?: number;
  /** confirmadas o publicadas que NO cumplen la regla: una sola fuente no oficial, o escenario (40) */
  confirmadas_sin_verificar?: number;
  /** publicadas que son verificadas: en la web pública salen «Verificada»; el resto, «En verificación» (40) */
  alertas_verificadas?: number;
  /** activas detectadas, en análisis o en verificación */
  por_verificar: number;
  /** por verificar que requieren revisión de una persona */
  esperan_aprobacion: number;
  /** activas publicadas (alerta = señal confirmada y publicada) */
  alertas_publicadas: number;
  descartadas: number;
  /** noticias recogidas en las últimas 24 h */
  noticias_24h: number;
  /** fuentes que AVIA vigila / en pausa o propuestas (desde el 39; la web cuenta las suyas con cifrasFuentes) */
  fuentes_activas?: number;
  /** activas leídas (OK o AVISO) / sin leer (CRÍTICO o DESCONOCIDO), desde el 41; mismas reglas que cifrasFuentes() */
  fuentes_leidas?: number;
  fuentes_sin_leer?: number;
  fuentes_en_pausa?: number;
}

const POR_VERIFICAR = ['detectada', 'en_analisis', 'en_verificacion'];

export function contar(senales: Senal[], noticias24h: number, ahora = Date.now()): Contadores {
  const a = senales.filter((s) => s.estado !== 'descartada');
  const n = (f: (s: Senal) => boolean) => a.filter(f).length;
  return {
    actualizado: new Date(ahora).toISOString(),
    senales_activas: a.length,
    oportunidades: n((s) => s.naturaleza === 'oportunidad'),
    riesgos: n((s) => s.naturaleza === 'riesgo'),
    mixtas: n((s) => s.naturaleza === 'mixta'),
    plazo_corto: n((s) => s.naturaleza !== 'riesgo' && s.plazo != null && s.plazo < 15),
    riesgos_altos: n((s) => s.naturaleza === 'riesgo' && s.prioridad === 'alta'),
    verificadas: n(esVerificada),
    verificadas_2_fuentes: n((s) => esVerificada(s) && respaldoDe(s).n >= 2),
    verificadas_oficial: n((s) => esVerificada(s) && respaldoDe(s).n < 2),
    verificadas_una_fuente: 0,
    confirmadas_sin_verificar: n((s) => esConfirmada(s) && !esVerificada(s)),
    por_verificar: n((s) => POR_VERIFICAR.includes(s.estado)),
    esperan_aprobacion: n((s) => POR_VERIFICAR.includes(s.estado) && Boolean(s.revision)),
    alertas_publicadas: n((s) => s.estado === 'publicada'),
    alertas_verificadas: n((s) => s.estado === 'publicada' && esVerificada(s)),
    descartadas: senales.length - a.length,
    noticias_24h: noticias24h,
  };
}

/** Si la base aún no tiene el 40, pasa sus números a la regla única sin esperar a la base:
 *  · con el 39: «verificadas» de la base incluía las de una sola fuente no oficial; se restan y pasan
 *    a «confirmadas sin verificar» (los mismos números de la base, solo reordenados);
 *  · sin el 39: no hay desglose en la base, se usa el cálculo local.
 *  Así el panel nunca vuelve a enseñar «Verificadas 59» con «2 con 2 o más fuentes». */
export function completarDesglose(base: Contadores, local: Contadores): Contadores {
  if (base.confirmadas_sin_verificar != null) return base;
  if (base.verificadas_oficial != null && base.verificadas_una_fuente != null) {
    return {
      ...base,
      verificadas: base.verificadas_2_fuentes + base.verificadas_oficial,
      verificadas_una_fuente: 0,
      confirmadas_sin_verificar: base.verificadas_una_fuente,
      alertas_verificadas: local.alertas_verificadas,
    };
  }
  return {
    ...base,
    verificadas: local.verificadas,
    verificadas_2_fuentes: local.verificadas_2_fuentes,
    verificadas_oficial: local.verificadas_oficial,
    verificadas_una_fuente: 0,
    confirmadas_sin_verificar: local.confirmadas_sin_verificar,
    alertas_verificadas: local.alertas_verificadas,
  };
}

/** «55 por fuente oficial · 2 con 2 o más fuentes»: las dos partes suman las verificadas */
export function desgloseVerificadas(k: Contadores): string {
  const partes = [
    [k.verificadas_oficial ?? 0, 'por fuente oficial'],
    [k.verificadas_2_fuentes, 'con 2 o más fuentes'],
  ] as const;
  const txt = partes.filter(([v]) => v > 0).map(([v, t]) => `${v} ${t}`);
  return txt.length ? txt.join(' · ') : 'ninguna todavía';
}

/** «2 confirmadas sin verificar (una sola fuente)» o '' si no hay */
export function textoSinVerificar(k: Contadores): string {
  const n = k.confirmadas_sin_verificar ?? 0;
  return n ? `${n} ${n === 1 ? 'confirmada' : 'confirmadas'} sin verificar (una sola fuente)` : '';
}

/** Una fuente activa está «leída» si en su última comprobación AVIA obtuvo respuesta (OK o AVISO).
 *  Es la misma regla que la base (ultimo_exito_en con OK o WARN) y que vigilante.contadores() desde el 41. */
export const fuenteLeida = (f: { estado: string }): boolean => f.estado === 'OK' || f.estado === 'WARN';

export interface CifrasFuentes {
  /** fuentes activas: las que AVIA vigila (sin las en pausa ni las propuestas sin aprobar) */
  total: number;
  /** activas que AVIA leyó en su última comprobación (OK o AVISO) */
  leidas: number;
  /** activas que AVIA no pudo leer (CRÍTICO) o que aún no ha leído (DESCONOCIDO); total = leídas + sin leer */
  sinLeer: number;
  /** en pausa o propuestas: no cuentan en total */
  enPausa: number;
}

/** LA cifra de fuentes del panel: encabezado, Pulso, pestaña Fuentes, Panorama y aviso de carga salen de aquí */
export function cifrasFuentes(fuentes: { estado: string }[]): CifrasFuentes {
  const activas = fuentes.filter((f) => f.estado !== 'MANT');
  const leidas = activas.filter(fuenteLeida).length;
  return { total: activas.length, leidas, sinLeer: activas.length - leidas, enPausa: fuentes.length - activas.length };
}

/** «28 de 33 fuentes leídas · 5 sin leer» (+ «· 6 en pausa» si se pide) */
export function textoFuentes(fuentes: { estado: string }[], conPausa = true): string {
  const r = cifrasFuentes(fuentes);
  return `${r.leidas} de ${r.total} ${r.total === 1 ? 'fuente leída' : 'fuentes leídas'} · ${r.sinLeer} sin leer${conPausa && r.enPausa ? ` · ${r.enPausa} en pausa` : ''}`;
}

/** «14:05» en hora de Bolivia */
export function horaBolivia(iso?: string | null): string {
  if (!iso || Number.isNaN(Date.parse(iso))) return '—';
  return enBolivia(iso, 'hora');
}
