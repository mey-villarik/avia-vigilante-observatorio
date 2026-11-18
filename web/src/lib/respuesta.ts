// Separa la respuesta de AVIA en texto visible y órdenes para la interfaz.
// El servidor ya lo hace, pero si al modelo se le escapa el JSON (suelto, en ```json```, cortado,
// con texto alrededor) aquí se limpia otra vez: el JSON de comandos nunca se muestra en el chat.
import type { Comando } from '../services/avia';

const leer = (s: string): unknown => {
  try {
    return JSON.parse(s);
  } catch {
    // saltos de línea crudos dentro de las cadenas: JSON.parse no los acepta
    try {
      return JSON.parse(s.replace(/\r?\n/g, '\\n'));
    } catch {
      return null;
    }
  }
};

const esComando = (c: unknown): c is Comando => !!c && typeof c === 'object' && typeof (c as { tipo?: unknown }).tipo === 'string';

export function separarRespuesta(texto: string, comandos: Comando[] = []): { texto: string; comandos: Comando[] } {
  const r = (texto ?? '').trim();
  if (!r.includes('"texto"')) return { texto: r, comandos };

  let cand: string;
  let fuera: string;
  const m = /```[a-zA-Z]*\s*(\{[\s\S]*?)(?:```|$)/.exec(r);
  if (m) {
    cand = m[1];
    fuera = (r.slice(0, m.index) + r.slice(m.index + m[0].length)).trim();
  } else {
    const i = r.indexOf('{');
    cand = r.slice(i);
    fuera = r.slice(0, i).trim();
    const j = cand.lastIndexOf('}');
    if (j >= 0 && cand.slice(j + 1).trim()) {
      fuera = (fuera + '\n\n' + cand.slice(j + 1).trim()).trim();
      cand = cand.slice(0, j + 1);
    }
  }
  cand = cand.trim();

  let visible = '';
  let ordenes: Comando[] = [];
  const obj = leer(cand) as { texto?: unknown; comandos?: unknown } | null;
  if (obj && typeof obj === 'object' && 'texto' in obj) {
    visible = String(obj.texto ?? '').trim();
    ordenes = Array.isArray(obj.comandos) ? obj.comandos.filter(esComando) : [];
  } else {
    // JSON roto o cortado: se rescata el texto y las órdenes que se puedan leer
    const mt = /"texto"\s*:\s*"((?:[^"\\]|\\.)*)/.exec(cand);
    if (mt) {
      const crudo = leer('"' + mt[1] + '"');
      visible = typeof crudo === 'string' ? crudo : mt[1].replace(/\\n/g, '\n').replace(/\\"/g, '"');
    }
    ordenes = (cand.match(/\{[^{}]*"tipo"\s*:\s*"[^"]+"[^{}]*\}/g) ?? []).map(leer).filter(esComando);
  }
  return { texto: (visible || fuera || 'Listo.').trim(), comandos: [...comandos, ...ordenes] };
}
