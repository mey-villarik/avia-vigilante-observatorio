// Contenido de cada panel del tablero Panorama. Para añadir un panel:
// 1) defínelo en PANELS (src/data/demo.ts), 2) añade su cuerpo en PANEL_BODY y su meta en PANEL_META.
import type { PanelId } from '../types';
import { DEPS, CATS, STL, catName } from '../data/demo';
import { activeSignals, canDecide, countStates, pendingDecision, useStore } from '../store';
import { scoreOf } from '../lib/util';
import { Icon } from '../components/Icon';
import { CatBars, Empty, EventsList, Histo, LineChart, NatPill, SigList, StPill } from '../components/common';

/** noticias leídas: la cifra del VPS, o el último punto de la serie */
function useNoticias(): number {
  const n = useStore((s) => s.noticiasRevisadas);
  const det = useStore((s) => s.serie.det);
  return n ?? det[det.length - 1] ?? 0;
}
const PRIO = { alta: 0, media: 1, baja: 2 } as const;

function Sintesis() {
  const a = activeSignals(useStore((s) => s.senales));
  const sintesis = useStore((s) => s.sintesis);
  const real = useStore((s) => s.origen === 'vps');
  const ventana = useStore((s) => s.ventanaHoras);
  const noticias = useNoticias();
  const opps = a.filter((s) => s.naturaleza === 'oportunidad');
  const riesgos = a.filter((s) => s.naturaleza === 'riesgo');
  const ver = a.filter((s) => ['confirmada', 'publicada'].includes(s.estado));
  const cortas = opps.filter((s) => s.plazo != null && s.plazo < 15).length;
  const altas = riesgos.filter((s) => s.prioridad === 'alta').length;
  const multi = ver.filter((s) => s.corr >= 2).length;
  return (
    <div className="synth">
      {real ? (
        <>
          {sintesis?.frase && <blockquote>{sintesis.frase}</blockquote>}
          <p>AVIA revisó <b>{noticias} noticias</b> y las juntó en <b>{a.length} señales</b>{ventana ? <> en las últimas <b>{ventana} h</b></> : null}. {sintesis?.texto}</p>
        </>
      ) : (
        <>
          <blockquote>Semana de oportunidades con un frente de lluvias que vigilar en Yungas.</blockquote>
          <p>AVIA juntó <b>{noticias} noticias</b> en <b>{a.length} señales</b>. Destacan el fondo de CAF para turismo comunitario (cierra en <b>12 días</b>) y la nueva frecuencia aérea a Santa Cruz. El riesgo principal es la alerta naranja en Yungas y Rurrenabaque, que se cruza con una restricción vial aún sin confirmar.</p>
        </>
      )}
      <div className="kpis">
        <div className="kpi"><small>Señales activas</small><b className="num">{a.length}</b><em>{ventana ? `en ${ventana} h` : 'sin descartadas'}</em></div>
        <div className="kpi"><small>Oportunidades</small><b className="num" style={{ color: 'var(--opp)' }}>{opps.length}</b><em>{cortas} con plazo &lt; 15 días</em></div>
        <div className="kpi"><small>Riesgos</small><b className="num" style={{ color: 'var(--risk)' }}>{riesgos.length}</b><em>{altas} de prioridad alta</em></div>
        <div className="kpi"><small>Verificadas</small><b className="num" style={{ color: 'var(--ok)' }}>{ver.length}</b><em>{multi} con 2 o más fuentes</em></div>
      </div>
    </div>
  );
}

function Ring({ v, col }: { v: number; col: string }) {
  const r = 46, C = 2 * Math.PI * r;
  return (
    <svg viewBox="0 0 118 118" role="img" aria-label={`${v} de 100`}>
      <circle cx={59} cy={59} r={r} fill="none" stroke="var(--surface2)" strokeWidth={9} />
      <circle cx={59} cy={59} r={r} fill="none" stroke={col} strokeWidth={9} strokeLinecap="round" strokeDasharray={`${(C * v) / 100} ${C}`} transform="rotate(-90 59 59)" />
      <text x={59} y={63} textAnchor="middle" fill="var(--ink)" style={{ fontFamily: 'var(--f-display)', fontSize: 30 }}>{v}</text>
      <text x={59} y={81} textAnchor="middle" fill="var(--faint)" style={{ fontFamily: 'var(--f-mono)', fontSize: 9 }}>DE 100</text>
    </svg>
  );
}

function Pulso() {
  const fuentes = useStore((s) => s.fuentes);
  const a = activeSignals(useStore((s) => s.senales));
  const c = countStates(fuentes);
  const att = Math.min(100, 38 + c.CRIT * 14 + c.WARN * 6 + a.filter((s) => s.naturaleza === 'riesgo' && s.prioridad === 'alta').length * 8);
  const op = Math.min(100, 30 + a.filter((s) => s.naturaleza !== 'riesgo').length * 7);
  const lvl = att > 70 ? 'Alto' : att > 50 ? 'Moderado' : 'Bajo';
  return (
    <>
      <div className="gauges">
        <div className="gauge"><Ring v={att} col="var(--risk)" /><span className="lab">Atención a riesgos</span><span className="lv">{lvl}</span></div>
        <div className="gauge"><Ring v={op} col="var(--opp)" /><span className="lab">Oportunidad</span><span className="lv">{op > 65 ? 'Favorable' : 'Estable'}</span></div>
      </div>
      <div className="scale">
        <div className="scale-bar"><i style={{ left: `${att}%` }} /></div>
        <div className="scale-l"><span>Normal</span><span>Vigilancia</span><span>Atención</span><span>Crítico</span></div>
      </div>
      <p className="note" style={{ margin: '10px 0 0' }}>Índices orientativos: suman estado de fuentes, prioridad y número de señales.</p>
    </>
  );
}

function FuentesMatrix() {
  const fuentes = useStore((s) => s.fuentes);
  const openDrawer = useStore((s) => s.openDrawer);
  return (
    <div className="src-matrix">
      {fuentes.map((s) => (
        <button key={s.id} className="src-chip" onClick={() => openDrawer({ kind: 'fuente', id: s.id })}>
          <div className="r"><StPill s={s.estado} /><span className="t mono tech">{s.lat ? Math.round(s.lat / 100) / 10 + ' s' : '—'}</span></div>
          <span className="n">{s.nombre}</span>
          <Histo hist={s.hist} />
          <span className="t">{catName(s.canal)}{s.freq ? ` · cada ${s.freq} min` : ''}</span>
        </button>
      ))}
    </div>
  );
}

function Cadena() {
  const a = useStore((s) => s.senales);
  const noticias = useNoticias();
  const steps: [string, number, string, string][] = [
    ['senales', noticias, 'Noticias leídas', 'var(--accent)'],
    ['temas', a.length, 'Señales agrupadas', 'var(--mix)'],
    ['shield', a.filter((s) => s.corr >= 2).length, 'Corroboradas', 'var(--ok)'],
    ['oportunidades', a.filter((s) => s.naturaleza !== 'riesgo').length, 'Valoradas para turismo', 'var(--opp)'],
    ['decision', a.filter((s) => s.estado === 'publicada').length, 'Acciones propuestas', 'var(--risk)'],
  ];
  return (
    <>
      <div className="chain">
        {steps.map(([i, n, l, c]) => (
          <div className="link" key={l}>
            <span className="ic" style={{ color: c, borderColor: c }}><Icon name={i} /></span>
            <b className="num">{n}</b><small>{l}</small>
          </div>
        ))}
      </div>
      <div className="chain-note">La máquina reúne y ordena. Una persona verifica. El observatorio propone y mide el resultado.</div>
    </>
  );
}

function Oportunidades() {
  const l = activeSignals(useStore((s) => s.senales)).filter((s) => s.naturaleza !== 'riesgo').sort((a, b) => scoreOf(b) - scoreOf(a)).slice(0, 5);
  return <SigList list={l} opp />;
}

function Riesgos() {
  const l = activeSignals(useStore((s) => s.senales)).filter((s) => s.naturaleza === 'riesgo').sort((a, b) => PRIO[a.prioridad] - PRIO[b.prioridad]).slice(0, 5);
  return <SigList list={l} opp={false} />;
}

const MAP_POS: Record<string, string> = {
  Pando: '1/1/2/3', 'La Paz': '2/1/4/2', Beni: '2/2/3/4', Cochabamba: '3/2/4/3', 'Santa Cruz': '3/3/5/5',
  Oruro: '4/1/5/2', Chuquisaca: '4/2/5/3', Potosí: '5/1/6/2', Tarija: '5/2/6/3',
};

function Mapa() {
  const a = activeSignals(useStore((s) => s.senales));
  const setSigFilter = useStore((s) => s.setSigFilter);
  const go = useStore((s) => s.go);
  return (
    <>
      <div className="bomap" role="list">
        {DEPS.map((d) => {
          const ss = a.filter((s) => s.deps.includes(d));
          const o = ss.filter((s) => s.naturaleza !== 'riesgo').length;
          const r = ss.filter((s) => s.naturaleza === 'riesgo').length;
          const tone = r > o ? 'var(--risk-soft)' : o ? 'var(--opp-soft)' : 'transparent';
          return (
            <button key={d} className="dep" role="listitem" style={{ gridArea: MAP_POS[d] }} aria-label={`${d}: ${o} oportunidades, ${r} riesgos`}
              onClick={() => { setSigFilter({ nat: 'all', dep: d, q: '' }); go('senales'); }}>
              <span className="heat" style={{ background: tone, opacity: Math.min(1, 0.4 + (o + r) * 0.2) }} />
              <span className="dn">{d}</span>
              <span className="dc"><span className="o">▲{o}</span><span className="r">●{r}</span></span>
            </button>
          );
        })}
      </div>
      <div className="map-legend">
        <span><i style={{ background: 'var(--opp)' }} />▲ oportunidades</span>
        <span><i style={{ background: 'var(--risk)' }} />● riesgos</span>
        <span>Toca un departamento para ver sus señales</span>
      </div>
    </>
  );
}

function Decision() {
  const l = pendingDecision(useStore((s) => s.senales));
  const role = useStore((s) => s.role);
  const openDrawer = useStore((s) => s.openDrawer);
  const moveSignal = useStore((s) => s.moveSignal);
  if (!l.length) return <Empty title="Nada pendiente">Todas las señales tienen decisión.</Empty>;
  return (
    <div className="dec">
      {l.map((s) => (
        <div className="dec-item" key={s.id}>
          <div className="row">
            <NatPill n={s.naturaleza} /><span className="tag">{STL[s.estado]}</span>
            {s.sla ? <span className="sla" title="Tiempo restante para revisar">⏱ {s.sla} min</span> : <span className="tag">{CATS[s.categoria]}</span>}
          </div>
          <button className="tt" style={{ background: 'none', border: 'none', padding: 0, textAlign: 'left' }} onClick={() => openDrawer({ kind: 'senal', id: s.id })}>{s.titulo}</button>
          <div className="row">
            <span className="note">{s.corr} fuente(s) · confianza {Math.round(s.conf * 100)}%</span>
            {canDecide(role)
              ? <span className="dec-actions">
                <button className="btn sm" onClick={() => moveSignal(s.id, 'confirmada')}><Icon name="check" /> Confirmar</button>
                <button className="btn sm ghost" onClick={() => moveSignal(s.id, 'descartada')}>Descartar</button>
              </span>
              : <span className="note">Solo lectura</span>}
          </div>
        </div>
      ))}
    </div>
  );
}

function Actividad() {
  const ev = useStore((s) => s.eventos);
  return <EventsList list={ev.slice(0, 7)} />;
}

function Temas() {
  const temas = useStore((s) => s.temas);
  if (!temas.length) return <Empty title="Sin temas">AVIA todavía no agrupó temas.</Empty>;
  const max = Math.max(...temas.map((t) => t.n));
  return (
    <>
      <div className="topics">
        {temas.map((t) => (
          <div className="topic" key={t.t}>
            <span className="tn">{t.t}</span>
            <span className="tv">{t.n} <span className={t.d > 0 ? 'up' : t.d < 0 ? 'down' : ''}>{t.d > 0 ? '▲' + t.d : t.d < 0 ? '▼' + -t.d : '='}</span></span>
            <span className="tb"><i style={{ width: `${(t.n / max) * 100}%`, background: `var(--${t.nat === 'oportunidad' ? 'opp' : t.nat === 'riesgo' ? 'risk' : 'mix'})` }} /></span>
          </div>
        ))}
      </div>
      <p className="note" style={{ margin: '10px 0 0' }}>Agrupación por similitud de contenido (embeddings) en ventana de 7 días.</p>
    </>
  );
}

function Categorias() {
  return <CatBars list={activeSignals(useStore((s) => s.senales))} />;
}

export const PANEL_BODY: Record<PanelId, () => JSX.Element> = {
  sintesis: Sintesis, pulso: Pulso, fuentes: FuentesMatrix, cadena: Cadena, oportunidades: Oportunidades,
  riesgos: Riesgos, mapa: Mapa, evolucion: LineChart, decision: Decision, actividad: Actividad, temas: Temas, categorias: Categorias,
};

export function usePanelMeta(id: PanelId): string {
  const nFuentes = useStore((s) => s.fuentes.length);
  const real = useStore((s) => s.origen === 'vps');
  const nPend = pendingDecision(useStore((s) => s.senales)).length;
  const meta: Record<PanelId, string> = {
    sintesis: 'Borrador de AVIA', fuentes: `${nFuentes} fuentes`, oportunidades: 'por puntuación', riesgos: 'vigentes',
    mapa: 'esquema', evolucion: real ? 'VPS' : 'demo', decision: `${nPend} pendientes`, actividad: real ? 'VPS' : 'en vivo', temas: real ? 'VPS' : '7 días',
    cadena: 'hoy', pulso: 'índice', categorias: 'activas',
  };
  return meta[id];
}
