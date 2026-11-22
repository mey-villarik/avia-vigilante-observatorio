import { Fragment, useState } from 'react';
import type { Senal } from '../types';
import { CATS, DEPS } from '../data/demo';
import { COLUMNAS, DESTINO, columnaDe, motivoNoPasa, type Columna, type Destino } from '../services/senales';
import { canDecide, useStore, type SigFilter } from '../store';
import { ago, esReciente, plazoTexto, porRevisar } from '../lib/util';
import { AccionTag, CertezaTag, IntlTag, NatPill } from '../components/common';
import { porqueAvia, porqueFrase, puntuacionesDe } from '../lib/puntuaciones';
import { esConfirmada, esVerificada, motivoVerificada } from '../lib/verificada';
import { filtrarSenales } from '../lib/filtroSenales';

/** Probabilidad de que ocurra y por qué (solo señales confirmadas, db/generico/33_probabilidad_senales.sql) */
function Probabilidad({ s }: { s: Senal }) {
  if (s.estado !== 'confirmada') return null;
  const pun = puntuacionesDe(s);
  const p = pun.probabilidad;
  if (p.valor == null || !p.origen) return null;
  const pct = Math.round(p.valor * 100);
  return (
    <span className={`cprob ${p.origen}`} title={porqueAvia('probabilidad', pun)}>
      <span className="cprob-h">
        <b className="mono">{pct} %</b> probable
        <span className="cprob-o">{p.origen === 'avia' ? 'AVIA' : 'cálculo base'}</span>
      </span>
      <span className="cprob-bar" aria-hidden="true"><i style={{ width: `${pct}%` }} /></span>
      <span className="cprob-r">{p.avia ? porqueFrase(p.avia) : 'AVIA todavía no ha explicado el porqué.'}</span>
    </span>
  );
}

function Card({ s, draggable, onDragStart, onDragEnd }: { s: Senal; draggable: boolean; onDragStart: () => void; onDragEnd: () => void }) {
  const openDrawer = useStore((st) => st.openDrawer);
  return (
    <button className="card" draggable={draggable}
      onDragStart={(e) => { e.dataTransfer.effectAllowed = 'move'; try { e.dataTransfer.setData('text/plain', s.id); } catch { /* */ } onDragStart(); }}
      onDragEnd={onDragEnd}
      onClick={() => openDrawer({ kind: 'senal', id: s.id })}>
      <span className="cm">
        <NatPill n={s.naturaleza} /><AccionTag s={s} /><CertezaTag s={s} /><span className="tag">{CATS[s.categoria]}</span><IntlTag codigo={s.id} />
        {esConfirmada(s) && !s.escenario && (esVerificada(s)
          ? <span className="tag verificada" title={motivoVerificada(s)}>Verificada</span>
          : <span className="tag sin-verificar" title={motivoVerificada(s)}>Sin verificar</span>)}
        {s.escenario && <span className="tag escenario" title="Predicción: no es un hecho y no se publica">Escenario</span>}
        {s.revisionVencida && <span className="tag vencida" title="Pasó la hora que tiene el analista para revisarla y nadie decidió todavía. No es el plazo de la oportunidad.">Revisión atrasada</span>}
        {!s.revisionVencida && s.sla ? <span className="sla" title="Tiempo restante para revisar">⏱ {plazoTexto(s.sla)}</span> : null}
      </span>
      <span className="ct">{s.titulo}</span>
      <Probabilidad s={s} />
      <span className="cf">
        <span>{s.deps.slice(0, 2).join(', ')}{s.deps.length > 2 ? ' +' + (s.deps.length - 2) : ''}</span>
        <span className="mono">{s.id} · {ago(s.min)}</span>
      </span>
      <span className="cf tech"><span>Relevancia {s.rel}/10 · Novedad {s.nov}/10</span><span>{s.corr} fte.</span></span>
    </button>
  );
}

/** Dos flechas pequeñas entre columnas: todas adelante (→) y todas atrás (←) */
function Pase({ de, a, nombreDe, nombreA }: { de: Columna; a: Columna; nombreDe: string; nombreA: string }) {
  const senales = useStore((s) => s.senales);
  const role = useStore((s) => s.role);
  const f = useStore((s) => s.sigFilter);
  const passSignals = useStore((s) => s.passSignals);
  const [ocupado, setOcupado] = useState(false);
  const decide = canDecide(role);
  const visibles = filtrarSenales(senales, f);
  const lista = (col: Columna, to: Destino) => visibles.filter((s) => columnaDe(s.estado) === col && !motivoNoPasa(s, to));
  const adelante = lista(de, DESTINO[a]);
  const atras = lista(a, DESTINO[de]);
  const mover = async (ids: string[], to: Destino) => {
    if (to === 'confirmada' && a === 'publicadas'
        && !window.confirm(`¿Retirar ${ids.length} alerta(s) de la web pública? Los mensajes ya enviados a Telegram no se borran.`)) return;
    setOcupado(true);
    try { await passSignals(ids, to); } finally { setOcupado(false); }
  };
  return (
    <div className="pase">
      <button className="pase-b" disabled={!decide || ocupado || !adelante.length} aria-label={`Pasar todas de ${nombreDe} a ${nombreA}`}
        title={`Pasar todas (${adelante.length}) a ${nombreA}`} onClick={() => void mover(adelante.map((s) => s.id), DESTINO[a])}>
        <span aria-hidden="true">→</span><b>{adelante.length}</b>
      </button>
      <button className="pase-b" disabled={!decide || ocupado || !atras.length} aria-label={`Devolver todas de ${nombreA} a ${nombreDe}`}
        title={`Devolver todas (${atras.length}) a ${nombreDe}`} onClick={() => void mover(atras.map((s) => s.id), DESTINO[de])}>
        <span aria-hidden="true">←</span><b>{atras.length}</b>
      </button>
    </div>
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
  const decide = canDecide(role);

  const visibles = f.periodo === 'todo' ? senales : senales.filter((s) => esReciente(s));
  const ocultas = senales.length - visibles.length;
  const pendientes = senales.filter(porRevisar);
  const vencidas = pendientes.filter((s) => s.revisionVencida).length;
  const descartadas = visibles.filter((s) => s.estado === 'descartada').length;
  // la misma función que usa el chat para decir qué señales se ven (CP3)
  const list = filtrarSenales(senales, f);

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Tratamiento del conocimiento</div>
          <h1>De noticia suelta a <em>señal verificada</em></h1>
          <p className="sub">Una señal junta una o varias noticias sobre el mismo hecho. AVIA la detecta, la evalúa y la corrobora; las de fuente oficial las pasa sola a Confirmadas. Al publicarse pasa a ser una alerta. {decide ? 'Muévelas de una en una arrastrándolas, o todas a la vez con las flechas entre columnas (→ adelante, ← atrás).' : 'Estás en modo consulta.'}</p>
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
          const sig = i < COLUMNAS.length - 1 ? COLUMNAS[i + 1] : null;
          return (
            <Fragment key={k}>
              <div className={`stage ${over === k ? 'drop' : ''}`}
                onDragOver={(e) => { if (!dragId) return; e.preventDefault(); setOver(k); }}
                onDragLeave={() => setOver(null)}
                onDrop={(e) => { e.preventDefault(); if (dragId) void passSignals([dragId], DESTINO[k]); setDragId(null); setOver(null); }}>
                <div className="stage-h" title={ayuda}>{n}<b>{ss.length}</b></div>
                <div className="stage-b">
                  {ss.length
                    ? ss.map((s) => <Card key={s.id} s={s} draggable={decide} onDragStart={() => setDragId(s.id)} onDragEnd={() => { setDragId(null); setOver(null); }} />)
                    : <div className="note" style={{ padding: 8 }}>Vacía</div>}
                </div>
              </div>
              {sig && <Pase de={k} a={sig[0]} nombreDe={n} nombreA={sig[1]} />}
            </Fragment>
          );
        })}
      </div>
      {descartadas > 0 && <p className="note" style={{ marginTop: 10 }}>{descartadas} señal(es) descartadas no se muestran.</p>}
    </>
  );
}
