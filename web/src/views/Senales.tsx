import { Fragment, useState } from 'react';
import type { Senal } from '../types';
import { CATS, DEPS } from '../data/demo';
import { COLUMNAS, columnaDe, motivoNoPasa, type Columna } from '../services/senales';
import { canDecide, useStore, type SigFilter } from '../store';
import { ago, esReciente, norm, plazoTexto, porRevisar } from '../lib/util';
import { CertezaTag, NatPill } from '../components/common';

function Card({ s, draggable, onDragStart, onDragEnd }: { s: Senal; draggable: boolean; onDragStart: () => void; onDragEnd: () => void }) {
  const openDrawer = useStore((st) => st.openDrawer);
  return (
    <button className="card" draggable={draggable}
      onDragStart={(e) => { e.dataTransfer.effectAllowed = 'move'; try { e.dataTransfer.setData('text/plain', s.id); } catch { /* */ } onDragStart(); }}
      onDragEnd={onDragEnd}
      onClick={() => openDrawer({ kind: 'senal', id: s.id })}>
      <span className="cm">
        <NatPill n={s.naturaleza} /><CertezaTag s={s} /><span className="tag">{CATS[s.categoria]}</span>
        {porRevisar(s) && <span className="tag por-aprobar" title="Riesgo o fuente no oficial: una persona la aprueba antes de publicarla. No pasa en bloque.">Por aprobar</span>}
        {s.escenario && <span className="tag escenario" title="Predicción: no es un hecho y no se publica">Escenario</span>}
        {s.revisionVencida && <span className="tag vencida" title="Pasó la hora que tiene el analista para revisarla y nadie decidió todavía. No es el plazo de la oportunidad.">Revisión atrasada</span>}
        {!s.revisionVencida && s.sla ? <span className="sla" title="Tiempo restante para revisar">⏱ {plazoTexto(s.sla)}</span> : null}
      </span>
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
  const { setSigFilter, passSignals } = useStore.getState();
  const [dragId, setDragId] = useState<string | null>(null);
  const [over, setOver] = useState<Columna | null>(null);
  const [pasando, setPasando] = useState<Columna | null>(null);
  const decide = canDecide(role);

  const visibles = f.periodo === 'todo' ? senales : senales.filter((s) => esReciente(s));
  const ocultas = senales.length - visibles.length;
  const pendientes = senales.filter(porRevisar);
  const vencidas = pendientes.filter((s) => s.revisionVencida).length;
  const descartadas = visibles.filter((s) => s.estado === 'descartada').length;
  const list = visibles.filter((s) => (!f.revisar || porRevisar(s))
    && (f.nat === 'all' || s.naturaleza === f.nat)
    && (f.dep === 'all' || s.deps.includes(f.dep))
    && (!f.q || norm(`${s.titulo} ${s.resumen} ${s.destinos.join(' ')} ${s.id}`).includes(norm(f.q))));

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Tratamiento del conocimiento</div>
          <h1>De noticia suelta a <em>señal verificada</em></h1>
          <p className="sub">Una señal junta una o varias noticias sobre el mismo hecho. AVIA la detecta, la evalúa y la corrobora; tú solo la confirmas y la publicas, y al publicarse pasa a ser una alerta. {decide ? 'Usa «Pasar todas» entre columnas para moverlas de una vez. Las que dicen «Por aprobar» (riesgos o fuentes no oficiales) se aprueban una por una desde su ficha.' : 'Estás en modo consulta.'}</p>
          <p className="sub"><a href="publico.html" target="_blank" rel="noopener noreferrer">Ver la web pública</a>: ahí aparecen como alertas las señales en «Publicada».</p>
        </div>
      </section>
      {pendientes.length > 0 && (
        <div className={`revisar-aviso ${vencidas ? 'vencida' : ''}`}>
          <span>
            <b>{pendientes.length} señal(es) esperan aprobación</b>
            {vencidas ? ` · ${vencidas} con el plazo vencido. No se publican hasta que alguien las apruebe.` : ' · Tienes 1 hora para cada una; nada se publica sin aprobación.'}
          </span>
          <button className={`btn ${f.revisar ? '' : 'gold'}`} onClick={() => setSigFilter({ revisar: !f.revisar })}>
            {f.revisar ? 'Ver todas' : 'Ver solo por revisar'}
          </button>
        </div>
      )}
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
        <label className="sr" htmlFor="sigPer">Periodo</label>
        <select id="sigPer" style={{ width: 'auto' }} value={f.periodo} onChange={(e) => setSigFilter({ periodo: e.target.value as SigFilter['periodo'] })}>
          <option value="recientes">Últimos 7 días y plazos abiertos</option>
          <option value="todo">Todo lo guardado (6 meses)</option>
        </select>
      </div>
      {f.periodo === 'recientes' && ocultas > 0 && (
        <p className="note" style={{ margin: '-6px 0 12px' }}>
          Hay {ocultas} señal(es) más antiguas guardadas. <button className="linklike" onClick={() => setSigFilter({ periodo: 'todo' })}>Ver todo lo guardado</button>
        </p>
      )}
      <div className="pipe tres">
        {COLUMNAS.map(([k, n, ayuda], i) => {
          const ss = list.filter((s) => columnaDe(s.estado) === k);
          if (f.revisar) ss.sort((a, b) => (a.revisionVencida ? -1 : a.sla ?? 1e9) - (b.revisionVencida ? -1 : b.sla ?? 1e9));
          const destino = k === 'confirmadas' ? 'confirmada' : k === 'publicadas' ? 'publicada' : null;
          const sig = i < COLUMNAS.length - 1 ? COLUMNAS[i + 1] : null;
          const aSig = k === 'detectadas' ? 'confirmada' : 'publicada';
          const aptas = sig ? ss.filter((s) => !motivoNoPasa(s, aSig)) : [];
          const quedan = ss.length - aptas.length;
          return (
            <Fragment key={k}>
              <div className={`stage ${over === k ? 'drop' : ''}`}
                onDragOver={(e) => { if (!dragId || !destino) return; e.preventDefault(); setOver(k); }}
                onDragLeave={() => setOver(null)}
                onDrop={(e) => { e.preventDefault(); if (dragId && destino) void passSignals([dragId], destino); setDragId(null); setOver(null); }}>
                <div className="stage-h" title={ayuda}>{n}<b>{ss.length}</b></div>
                <div className="stage-b">
                  {ss.length
                    ? ss.map((s) => <Card key={s.id} s={s} draggable={decide && k !== 'publicadas'} onDragStart={() => setDragId(s.id)} onDragEnd={() => { setDragId(null); setOver(null); }} />)
                    : <div className="note" style={{ padding: 8 }}>Vacía</div>}
                </div>
              </div>
              {sig && (
                <div className="pase">
                  <button className="btn gold" disabled={!decide || !aptas.length || pasando !== null}
                    title={!decide ? 'Estás en modo consulta' : quedan ? `${quedan} se quedan: ${k === 'detectadas' ? 'esperan aprobación una por una' : 'escenarios, no se publican'}` : `Pasar las ${aptas.length} a ${sig[1]}`}
                    onClick={async () => { setPasando(k); try { await passSignals(aptas.map((s) => s.id), aSig); } finally { setPasando(null); } }}>
                    <span className="pase-t">{pasando === k ? 'Pasando…' : `Pasar todas (${aptas.length})`}</span>
                    <span className="pase-f" aria-hidden="true">→</span>
                  </button>
                  {quedan > 0 && <span className="pase-n">{quedan} se quedan</span>}
                </div>
              )}
            </Fragment>
          );
        })}
      </div>
      {descartadas > 0 && <p className="note" style={{ marginTop: 10 }}>{descartadas} señal(es) descartadas no se muestran.</p>}
    </>
  );
}
