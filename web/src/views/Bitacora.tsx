import { useStore } from '../store';
import { Icon } from '../components/Icon';
import { EventsList } from '../components/common';

export function Bitacora() {
  const eventos = useStore((s) => s.eventos);
  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Trazabilidad</div>
          <h1>Todo lo que pasó, <em>en orden</em></h1>
          <p className="sub">Comprobaciones de fuentes, señales nuevas y decisiones de las personas. En la versión real este registro no se puede borrar.</p>
        </div>
      </section>
      <section className="panel" style={{ '--w': 12 } as React.CSSProperties}>
        <div className="panel-h"><h2><Icon name="bitacora" />Registro</h2><span className="meta">{eventos.length} eventos</span></div>
        <div className="panel-b"><EventsList list={eventos} /></div>
      </section>
    </>
  );
}
