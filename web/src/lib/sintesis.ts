// Síntesis del día en 3 bloques (mejora 8 de la PoC): qué pasa, por qué importa, qué vigilar.
// La fuente es la base: vigilante.sintesis_dia() en db/generico/26_sintesis_dia.sql. Aquí se repiten
// las mismas reglas solo para los datos de ejemplo y para vigilante.json antiguos que no la traen.
// Si cambias una regla, cámbiala en los dos sitios (y en docs/sintesis-dia.md).
import type { Fuente, ItemSintesis, RevisionesVencidas, Senal, SintesisDia } from '../types';
import type { Contadores } from './contadores';
import { certezaDe } from './certeza';
import { puntuacionesDe } from './puntuaciones';
import { recoDe } from './recomendacion';

const MAX = 3;
const PRIO = { alta: 0, media: 1, baja: 2 } as const;
const IMP = { alto: 0, medio: 1, bajo: 2, 'sin datos': 3 } as const;
const plural = (n: number, uno: string, varios: string) => `${n} ${n === 1 ? uno : varios}`;
const bajaInicial = (t: string) => t.charAt(0).toLowerCase() + t.slice(1);

export function totalesTexto(k: Contadores): string {
  return `${plural(k.senales_activas, 'señal activa', 'señales activas')}: ${plural(k.riesgos, 'riesgo', 'riesgos')}, `
    + `${plural(k.oportunidades, 'oportunidad', 'oportunidades')}${k.mixtas ? ` y ${plural(k.mixtas, 'mixta', 'mixtas')}` : ''}; `
    + `${k.noticias_24h} noticias revisadas en 24 h.`;
}

export function sintesisDe(senales: Senal[], fuentes: Fuente[], k: Contadores): SintesisDia {
  const act = senales.filter((s) => s.estado !== 'descartada');
  const info = act.map((s) => ({ s, c: certezaDe(s), p: puntuacionesDe(s), r: recoDe(s) }));

  const hechos = info
    .filter((x) => !x.s.escenario && ['confirmado', 'convocado'].includes(x.c.nivel))
    .sort((a, b) => PRIO[a.s.prioridad] - PRIO[b.s.prioridad] || IMP[a.p.impacto.nivel] - IMP[b.p.impacto.nivel])
    .slice(0, MAX);
  const que_pasa: ItemSintesis[] = hechos.map((x) => ({
    codigo: x.s.id, titulo: x.s.titulo, certeza: x.c.nivel, naturaleza: x.s.naturaleza,
    lugares: x.s.deps.join(', ') || undefined, texto: x.s.resumen.slice(0, 180), impacto: x.p.impacto.nivel, motivo: x.p.impacto.motivo, para_quien: x.r.para_quien,
  }));
  const por_que_importa: ItemSintesis[] = hechos.map((x) => ({
    codigo: x.s.id, titulo: x.s.titulo, impacto: x.p.impacto.nivel,
    texto: x.p.impacto.nivel === 'sin datos' ? 'Impacto turístico sin datos: AVIA no lo valoró' : x.p.impacto.motivo,
    para_quien: x.r.para_quien,
  }));

  const vigilar: { o: number; it: ItemSintesis }[] = [];
  for (const x of info) {
    const { s } = x;
    if (!s.escenario && s.naturaleza !== 'oportunidad' && ['posible', 'rumor'].includes(x.c.nivel) && s.prioridad !== 'baja') {
      const f = x.r.falta_saber[0];
      vigilar.push({ o: 10 + PRIO[s.prioridad], it: { codigo: s.id, titulo: s.titulo, tipo: 'sin_confirmar', certeza: x.c.nivel,
        texto: `Riesgo sin confirmar (${x.c.nivel})${f ? `. Falta saber: ${bajaInicial(f)}` : ''}` } });
    }
    if (x.r.afirma_sin_verificar) {
      vigilar.push({ o: 15, it: { codigo: s.id, titulo: s.titulo, tipo: 'recomendacion_sin_verificar',
        texto: `La recomendación da algo por operativo sin dato oficial reciente: comprobar con ${x.r.verificar_con}` } });
    }
    if (x.c.nivel === 'convocado') {
      vigilar.push({ o: 20 + PRIO[s.prioridad], it: { codigo: s.id, titulo: s.titulo, tipo: 'convocado', certeza: 'convocado',
        texto: 'Anunciado: confirmar si se mantiene en la fecha' } });
    }
    if (s.naturaleza !== 'riesgo' && s.plazo != null && s.plazo < 15) {
      vigilar.push({ o: 30 + PRIO[s.prioridad], it: { codigo: s.id, titulo: s.titulo, tipo: 'plazo',
        texto: `Oportunidad que cierra en ${plural(s.plazo, 'día', 'días')}` } });
    }
  }
  const que_vigilar = vigilar.sort((a, b) => a.o - b.o).slice(0, MAX * 2).map((v) => v.it);
  const caidas = fuentes.filter((f) => f.estado === 'CRIT').length;
  if (caidas) que_vigilar.push({ tipo: 'fuentes', texto: `${plural(caidas, 'fuente no se puede leer', 'fuentes no se pueden leer')}: puede haber hechos sin detectar` });

  return { totales: totalesTexto(k), que_pasa, por_que_importa, que_vigilar, revisiones_vencidas: vencidasDe(senales) };
}

/** Revisiones vencidas a partir de las señales (datos de ejemplo o vigilante.json sin el 45). Sin responsable conocido. */
export function vencidasDe(senales: Senal[]): RevisionesVencidas {
  const v = senales.filter((s) => s.revisionVencida && ['detectada', 'en_analisis', 'en_verificacion'].includes(s.estado));
  return { total: v.length, senales: v.slice(0, 5).map((s) => ({ codigo: s.id, titulo: s.titulo })), responsable: null, responsable_origen: null };
}

/** El aviso va aparte: se quita de «qué vigilar» la línea que traía el 26 antes del 45 */
export function separarVencidas(sd: SintesisDia, senales: Senal[]): SintesisDia {
  const que_vigilar = sd.que_vigilar.filter((i) => i.tipo !== 'revision_vencida');
  let rv = sd.revisiones_vencidas;
  if (!rv) {
    const local = vencidasDe(senales);
    // el 26 sin el 45 solo da la cifra en el texto: se usa si es mayor que la que se ve en las señales
    const linea = sd.que_vigilar.find((i) => i.tipo === 'revision_vencida');
    const n = linea ? parseInt(linea.texto ?? '', 10) : NaN;
    rv = Number.isFinite(n) && n > local.total ? { ...local, total: n } : local;
  }
  return { ...sd, que_vigilar, revisiones_vencidas: rv };
}

export const textoVencidas = (n: number) => plural(n, 'señal con revisión vencida', 'señales con revisión vencida');
export const textoResponsable = (rv: RevisionesVencidas) =>
  rv.responsable ? `Responsable: ${rv.responsable}${rv.responsable_origen === 'analistas' ? ' (analistas)' : ''}` : 'Sin responsable asignado';

/** La síntesis como texto plano, para el chat y para copiarla */
export function sintesisTexto(s: SintesisDia): string {
  const linea = (i: ItemSintesis) => `- ${i.codigo ? `${i.codigo} ` : ''}${i.certeza ? `[${i.certeza}] ` : ''}${i.titulo ? `${i.titulo}${i.texto || i.motivo ? ': ' : ''}` : ''}${i.texto ?? i.motivo ?? ''}`.trimEnd();
  const bloque = (t: string, l: ItemSintesis[], vacio: string) => `#### ${t}\n${l.length ? l.map(linea).join('\n') : vacio}`;
  const rv = s.revisiones_vencidas;
  return [
    ...(rv?.total ? [`**⚠ ${textoVencidas(rv.total)}: nadie ${rv.total === 1 ? 'la decidió' : 'las decidió'} a tiempo. ${textoResponsable(rv)}.**`] : []),
    s.totales,
    bloque('Qué pasa', s.que_pasa, 'Sin novedades confirmadas ni convocadas.'),
    bloque('Por qué importa', s.por_que_importa, 'Sin datos: no hay hechos que valorar.'),
    bloque('Qué vigilar', s.que_vigilar, 'Nada pendiente de vigilar.'),
  ].join('\n');
}
