// Lógica del chat "Pregunta a AVIA": abrir, enviar y aplicar las órdenes que devuelve AVIA.
import type { PanelId, Senal, VistaId } from '../types';
import { DEPS, PANELS, STATE_TXT, STL } from '../data/demo';
import { activeSignals, conProblema, useStore } from '../store';
import { ROLE_NAME, norm } from '../lib/util';
import { aviaConectado, remoto, type Comando } from './avia';
import { GLOSARIO, TERMINOS } from '../lib/glosario';
import { fechaBolivia, trazaDe } from '../lib/trazabilidad';
import { CERTEZAS, NIVELES_CERTEZA, certezaDe } from '../lib/certeza';
import { recoCorta, recoTexto } from '../lib/recomendacion';
import { separarVencidas, sintesisDe, sintesisTexto } from '../lib/sintesis';
import { calcularPulso, pulsoTexto } from '../lib/pulso';
import { contar } from '../lib/contadores';
import { separarRespuesta } from '../lib/respuesta';
import { filtrarSenales, filtroDesdePedido, filtroTexto, mismoFiltro } from '../lib/filtroSenales';
import { certezaPlazo, cierreTexto } from '../lib/plazo';

const SALUDO = 'Hola, soy AVIA. Vigilo las fuentes del observatorio, junto las noticias en señales y te doy recomendaciones. Una señal solo es alerta cuando una persona del equipo la publica.\n\nPregúntame lo que quieras o pídeme que cambie el tablero.';

export const CHIPS = ['¿Qué oportunidades cierran pronto?', '¿Qué fuentes fallan?', 'Riesgos en La Paz', 'Añade el mapa al tablero', 'Haz un resumen para el ministerio'];

let ctl: AbortController | null = null;

const VISTAS: VistaId[] = ['panorama', 'mapa', 'fuentes', 'senales', 'oportunidades', 'internacional', 'analisis', 'bitacora'];
const VISTA_TXT: Record<VistaId, string> = {
  panorama: 'Panorama', mapa: 'Mapa', fuentes: 'Fuentes', senales: 'Señales', oportunidades: 'Oportunidades',
  internacional: 'Internacional', analisis: 'Análisis', bitacora: 'Bitácora',
};
const MAX_IDS = 20;

/** Resultado de aplicar una orden: etiqueta corta y, sobre todo, lo que de verdad quedó en pantalla */
export interface Aplicado { act: string | null; evidencia: string | null; ok: boolean }

/** Aplica en la interfaz una orden de AVIA y COMPRUEBA lo que quedó (CP3 de Carlos): la confirmación
 *  sale del estado real del panel, con los códigos de las señales que se ven, nunca del texto del modelo. */
export function aplicarComando(c: Comando): Aplicado {
  const st = useStore.getState();
  if (c.tipo === 'abrir') {
    const partes: string[] = [];
    let ok = true;
    const quiereFiltro = c.filtro && typeof c.filtro === 'object';
    const vista = (c.vista ?? (quiereFiltro ? 'senales' : undefined)) as VistaId | undefined;
    if (vista) {
      if (!VISTAS.includes(vista)) return { act: null, ok: false, evidencia: `No abrí nada: la vista «${vista}» no existe en el panel.` };
      if (quiereFiltro) {
        if (vista !== 'senales') return { act: null, ok: false, evidencia: `No apliqué el filtro: solo la vista Señales tiene ese filtro.` };
        const r = filtroDesdePedido(c.filtro!);
        if ('error' in r) return { act: null, ok: false, evidencia: `No apliqué el filtro: ${r.error}.` };
        st.setSigFilter(r.filtro);
      }
      st.go(vista);
      const ahora = useStore.getState();
      if (ahora.view !== vista) return { act: null, ok: false, evidencia: `No pude abrir la vista ${VISTA_TXT[vista]}.` };
      if (vista === 'senales') {
        const pedido = quiereFiltro ? filtroDesdePedido(c.filtro!) : null;
        if (pedido && 'filtro' in pedido && !mismoFiltro(ahora.sigFilter, pedido.filtro)) {
          return { act: null, ok: false, evidencia: 'Abrí Señales, pero el filtro no quedó aplicado. Revisa los filtros de la vista.' };
        }
        const ids = filtrarSenales(ahora.senales, ahora.sigFilter).map((s) => s.id);
        const lista = ids.length
          ? `: ${ids.slice(0, MAX_IDS).join(', ')}${ids.length > MAX_IDS ? ` y ${ids.length - MAX_IDS} más` : ''}`
          : '. Ninguna señal cumple ese filtro ahora mismo';
        partes.push(`Vista Señales abierta con el filtro ${filtroTexto(ahora.sigFilter)}. Se muestran ${ids.length} señal${ids.length === 1 ? '' : 'es'}${lista}.`);
      } else {
        partes.push(`Vista ${VISTA_TXT[vista]} abierta.`);
      }
    }
    if (c.senal) {
      if (st.senales.some((s) => s.id === c.senal)) {
        st.openDrawer({ kind: 'senal', id: c.senal });
        const d = useStore.getState().drawer;
        if (d?.kind === 'senal' && d.id === c.senal) partes.push(`Ficha de ${c.senal} abierta.`);
        else { ok = false; partes.push(`No pude abrir la ficha de ${c.senal}.`); }
      } else { ok = false; partes.push(`No abrí ${c.senal}: no está en el panel ahora mismo.`); }
    }
    if (c.fuente) {
      if (st.fuentes.some((f) => f.id === c.fuente)) { st.openDrawer({ kind: 'fuente', id: c.fuente }); partes.push(`Fuente ${c.fuente} abierta.`); }
      else { ok = false; partes.push(`No abrí la fuente ${c.fuente}: no está en el panel.`); }
    }
    if (!partes.length) return { act: null, ok: false, evidencia: null };
    return { act: ok ? `Abrí ${vista ? VISTA_TXT[vista] : c.senal || c.fuente}` : null, ok, evidencia: partes.join(' ') };
  }
  if (c.tipo === 'tablero' && c.panel in PANELS) {
    const ok = c.accion === 'agregar' ? st.addPanel(c.panel as PanelId, true) : st.removePanel(c.panel as PanelId, true);
    st.go('panorama');
    return { act: ok ? 'Tablero actualizado' : null, ok, evidencia: ok ? null : 'No cambié el tablero.' };
  }
  return { act: null, ok: false, evidencia: null };
}

// Frases del modelo que dicen que ya abrió o filtró algo. Se quitan siempre: lo que se hizo lo dice
// el panel con la evidencia de aplicarComando (CP3).
const AFIRMA_ACCION = /[^.\n]*\b(?:ya\s+)?(?:te\s+)?(?:abr[ií](?!r)|he abierto|acabo de abrir|apliqué|he aplicado|filtré|he filtrado|dejé (?:abiert|filtrad)[ao]s?|te (?:muestro|llevo|llevé) a la vista)(?=[\s,.;:!?)]|$)[^.\n]*[.]?/giu;

/** Quita del texto las afirmaciones de acciones y añade lo que de verdad pasó en la interfaz */
export function textoConEvidencia(texto: string, comandos: Comando[]): { texto: string; act?: string } {
  const aplicados = comandos.map(aplicarComando);
  const afirmaba = AFIRMA_ACCION.test(texto);
  AFIRMA_ACCION.lastIndex = 0;
  let limpio = texto.replace(AFIRMA_ACCION, '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  const evid = aplicados.map((a) => a.evidencia).filter((x): x is string => Boolean(x));
  if (!evid.length && afirmaba) evid.push('No abrí ninguna vista ni apliqué filtros: la respuesta no traía la orden. Pídemelo otra vez o usa los filtros de la vista Señales.');
  if (evid.length) limpio = `${limpio}${limpio ? '\n\n' : ''}${evid.map((e) => `**En pantalla:** ${e}`).join('\n')}`;
  const act = aplicados.map((a) => a.act).filter(Boolean).join(' · ');
  return { texto: limpio || 'Listo.', act: act || undefined };
}

const PRIO_N = { alta: 0, media: 1, baja: 2 } as const;
const fuenteDe = (s: Senal) => {
  const f = trazaDe(s).fuentes[0];
  if (!f) return ' (sin fuente enlazada)';
  const fecha = f.fecha ? `fecha ${fechaBolivia(f.fecha)} sin distinguir` : f.publicada ? `publicado ${fechaBolivia(f.publicada)}` : 'la fuente no da fecha';
  return ` (${f.nombre}, ${fecha}${f.url ? ', ' + f.url : ''})`;
};

/** Respuesta por bloques (mejora 3 de la PoC): hechos, pendiente, interpretación, impacto, escenarios, recomendación.
 *  Mismo formato que pide el prompt de avia_api.py. Un bloque vacío lo dice; nunca se rellena. */
export function bloques(lista: Senal[]): string {
  const orden = [...lista].sort((a, b) => PRIO_N[a.prioridad] - PRIO_N[b.prioridad]);
  const reales = orden.filter((s) => !s.escenario);
  // mejora 6: hechos = confirmado o convocado; pendiente = posible o rumor
  const hechos = reales.filter((s) => ['confirmado', 'convocado'].includes(certezaDe(s).nivel));
  const pend = reales.filter((s) => ['posible', 'rumor'].includes(certezaDe(s).nivel));
  const esc = orden.filter((s) => s.escenario);
  const lugares = [...new Set(reales.flatMap((s) => [...s.deps, ...s.destinos]))];
  const linea = (s: Senal) => `- [${certezaDe(s).nivel}] ${s.id} ${s.titulo}${fuenteDe(s)}`;
  const top = (hechos[0] ?? pend[0]);
  return [
    '#### Hechos',
    hechos.length ? hechos.map(linea).join('\n') : 'Sin datos: ninguna señal está confirmada ni convocada todavía.',
    '#### Pendiente de verificar',
    pend.length ? pend.map((s) => `${linea(s)}: falta ${s.corr < 2 ? 'una fuente oficial o una segunda fuente independiente' : 'la revisión de una persona'} (${certezaDe(s).motivo.toLowerCase()})`).join('\n') : 'Nada pendiente.',
    '#### Interpretación',
    top?.importancia ? `AVIA interpreta (no es un hecho): ${top.importancia}` : 'Sin datos.',
    '#### Impacto turístico',
    lugares.length ? `Afecta a ${lugares.slice(0, 8).join(', ')}${lugares.length > 8 ? ` y ${lugares.length - 8} lugares más` : ''}. ${reales.filter((s) => s.naturaleza === 'riesgo').length} riesgo(s) y ${reales.filter((s) => s.naturaleza !== 'riesgo').length} oportunidad(es) o mixta(s).` : 'Sin datos para medirlo.',
    '#### Escenarios',
    esc.length ? esc.map((s) => `- Escenario (no es un hecho): ${s.id} ${s.titulo}`).join('\n') : 'Sin datos suficientes para plantear escenarios.',
    '#### Recomendación',
    top ? recoTexto(top) : 'Sin datos.',
  ].join('\n');
}

/** Respuestas por reglas cuando no hay backend de AVIA */
function localReply(q: string): { text: string; act?: string } {
  const st = useStore.getState();
  const t = norm(q);
  const panelHit = (Object.entries(PANELS) as [PanelId, (typeof PANELS)[PanelId]][]).find(([k, p]) =>
    t.includes(norm(p.t)) || t.includes(k) || (k === 'mapa' && t.includes('mapa')) || (k === 'evolucion' && t.includes('grafic'))
    || (k === 'temas' && t.includes('tema')) || (k === 'actividad' && t.includes('actividad')));

  if (/(anade|agrega|pon|muestra)/.test(t) && panelHit) {
    if (st.layout.some((p) => p.id === panelHit[0])) { st.go('panorama'); return { text: `«${panelHit[1].t}» ya está en el tablero. Te llevé al Panorama.` }; }
    st.addPanel(panelHit[0], true);
    return { text: `Listo, añadí «${panelHit[1].t}» al tablero.`, act: 'Tablero actualizado' };
  }
  if (/(quita|elimina|saca|oculta)/.test(t) && panelHit) {
    st.removePanel(panelHit[0], true);
    return { text: `Quité «${panelHit[1].t}». Puedes volver a ponerlo cuando quieras.`, act: 'Tablero actualizado' };
  }
  if (/fuente|falla|caid|estado/.test(t)) {
    const bad = st.fuentes.filter(conProblema);
    st.go('fuentes');
    return {
      text: bad.length ? `Hay ${bad.length} fuentes que revisar:\n` + bad.map((s) => `• ${s.nombre}: ${STATE_TXT[s.estado]} — ${s.info}`).join('\n') : 'Todas las fuentes están bien.',
      act: 'Abrí la vista Fuentes',
    };
  }
  if (/certeza|rumor|convocad|confirmad.*posible|posible.*confirmad/.test(t)) {
    st.openDrawer({ kind: 'glosario' });
    const cuenta = NIVELES_CERTEZA.map((k) => `${activeSignals(st.senales).filter((s) => certezaDe(s).nivel === k).length} ${k}`).join(', ');
    return { text: `Grado de certeza de cada señal:\n${NIVELES_CERTEZA.map((k) => `• ${CERTEZAS[k].t}: ${CERTEZAS[k].def}`).join('\n')}\nAhora: ${cuenta}.`, act: 'Abrí el glosario' };
  }
  const termino = TERMINOS.find((k) => new RegExp(`que es (una |un )?${norm(GLOSARIO[k].t)}|diferencia`).test(t));
  if (termino || /glosario/.test(t)) {
    const l = termino && !/diferencia/.test(t) ? [termino] : TERMINOS;
    st.openDrawer({ kind: 'glosario' });
    return { text: l.map((k) => `• ${GLOSARIO[k].t}: ${GLOSARIO[k].def}`).join('\n'), act: 'Abrí el glosario' };
  }
  const dep = DEPS.find((d) => t.includes(norm(d)));
  const act = activeSignals(st.senales);
  if (/alerta/.test(t)) {
    const l = act.filter((s) => s.estado === 'publicada' && (!dep || s.deps.includes(dep)));
    return { text: l.length ? `Alertas publicadas${dep ? ' en ' + dep : ''} (señales que el equipo confirmó y publicó):\n` + l.map((s) => `• ${s.id} ${s.titulo} (${s.naturaleza})`).join('\n') : `No hay alertas publicadas${dep ? ' en ' + dep : ''}. Puede haber señales en verificación: pregúntame por riesgos u oportunidades.` };
  }
  if (/riesgo|peligro/.test(t)) {
    const l = act.filter((s) => s.naturaleza === 'riesgo' && (!dep || s.deps.includes(dep)));
    return { text: l.length ? `Hay ${l.length} riesgo${l.length === 1 ? '' : 's'} activo${l.length === 1 ? '' : 's'}${dep ? ' en ' + dep : ''}:\n` + l.map((s) => `• ${s.id} ${s.titulo} (${STL[s.estado]}). Recomendación: ${recoCorta(s)}.`).join('\n') : `No hay riesgos activos${dep ? ' en ' + dep : ''}.` };
  }
  if (/oportunidad|plazo|cierra|fondo|convocatoria/.test(t)) {
    const todas = act.filter((s) => s.naturaleza !== 'riesgo' && (!dep || s.deps.includes(dep))).sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999));
    const l = todas.slice(0, 4);
    return { text: l.length ? `Hay ${todas.length} oportunidades${todas.length > l.length ? `; estas son las ${l.length} con el plazo más cercano` : ''}:\n` + l.map((s) => `• ${s.id} ${s.titulo}${s.cierre ? ` — ${cierreTexto(s.cierre.fecha)} (plazo ${certezaPlazo(s).nivel})` : ''}. Recomendación: ${recoCorta(s)}.`).join('\n') : 'No encontré oportunidades con ese filtro.' };
  }
  if (/resumen|sintesis|ministerio|informe|situacion|panorama/.test(t)) {
    const l = act.filter((x) => !dep || x.deps.includes(dep));
    if (dep) return { text: `Resumen de ${dep}: ${l.length} señales activas${st.origen === 'vps' ? '' : ' (datos de ejemplo)'}.\n` + bloques(l) };
    // el resumen del día va siempre en 3 bloques (mejora 8): qué pasa, por qué importa, qué vigilar
    const sd = st.sintesisDia ? separarVencidas(st.sintesisDia, st.senales) : sintesisDe(st.senales, st.fuentes, st.contadores ?? contar(st.senales, st.noticiasRevisadas ?? 0));
    return { text: `Resumen del día${st.origen === 'vps' ? '' : ' (datos de ejemplo)'}:\n` + sintesisTexto(sd) };
  }
  const m = q.match(/SEN-\d{4}/i);
  const s = m && st.senales.find((x) => x.id === m[0].toUpperCase());
  if (s) { st.openDrawer({ kind: 'senal', id: s.id }); return { text: `${s.id}: ${s.titulo}\n` + bloques([s]), act: 'Abrí la señal' }; }
  if (dep) {
    const l = act.filter((x) => x.deps.includes(dep));
    return { text: `${dep} tiene ${l.length} señales:\n` + l.map((x) => `• ${x.id} ${x.titulo} (${x.naturaleza})`).join('\n') };
  }
  return { text: 'En modo local entiendo preguntas sobre oportunidades, riesgos, fuentes, un departamento o un código SEN, y órdenes como «añade el mapa» o «quita la actividad». Con la IA activa puedo hacer análisis más abiertos.' };
}

export async function sendChat(txt: string) {
  const st = useStore.getState();
  txt = txt.trim();
  if (!txt || st.chatBusy) return;
  st.pushChat({ role: 'u', text: txt });
  st.setChatBusy(true);
  const bubble = st.pushChat({ role: 'a', text: 'Pensando…' });

  // el Pulso lo calcula el panel: la explicación sale de las mismas cuentas, con los números de ahora
  if (/\bpulso\b|nivel de vigilancia|indice de riesgo|indice de oportunidad/.test(norm(txt))) {
    st.openDrawer({ kind: 'pulso' });
    useStore.getState().updateChat(bubble, { text: pulsoTexto(calcularPulso(st.senales, st.fuentes)), act: 'Abrí la explicación del Pulso' });
    useStore.getState().setChatBusy(false);
    return;
  }

  if (!aviaConectado) {
    await new Promise((r) => setTimeout(r, 350));
    const r = localReply(txt);
    useStore.getState().updateChat(bubble, { text: r.text, act: r.act });
    useStore.getState().setChatBusy(false);
    return;
  }

  // panel y AVIA leen la misma base: si los datos del panel tienen más de 1 minuto, se recargan a la vez
  // para que los números de la pantalla y los de la respuesta sean del mismo momento
  if (st.origen === 'vps' && (!st.generado || Date.now() - Date.parse(st.generado) > 60000)) void st.loadRemote(true);

  ctl = new AbortController();
  const historial = useStore.getState().chat
    .filter((m) => m.id !== bubble)
    .slice(-10)
    .map((m) => ({ role: m.role === 'u' ? 'user' as const : 'assistant' as const, content: m.role === 'u' ? m.text : separarRespuesta(m.text).texto }));
  try {
    const res = await remoto.chat(historial, ROLE_NAME[st.role], ctl.signal);
    // solo se muestra «texto»; las órdenes se aplican sin enseñar el JSON
    const limpia = separarRespuesta(res.texto, res.comandos ?? []);
    // CP3: solo se confirma lo que de verdad quedó en pantalla, con los códigos de las señales que se ven
    const r = textoConEvidencia(limpia.texto, limpia.comandos);
    useStore.getState().updateChat(bubble, { text: r.texto, act: r.act });
  } catch (e) {
    const cancel = e instanceof DOMException && e.name === 'AbortError';
    useStore.getState().updateChat(bubble, { text: cancel ? 'Detenido.' : 'No pude responder ahora. Prueba otra vez en un momento.' });
  } finally {
    useStore.getState().setChatBusy(false);
  }
}

export function useChat() {
  const openChat = (prefill?: string) => {
    const st = useStore.getState();
    st.closeDrawer();
    st.setChatOpen(true);
    if (!st.chat.length) st.pushChat({ role: 'a', text: SALUDO });
    if (prefill) void sendChat(prefill);
  };
  const closeChat = () => useStore.getState().setChatOpen(false);
  const resetChat = () => {
    ctl?.abort();
    const st = useStore.getState();
    st.clearChat();
    st.pushChat({ role: 'a', text: SALUDO });
  };
  return { openChat, closeChat, resetChat };
}
