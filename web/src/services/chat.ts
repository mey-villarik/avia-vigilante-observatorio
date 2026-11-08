// Lógica del chat "Pregunta a AVIA": abrir, enviar y aplicar las órdenes que devuelve AVIA.
import type { PanelId, VistaId } from '../types';
import { DEPS, PANELS, STATE_TXT, STL } from '../data/demo';
import { activeSignals, conProblema, useStore } from '../store';
import { ROLE_NAME, norm } from '../lib/util';
import { aviaConectado, remoto, type Comando } from './avia';

const SALUDO = 'Hola, soy AVIA. Vigilo las fuentes del observatorio, junto las noticias en señales y te propongo oportunidades y soluciones.\n\nPregúntame lo que quieras o pídeme que cambie el tablero.';

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
  const dep = DEPS.find((d) => t.includes(norm(d)));
  const act = activeSignals(st.senales);
  if (/riesgo|peligro|alerta/.test(t)) {
    const l = act.filter((s) => s.naturaleza === 'riesgo' && (!dep || s.deps.includes(dep)));
    return { text: l.length ? `Riesgos${dep ? ' en ' + dep : ''}:\n` + l.map((s) => `• ${s.id} ${s.titulo} (${STL[s.estado]}). Verificar: ${s.soluciones[0].t.toLowerCase()}.`).join('\n') : `No hay riesgos activos${dep ? ' en ' + dep : ''}.` };
  }
  if (/oportunidad|plazo|cierra|fondo|convocatoria/.test(t)) {
    const l = act.filter((s) => s.naturaleza !== 'riesgo' && (!dep || s.deps.includes(dep))).sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999)).slice(0, 4);
    return { text: l.length ? 'Oportunidades por plazo:\n' + l.map((s) => `• ${s.id} ${s.titulo}${s.plazo ? ` — ${s.plazo} días` : ''}. Siguiente paso: ${s.soluciones[0].t.toLowerCase()}.`).join('\n') : 'No encontré oportunidades con ese filtro.' };
  }
  if (/resumen|sintesis|ministerio|informe/.test(t) && st.origen === 'vps') {
    const r = act.filter((x) => x.naturaleza === 'riesgo').sort((a, b) => ({ alta: 0, media: 1, baja: 2 })[a.prioridad] - ({ alta: 0, media: 1, baja: 2 })[b.prioridad]).slice(0, 2);
    const o = act.filter((x) => x.naturaleza !== 'riesgo').sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999)).slice(0, 3);
    const ver = act.filter((x) => ['detectada', 'en_verificacion'].includes(x.estado)).slice(0, 3);
    return {
      text: [
        `Resumen: ${act.length} señales activas.`,
        st.sintesis?.frase ?? '',
        r.length ? 'Lo urgente:\n' + r.map((x) => `• ${x.id} ${x.titulo}`).join('\n') : '',
        o.length ? 'Mejores oportunidades:\n' + o.map((x) => `• ${x.id} ${x.titulo}${x.plazo != null ? ` — ${x.plazo} días` : ''}`).join('\n') : '',
        ver.length ? 'Falta verificar:\n' + ver.map((x) => `• ${x.id} ${x.titulo}`).join('\n') : '',
      ].filter(Boolean).join('\n\n'),
    };
  }
  if (/resumen|sintesis|ministerio|informe/.test(t)) {
    return { text: `Resumen (datos de ejemplo): ${act.length} señales activas. Lo más urgente es la alerta naranja en Yungas y Rurrenabaque (SEN-0418). Las mejores oportunidades son el fondo de CAF para turismo comunitario, que cierra en 12 días (SEN-0417), y la nueva frecuencia aérea a Santa Cruz (SEN-0413). Falta confirmar la señal de dengue con el Ministerio de Salud (SEN-0415).` };
  }
  const m = q.match(/SEN-\d{4}/i);
  const s = m && st.senales.find((x) => x.id === m[0].toUpperCase());
  if (s) { st.openDrawer({ kind: 'senal', id: s.id }); return { text: `${s.id}: ${s.titulo}. ${s.importancia}`, act: 'Abrí la señal' }; }
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
