import { CATS, STL } from '../data/demo';
import { activeSignals, useStore } from '../store';
import { scoreOf } from '../lib/util';
import { Icon } from '../components/Icon';
import { NatPill } from '../components/common';
import { useChat } from '../services/chat';

export const planPrompt = (id: string, titulo: string) =>
  `Dame un plan de acción para ${id} (${titulo}). ¿Quién puede aprovecharlo o a quién afecta y qué hago primero?`;

export function Oportunidades() {
  const senales = useStore((s) => s.senales);
  const openDrawer = useStore((s) => s.openDrawer);
  const { openChat } = useChat();
  const l = activeSignals(senales).filter((s) => s.naturaleza !== 'riesgo').sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999));

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Oportunidades</div>
          <h1>Lo que se puede <em>aprovechar</em> ahora</h1>
          <p className="sub">AVIA no solo avisa: cruza cada oportunidad con quién puede aprovecharla y propone el siguiente paso. Ordenadas por plazo.</p>
        </div>
        <div className="head-actions">
          <button className="btn gold" onClick={() => openChat('Mirando todas las señales, ¿qué oportunidades nuevas propones que todavía no estén planteadas? Combina señales cuando tenga sentido.')}>
            <Icon name="spark" /> Proponer oportunidades nuevas
          </button>
        </div>
      </section>
      <div className="opp-grid">
        {l.map((s) => (
          <article className="opp" key={s.id}>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
              <NatPill n={s.naturaleza} /><span className="tag">{s.tipoOpp || CATS[s.categoria]}</span><span className="tag">{STL[s.estado]}</span>
            </div>
            <div className="ot">{s.titulo}</div>
            <p className="od">{s.importancia}</p>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', gap: 10, flexWrap: 'wrap' }}>
              {s.plazo
                ? <div className="countdown"><b className="num">{s.plazo}</b><small>días para actuar</small></div>
                : <div className="countdown"><small>Sin plazo: tendencia en seguimiento</small></div>}
              <span className="note mono">puntuación {scoreOf(s)}</span>
            </div>
            {s.actores && <div className="actors">{s.actores.map((a) => <span className="tag" key={a}>{a}</span>)}</div>}
            <div className="propose"><b>Siguiente paso propuesto</b>{s.soluciones[0].t}. <span style={{ color: 'var(--muted)' }}>{s.soluciones[0].d}</span></div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              <button className="btn sm" onClick={() => openDrawer({ kind: 'senal', id: s.id })}><Icon name="eye" /> Ver detalle</button>
              <button className="btn sm ghost" onClick={() => openChat(planPrompt(s.id, s.titulo))}><Icon name="spark" /> Plan con AVIA</button>
            </div>
          </article>
        ))}
      </div>
    </>
  );
}
