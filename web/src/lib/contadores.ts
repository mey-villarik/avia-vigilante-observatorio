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
  /** verificadas con 2 o más noticias enlazadas */
  verificadas_2_fuentes: number;
  /** activas detectadas, en análisis o en verificación */
  por_verificar: number;
  /** por verificar que requieren revisión de una persona */
  esperan_aprobacion: number;
  /** activas publicadas (alerta = señal confirmada y publicada) */
  alertas_publicadas: number;
  descartadas: number;
  /** noticias recogidas en las últimas 24 h */
  noticias_24h: number;
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
    verificadas_2_fuentes: n((s) => VERIFICADA.includes(s.estado) && s.corr >= 2),
    por_verificar: n((s) => POR_VERIFICAR.includes(s.estado)),
    esperan_aprobacion: n((s) => POR_VERIFICAR.includes(s.estado) && Boolean(s.revision)),
    alertas_publicadas: n((s) => s.estado === 'publicada'),
    descartadas: senales.length - a.length,
    noticias_24h: noticias24h,
  };
}

/** «14:05» en hora de Bolivia */
export function horaBolivia(iso?: string | null): string {
  if (!iso) return '—';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '—';
  return new Date(t).toLocaleTimeString('es-BO', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'America/La_Paz' });
}
