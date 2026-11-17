// Grado de certeza por señal (mejora 6 de la PoC). La fuente es la base: vigilante.certeza() en
// db/generico/24_grado_certeza.sql. Aquí se repiten las mismas reglas solo para los datos de ejemplo
// y para vigilante.json antiguos que no la traen.
import type { Certeza, NivelCerteza, Senal } from '../types';
import { FUENTES_DEMO } from '../data/demo';

/** Las cuatro palabras, de más a menos seguro. Mismo texto que GLOSARIO en avia_api.py y docs/glosario.md */
export const CERTEZAS: Record<NivelCerteza, { t: string; def: string; ejemplo: string }> = {
  confirmado: {
    t: 'Confirmado',
    def: 'Ya pasó o está pasando, y lo respalda una fuente oficial, dos fuentes distintas o una persona del equipo.',
    ejemplo: 'El SENAMHI emitió el aviso naranja N° 41 para los Yungas.',
  },
  convocado: {
    t: 'Convocado',
    def: 'Lo anunció quien lo organiza para una fecha futura: paro, bloqueo, feria, cierre programado, convocatoria. Está anunciado; no se sabe si al final ocurrirá.',
    ejemplo: 'La federación de transporte convocó un paro para el jueves.',
  },
  posible: {
    t: 'Posible',
    def: 'Hay indicios en una fuente, pero nadie lo ha confirmado. Las predicciones (escenarios) siempre son «posible».',
    ejemplo: 'Un diario dice que se analiza cerrar un tramo de la ruta.',
  },
  rumor: {
    t: 'Rumor',
    def: 'No hay una fuente identificable, o solo lo cuentan redes o páginas no oficiales sin respaldo.',
    ejemplo: '«Circula en redes» que habrá bloqueos el fin de semana.',
  },
};
export const NIVELES_CERTEZA = Object.keys(CERTEZAS) as NivelCerteza[];

export const ORIGEN_CERTEZA: Record<Certeza['origen'], string> = {
  persona: 'Lo comprobó una persona del equipo',
  modelo: 'Lo propuso AVIA y las fuentes lo sostienen',
  modelo_ajustado: 'AVIA proponía uno más alto; la base lo bajó por falta de fuentes',
  reglas: 'Deducido de las fuentes (señal sin propuesta de AVIA)',
};

/** El de la base si llegó; si no, las mismas reglas con lo que hay en la señal */
export function certezaDe(s: Senal): Certeza {
  if (s.certeza) return s.certeza;
  if (s.escenario) return { nivel: 'posible', origen: 'reglas', motivo: 'Es un escenario (predicción), no un hecho' };
  if (s.estado === 'confirmada' || s.estado === 'publicada') {
    const quien = s.traza?.ultima_verificacion?.quien;
    return { nivel: 'confirmado', origen: 'persona', motivo: `Comprobado por ${quien ?? 'una persona del equipo'}` };
  }
  const fuentes = s.fuentes.map((id) => FUENTES_DEMO.find((f) => f.id === id)).filter(Boolean);
  const oficial = fuentes.some((f) => f!.tipo === 'oficial') || (s.traza?.fuentes.some((f) => f.oficial) ?? false);
  const n = Math.max(s.corr, fuentes.length, s.enlaces?.length ?? 0, s.traza?.fuentes.length ?? 0);
  if (!n) return { nivel: 'rumor', origen: 'reglas', motivo: 'Ninguna noticia la respalda' };
  if (oficial) return { nivel: 'confirmado', origen: 'reglas', motivo: 'Lo publica una fuente oficial' };
  if (n >= 2) return { nivel: 'confirmado', origen: 'reglas', motivo: `${n} fuentes distintas lo cuentan` };
  if (fuentes.length && fuentes.every((f) => f!.tipo === 'social')) {
    return { nivel: 'rumor', origen: 'reglas', motivo: 'Solo lo cuenta una fuente no oficial, sin respaldo' };
  }
  return { nivel: 'posible', origen: 'reglas', motivo: 'Lo cuenta una sola fuente no oficial; falta confirmación' };
}
