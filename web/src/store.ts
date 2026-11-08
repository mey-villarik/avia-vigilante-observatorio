// Estado global de la aplicación (zustand).
// Los datos vienen hoy de src/data/demo.ts; cuando exista la API, las acciones que cambian
// fuentes y señales deben llamar a src/services/api.ts además de actualizar el estado.
import { create } from 'zustand';
import {
  CATS, DEPS, EVENTOS_DEMO, FUENTES_DEMO, PANELS, PENDIENTES_DEMO, PRESETS, SENALES_DEMO, SERIE_DEMO, STATE_TXT, STL, TEMAS_DEMO, VIEWS, h24,
} from './data/demo';
import { cargarVps } from './services/datos';
import { accesoConfigurado, type Perfil } from './services/auth';
import { activarFuente, altaFuente, editarFuente, eliminarFuente, leerFuentesBd, mezclarFuentes, type AltaFuente } from './services/fuentes';
import { leerEstados, leerMovimientos, moverSenal, siguientesPasos, transicionValida } from './services/senales';
import type {
  CategoriaId, EstadoFuente, Etapa, Evaluacion, Evento, Fuente, PanelEnTablero, PanelId, Rol, Senal, Serie, Tema, TipoAnalisis, VistaId,
} from './types';
import { ROLE_NAME, clock, storage } from './lib/util';

export type Drawer =
  | { kind: 'fuente'; id: string }
  | { kind: 'senal'; id: string }
  | { kind: 'catalogo' }
  | { kind: 'a11y' }
  | { kind: 'guardar' }
  | { kind: 'nueva-fuente' }
  | { kind: 'editar-fuente'; id: string }
  | { kind: 'equipo' }
  | { kind: 'mi-clave' };

export interface Toast { id: number; msg: string }
export interface ChatMsg { id: number; role: 'a' | 'u'; text: string; act?: string }

export interface Analisis { type: TipoAnalisis; scope: 'all' | 'oportunidad' | 'riesgo'; dep: string; text: string; q: string }
export interface SigFilter { nat: 'all' | 'oportunidad' | 'riesgo' | 'mixta'; dep: string; q: string }

interface State {
  // navegación y preferencias
  view: VistaId;
  role: Rol;
  /** persona que ha iniciado sesión (null sin login) */
  perfil: Perfil | null;
  /** true si los estados de las señales se leen y guardan en la base de datos */
  enBd: boolean;
  sideOpen: boolean;
  editing: boolean;
  preset: string;
  layout: PanelEnTablero[];
  custom: Record<string, PanelEnTablero[]>;
  flashPanel: PanelId | null;
  srcFilter: 'all' | 'problemas' | EstadoFuente;
  srcQ: string;
  sigFilter: SigFilter;
  analysis: Analisis;
  live: boolean;
  fs: number;
  contrast: 'normal' | 'alto';
  simple: boolean;
  theme: 'dark' | 'light' | null;
  // datos
  /** de dónde vienen los datos: ejemplo inventado o vigilante.json del VPS */
  origen: 'demo' | 'vps';
  cargando: boolean;
  errorDatos: string | null;
  /** fecha en que Hermes generó los datos (ISO) */
  generado: string | null;
  ventanaHoras: number | null;
  noticiasRevisadas: number | null;
  sintesis: { frase: string; texto: string } | null;
  temas: Tema[];
  serie: Serie;
  fuentes: Fuente[];
  senales: Senal[];
  pendientes: Senal[];
  eventos: Evento[];
  tick: number;
  // capas
  drawer: Drawer | null;
  searchOpen: boolean;
  toasts: Toast[];
  chatOpen: boolean;
  docked: boolean;
  chat: ChatMsg[];
  chatBusy: boolean;
}

interface Actions {
  go: (v: VistaId) => void;
  setRole: (r: Rol) => void;
  setSesion: (p: Perfil | null) => void;
  setSideOpen: (o: boolean) => void;
  setEditing: (e: boolean) => void;
  applyPreset: (k: string) => void;
  resetBoard: () => void;
  movePanel: (id: PanelId, dir: number) => void;
  dropPanel: (dragId: PanelId, targetId: PanelId, after: boolean) => void;
  widenPanel: (id: PanelId) => void;
  removePanel: (id: PanelId, quiet?: boolean) => boolean;
  addPanel: (id: PanelId, quiet?: boolean) => boolean;
  saveBoard: (name: string) => void;
  setSrcFilter: (f: State['srcFilter']) => void;
  setSrcQ: (q: string) => void;
  setSigFilter: (f: Partial<SigFilter>) => void;
  setAnalysis: (a: Partial<Analisis>) => void;
  recheck: (id: string, quiet?: boolean) => void;
  checkAll: () => void;
  ackSource: (id: string) => void;
  toggleMant: (id: string) => void;
  addSource: (f: AltaFuente) => Promise<boolean>;
  removeSource: (id: string) => Promise<void>;
  editSource: (id: string, f: AltaFuente) => Promise<boolean>;
  moveSignal: (id: string, to: Etapa, note?: string) => boolean;
  addEvaluatedSignal: (r: Evaluacion) => string;
  liveStep: () => void;
  /** carga vigilante.json del VPS; si falla, deja los datos que hubiera */
  loadRemote: (quiet?: boolean) => Promise<void>;
  setLive: (on: boolean) => void;
  setPrefs: (p: Partial<Pick<State, 'fs' | 'contrast' | 'simple' | 'theme' | 'docked'>>) => void;
  openDrawer: (d: Drawer) => void;
  closeDrawer: () => void;
  setSearchOpen: (o: boolean) => void;
  toast: (msg: string) => void;
  dismissToast: (id: number) => void;
  setChatOpen: (o: boolean) => void;
  pushChat: (m: Omit<ChatMsg, 'id'>) => number;
  updateChat: (id: number, m: Partial<ChatMsg>) => void;
  clearChat: () => void;
  setChatBusy: (b: boolean) => void;
}

export type Store = State & Actions;

let seq = 1;
const nextId = () => seq++;

const presetLayout = (k: string): PanelEnTablero[] => (PRESETS[k] ?? PRESETS.ejecutivo).l.map(([id, w]) => ({ id, w }));

const initialView = (): VistaId => {
  const h = location.hash.slice(1) as VistaId;
  return VIEWS.some((v) => v[0] === h) ? h : 'panorama';
};

const shortName = (f: Fuente) => f.nombre.split(' ·')[0];

/** Simula una comprobación de una fuente. En producción el estado lo escribe el ciclo de 30 min. */
function simulateCheck(s: Fuente): { fuente: Fuente; evento: Evento; cambio: boolean } {
  let ns: EstadoFuente;
  if (s.id === 'abc_caminos') ns = Math.random() < 0.35 ? 'OK' : 'CRIT';
  else if (s.id === 'minsalud') ns = Math.random() < 0.3 ? 'OK' : 'WARN';
  else if (s.id === 'minturismo') ns = Math.random() < 0.5 ? 'OK' : 'WARN';
  else if (s.estado === 'OK') ns = Math.random() < 0.06 ? 'WARN' : 'OK';
  else if (s.estado === 'UNKNOWN') ns = 'UNKNOWN';
  else ns = 'OK';

  const f: Fuente = { ...s, hist: [...s.hist.slice(1), ns], last: 0 };
  if (ns === 'OK' && f.lat) f.lat = Math.round(500 + Math.random() * 1800);
  if (ns !== s.estado) {
    f.estado = ns; f.desde = 0; f.ack = false;
    if (ns === 'OK') {
      f.info = s.id === 'abc_caminos' ? 'HTTP 200 en 6,1 s · 2 tramos con restricción'
        : s.id === 'minsalud' ? 'HTTP 200 · 1 comunicado nuevo'
          : s.id === 'minturismo' ? 'HTTP 200 en 2,3 s · 1 nota nueva' : s.info;
    }
    if (ns === 'WARN' && s.id !== 'minsalud') f.info = 'Respuesta lenta (> 5 s) · reintentando';
    return {
      fuente: f, cambio: true,
      evento: { t: 0, k: ns, w: `${shortName(s)} pasó a ${STATE_TXT[ns]}`, d: ns === 'OK' ? 'Recuperada · vuelve a aportar datos' : 'Revisar comprobaciones' },
    };
  }
  return { fuente: f, cambio: false, evento: { t: 0, k: ns, w: `${shortName(s)} · comprobación`, d: f.info } };
}

const MAX_EVENTOS = 40;

export const useStore = create<Store>()((set, get) => {
  const savedPreset = storage.get('preset', 'ejecutivo');
  const persistLayout = () => { storage.set('layout', get().layout); storage.set('preset', get().preset); };
  const logEvent = (e: Evento) => set((s) => ({ eventos: [e, ...s.eventos].slice(0, MAX_EVENTOS) }));

  return {
    view: initialView(),
    role: accesoConfigurado ? 'visor' : storage.get<Rol>('role', 'analista'),
    perfil: null,
    enBd: false,
    sideOpen: false,
    editing: false,
    preset: savedPreset,
    layout: storage.get<PanelEnTablero[] | null>('layout', null) ?? presetLayout(savedPreset),
    custom: storage.get('custom', {}),
    flashPanel: null,
    srcFilter: 'all',
    srcQ: '',
    sigFilter: { nat: 'all', dep: 'all', q: '' },
    analysis: { type: 'panorama', scope: 'all', dep: 'all', text: '', q: '' },
    live: true,
    fs: storage.get('fs', 1),
    contrast: storage.get('contrast', 'normal'),
    simple: storage.get('simple', false),
    theme: storage.get('theme', null),
    origen: 'demo',
    cargando: false,
    errorDatos: null,
    generado: null,
    ventanaHoras: null,
    noticiasRevisadas: null,
    sintesis: null,
    temas: TEMAS_DEMO,
    serie: SERIE_DEMO,
    fuentes: FUENTES_DEMO.map((f) => ({ ...f })),
    senales: SENALES_DEMO.map((s) => ({ ...s })),
    pendientes: PENDIENTES_DEMO.map((s) => ({ ...s })),
    eventos: EVENTOS_DEMO.map((e) => ({ ...e })),
    tick: 0,
    drawer: null,
    searchOpen: false,
    toasts: [],
    chatOpen: false,
    docked: storage.get('docked', false),
    chat: [],
    chatBusy: false,

    go: (v) => {
      if (!VIEWS.some((x) => x[0] === v)) return;
      set({ view: v, sideOpen: false });
      try { history.replaceState(null, '', '#' + v); } catch { /* iframe sin historial */ }
      window.scrollTo({ top: 0 });
    },
    setSesion: (p) => set({ perfil: p, role: p?.rol ?? 'visor' }),
    setRole: (r) => {
      if (accesoConfigurado) return; // con login, el rol lo da el perfil
      storage.set('role', r); set({ role: r }); get().toast(`Ahora entras como ${ROLE_NAME[r]}.`); },
    setSideOpen: (o) => set({ sideOpen: o }),
    setEditing: (e) => set({ editing: e }),

    applyPreset: (k) => {
      const { custom } = get();
      let layout: PanelEnTablero[];
      if (k.startsWith('c:')) {
        const c = custom[k.slice(2)];
        if (!c) return;
        layout = c.map((p) => ({ ...p }));
      } else layout = presetLayout(k);
      const simple = k === 'sencillo';
      storage.set('simple', simple);
      set({ layout, preset: k, simple });
      persistLayout();
      get().go('panorama');
      get().toast(`Tablero «${k.startsWith('c:') ? k.slice(2) : PRESETS[k].n}» aplicado.`);
    },
    resetBoard: () => { const p = get().preset; get().applyPreset(p.startsWith('c:') ? 'ejecutivo' : p); },

    movePanel: (id, dir) => {
      const layout = [...get().layout];
      const i = layout.findIndex((p) => p.id === id);
      const j = i + dir;
      if (i < 0 || j < 0 || j >= layout.length) return;
      const [p] = layout.splice(i, 1);
      layout.splice(j, 0, p);
      set({ layout }); persistLayout();
    },
    dropPanel: (dragId, targetId, after) => {
      const layout = [...get().layout];
      const from = layout.findIndex((x) => x.id === dragId);
      if (from < 0) return;
      const [item] = layout.splice(from, 1);
      let to = layout.findIndex((x) => x.id === targetId);
      if (after) to++;
      layout.splice(to, 0, item);
      set({ layout }); persistLayout(); get().toast('Panel movido.');
    },
    widenPanel: (id) => {
      const seqW = [4, 5, 6, 7, 8, 12];
      set({ layout: get().layout.map((p) => (p.id === id ? { ...p, w: seqW[(seqW.indexOf(p.w) + 1) % seqW.length] || 4 } : p)) });
      persistLayout();
    },
    removePanel: (id, quiet) => {
      if (!get().layout.some((p) => p.id === id)) return false;
      set({ layout: get().layout.filter((p) => p.id !== id) }); persistLayout();
      if (!quiet) get().toast(`Quitaste «${PANELS[id].t}». Puedes volver a añadirlo desde el catálogo.`);
      return true;
    },
    addPanel: (id, quiet) => {
      if (!PANELS[id]) return false;
      if (get().layout.some((p) => p.id === id)) { if (!quiet) get().toast('Ese panel ya está en el tablero.'); return false; }
      set({ layout: [...get().layout, { id, w: PANELS[id].w }], flashPanel: id }); persistLayout();
      if (get().view !== 'panorama') get().go('panorama');
      if (!quiet) get().toast(`Añadiste «${PANELS[id].t}».`);
      return true;
    },
    saveBoard: (name) => {
      const custom = { ...get().custom, [name]: get().layout.map((p) => ({ ...p })) };
      storage.set('custom', custom);
      set({ custom, preset: 'c:' + name, drawer: null }); persistLayout();
      get().toast(`Tablero «${name}» guardado.`);
    },

    setSrcFilter: (f) => set({ srcFilter: f }),
    setSrcQ: (q) => set({ srcQ: q }),
    setSigFilter: (f) => set({ sigFilter: { ...get().sigFilter, ...f } }),
    setAnalysis: (a) => set({ analysis: { ...get().analysis, ...a } }),

    recheck: (id, quiet) => {
      if (get().origen === 'vps') { void get().loadRemote(quiet); return; }
      const s = get().fuentes.find((f) => f.id === id);
      if (!s || s.estado === 'MANT') return;
      const { fuente, evento, cambio } = simulateCheck(s);
      set({ fuentes: get().fuentes.map((f) => (f.id === id ? fuente : f)) });
      logEvent(evento);
      if (!quiet) get().toast(cambio ? `${shortName(s)}: ${STATE_TXT[fuente.estado]}` : `Comprobada: ${STATE_TXT[fuente.estado]}`);
    },
    checkAll: () => {
      if (get().origen === 'vps') { void get().loadRemote(); return; }
      get().fuentes.forEach((f) => get().recheck(f.id, true));
      get().toast('Se comprobaron todas las fuentes.');
    },
    ackSource: (id) => {
      const s = get().fuentes.find((f) => f.id === id);
      if (!s) return;
      set({ fuentes: get().fuentes.map((f) => (f.id === id ? { ...f, ack: true } : f)) });
      logEvent({ t: 0, k: 'check', w: `${ROLE_NAME[get().role]} reconoció el problema en ${shortName(s)}`, d: s.info });
      get().toast('Problema reconocido.');
    },
    toggleMant: (id) => {
      const f0 = get().fuentes.find((f) => f.id === id);
      if (f0?.enBd && get().perfil) {
        const activa = f0.estado === 'MANT';
        activarFuente(id, activa)
          .then(() => { get().toast(activa ? `${f0.nombre}: AVIA vuelve a vigilarla.` : `${f0.nombre} en pausa: AVIA deja de vigilarla.`); return get().loadRemote(true); })
          .catch((e: unknown) => get().toast(`No se guardó: ${e instanceof Error ? e.message : String(e)}`));
        return;
      }
      set({
      fuentes: get().fuentes.map((f) => (f.id !== id ? f : f.estado === 'MANT'
        ? { ...f, estado: 'UNKNOWN', info: 'Pendiente de la primera comprobación', desde: 0 }
        : { ...f, estado: 'MANT', info: 'Mantenimiento programado por el administrador', desde: 0 })),
      });
    },
    addSource: async (a) => {
      if (get().perfil) {
        try {
          const codigo = await altaFuente(a);
          set({ drawer: null });
          get().toast(`Fuente guardada (${codigo}). AVIA la vigilará desde su próxima ronda.`);
          await get().loadRemote(true);
          return true;
        } catch (e) {
          get().toast(`No se guardó: ${e instanceof Error ? e.message : String(e)}`);
          return false;
        }
      }
      const { nombre, url, freq } = a;
      const canal = a.canal as CategoriaId;
      const f: Fuente = {
        id: 'nueva_' + Date.now().toString(36), nombre, canal, tipo: 'nueva', url, metodo: 'Por definir', freq,
        estado: 'UNKNOWN', info: 'Pendiente de la primera comprobación', lat: null, items: 0, desde: 0,
        hist: h24('u'.repeat(24)), verif: 'por confirmar',
      };
      set({ fuentes: [...get().fuentes, f], drawer: null });
      logEvent({ t: 0, k: 'UNKNOWN', w: 'Fuente añadida', d: nombre });
      get().toast('Fuente añadida. Pulsa «Comprobar ahora» para probarla.');
      return true;
    },

    editSource: async (id, a) => {
      try {
        await editarFuente(id, a);
        get().toast(`Cambios guardados en ${a.nombre}. AVIA los usa desde su próxima ronda.`);
        set({ drawer: { kind: 'fuente', id } });
        await get().loadRemote(true);
        return true;
      } catch (e) {
        get().toast(`No se guardó: ${e instanceof Error ? e.message : String(e)}`);
        return false;
      }
    },

    removeSource: async (id) => {
      const f0 = get().fuentes.find((f) => f.id === id);
      if (!f0) return;
      if (f0.enBd && get().perfil) {
        try {
          await eliminarFuente(id);
        } catch (e) {
          get().toast(`No se eliminó: ${e instanceof Error ? e.message : String(e)}`);
          return;
        }
      }
      set({ fuentes: get().fuentes.filter((f) => f.id !== id), drawer: null });
      logEvent({ t: 0, k: 'MANT', w: 'Fuente eliminada', d: f0.nombre });
      get().toast(f0.enBd ? `${f0.nombre} eliminada: AVIA deja de vigilarla.` : `${f0.nombre} eliminada.`);
      if (f0.enBd && get().perfil) void get().loadRemote(true);
    },

    moveSignal: (id, to, note = '') => {
      const { role } = get();
      const s = get().senales.find((x) => x.id === id);
      if (!s || role === 'visor' || s.estado === to) return false;
      const conBd = Boolean(get().perfil) && get().origen === 'vps';
      if (conBd && !transicionValida(s.estado, to)) {
        get().toast(`No se puede pasar de «${STL[s.estado]}» a «${STL[to]}». Desde aquí: ${siguientesPasos(s.estado)}, o descartar.`);
        return false;
      }
      const quien = get().perfil?.nombre ?? ROLE_NAME[role];
      const updated: Senal = {
        ...s, estado: to,
        historial: [{ de: s.estado, a: to, quien, cuando: clock(0), nota: note }, ...(s.historial ?? [])],
        sla: ['confirmada', 'publicada'].includes(to) ? null : s.sla,
      };
      set({ senales: get().senales.map((x) => (x.id === id ? updated : x)) });
      logEvent({ t: 0, k: 'check', w: `${quien} movió ${id} a «${STL[to]}»`, d: s.titulo + (note ? ' · Nota: ' + note : '') });
      get().toast(`${id} → ${STL[to]}`);
      if (conBd) {
        moverSenal(id, to, note).catch((e: unknown) => {
          // no se guardó: se deshace en pantalla
          set({ senales: get().senales.map((x) => (x.id === id ? s : x)) });
          get().toast(`No se guardó: ${e instanceof Error ? e.message : String(e)}`);
        });
      }
      return true;
    },
    addEvaluatedSignal: (r) => {
      const id = 'SEN-' + String(422 + get().senales.length).padStart(4, '0');
      const s: Senal = {
        id, titulo: r.titulo || 'Noticia evaluada', resumen: 'Añadida desde Análisis.',
        naturaleza: ['oportunidad', 'riesgo', 'mixta'].includes(r.naturaleza) ? r.naturaleza : 'mixta',
        categoria: (r.categoria in CATS ? r.categoria : 'mercado') as CategoriaId,
        deps: (r.departamentos || []).filter((d) => DEPS.includes(d)), destinos: r.destinos || [],
        estado: 'detectada', prioridad: 'media', rel: +r.relevancia || 5, nov: +r.novedad || 5, conf: +r.confianza || 0.5,
        fuentes: [], corr: 0, min: 0, importancia: r.importancia || '',
        soluciones: (r.acciones?.length ? r.acciones : ['Verificar']).map((t) => ({ t, d: '' })),
      };
      set({ senales: [s, ...get().senales] });
      get().toast(`${id} añadida como detectada.`);
      return id;
    },

    liveStep: () => {
      const st = get();
      if (st.origen !== 'demo') return; // la simulación nunca toca datos reales
      const tick = st.tick + 1;
      const dt = 0.33;
      set({
        tick,
        eventos: st.eventos.map((e) => ({ ...e, t: e.t - dt })),
        fuentes: st.fuentes.map((f) => ({ ...f, last: (f.last ?? Math.floor((f.freq ?? 30) * 0.4)) + dt, desde: (f.desde ?? 0) + dt })),
        senales: st.senales.map((s) => ({ ...s, min: s.min + dt, sla: s.sla ? Math.max(1, Math.floor(s.sla - dt)) : s.sla })),
      });
      const cand = get().fuentes.filter((f) => f.estado !== 'MANT' && f.estado !== 'UNKNOWN');
      if (cand.length) get().recheck(cand[Math.floor(Math.random() * cand.length)].id, true);
      if (tick % 3 === 0 && get().pendientes.length) {
        const [n, ...rest] = get().pendientes;
        set({ pendientes: rest, senales: [{ ...n, min: 0 }, ...get().senales] });
        logEvent({ t: 0, k: 'spark', w: 'AVIA detectó una señal nueva', d: `${n.id} · ${n.titulo}` });
        get().toast(`Nueva señal: ${n.titulo}`);
      }
    },
    setLive: (on) => set({ live: on && get().origen === 'demo' }),

    loadRemote: async (quiet) => {
      if (get().cargando) return;
      set({ cargando: true });
      try {
        const d = await cargarVps(get().perfil);
        // con sesión: el estado de cada señal y los movimientos de las personas salen de la base de datos
        let bd = false;
        if (get().perfil) {
          try {
            const [estados, movs, fbd] = await Promise.all([leerEstados(), leerMovimientos(), leerFuentesBd().catch(() => [])]);
            d.fuentes = mezclarFuentes(d.fuentes, fbd);
            d.senales = d.senales.map((s) => (estados.has(s.id) ? { ...s, estado: estados.get(s.id)! } : s));
            d.eventos = [...movs, ...d.eventos].sort((a, b) => b.t - a.t);
            bd = estados.size > 0;
          } catch (e) {
            console.warn('Sin estados de la base de datos:', e);
          }
        }
        const primera = get().origen !== 'vps';
        set({
          origen: 'vps', live: false, enBd: bd, pendientes: [], errorDatos: null,
          fuentes: d.fuentes, senales: d.senales, eventos: d.eventos,
          temas: d.temas, serie: d.serie ?? SERIE_DEMO, sintesis: d.sintesis,
          generado: d.generado, ventanaHoras: d.ventanaHoras, noticiasRevisadas: d.noticiasRevisadas,
        });
        if (primera) get().toast(`Datos reales del Vigilante: ${d.senales.length} señales, ${d.fuentes.length} fuentes.`);
        else if (!quiet) get().toast('Datos actualizados.');
      } catch (e) {
        const msg = e instanceof Error ? e.message : 'error desconocido';
        set({ errorDatos: msg });
        if (!quiet) get().toast(get().origen === 'vps' ? `No se pudo actualizar: ${msg}` : 'Sin conexión con el VPS: se muestran datos de ejemplo.');
      } finally {
        set({ cargando: false });
      }
    },

    setPrefs: (p) => { Object.entries(p).forEach(([k, v]) => storage.set(k, v)); set(p); },
    openDrawer: (d) => set({ drawer: d }),
    closeDrawer: () => set({ drawer: null }),
    setSearchOpen: (o) => set({ searchOpen: o }),
    toast: (msg) => {
      const id = nextId();
      set({ toasts: [...get().toasts, { id, msg }] });
      setTimeout(() => get().dismissToast(id), 3800);
    },
    dismissToast: (id) => set({ toasts: get().toasts.filter((t) => t.id !== id) }),
    setChatOpen: (o) => set({ chatOpen: o }),
    pushChat: (m) => { const id = nextId(); set({ chat: [...get().chat, { ...m, id }] }); return id; },
    updateChat: (id, m) => set({ chat: get().chat.map((x) => (x.id === id ? { ...x, ...m } : x)) }),
    clearChat: () => set({ chat: [] }),
    setChatBusy: (b) => set({ chatBusy: b }),
  };
});

// Selectores derivados
export const activeSignals = (s: Senal[]) => s.filter((x) => x.estado !== 'descartada');
export const pendingDecision = (s: Senal[]) => s.filter((x) => ['detectada', 'en_verificacion'].includes(x.estado));
export function countStates(fuentes: Fuente[]): Record<EstadoFuente, number> {
  const c: Record<EstadoFuente, number> = { OK: 0, WARN: 0, CRIT: 0, UNKNOWN: 0, MANT: 0 };
  fuentes.forEach((f) => { c[f.estado]++; });
  return c;
}
export const canDecide = (r: Rol) => r !== 'visor';
export const isAdmin = (r: Rol) => r === 'admin';
