import { useEffect } from 'react';
import type { VistaId } from './types';
import { VIEWS } from './data/demo';
import { useStore } from './store';
import { Sidebar, Topbar, Toasts } from './components/Shell';
import { Drawer } from './components/Drawer';
import { Search } from './components/Search';
import { Chat } from './components/Chat';
import { Foot } from './components/common';
import { useChat } from './services/chat';
import { Panorama } from './views/Panorama';
import { Fuentes } from './views/Fuentes';
import { Senales } from './views/Senales';
import { Oportunidades } from './views/Oportunidades';
import { Analisis } from './views/Analisis';
import { Bitacora } from './views/Bitacora';

const VISTAS: Record<VistaId, () => JSX.Element> = {
  panorama: Panorama, fuentes: Fuentes, senales: Senales, oportunidades: Oportunidades, analisis: Analisis, bitacora: Bitacora,
};

/** Aplica tema, contraste, tamaño de texto y modo sencillo al documento */
function usePrefs() {
  const fs = useStore((s) => s.fs);
  const theme = useStore((s) => s.theme);
  const contrast = useStore((s) => s.contrast);
  const simple = useStore((s) => s.simple);
  useEffect(() => {
    const r = document.documentElement;
    r.style.setProperty('--fs', String(fs));
    if (theme) r.setAttribute('data-theme', theme); else r.removeAttribute('data-theme');
    r.setAttribute('data-contrast', contrast);
    document.body.classList.toggle('simple', simple);
  }, [fs, theme, contrast, simple]);
}

/** Simulación de comprobaciones cada 20 s (solo en la demo) */
function useLiveSimulation() {
  const live = useStore((s) => s.live);
  useEffect(() => {
    if (!live) return;
    const t = setInterval(() => useStore.getState().liveStep(), 20000);
    return () => clearInterval(t);
  }, [live]);
}

function useShortcuts() {
  const { openChat } = useChat();
  useEffect(() => {
    const onHash = () => {
      const v = location.hash.slice(1) as VistaId;
      if (VIEWS.some((x) => x[0] === v) && v !== useStore.getState().view) useStore.getState().go(v);
    };
    const onKey = (e: KeyboardEvent) => {
      const st = useStore.getState();
      const el = e.target as HTMLElement;
      const typing = el.matches?.('input,textarea,select');
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); st.setSearchOpen(true); return; }
      if (e.key === 'Escape') {
        if (st.searchOpen) return st.setSearchOpen(false);
        if (st.drawer) return st.closeDrawer();
        if (st.chatOpen) return st.setChatOpen(false);
        if (st.editing) return st.setEditing(false);
      }
      if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key.toLowerCase() === 'h') { e.preventDefault(); if (st.chatOpen) document.getElementById('chatIn')?.focus(); else openChat(); }
      if (e.key.toLowerCase() === 'e' && st.view === 'panorama') st.setEditing(!st.editing);
    };
    window.addEventListener('hashchange', onHash);
    document.addEventListener('keydown', onKey);
    return () => { window.removeEventListener('hashchange', onHash); document.removeEventListener('keydown', onKey); };
  }, []);
}

export default function App() {
  const view = useStore((s) => s.view);
  usePrefs();
  useLiveSimulation();
  useShortcuts();
  const Vista = VISTAS[view];
  return (
    <>
      <div className="shell">
        <Sidebar />
        <div className="main">
          <Topbar />
          <main className="content" tabIndex={-1}>
            <Vista />
            <Foot />
          </main>
        </div>
      </div>
      <Chat />
      <Drawer />
      <Search />
      <Toasts />
    </>
  );
}
