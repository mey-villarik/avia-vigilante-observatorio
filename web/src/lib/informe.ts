// Informe para la Dirección en PDF, de 1 página (P2 de la auditoría para la Dirección, 2026-11-22).
//
// Tres bloques, los mismos de la vista Dirección y con sus mismas reglas (lib/direccion.ts):
//   1. Estado de los 3 ejes (movilidad, servicios esenciales, atención turística) y el semáforo de Bolivia.
//   2. Las 3 decisiones de hoy, cada una con su ficha «Acción recomendada · Plazo · Cómo verificar».
//   3. Lo que viene en los próximos 7 días, por fecha de ocurrencia.
// Arriba, la línea de totales de la síntesis del día (vigilante.sintesis_dia, 26) y, en el informe
// semanal, el balance de la semana. Aquí NO se recalcula nada: solo se junta lo que ya da la base
// (o lib/direccion con las mismas reglas cuando la base no trae «direccion»).
//
// datosInforme() arma el contenido (sin dependencias, se puede probar); pdfInforme() lo dibuja con
// jsPDF, que se carga solo al pulsar el botón para no engordar el panel.
import type { Fuente, Senal, SintesisDia } from '../types';
import {
  EJE_TXT, ESTADO_TXT, TIPO_VIENE_TXT, ejeDe, fichaDe, loQueViene, resumenEjes, semaforoBolivia,
  semaforoDepartamentos, topDecisiones, type Eje, type EstadoEje,
} from './direccion';
import { ACCION_TXT, accionDe } from './accion';
import { CERTEZAS, certezaDe } from './certeza';
import { cifrasFuentes } from './contadores';
import { enBolivia } from './hora';
import { hoyBolivia } from './vigencia';

export type TipoInforme = 'diario' | 'semanal';
export const TIPO_INFORME_TXT: Record<TipoInforme, string> = { diario: 'Informe del día', semanal: 'Informe semanal' };

export interface InformeEje { eje: Eje; nombre: string; estado: EstadoEje; motivo: string; cuenta: string; riesgos: string[] }
export interface InformeDecision { codigo: string; titulo: string; etiquetas: string[]; accion: string; plazo: string; verificar: string; afecta?: string }
export interface InformeViene { dia: string; fecha: string; items: { titulo: string; detalle: string }[] }
export interface Informe {
  tipo: TipoInforme;
  titulo: string;
  /** «domingo, 22 de noviembre de 2026 · 11:05 (hora de Bolivia)» */
  fecha: string;
  /** para el nombre del archivo, AAAA-MM-DD */
  dia: string;
  bolivia: { estado: EstadoEje; texto: string; motivo: string };
  totales: string;
  fuentes: string;
  departamentos: string;
  /** solo en el semanal */
  semana?: string[];
  ejes: InformeEje[];
  decisiones: InformeDecision[];
  viene: InformeViene[];
  /** lo que no cupo en «Lo que viene» */
  vieneMas: number;
}

const plural = (n: number, uno: string, varios: string) => `${n} ${n === 1 ? uno : varios}`;
const MAX_VIENE = 9;

export function datosInforme(
  senales: Senal[], fuentes: Fuente[], sintesis: SintesisDia | null, tipo: TipoInforme, ahora = Date.now(),
): Informe {
  const hoy = hoyBolivia(ahora);
  const activas = senales.filter((s) => s.estado !== 'descartada');
  const ejes = resumenEjes(senales);
  const bo = semaforoBolivia(ejes);

  // 1. ejes
  const informeEjes: InformeEje[] = ejes.map((r) => {
    const c: string[] = [];
    if (r.cuenta.accion) c.push(`${r.cuenta.accion} para actuar hoy`);
    if (r.cuenta.atencion) c.push(`${r.cuenta.atencion} para preparar`);
    if (r.cuenta.oportunidades) c.push(plural(r.cuenta.oportunidades, 'oportunidad', 'oportunidades'));
    return {
      eje: r.eje, nombre: EJE_TXT[r.eje], estado: r.estado, motivo: r.motivo,
      cuenta: c.length ? c.join(' · ') : 'Sin señales activas',
      riesgos: r.senales.filter((s) => s.naturaleza !== 'oportunidad' && accionDe(s).accion !== 'seguir').slice(0, 2).map((s) => s.titulo),
    };
  });

  // 2. decisiones
  const decisiones: InformeDecision[] = topDecisiones(senales, 3, ahora).map((s) => {
    const f = fichaDe(s, ahora);
    const eje = ejeDe(s);
    const et = [
      eje ? EJE_TXT[eje] : null,
      s.naturaleza === 'oportunidad' ? 'Oportunidad' : ACCION_TXT[accionDe(s).accion],
      CERTEZAS[certezaDe(s).nivel].t,
      s.deps.length ? s.deps.slice(0, 3).join(', ') : null,
      s.id,
    ].filter(Boolean) as string[];
    return { codigo: s.id, titulo: s.titulo, etiquetas: et, accion: f.accion, plazo: f.plazo, verificar: f.verificar, afecta: f.afecta || undefined };
  });

  // 3. lo que viene (7 días), por día
  const items = loQueViene(senales, 7, ahora);
  const viene: InformeViene[] = [];
  items.slice(0, MAX_VIENE).forEach((it) => {
    const dia = it.dias === 0 ? 'Hoy' : it.dias === 1 ? 'Mañana' : enBolivia(it.fecha, 'diaSemana');
    let g = viene.find((v) => v.fecha === it.fecha);
    if (!g) { g = { dia, fecha: enBolivia(it.fecha, 'diaCorto'), items: [] }; viene.push(g); }
    const det = [
      TIPO_VIENE_TXT[it.tipo],
      it.eje ? EJE_TXT[it.eje] : null,
      CERTEZAS[certezaDe(it.senal).nivel].t,
      it.fin && it.fin !== it.fecha ? `hasta el ${enBolivia(it.fin, 'diaCorto')}` : null,
      it.senal.deps.length ? it.senal.deps.slice(0, 3).join(', ') : null,
    ].filter(Boolean).join(' · ');
    g.items.push({ titulo: `${it.senal.titulo} (${it.senal.id})`, detalle: det });
  });

  // departamentos
  const sem = Object.values(semaforoDepartamentos(senales));
  const rojos = sem.filter((d) => d.estado === 'accion').map((d) => d.dep);
  const amarillos = sem.filter((d) => d.estado === 'atencion').map((d) => d.dep);
  const departamentos = !rojos.length && !amarillos.length
    ? 'Los 9 departamentos en verde: ninguno pide medidas.'
    : [rojos.length ? `En rojo: ${rojos.join(', ')}` : null, amarillos.length ? `En amarillo: ${amarillos.join(', ')}` : null,
      `${sem.length - rojos.length - amarillos.length} en verde`].filter(Boolean).join('. ') + '.';

  // fuentes: la misma cifra que el resto del panel (41)
  const cf = cifrasFuentes(fuentes);
  const fuentesTxt = cf.total
    ? `${cf.leidas} de ${cf.total} fuentes leídas${cf.sinLeer ? `; ${cf.sinLeer} sin leer: puede haber hechos sin detectar` : ''}.`
    : '';

  // semana: lo que entró en 7 días
  let semana: string[] | undefined;
  if (tipo === 'semanal') {
    const nuevas = senales.filter((s) => s.min <= 7 * 1440);
    const r = nuevas.filter((s) => s.naturaleza === 'riesgo').length;
    const o = nuevas.filter((s) => s.naturaleza === 'oportunidad').length;
    const m = nuevas.length - r - o;
    const desc = nuevas.filter((s) => s.estado === 'descartada').length;
    const publ = nuevas.filter((s) => s.estado === 'publicada').length;
    semana = [
      `${plural(nuevas.length, 'señal nueva', 'señales nuevas')} en 7 días: ${plural(r, 'riesgo', 'riesgos')}, ${plural(o, 'oportunidad', 'oportunidades')}${m ? ` y ${plural(m, 'mixta', 'mixtas')}` : ''}.`,
      `${plural(publ, 'publicada', 'publicadas')} y ${plural(desc, 'descartada', 'descartadas')} tras verificar.`,
    ];
  }

  const ahoraTxt = `${enBolivia(ahora, 'fecha')} · ${enBolivia(ahora, 'hora')} (hora de Bolivia)`;
  return {
    tipo,
    titulo: TIPO_INFORME_TXT[tipo],
    fecha: ahoraTxt,
    dia: hoy,
    bolivia: { estado: bo.estado, texto: ESTADO_TXT[bo.estado], motivo: bo.motivo },
    totales: sintesis?.totales ?? `${plural(activas.length, 'señal activa', 'señales activas')}.`,
    fuentes: fuentesTxt,
    departamentos,
    semana,
    ejes: informeEjes,
    decisiones,
    viene,
    vieneMas: Math.max(0, items.length - MAX_VIENE),
  };
}

// ───────── PDF ─────────

// Las fuentes estándar del PDF solo llevan el juego Windows-1252: se cambian los signos que no están
// (flechas, emojis…) para que no salgan como basura.
const CP1252_EXTRA = '€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ';
export function textoPdf(t: string): string {
  return t
    .replace(/[→⇒➜]/g, '->').replace(/[←⇐]/g, '<-').replace(/≥/g, '>=').replace(/≤/g, '<=').replace(/≈/g, '~')
    .replace(/[​-‍️]/g, '').replace(/ | /g, ' ')
    .split('').filter((c) => { const n = c.charCodeAt(0); return (n >= 32 && n < 127) || (n >= 160 && n <= 255) || CP1252_EXTRA.includes(c); })
    .join('').replace(/\s{2,}/g, ' ').trim();
}

type RGB = [number, number, number];
const COLOR: Record<EstadoEje, RGB> = { accion: [192, 57, 43], atencion: [212, 160, 23], normal: [46, 139, 87] };
const TINTA: RGB = [31, 41, 55];
const GRIS: RGB = [107, 114, 128];
const LINEA: RGB = [209, 213, 219];
const MARCA: RGB = [22, 52, 86];

export async function pdfInforme(inf: Informe): Promise<Blob> {
  const { jsPDF } = await import('jspdf');
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true });
  const W = 210, H = 297, M = 14, ANCHO = W - 2 * M, PIE = H - 12;
  let y = 0;

  const color = (c: RGB) => doc.setTextColor(c[0], c[1], c[2]);
  const fuente = (estilo: 'normal' | 'bold' | 'italic', tam: number) => { doc.setFont('helvetica', estilo); doc.setFontSize(tam); };
  const alto = (tam: number) => tam * 0.3528 * 1.25;   // alto de línea en mm
  /** escribe un párrafo; devuelve false si no cabe entero y lo corta con «…» */
  const parrafo = (t: string, x: number, ancho: number, tam: number, estilo: 'normal' | 'bold' | 'italic' = 'normal', c: RGB = TINTA, maxLineas = 99, limite = PIE - 4): number => {
    fuente(estilo, tam); color(c);
    let lineas: string[] = doc.splitTextToSize(textoPdf(t), ancho);
    const cabe = Math.max(0, Math.floor((limite - y) / alto(tam)));
    const n = Math.min(lineas.length, maxLineas, cabe);
    if (n < lineas.length) { lineas = lineas.slice(0, n); if (n) lineas[n - 1] = lineas[n - 1].replace(/\s*\S*$/, '') + '…'; }
    lineas.forEach((l, i) => doc.text(l, x, y + alto(tam) * (i + 0.8)));
    return n * alto(tam);
  };
  const circulo = (x: number, cy: number, r: number, e: EstadoEje) => { const c = COLOR[e]; doc.setFillColor(c[0], c[1], c[2]); doc.circle(x, cy, r, 'F'); };
  const titulo = (t: string, nota?: string) => {
    y += 3;
    fuente('bold', 11); color(MARCA); doc.text(textoPdf(t), M, y + 4);
    if (nota) { const w = doc.getTextWidth(textoPdf(t)); fuente('normal', 8); color(GRIS); doc.text(textoPdf(nota), M + w + 3, y + 4); }
    doc.setDrawColor(MARCA[0], MARCA[1], MARCA[2]); doc.setLineWidth(0.4); doc.line(M, y + 5.6, W - M, y + 5.6);
    y += 8;
  };

  // ── cabecera
  doc.setFillColor(MARCA[0], MARCA[1], MARCA[2]); doc.rect(0, 0, W, 22, 'F');
  fuente('bold', 15); doc.setTextColor(255, 255, 255); doc.text(textoPdf(`${inf.titulo} para la Dirección`), M, 10);
  fuente('normal', 8.5); doc.setTextColor(220, 228, 238);
  doc.text(textoPdf(`ORBITA · Observatorio de turismo de Bolivia · AVIA · ${inf.fecha}`), M, 16.5);
  y = 28;

  // ── semáforo de Bolivia
  circulo(M + 3.5, y + 3.5, 3.5, inf.bolivia.estado);
  fuente('bold', 14); color(TINTA); doc.text('Bolivia:', M + 10, y + 5);
  const wb = doc.getTextWidth('Bolivia: ');
  color(COLOR[inf.bolivia.estado]); doc.text(textoPdf(inf.bolivia.texto), M + 10 + wb, y + 5);
  y += 8.5;
  y += parrafo(inf.bolivia.motivo, M, ANCHO, 9.5, 'normal', TINTA, 2);
  y += parrafo([inf.totales, inf.fuentes].filter(Boolean).join(' '), M, ANCHO, 8, 'normal', GRIS, 2);
  y += parrafo(`Departamentos. ${inf.departamentos}`, M, ANCHO, 8, 'normal', GRIS, 2);
  if (inf.semana?.length) {
    y += 1;
    fuente('bold', 8); color(TINTA); doc.text('La semana:', M, y + alto(8) * 0.8);
    const ws = doc.getTextWidth('La semana: ');
    y += parrafo(inf.semana.join(' '), M + ws, ANCHO - ws, 8, 'normal', TINTA, 2);
  }

  // ── 1. ejes
  titulo('1. Estado de los tres ejes');
  const gap = 4, wc = (ANCHO - 2 * gap) / 3, y0 = y, altoCaja = 40;
  inf.ejes.forEach((e, i) => {
    const x = M + i * (wc + gap);
    const c = COLOR[e.estado];
    doc.setDrawColor(LINEA[0], LINEA[1], LINEA[2]); doc.setLineWidth(0.3); doc.rect(x, y0, wc, altoCaja);
    doc.setFillColor(c[0], c[1], c[2]); doc.rect(x, y0, wc, 1.6, 'F');
    y = y0 + 3;
    fuente('bold', 9.5); color(TINTA); doc.text(textoPdf(e.nombre), x + 3, y + 3.5);
    circulo(x + 4.5, y + 8.2, 1.6, e.estado);
    fuente('bold', 9); color(c); doc.text(textoPdf(ESTADO_TXT[e.estado]), x + 7.5, y + 9.2);
    y += 11.5;
    const lim = y0 + altoCaja - 1.5;
    y += parrafo(e.motivo, x + 3, wc - 6, 7.5, 'normal', TINTA, 3, lim);
    y += parrafo(e.cuenta, x + 3, wc - 6, 7, 'italic', GRIS, 2, lim);
    e.riesgos.forEach((r) => { if (y < lim - 3) y += parrafo(`• ${r}`, x + 3, wc - 6, 7, 'normal', TINTA, 2, lim); });
  });
  y = y0 + altoCaja + 1;

  // ── 2. decisiones
  titulo('2. Decisiones de hoy', 'las 3 más urgentes');
  if (!inf.decisiones.length) {
    y += parrafo('Nada que decidir ahora: ningún riesgo pide medidas y ninguna convocatoria cierra en los próximos 7 días.', M, ANCHO, 9, 'italic', GRIS);
  }
  inf.decisiones.forEach((d, i) => {
    const xT = M + 7;
    fuente('bold', 11); color(MARCA); doc.text(String(i + 1), M + 1, y + 4);
    y += parrafo(d.titulo, xT, ANCHO - 7, 9.5, 'bold', TINTA, 2);
    y += parrafo(d.etiquetas.join(' · '), xT, ANCHO - 7, 7, 'normal', GRIS, 1);
    const fila = (et: string, t: string, max: number) => {
      fuente('bold', 8); color(TINTA); doc.text(textoPdf(et), xT, y + alto(8) * 0.8);
      y += parrafo(t, xT + 30, ANCHO - 37, 8, 'normal', TINTA, max);
    };
    fila('Acción recomendada', d.accion + (d.afecta ? ` (afecta a ${d.afecta.replace(/\.$/, '').toLowerCase()})` : ''), 3);
    fila('Plazo', d.plazo, 1);
    fila('Cómo verificar', d.verificar, 2);
    y += 2.2;
  });

  // ── 3. lo que viene
  titulo('3. Lo que viene', 'próximos 7 días, por fecha en que ocurre');
  if (!inf.viene.length) {
    y += parrafo('Ninguna señal activa tiene una fecha de ocurrencia o de cierre en los próximos 7 días.', M, ANCHO, 9, 'italic', GRIS);
  }
  for (const g of inf.viene) {
    if (y > PIE - 10) break;
    const yDia = y;
    fuente('bold', 8.5); color(TINTA); doc.text(textoPdf(g.dia), M, y + 3);
    fuente('normal', 7); color(GRIS); doc.text(textoPdf(g.fecha), M, y + 6.2);
    for (const it of g.items) {
      if (y > PIE - 10) break;
      y += parrafo(it.titulo, M + 26, ANCHO - 26, 8.5, 'normal', TINTA, 2);
      y += parrafo(it.detalle, M + 26, ANCHO - 26, 7, 'normal', GRIS, 1);
      y += 0.8;
    }
    y = Math.max(y, yDia + 8);
    doc.setDrawColor(LINEA[0], LINEA[1], LINEA[2]); doc.setLineWidth(0.2); doc.line(M, y, W - M, y);
    y += 1.2;
  }
  if (inf.vieneMas) y += parrafo(`Y ${inf.vieneMas} más en el panel (vista Dirección, «Lo que viene»).`, M, ANCHO, 7.5, 'italic', GRIS, 1);

  // ── pie
  doc.setDrawColor(LINEA[0], LINEA[1], LINEA[2]); doc.setLineWidth(0.3); doc.line(M, PIE, W - M, PIE);
  fuente('normal', 6.8); color(GRIS);
  doc.text(textoPdf('Generado por AVIA desde el panel del observatorio. Fechas en hora de Bolivia. Lo no confirmado lleva su certeza (posible, rumor); las predicciones son escenarios.'), M, PIE + 4, { maxWidth: ANCHO });
  return doc.output('blob');
}

/** arma el informe, lo dibuja y lo descarga */
export async function descargarInforme(senales: Senal[], fuentes: Fuente[], sintesis: SintesisDia | null, tipo: TipoInforme): Promise<void> {
  const inf = datosInforme(senales, fuentes, sintesis, tipo);
  const blob = await pdfInforme(inf);
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `AVIA-${tipo === 'diario' ? 'informe-dia' : 'informe-semanal'}-${inf.dia}.pdf`;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
