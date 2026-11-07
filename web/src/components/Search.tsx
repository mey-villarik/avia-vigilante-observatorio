// Buscador global (Ctrl+K): señales, fuentes, paneles y vistas.
import { useEffect, useRef, useState } from 'react';
import type { PanelId } from '../types';
import { PANELS, STATE_TXT, VIEWS } from '../data/demo';
import { useStore } from '../store';
import { norm } from '../lib/util';
import { Empty } from './common';

interface Resultado { k: string; t: string; s: string; a: () => void }

export function Search() {
  const open = useStore((s) => s.searchOpen);
  const senales = useStore((s) => s.senales);
  const fuentes = useStore((s) => s.fuentes);
  const { setSearchOpen, openDrawer, addPanel, go } = useStore.getState();
  const [q, setQ] = useState('');
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => { if (open) setQ(''); }, [open]);
  if (!open) return null;

  const n = norm(q);
  const R: Resultado[] = [];
  senales.forEach((s) => {
    if (!n || norm(`${s.id} ${s.titulo} ${s.destinos.join(' ')} ${s.deps.join(' ')}`).includes(n)) {
      R.push({ k: 'Señal', t: s.titulo, s: `${s.id} · ${s.deps.join(', ')}`, a: () => openDrawer({ kind: 'senal', id: s.id }) });
    }
  });
  if (n) {
    fuentes.forEach((s) => { if (norm(`${s.nombre} ${s.url} ${s.canal}`).includes(n)) R.push({ k: 'Fuente', t: s.nombre, s: STATE_TXT[s.estado], a: () => openDrawer({ kind: 'fuente', id: s.id }) }); });
    (Object.entries(PANELS) as [PanelId, (typeof PANELS)[PanelId]][]).forEach(([k, p]) => { if (norm(p.t + ' ' + p.d).includes(n)) R.push({ k: 'Panel', t: 'Añadir: ' + p.t, s: p.d, a: () => addPanel(k) }); });
    VIEWS.forEach(([id, name]) => { if (norm(name).includes(n)) R.push({ k: 'Vista', t: 'Ir a ' + name, s: '', a: () => go(id) }); });
  }
  const res = R.slice(0, 10);
  const pick = (r?: Resultado) => { setSearchOpen(false); r?.a(); };

  return (
    <div className="search" role="dialog" aria-modal="true" aria-label="Buscar" onClick={(e) => e.target === e.currentTarget && setSearchOpen(false)}>
      <div className="search-box">
        <div className="search-top">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4.2-4.2" /></svg>
          <input ref={input} autoFocus type="search" placeholder="Buscar señales, fuentes, destinos, paneles…" autoComplete="off" aria-label="Buscar"
            value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); pick(res[0]); } }} />
          <span className="kbd">ESC</span>
        </div>
        <div className="search-res">
          {res.length
            ? res.map((r, i) => (
              <button key={i} className={`sres ${i === 0 ? 'on' : ''}`} onClick={() => pick(r)}>
                <span><b>{r.t}</b><small>{r.s}</small></span><span className="k">{r.k}</span>
              </button>
            ))
            : <Empty title="Sin resultados">Prueba con un destino, un departamento o una fuente.</Empty>}
        </div>
      </div>
    </div>
  );
}
