// Contadores del panel con definiciones fijas (mejora 1 de la PoC: «panel y AVIA cuentan lo mismo»).
//
// La fuente única es la base: vigilante.contadores() en db/generico/21_contadores_unicos.sql. La web
// muestra esos números tal cual y AVIA recibe los mismos. contar() repite las definiciones aquí
// solo para los datos de ejemplo y para el momento entre un cambio hecho en pantalla y la recarga.
// Si cambias una definición, cámbiala en los dos sitios (y en docs/contadores.md).
import type { Senal } from '../types';

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
  /** activas confirmadas o publicadas */
  verificadas: number;
  /** verificadas con noticias de 2 o más fuentes distintas */
  verificadas_2_fuentes: number;
  /** verificadas con menos de 2 fuentes pero con fuente oficial (pasaron solas a Confirmadas, 29).
   *  Desde el 39; ausente si la base aún no lo tiene (useContadores lo completa). */
  verificadas_oficial?: number;
  /** verificadas con una sola fuente no oficial (las movió una persona). Las tres suman «verificadas». */
  verificadas_una_fuente?: number;
  /** activas detectadas, en análisis o en verificación */
  por_verificar: number;
  /** por verificar que requieren revisión de una persona */
  esperan_aprobacion: number;
  /** activas publicadas (alerta = señal confirmada y publicada) */
  alertas_publicadas: number;
  descartadas: number;
  /** noticias recogidas en las últimas 24 h */
  noticias_24h: number;
  /** fuentes que AVIA vigila / en pausa o propuestas (desde el 39; la web cuenta las suyas con resumenFuentes) */
  fuentes_activas?: number;
  fuentes_en_pausa?: number;
}

/** fuentes distintas que sostienen la señal y si alguna es oficial */
function respaldoDe(s: Senal): { n: number; oficial: boolean } {
  const f = s.puntos?.fiabilidad;
  const n = Math.max(s.corr, f?.fuentes ?? 0);
  const oficial = f?.oficial ?? (s.traza?.fuentes.some((x) => x.oficial) ?? false);
  return { n, oficial };
}

const POR_VERIFICAR = ['detectada', 'en_analisis', 'en_verificacion'];
const VERIFICADA = ['confirmada', 'publicada'];

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
    verificadas: n((s) => VERIFICADA.includes(s.estado)),
    verificadas_2_fuentes: n((s) => VERIFICADA.includes(s.estado) && respaldoDe(s).n >= 2),
    verificadas_oficial: n((s) => VERIFICADA.includes(s.estado) && respaldoDe(s).n < 2 && respaldoDe(s).oficial),
    verificadas_una_fuente: n((s) => VERIFICADA.includes(s.estado) && respaldoDe(s).n < 2 && !respaldoDe(s).oficial),
    por_verificar: n((s) => POR_VERIFICAR.includes(s.estado)),
    esperan_aprobacion: n((s) => POR_VERIFICAR.includes(s.estado) && Boolean(s.revision)),
    alertas_publicadas: n((s) => s.estado === 'publicada'),
    descartadas: senales.length - a.length,
    noticias_24h: noticias24h,
  };
}

/** Si la base aún no tiene el 39, completa el desglose de verificadas con el cálculo local sin
 *  cambiar el total de la base: las tres partes siempre suman «verificadas». */
export function completarDesglose(base: Contadores, local: Contadores): Contadores {
  if (base.verificadas_oficial != null && base.verificadas_una_fuente != null) return base;
  const resto = Math.max(0, base.verificadas - base.verificadas_2_fuentes);
  const oficial = Math.min(resto, local.verificadas_oficial ?? 0);
  return { ...base, verificadas_oficial: oficial, verificadas_una_fuente: resto - oficial };
}

/** «2 con 2 o más fuentes · 55 por fuente oficial · 2 con una sola fuente»: suma las verificadas */
export function desgloseVerificadas(k: Contadores): string {
  const partes = [
    [k.verificadas_2_fuentes, 'con 2 o más fuentes'],
    [k.verificadas_oficial ?? 0, 'por fuente oficial'],
    [k.verificadas_una_fuente ?? 0, 'con una sola fuente'],
  ] as const;
  const txt = partes.filter(([v]) => v > 0).map(([v, t]) => `${v} ${t}`);
  return txt.length ? txt.join(' · ') : 'ninguna todavía';
}

/** Fuentes que AVIA vigila y en pausa (o propuestas sin aprobar): las mismas en todo el panel */
export function resumenFuentes(fuentes: { estado: string }[]): { activas: number; enPausa: number; total: number } {
  const enPausa = fuentes.filter((f) => f.estado === 'MANT').length;
  return { activas: fuentes.length - enPausa, enPausa, total: fuentes.length };
}

/** «33 fuentes activas · 6 en pausa» */
export function textoFuentes(fuentes: { estado: string }[]): string {
  const r = resumenFuentes(fuentes);
  return `${r.activas} ${r.activas === 1 ? 'fuente activa' : 'fuentes activas'}${r.enPausa ? ` · ${r.enPausa} en pausa` : ''}`;
}

/** «14:05» en hora de Bolivia */
export function horaBolivia(iso?: string | null): string {
  if (!iso) return '—';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '—';
  return new Date(t).toLocaleTimeString('es-BO', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'America/La_Paz' });
}
