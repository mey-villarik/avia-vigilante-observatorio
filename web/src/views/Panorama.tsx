import { useEffect, useRef, useState } from 'react';
import type { PanelEnTablero, PanelId } from '../types';
import { PANELS } from '../data/demo';
import { useStore } from '../store';
import { clock } from '../lib/util';
import { Icon } from '../components/Icon';
import { PANEL_BODY, usePanelMeta } from '../panels/panels';
import { useChat } from '../services/chat';

interface DragState { dragId: PanelId | null; over: PanelId | null; after: boolean }

function Panel({ p, drag, setDrag }: { p: PanelEnTablero; drag: DragState; setDrag: (d: DragState) => void }) {
  const d = PANELS[p.id];
  const Body = PANEL_BODY[p.id];
  const meta = usePanelMeta(p.id);
  const { movePanel, widenPanel, removePanel, dropPanel } = useStore.getState();
  const flash = useStore((s) => s.flashPanel === p.id);
  const ref = useRef<HTMLElement>(null);

  useEffect(() => {
    if (!flash || !ref.current) return;
    ref.current.scrollIntoView({ behavior: 'smooth', block: 'center' });
    useStore.setState({ flashPanel: null });
  }, [flash]);

  const cls = ['panel',
    flash ? 'flash' : '',
    drag.dragId === p.id ? 'dragging' : '',
    drag.over === p.id ? (drag.after ? 'drop-after' : 'drop-before') : ''].join(' ');

  return (
    <section
      ref={ref}
      className={cls}
      style={{ '--w': p.w } as React.CSSProperties}
      aria-label={d.t}
      onDragOver={(e) => {
        if (!drag.dragId || drag.dragId === p.id) return;
        e.preventDefault();
        const r = e.currentTarget.getBoundingClientRect();
        setDrag({ ...drag, over: p.id, after: e.clientX - r.left > r.width / 2 });
      }}
      onDragLeave={() => drag.over === p.id && setDrag({ ...drag, over: null })}
      onDrop={(e) => {
        e.preventDefault();
        if (drag.dragId) dropPanel(drag.dragId, p.id, drag.after);
        setDrag({ dragId: null, over: null, after: false });
      }}
    >
      <div className="panel-h">
        <span
          className="grip" draggable title="Arrastrar para mover" aria-hidden="true"
          onDragStart={(e) => {
            e.dataTransfer.effectAllowed = 'move';
            try { e.dataTransfer.setData('text/plain', p.id); } catch { /* navegadores antiguos */ }
            if (ref.current) e.dataTransfer.setDragImage(ref.current, 20, 20);
            setDrag({ dragId: p.id, over: null, after: false });
          }}
          onDragEnd={() => setDrag({ dragId: null, over: null, after: false })}
        ><Icon name="grip" /></span>
        <h2><Icon name={d.i} />{d.t}</h2>
        <span className="meta">{meta}</span>
        <span className="panel-tools">
          <button onClick={() => movePanel(p.id, -1)} aria-label={`Mover ${d.t} antes`} title="Mover antes"><Icon name="left" /></button>
          <button onClick={() => movePanel(p.id, 1)} aria-label={`Mover ${d.t} después`} title="Mover después"><Icon name="right" /></button>
          <button onClick={() => widenPanel(p.id)} aria-label={`Cambiar ancho de ${d.t}`} title="Cambiar ancho"><Icon name="wider" /></button>
          <button onClick={() => removePanel(p.id)} aria-label={`Quitar ${d.t}`} title="Quitar"><Icon name="close" /></button>
        </span>
      </div>
      <div className="panel-b"><Body /></div>
    </section>
  );
}

export function Panorama() {
  const nFuentes = useStore((s) => s.fuentes.length);
  const editing = useStore((s) => s.editing);
  const generado = useStore((s) => s.generado);
  const layout = useStore((s) => s.layout);
  const { setEditing, openDrawer, resetBoard } = useStore.getState();
  const { openChat } = useChat();
  const [drag, setDrag] = useState<DragState>({ dragId: null, over: null, after: false });

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Inteligencia turística · hoy</div>
          <h1>Lo que <em>cambia</em> en el turismo de Bolivia</h1>
          <p className="sub">El Vigilante lee {nFuentes} fuentes, junta noticias dispersas, las verifica y valora su importancia para el turismo. Aquí ves el resultado; arrastra, quita o añade paneles a tu gusto.</p>
        </div>
        <div className="head-actions">
          <span className="updated">{generado ? `Datos generados ${clock(-(Date.now() - Date.parse(generado)) / 60000)}` : `Última comprobación ${clock(-1)}`}</span>
          <button className={`btn ${editing ? 'on' : ''}`} onClick={() => setEditing(!editing)}><Icon name="edit" /> {editing ? 'Terminar edición' : 'Editar tablero'}</button>
          <button className="btn gold" onClick={() => openChat('Haz el resumen del día para el equipo de supervisión turística: lo urgente, las 3 mejores oportunidades y qué falta verificar.')}><Icon name="sintesis" /> Resumen del día</button>
        </div>
      </section>
      {editing && (
        <div className="edit-bar" role="note">
          <strong>Modo edición.</strong>
          <span>Arrastra un panel por su asa o usa las flechas. El botón ↔ cambia el ancho. Los cambios se guardan en este navegador.</span>
          <span style={{ marginLeft: 'auto', display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <button className="btn sm" onClick={() => openDrawer({ kind: 'catalogo' })}><Icon name="plus" /> Añadir panel</button>
            <button className="btn sm" onClick={() => openDrawer({ kind: 'guardar' })}><Icon name="save" /> Guardar como tablero</button>
            <button className="btn sm ghost" onClick={resetBoard}><Icon name="reset" /> Restablecer</button>
          </span>
        </div>
      )}
      <div className={`board ${editing ? 'editing' : ''}`}>
        {layout.filter((p) => PANELS[p.id]).map((p) => <Panel key={p.id} p={p} drag={drag} setDrag={setDrag} />)}
        {editing && (
          <button className="add-tile" onClick={() => openDrawer({ kind: 'catalogo' })}><Icon name="plus" /><span>Añadir un panel</span></button>
        )}
      </div>
    </>
  );
}
