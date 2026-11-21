// «Verificada» significa una sola cosa en todo el panel, la web pública y AVIA (db/generico/40_verificada_unica.sql):
//
//   VERIFICADA = señal confirmada o publicada, que no es escenario, y que respalda
//                una fuente oficial (u organismo internacional)  o  2 o más fuentes distintas.
//
// Una confirmada o publicada que no cumple (una sola fuente no oficial, o un escenario) es
// «Confirmada sin verificar». La regla de verdad está en la base (vigilante.respaldo_senal); esta
// copia sirve para la etiqueta de cada tarjeta, los datos de ejemplo y el instante entre un cambio
// en pantalla y la recarga. Si la cambias, cámbiala también en el 40 y en hermes/avia-api/avia_api.py.
import type { Senal } from '../types';

export const DEF_VERIFICADA = 'Verificada: confirmada y respaldada por una fuente oficial o por 2 o más fuentes distintas.';
export const DEF_SIN_VERIFICAR = 'Confirmada sin verificar: la sostiene una sola fuente no oficial (o es un escenario). Falta una fuente oficial o una segunda fuente distinta.';

const CONFIRMADA = ['confirmada', 'publicada'];

/** Fuentes distintas que sostienen la señal y si alguna es oficial */
export function respaldoDe(s: Senal): { n: number; oficial: boolean } {
  const f = s.puntos?.fiabilidad;
  // la base cuenta fuentes DISTINTAS (22); «corr» son noticias y solo vale sin datos de la base
  const n = f ? f.fuentes : s.corr;
  const oficial = f?.oficial ?? (s.traza?.fuentes.some((x) => x.oficial) ?? false);
  return { n, oficial };
}

/** Confirmada o publicada (lo decide la columna, no el respaldo) */
export const esConfirmada = (s: Senal) => CONFIRMADA.includes(s.estado);

/** La regla única: confirmada o publicada, no escenario, y fuente oficial o 2+ fuentes distintas */
export function esVerificada(s: Senal): boolean {
  if (!esConfirmada(s) || s.escenario) return false;
  const r = respaldoDe(s);
  return r.oficial || r.n >= 2;
}

/** Por qué es (o no) verificada, en una frase */
export function motivoVerificada(s: Senal): string {
  if (s.escenario) return 'Es un escenario (predicción): no se verifica.';
  const r = respaldoDe(s);
  if (r.oficial) return 'La respalda una fuente oficial.';
  if (r.n >= 2) return `La respaldan ${r.n} fuentes distintas.`;
  return r.n === 1 ? 'Solo la cuenta una fuente no oficial: falta una fuente oficial o una segunda fuente.'
    : 'No tiene noticias enlazadas: no se puede comprobar.';
}
