// Piezas pequeñas reutilizadas en varias vistas.
import type { EstadoFuente, Evento, Naturaleza, Senal } from '../types';
import { CATS, STATE_TXT, STL } from '../data/demo';
import { clock, scoreOf } from '../lib/util';
import { useStore } from '../store';

const NAT_TXT: Record<Naturaleza, string> = { oportunidad: 'Oportunidad', riesgo: 'Riesgo', mixta: 'Mixta' };

export const NatPill = ({ n }: { n: Naturaleza }) => (
  <span className={`pill nat-${n}`}><span className="d" />{NAT_TXT[n]}</span>
);

export const StPill = ({ s, title }: { s: EstadoFuente; title?: string }) => (
  <span className={`pill st-${s}`} title={title}><span className="d" />{STATE_TXT[s]}</span>
);

export const Histo = ({ hist, height, titles }: { hist: EstadoFuente[]; height?: number; titles?: boolean }) => (
  <div className="histo" style={height ? { height } : undefined} aria-label="Últimas 24 comprobaciones">
    {hist.map((x, i) => <i key={i} className={`h-${x}`} title={titles ? STATE_TXT[x] : undefined} />)}
  </div>
);

export const Empty = ({ title, children }: { title: string; children: React.ReactNode }) => (
  <div className="empty"><b>{title}</b>{children}</div>
);

export function SigList({ list, opp }: { list: Senal[]; opp: boolean }) {
  const openDrawer = useStore((s) => s.openDrawer);
  if (!list.length) return <Empty title="Sin señales">No hay elementos para mostrar.</Empty>;
  return (
    <div className="sig-list">
      {list.map((s) => (
        <button key={s.id} className="sig" onClick={() => openDrawer({ kind: 'senal', id: s.id })}>
          <span className={`bar ${opp ? 'oportunidad' : s.prioridad}`} />
          <span style={{ minWidth: 0 }}>
            <span className="sig-t" style={{ display: 'block' }}>{s.titulo}</span>
            <span className="sig-m"><NatPill n={s.naturaleza} /><span>{s.deps.join(', ')}</span><span className="tech">· {s.corr} fuente(s)</span></span>
          </span>
          <span className="sig-r">
            {opp && s.plazo
              ? <span className="score" style={{ color: 'var(--opp)' }}>{s.plazo} días</span>
              : <span className="tag">{STL[s.estado]}</span>}
            <span className="tech">puntuación <span className="score">{scoreOf(s)}</span></span>
          </span>
        </button>
      ))}
    </div>
  );
}

export function CatBars({ list }: { list: Senal[] }) {
  const rows = (Object.keys(CATS) as (keyof typeof CATS)[]).map((k) => {
    const ss = list.filter((s) => s.categoria === k);
    return {
      k,
      o: ss.filter((s) => s.naturaleza === 'oportunidad').length,
      r: ss.filter((s) => s.naturaleza === 'riesgo').length,
      m: ss.filter((s) => s.naturaleza === 'mixta').length,
    };
  }).filter((r) => r.o + r.r + r.m);
  const max = Math.max(1, ...rows.map((r) => r.o + r.r + r.m));
  return (
    <>
      <div className="chart-legend">
        <span><i style={{ background: 'var(--opp)' }} />Oportunidad</span>
        <span><i style={{ background: 'var(--risk)' }} />Riesgo</span>
        <span><i style={{ background: 'var(--mix)' }} />Mixta</span>
      </div>
      <div className="hbars">
        {rows.map((r) => (
          <div className="hb" key={r.k}>
            <span>{CATS[r.k]}</span>
            <span className="track" role="img" aria-label={`${CATS[r.k]}: ${r.o} oportunidades, ${r.r} riesgos, ${r.m} mixtas`} style={{ width: `${((r.o + r.r + r.m) / max) * 100}%` }}>
              <i style={{ flex: r.o, background: 'var(--opp)' }} />
              <i style={{ flex: r.r, background: 'var(--risk)' }} />
              <i style={{ flex: r.m, background: 'var(--mix)' }} />
            </span>
            <span className="v">{r.o + r.r + r.m}</span>
          </div>
        ))}
      </div>
    </>
  );
}

export function LineChart() {
  const S = useStore((s) => s.serie);
  const real = useStore((s) => s.origen === 'vps');
  const top = Math.max(1, ...S.det, ...S.opp, ...S.risk);
  const paso = Math.ceil(top / 3 / 5) * 5 || 5;
  const max = paso * 3;
  const W = 640, H = 200, L = 30, R = 12, T = 12, B = 24;
  const x = (i: number) => L + ((W - L - R) * i) / (S.labels.length - 1);
  const y = (v: number) => T + (1 - v / max) * (H - T - B);
  const path = (a: number[]) => a.map((v, i) => (i ? 'L' : 'M') + x(i).toFixed(1) + ',' + y(v).toFixed(1)).join(' ');
  const area = path(S.det) + ` L${x(S.det.length - 1)},${H - B} L${L},${H - B} Z`;
  const last = (a: number[]) => a[a.length - 1];
  const end = (a: number[], c: string) => <circle cx={x(a.length - 1)} cy={y(last(a))} r={4} fill={c} stroke="var(--surface)" strokeWidth={2} />;
  return (
    <div className="chart">
      <div className="chart-legend">
        <span><i style={{ background: 'var(--accent)' }} />Noticias detectadas ({last(S.det)})</span>
        <span><i style={{ background: 'var(--opp)' }} />Oportunidades ({last(S.opp)})</span>
        <span><i style={{ background: 'var(--risk)' }} />Riesgos ({last(S.risk)})</span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={real ? 'Evolución por día, datos del VPS' : 'Evolución de 14 días, datos de ejemplo'}>
        <defs>
          <linearGradient id="gA" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="var(--accent)" stopOpacity=".22" />
            <stop offset="1" stopColor="var(--accent)" stopOpacity="0" />
          </linearGradient>
        </defs>
        {[0, paso, paso * 2, max].map((v) => (
          <g key={v}>
            <line x1={L} x2={W - R} y1={y(v)} y2={y(v)} stroke="var(--line)" strokeDasharray="3 5" />
            <text x={L - 6} y={y(v) + 3} textAnchor="end">{v}</text>
          </g>
        ))}
        <path d={area} fill="url(#gA)" />
        <path d={path(S.det)} fill="none" stroke="var(--accent)" strokeWidth={2.2} strokeLinejoin="round" />
        <path d={path(S.opp)} fill="none" stroke="var(--opp)" strokeWidth={2.2} strokeLinejoin="round" />
        <path d={path(S.risk)} fill="none" stroke="var(--risk)" strokeWidth={2} strokeLinejoin="round" strokeDasharray="5 4" />
        {end(S.det, 'var(--accent)')}{end(S.opp, 'var(--opp)')}{end(S.risk, 'var(--risk)')}
        {S.labels.map((l, i) => (i % 2 === 0 || i === S.labels.length - 1
          ? <text key={i} x={x(i)} y={H - 6} textAnchor="middle">{l}</text> : null))}
      </svg>
      <div className="chart-note">{real ? 'Días del mes · datos publicados por AVIA en el VPS.' : 'Octubre–noviembre 2026 · serie inventada para la demostración.'}</div>
    </div>
  );
}

export function EventsList({ list }: { list: Evento[] }) {
  return (
    <div className="events">
      {list.map((e, i) => {
        const k = e.k;
        const badge = k in STATE_TXT
          ? <span className={`pill st-${k}`} style={{ fontSize: 10.5 }}>{STATE_TXT[k as EstadoFuente]}</span>
          : <span className="pill nat-oportunidad" style={{ fontSize: 10.5 }}>{k === 'check' ? 'DECISIÓN' : 'AVIA'}</span>;
        return (
          <div className="ev" key={i + e.w}>
            {badge}
            <span className="what">{e.w}<small>{e.d}</small></span>
            <time>{clock(e.t)}</time>
          </div>
        );
      })}
    </div>
  );
}

export function Foot() {
  const real = useStore((s) => s.origen === 'vps');
  const enBd = useStore((s) => s.enBd);
  return (
    <footer className="foot">
      <span>ORBITA Vigilante · {real ? 'datos del VPS' : 'prueba de concepto'}</span>
      <span>{real ? (enBd ? 'Señales publicadas por AVIA · las etapas de las señales se guardan en la base de datos' : 'Señales publicadas por AVIA · las decisiones aún no se guardan en el servidor') : 'Datos de ejemplo inventados · no usar para decisiones reales'}</span>
    </footer>
  );
}
