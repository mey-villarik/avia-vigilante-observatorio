import type { EstadoFuente } from '../types';
import { STATE_TXT, catName } from '../data/demo';
import { countStates, isAdmin, useStore } from '../store';
import { ago, clock, norm } from '../lib/util';
import { Icon } from '../components/Icon';
import { Histo, StPill } from '../components/common';

const ESTADOS: EstadoFuente[] = ['OK', 'WARN', 'CRIT', 'UNKNOWN', 'MANT'];

export function Fuentes() {
  const fuentes = useStore((s) => s.fuentes);
  const role = useStore((s) => s.role);
  const srcFilter = useStore((s) => s.srcFilter);
  const srcQ = useStore((s) => s.srcQ);
  const real = useStore((s) => s.origen === 'vps');
  const { setSrcFilter, setSrcQ, openDrawer, checkAll } = useStore.getState();
  const c = countStates(fuentes);

  const list = srcFilter === 'problemas'
    ? fuentes.filter((s) => ['WARN', 'CRIT', 'UNKNOWN'].includes(s.estado))
    : fuentes.filter((s) => (srcFilter === 'all' || s.estado === srcFilter)
      && (!srcQ || norm(`${s.nombre} ${s.canal} ${s.url}`).includes(norm(srcQ))));

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Supervisión de fuentes</div>
          <h1>Cada fuente, <em>comprobada</em> sin descanso</h1>
          <p className="sub">Como un sistema de supervisión: cada fuente tiene comprobaciones (disponibilidad, frescura, estructura y novedad), un estado y su historial. Si una falla, el Vigilante lo dice antes de que falte información.</p>
        </div>
        <div className="head-actions">
          {isAdmin(role) && <button className="btn" onClick={() => openDrawer({ kind: 'nueva-fuente' })}><Icon name="plus" /> Añadir fuente</button>}
          <button className="btn primary" onClick={checkAll}><Icon name="refresh" /> {real ? 'Recargar datos' : 'Comprobar todas'}</button>
        </div>
      </section>
      <div className="nag-summary">
        <button className={`nag-box st-total ${srcFilter === 'all' && !srcQ ? 'on' : ''}`} onClick={() => { setSrcFilter('all'); setSrcQ(''); }}>
          <b className="num">{fuentes.length}</b><small>Total</small>
        </button>
        {ESTADOS.map((k) => (
          <button key={k} className={`nag-box st-${k} ${srcFilter === k ? 'on' : ''}`} onClick={() => setSrcFilter(srcFilter === k ? 'all' : k)}>
            <b className="num">{c[k]}</b><small>{STATE_TXT[k]}</small>
          </button>
        ))}
      </div>
      <div className="toolbar">
        <label className="sr" htmlFor="srcQ">Filtrar fuentes</label>
        <input className="inp" id="srcQ" placeholder="Filtrar por nombre, canal o URL" value={srcQ} onChange={(e) => setSrcQ(e.target.value)} />
        <div className="seg">
          <button className={srcFilter === 'all' ? 'on' : ''} onClick={() => setSrcFilter('all')}>Todas</button>
          <button className={srcFilter === 'problemas' ? 'on' : ''} onClick={() => setSrcFilter('problemas')}>Con problemas</button>
        </div>
      </div>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>Estado</th><th>Fuente</th><th>Canal</th><th>Última comprobación</th><th className="tech">En este estado</th>
              <th>{real ? 'Historial' : 'Últimas 24'}</th><th className="tech">Información del check</th><th className="tech">{real ? 'Elementos nuevos' : 'Señales 24 h'}</th>
            </tr>
          </thead>
          <tbody>
            {list.map((s) => (
              <tr key={s.id} tabIndex={0}
                onClick={() => openDrawer({ kind: 'fuente', id: s.id })}
                onKeyDown={(e) => e.key === 'Enter' && openDrawer({ kind: 'fuente', id: s.id })}>
                <td><StPill s={s.estado} />{s.ack && <div className="ack">✓ reconocido</div>}{s.flap && <div className="flap">⇅ intermitente</div>}</td>
                <td><div className="srcname">{s.nombre}</div><div className="srcurl">{s.url}</div></td>
                <td>{catName(s.canal)}<div className="note">{s.tipo}</div></td>
                <td className="mono">{real && s.last == null ? <span className="note">Aún no</span> : clock(-(s.last ?? Math.floor((s.freq ?? 30) * 0.4)))}{s.freq ? <div className="note">cada {s.freq} min</div> : null}</td>
                <td className="mono tech">{s.desde != null ? ago(s.desde).replace('hace ', '') : '—'}</td>
                <td style={{ minWidth: 130 }}><Histo hist={s.hist} /></td>
                <td className="tech"><div className="info">{s.info}</div></td>
                <td className="mono tech">{s.items}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="note">{real
        ? 'Estados publicados por AVIA en el VPS. La web los vuelve a leer cada 5 minutos.'
        : 'Los estados son de ejemplo. Las URL vienen del catálogo de fuentes; las marcadas «no abierta» o «por confirmar» hay que revisarlas a mano antes de activarlas.'}</p>
    </>
  );
}
