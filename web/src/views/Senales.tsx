import { useState } from 'react';
import type { Etapa, Senal } from '../types';
import { CATS, DEPS, STAGES } from '../data/demo';
import { canDecide, useStore, type SigFilter } from '../store';
import { ago, norm } from '../lib/util';
import { NatPill } from '../components/common';

function Card({ s, draggable, onDragStart, onDragEnd }: { s: Senal; draggable: boolean; onDragStart: () => void; onDragEnd: () => void }) {
  const openDrawer = useStore((st) => st.openDrawer);
  return (
    <button className="card" draggable={draggable}
      onDragStart={(e) => { e.dataTransfer.effectAllowed = 'move'; try { e.dataTransfer.setData('text/plain', s.id); } catch { /* */ } onDragStart(); }}
      onDragEnd={onDragEnd}
      onClick={() => openDrawer({ kind: 'senal', id: s.id })}>
      <span className="cm"><NatPill n={s.naturaleza} /><span className="tag">{CATS[s.categoria]}</span></span>
      <span className="ct">{s.titulo}</span>
      <span className="cf">
        <span>{s.deps.slice(0, 2).join(', ')}{s.deps.length > 2 ? ' +' + (s.deps.length - 2) : ''}</span>
        <span className="mono">{s.id} · {ago(s.min)}</span>
      </span>
      <span className="cf tech"><span>Relevancia {s.rel}/10 · Novedad {s.nov}/10</span><span>{s.corr} fte.</span></span>
    </button>
  );
}

const NAT_OPTS: [SigFilter['nat'], string][] = [['all', 'Todas'], ['oportunidad', 'Oportunidades'], ['riesgo', 'Riesgos'], ['mixta', 'Mixtas']];

export function Senales() {
  const senales = useStore((s) => s.senales);
  const role = useStore((s) => s.role);
  const f = useStore((s) => s.sigFilter);
  const { setSigFilter, moveSignal } = useStore.getState();
  const [dragId, setDragId] = useState<string | null>(null);
  const [over, setOver] = useState<Etapa | null>(null);
  const decide = canDecide(role);

  const list = senales.filter((s) => (f.nat === 'all' || s.naturaleza === f.nat)
    && (f.dep === 'all' || s.deps.includes(f.dep))
    && (!f.q || norm(`${s.titulo} ${s.resumen} ${s.destinos.join(' ')} ${s.id}`).includes(norm(f.q))));

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Tratamiento del conocimiento</div>
          <h1>De noticia suelta a <em>señal verificada</em></h1>
          <p className="sub">Cada señal recorre etapas: AVIA la detecta y la evalúa, una persona la verifica y el observatorio la publica. {decide ? 'Arrastra una tarjeta a otra columna o ábrela para decidir.' : 'Estás en modo consulta.'}</p>
          <p className="sub"><a href="publico.html" target="_blank" rel="noopener noreferrer">Ver la web pública</a>: ahí aparece lo que está en «Publicada».</p>
        </div>
      </section>
      <div className="toolbar">
        <label className="sr" htmlFor="sigQ">Buscar señales</label>
        <input className="inp" id="sigQ" placeholder="Buscar por título, destino o código" value={f.q} onChange={(e) => setSigFilter({ q: e.target.value })} />
        <div className="seg">
          {NAT_OPTS.map(([k, n]) => <button key={k} className={f.nat === k ? 'on' : ''} onClick={() => setSigFilter({ nat: k })}>{n}</button>)}
        </div>
        <label className="sr" htmlFor="sigDep">Departamento</label>
        <select id="sigDep" style={{ width: 'auto' }} value={f.dep} onChange={(e) => setSigFilter({ dep: e.target.value })}>
          <option value="all">Todos los departamentos</option>
          {DEPS.map((d) => <option key={d}>{d}</option>)}
        </select>
      </div>
      <div className="pipe">
        {STAGES.map(([k, n]) => {
          const ss = list.filter((s) => s.estado === k);
          return (
            <div key={k} className={`stage ${over === k ? 'drop' : ''}`}
              onDragOver={(e) => { if (!dragId) return; e.preventDefault(); setOver(k); }}
              onDragLeave={() => setOver(null)}
              onDrop={(e) => { e.preventDefault(); if (dragId) moveSignal(dragId, k); setDragId(null); setOver(null); }}>
              <div className="stage-h">{n}<b>{ss.length}</b></div>
              <div className="stage-b">
                {ss.length
                  ? ss.map((s) => <Card key={s.id} s={s} draggable={decide} onDragStart={() => setDragId(s.id)} onDragEnd={() => { setDragId(null); setOver(null); }} />)
                  : <div className="note" style={{ padding: 8 }}>Vacía</div>}
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}
