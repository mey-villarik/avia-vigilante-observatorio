import { useState } from 'react';
import type { EstadoFuente } from '../types';
import { CATS, STATE_TXT, catName } from '../data/demo';
import { METODO_TXT } from '../services/fuentes';
import { conProblema, countStates, isAdmin, useStore } from '../store';
import { ago, clock, norm } from '../lib/util';
import { Icon } from '../components/Icon';
import { Histo, StPill } from '../components/common';

const ESTADOS: EstadoFuente[] = ['OK', 'WARN', 'CRIT', 'UNKNOWN', 'MANT'];

const QUIEN: Record<string, string> = { avia: 'AVIA', sincronizacion: 'una búsqueda', 'migracion-15': 'una propuesta antigua' };

/** Fuentes que AVIA vio y no están en el catálogo. No se vigilan hasta que un administrador las aprueba. */
function Candidatas() {
  const role = useStore((s) => s.role);
  const todas = useStore((s) => s.candidatas);
  const decideCandidate = useStore((s) => s.decideCandidate);
  const [canal, setCanal] = useState<Record<number, string>>({});
  const [ocupada, setOcupada] = useState<number | null>(null);
  const pendientes = todas.filter((c) => c.estado === 'pendiente');
  const decididas = todas.filter((c) => c.estado !== 'pendiente').slice(0, 5);
  if (!todas.length) return null;
  const admin = isAdmin(role);
  const decidir = async (id: number, aprobar: boolean) => {
    setOcupada(id);
    await decideCandidate(id, aprobar, { categoria: canal[id] ?? 'turismo' });
    setOcupada(null);
  };

  return (
    <section className="propuestas candidatas" aria-label="Fuentes candidatas">
      <h2>{pendientes.length
        ? `${pendientes.length === 1 ? '1 fuente nueva espera' : `${pendientes.length} fuentes nuevas esperan`} tu decisión`
        : 'Fuentes candidatas'}</h2>
      <p className="note">{admin
        ? 'AVIA solo vigila las fuentes del catálogo. Estas las vio en una noticia o una búsqueda: si apruebas una, entra en el catálogo y se lee desde la próxima ronda.'
        : 'AVIA las vio en una noticia o una búsqueda. No se vigilan hasta que un administrador las aprueba.'}</p>
      {pendientes.length > 0 && (
        <ul>
          {pendientes.map((c) => (
            <li key={c.id}>
              <div className="cand-txt">
                <b>{c.nombre}</b>
                <div className="srcurl">{/^https?:\/\//.test(c.url) ? <a href={c.url} target="_blank" rel="noopener noreferrer">{c.url}</a> : c.url}</div>
                {c.motivo && <div className="note">Motivo: {c.motivo}</div>}
                <div className="note">
                  La propuso {QUIEN[c.propuesta_por] ?? c.propuesta_por} {ago(Math.max(0, (Date.now() - Date.parse(c.propuesta_en)) / 60000))}
                  {c.veces > 1 && <> · vista {c.veces} veces</>}
                </div>
                {c.evidencia.length > 0
                  ? (
                    <div className="note">Visto en: {c.evidencia.map((e, i) => (
                      <span key={e.id}>{i > 0 && ' · '}{/^https?:\/\//.test(e.url)
                        ? <a href={e.url} target="_blank" rel="noopener noreferrer">{e.titulo || e.url}</a>
                        : (e.titulo || 'noticia sin título')}</span>
                    ))}</div>
                  )
                  : <div className="note">Sin noticia de respaldo: revisa la dirección antes de aprobarla.</div>}
              </div>
              {admin && (
                <div className="acciones">
                  <label className="sr" htmlFor={`cand-c-${c.id}`}>Canal de {c.nombre}</label>
                  <select id={`cand-c-${c.id}`} value={canal[c.id] ?? 'turismo'} onChange={(e) => setCanal({ ...canal, [c.id]: e.target.value })}>
                    {Object.entries(CATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                  </select>
                  <button className="btn primary" disabled={ocupada === c.id} onClick={() => void decidir(c.id, true)}>Aprobar</button>
                  <button className="btn ghost" disabled={ocupada === c.id} onClick={() => void decidir(c.id, false)}>Rechazar</button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      {decididas.length > 0 && (
        <p className="note">Últimas decisiones: {decididas.map((c, i) => (
          <span key={c.id}>{i > 0 && ' · '}{c.nombre} ({c.estado === 'aprobada' ? `aprobada${c.codigo ? `, ${c.codigo}` : ''}` : 'rechazada'})</span>
        ))}</p>
      )}
    </section>
  );
}

export function Fuentes() {
  const fuentes = useStore((s) => s.fuentes);
  const role = useStore((s) => s.role);
  const srcFilter = useStore((s) => s.srcFilter);
  const srcQ = useStore((s) => s.srcQ);
  const real = useStore((s) => s.origen === 'vps');
  const todasPropuestas = useStore((s) => s.propuestas);
  const propuestas = todasPropuestas.filter((p) => p.estado === 'pendiente');
  const { setSrcFilter, setSrcQ, openDrawer, checkAll, decideProposal } = useStore.getState();
  const c = countStates(fuentes);

  const list = srcFilter === 'problemas'
    ? fuentes.filter(conProblema)
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
      <Candidatas />
      {propuestas.length > 0 && (
        <section className="propuestas" aria-label="Propuestas de AVIA">
          <h2>AVIA propone cambiar cómo se leen {propuestas.length === 1 ? '1 fuente' : `${propuestas.length} fuentes`}</h2>
          <p className="note">{isAdmin(role) ? 'No cambia nada hasta que lo apruebes. Apify cuesta dinero y tiene un tope al mes.' : 'Las aprueba o rechaza un administrador.'}</p>
          <ul>
            {propuestas.map((p) => (
              <li key={p.id}>
                <div>
                  <b>{p.nombre}</b>: de {METODO_TXT[p.metodo_actual] ?? p.metodo_actual} a <b>{METODO_TXT[p.metodo_propuesto] ?? p.metodo_propuesto}</b>
                  {typeof p.config?.apify_actor === 'string' && <span className="note"> · actor {p.config.apify_actor}</span>}
                  <div className="note">Motivo: {p.motivo} · {ago(Math.max(0, (Date.now() - Date.parse(p.propuesta_en)) / 60000))}</div>
                </div>
                {isAdmin(role) && (
                  <div className="acciones">
                    <button className="btn primary" onClick={() => decideProposal(p.id, true)}>Aprobar</button>
                    <button className="btn ghost" onClick={() => decideProposal(p.id, false)}>Rechazar</button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
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
                <td><StPill s={s.estado} />{s.ack && <div className="ack">✓ reconocido{s.bd?.reconocida_por ? ` por ${s.bd.reconocida_por}` : ''}</div>}{s.flap && <div className="flap">⇅ intermitente</div>}{s.sinLeer && <div className="flap">⚠ AVIA no la lee</div>}{s.bd && !s.sinLeer && s.estado === 'UNKNOWN' && !s.bd.ultima_consulta_en && s.bd.activa && <div className="ack">nueva · en espera</div>}</td>
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
        ? 'Estados de la última lectura de cada fuente (recolector del VPS o ronda de AVIA). La web los vuelve a leer cada 5 minutos.'
        : 'Los estados son de ejemplo. Las URL vienen del catálogo de fuentes; las marcadas «no abierta» o «por confirmar» hay que revisarlas a mano antes de activarlas.'}</p>
    </>
  );
}
