// Lógica del chat "Pregunta a AVIA": abrir, enviar y aplicar las órdenes que devuelve AVIA.
import type { Etapa, PanelId, Senal, VistaId } from '../types';
import { DEPS, PANELS, STATE_TXT, STL } from '../data/demo';
import { activeSignals, conProblema, useStore } from '../store';
import { ROLE_NAME, norm } from '../lib/util';
import { aviaConectado, remoto, type Comando } from './avia';
import { GLOSARIO, TERMINOS } from '../lib/glosario';
import { fechaBolivia, trazaDe } from '../lib/trazabilidad';
import { CERTEZAS, NIVELES_CERTEZA, certezaDe } from '../lib/certeza';

const SALUDO = 'Hola, soy AVIA. Vigilo las fuentes del observatorio, junto las noticias en señales y te doy recomendaciones. Una señal solo es alerta cuando una persona del equipo la publica.\n\nPregúntame lo que quieras o pídeme que cambie el tablero.';

export const CHIPS = ['¿Qué oportunidades cierran pronto?', '¿Qué fuentes fallan?', 'Riesgos en La Paz', 'Añade el mapa al tablero', 'Haz un resumen para el ministerio'];

let ctl: AbortController | null = null;

/** Aplica en la interfaz una orden de AVIA. Devuelve una etiqueta corta de lo que hizo. */
export function aplicarComando(c: Comando): string | null {
  const st = useStore.getState();
  if (c.tipo === 'abrir') {
    if (c.vista) st.go(c.vista as VistaId);
    if (c.senal && st.senales.some((s) => s.id === c.senal)) st.openDrawer({ kind: 'senal', id: c.senal });
    if (c.fuente && st.fuentes.some((f) => f.id === c.fuente)) st.openDrawer({ kind: 'fuente', id: c.fuente });
    return 'Abrí ' + (c.senal || c.fuente || c.vista);
  }
  if (c.tipo === 'tablero' && c.panel in PANELS) {
    const ok = c.accion === 'agregar' ? st.addPanel(c.panel as PanelId, true) : st.removePanel(c.panel as PanelId, true);
    st.go('panorama');
    return ok ? 'Tablero actualizado' : null;
  }
  return null;
}

const POR_VERIFICAR: Etapa[] = ['detectada', 'en_analisis', 'en_verificacion'];
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
    top ? `${top.soluciones[0].t}${POR_VERIFICAR.includes(top.estado) ? ' (antes, confirmar la señal ' + top.id + ')' : ''}.` : 'Sin datos.',
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
    return { text: l.length ? `Hay ${l.length} riesgo${l.length === 1 ? '' : 's'} activo${l.length === 1 ? '' : 's'}${dep ? ' en ' + dep : ''}:\n` + l.map((s) => `• ${s.id} ${s.titulo} (${STL[s.estado]}). Recomendación: ${s.soluciones[0].t.toLowerCase()}.`).join('\n') : `No hay riesgos activos${dep ? ' en ' + dep : ''}.` };
  }
  if (/oportunidad|plazo|cierra|fondo|convocatoria/.test(t)) {
    const todas = act.filter((s) => s.naturaleza !== 'riesgo' && (!dep || s.deps.includes(dep))).sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999));
    const l = todas.slice(0, 4);
    return { text: l.length ? `Hay ${todas.length} oportunidades${todas.length > l.length ? `; estas son las ${l.length} con el plazo más cercano` : ''}:\n` + l.map((s) => `• ${s.id} ${s.titulo}${s.plazo ? ` — ${s.plazo} días` : ''}. Recomendación: ${s.soluciones[0].t.toLowerCase()}.`).join('\n') : 'No encontré oportunidades con ese filtro.' };
  }
  if (/resumen|sintesis|ministerio|informe|situacion|panorama/.test(t)) {
    const l = act.filter((x) => !dep || x.deps.includes(dep));
    return { text: `Resumen${dep ? ' de ' + dep : ''}: ${l.length} señales activas${st.origen === 'vps' ? '' : ' (datos de ejemplo)'}.\n` + (st.sintesis?.frase ? st.sintesis.frase + '\n' : '') + bloques(l) };
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
    .map((m) => ({ role: m.role === 'u' ? 'user' as const : 'assistant' as const, content: m.text }));
  try {
    const res = await remoto.chat(historial, ROLE_NAME[st.role], ctl.signal);
    const hechos = (res.comandos ?? []).map(aplicarComando).filter(Boolean);
    useStore.getState().updateChat(bubble, { text: res.texto, act: hechos.length ? hechos.join(' · ') : undefined });
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
