import { useRef, useState } from 'react';
import type { Evaluacion, TipoAnalisis } from '../types';
import { CATS, DEPS } from '../data/demo';
import { activeSignals, canDecide, useStore, type Analisis as AnalisisState } from '../store';
import { Icon } from '../components/Icon';
import { CatBars, Empty, NatPill } from '../components/common';
import { Markdown } from '../components/Markdown';
import { AN_TYPES, aviaConectado, analisisLocal, evaluarLocal, remoto } from '../services/avia';

type Resultado =
  | { kind: 'texto'; text: string; note?: string }
  | { kind: 'eval'; r: Evaluacion; note?: string };

const SCOPES: [AnalisisState['scope'], string][] = [['all', 'Todas'], ['oportunidad', 'Oportunidades'], ['riesgo', 'Riesgos']];

function EvalCard({ r }: { r: Evaluacion }) {
  const role = useStore((s) => s.role);
  const addEvaluatedSignal = useStore((s) => s.addEvaluatedSignal);
  const nat = ['oportunidad', 'riesgo', 'mixta'].includes(r.naturaleza) ? r.naturaleza : 'mixta';
  return (
    <>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
        <NatPill n={nat} />
        <span className="tag">{CATS[r.categoria as keyof typeof CATS] || r.categoria || '—'}</span>
        {(r.departamentos || []).map((d) => <span className="tag" key={d}>{d}</span>)}
      </div>
      <h3>{r.titulo || 'Noticia evaluada'}</h3>
      <div className="eval">
        <div><small>Relevancia</small><b>{r.relevancia ?? '—'}/10</b></div>
        <div><small>Novedad</small><b>{r.novedad ?? '—'}/10</b></div>
        <div><small>Confianza</small><b>{r.confianza != null ? Math.round(r.confianza * 100) + '%' : '—'}</b></div>
      </div>
      <p><b>Por qué importa:</b> {r.importancia}</p>
      {r.acciones?.length > 0 && <><p><b>Acciones:</b></p><ul>{r.acciones.map((x) => <li key={x}>{x}</li>)}</ul></>}
      {r.verificar && <p><b>Qué verificar:</b> {r.verificar}</p>}
      {canDecide(role) && <button className="btn sm gold" onClick={() => addEvaluatedSignal(r)}><Icon name="plus" /> Añadir como señal detectada</button>}
    </>
  );
}

export function Analisis() {
  const a = useStore((s) => s.analysis);
  const senales = useStore((s) => s.senales);
  const { setAnalysis, toast } = useStore.getState();
  const [res, setRes] = useState<Resultado | null>(null);
  const [mode, setMode] = useState('');
  const [busy, setBusy] = useState(false);
  const ctl = useRef<AbortController | null>(null);

  const conjunto = activeSignals(senales).filter((s) =>
    (a.scope === 'all' || (a.scope === 'oportunidad' ? s.naturaleza !== 'riesgo' : s.naturaleza !== 'oportunidad'))
    && (a.dep === 'all' || s.deps.includes(a.dep)));

  const local = (note?: string): Resultado =>
    a.type === 'noticia'
      ? { kind: 'eval', r: evaluarLocal(a.text), note: (note ? note + ' ' : '') + 'Análisis local por palabras clave (sin IA). Con AVIA la evaluación es mucho más fina.' }
      : { kind: 'texto', text: analisisLocal(a.type, a.dep, conjunto), note: (note ? note + ' ' : '') + 'Análisis local calculado con reglas (sin IA).' };

  async function run() {
    if (a.type === 'noticia' && !a.text.trim()) return toast('Pega primero el texto de una noticia.');
    if (a.type === 'libre' && !a.q.trim()) return toast('Escribe tu pregunta.');
    if (!aviaConectado) { setMode('análisis local'); setRes(local()); return; }
    setMode('AVIA (IA)'); setBusy(true); setRes({ kind: 'texto', text: 'Pensando…' });
    ctl.current = new AbortController();
    try {
      if (a.type === 'noticia') setRes({ kind: 'eval', r: await remoto.evaluar(a.text, ctl.current.signal) });
      else {
        const r = await remoto.analisis(a.type, a.dep === 'all' ? 'Todo Bolivia' : a.dep, conjunto, a.type === 'libre' ? a.q : undefined, ctl.current.signal);
        setRes({ kind: 'texto', text: r.texto });
      }
    } catch (e) {
      const cancel = e instanceof DOMException && e.name === 'AbortError';
      setMode('análisis local');
      setRes(cancel ? { kind: 'texto', text: 'Detenido.' } : local('AVIA no respondió; se muestra el análisis local.'));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Análisis</div>
          <h1>Pregunta a los <em>datos</em></h1>
          <p className="sub">Elige un tipo de análisis y el conjunto de señales. AVIA trabaja solo con la información del observatorio y cita los códigos de las señales que usa.</p>
        </div>
      </section>
      <div className="an-grid">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <section className="panel" style={{ '--w': 12 } as React.CSSProperties}>
            <div className="panel-h"><h2><Icon name="analisis" />1 · Tipo de análisis</h2></div>
            <div className="panel-b">
              <div className="an-types">
                {(Object.entries(AN_TYPES) as [TipoAnalisis, [string, string]][]).map(([k, [t, d]]) => (
                  <button key={k} className={`an-type ${a.type === k ? 'on' : ''}`} onClick={() => setAnalysis({ type: k })}><b>{t}</b><small>{d}</small></button>
                ))}
              </div>
            </div>
          </section>
          <section className="panel" style={{ '--w': 12 } as React.CSSProperties}>
            <div className="panel-h"><h2><Icon name="categorias" />2 · Con qué información</h2></div>
            <div className="panel-b" style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
              {a.type === 'noticia' ? (
                <div className="field">
                  <label htmlFor="anText">Texto de la noticia</label>
                  <textarea className="inp" id="anText" rows={6} placeholder="Pega aquí una noticia, un comunicado o un párrafo…" value={a.text} onChange={(e) => setAnalysis({ text: e.target.value })} />
                </div>
              ) : (
                <>
                  <div className="seg">
                    {SCOPES.map(([k, n]) => <button key={k} className={a.scope === k ? 'on' : ''} onClick={() => setAnalysis({ scope: k })}>{n}</button>)}
                  </div>
                  <div className="field">
                    <label htmlFor="anDep">Territorio</label>
                    <select id="anDep" value={a.dep} onChange={(e) => setAnalysis({ dep: e.target.value })}>
                      <option value="all">Todo Bolivia</option>
                      {DEPS.map((d) => <option key={d}>{d}</option>)}
                    </select>
                  </div>
                </>
              )}
              {a.type === 'libre' && (
                <div className="field">
                  <label htmlFor="anQ">Tu pregunta</label>
                  <textarea className="inp" id="anQ" rows={3} placeholder="Por ejemplo: ¿qué oportunidades hay para comunidades del altiplano?" value={a.q} onChange={(e) => setAnalysis({ q: e.target.value })} />
                </div>
              )}
              <p className="note" style={{ margin: 0 }}>{a.type === 'noticia' ? 'El texto no se guarda.' : `Se usarán ${conjunto.length} señales.`}</p>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <button className="btn gold" onClick={run} disabled={busy}><Icon name="spark" /> Analizar</button>
                {busy && <button className="btn ghost" onClick={() => ctl.current?.abort()}>Detener</button>}
              </div>
            </div>
          </section>
          <section className="panel" style={{ '--w': 12 } as React.CSSProperties}>
            <div className="panel-h"><h2><Icon name="categorias" />Distribución del conjunto</h2><span className="meta">calculado</span></div>
            <div className="panel-b"><CatBars list={conjunto} /></div>
          </section>
        </div>
        <section className="panel" style={{ '--w': 12 } as React.CSSProperties}>
          <div className="panel-h"><h2><Icon name="sintesis" />Resultado</h2><span className="meta">{mode}</span></div>
          <div className="panel-b">
            <div className="out" aria-live="polite">
              {!res && <Empty title="Aún no hay análisis">Elige un tipo y pulsa «Analizar». Si AVIA no está conectada, se usa un análisis local básico.</Empty>}
              {res?.note && <p className="note">{res.note}</p>}
              {res?.kind === 'texto' && <Markdown text={res.text} />}
              {res?.kind === 'eval' && <EvalCard r={res.r} />}
            </div>
          </div>
        </section>
      </div>
    </>
  );
}
