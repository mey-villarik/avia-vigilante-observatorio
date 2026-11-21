// Contenido de cada panel del tablero Panorama. Para añadir un panel:
// 1) defínelo en PANELS (src/data/demo.ts), 2) añade su cuerpo en PANEL_BODY y su meta en PANEL_META.
import { useEffect, useMemo, useState } from 'react';
import type { PanelId } from '../types';
import { DEPS, CATS, STL, catName } from '../data/demo';
import { activeSignals, canDecide, pendingDecision, useContadores, useSintesisDia, useStore } from '../store';
import { CERTEZAS } from '../lib/certeza';
import type { ItemSintesis } from '../types';
import { desgloseVerificadas, horaBolivia, textoFuentes, textoSinVerificar } from '../lib/contadores';
import { DEF_SIN_VERIFICAR, DEF_VERIFICADA } from '../lib/verificada';
import { puntuacionesDe } from '../lib/puntuaciones';
import { esReciente, plazoTexto, scoreOf } from '../lib/util';
import { useEventos } from '../services/eventos';
import { useCambios } from '../services/cambios';
import { resumenRegion } from '../lib/regiones';
import { MapaBolivia } from '../views/Mapa';
import { calcularPulso, posicionVigilancia } from '../lib/pulso';
import { leerVotos, type VotoPublicacion } from '../services/senales';
import { supabase } from '../services/auth';
import { Icon } from '../components/Icon';
import { CatBars, Empty, EventsList, Histo, LineChart, NatPill, SigList, StPill } from '../components/common';

/** noticias leídas: la cifra del VPS, o el último punto de la serie */
const PRIO = { alta: 0, media: 1, baja: 2 } as const;

/** «Cambios desde ayer» (db/generico/27_comparacion_dia.sql): solo los conteos; si todo es 0, no se muestra */
function CambiosAyer() {
  const c = useStore((s) => s.comparacionDia);
  if (!c) return null;
  const { nuevas, subieron, bajaron, resueltas } = c.conteos;
  if (!nuevas && !subieron && !bajaron && !resueltas) return null;
  const n = (v: number, uno: string, varios: string) => `${v} ${v === 1 ? uno : varios}`;
  const titulos = (l: { titulo: string }[]) => l.map((x) => x.titulo).join(' · ') || undefined;
  const partes = [
    nuevas ? <span key="n" className="ca-n" title={titulos(c.senales_nuevas)}>{n(nuevas, 'señal nueva', 'señales nuevas')}</span> : null,
    subieron ? <span key="s" className="ca-s" title={titulos(c.subieron_certeza)}>{n(subieron, 'subió de certeza', 'subieron de certeza')}</span> : null,
    bajaron ? <span key="b" className="ca-b" title={titulos(c.bajaron_certeza)}>{n(bajaron, 'bajó de certeza', 'bajaron de certeza')}</span> : null,
    resueltas ? <span key="r" className="ca-r" title={titulos(c.resueltas)}>{n(resueltas, 'resuelta', 'resueltas')}</span> : null,
  ].filter(Boolean);
  return (
    <section className="sd-b cambios-ayer" aria-label="Cambios desde ayer">
      <h4>Cambios desde ayer</h4>
      <p className="ca-l">{partes}</p>
      {c.comparable === false && <p className="note" style={{ margin: 0 }}>Aún no hay 24 h de registro: la subida o bajada de certeza se verá a partir de mañana.</p>}
    </section>
  );
}

function Sintesis() {
  const k = useContadores();
  const sd = useSintesisDia();
  const real = useStore((s) => s.origen === 'vps');
  const abrir = (codigo?: string) => { if (codigo) useStore.getState().openDrawer({ kind: 'senal', id: codigo }); };
  const Item = ({ i }: { i: ItemSintesis }) => (
    <li>
      {i.certeza && <span className={`tag cert cert-${i.certeza}`}>{CERTEZAS[i.certeza].t}</span>}{' '}
      {i.codigo ? <button className="linklike" onClick={() => abrir(i.codigo)}>{i.titulo}</button> : null}
      {i.codigo ? ': ' : ''}{i.texto ?? i.motivo}
      {i.lugares ? <small className="sd-l"> · {i.lugares}</small> : null}
    </li>
  );
  const Bloque = ({ t, l, vacio }: { t: string; l: ItemSintesis[]; vacio: string }) => (
    <section className="sd-b">
      <h4>{t}</h4>
      {l.length ? <ul>{l.map((i, n) => <Item key={`${i.codigo ?? i.tipo}-${n}`} i={i} />)}</ul> : <p className="note" style={{ margin: 0 }}>{vacio}</p>}
    </section>
  );
  return (
    <div className="synth">
      <p className="sd-t">{sd.totales}</p>
      <CambiosAyer />
      <Bloque t="Qué pasa" l={sd.que_pasa} vacio="Sin novedades confirmadas ni convocadas." />
      <Bloque t="Por qué importa" l={sd.por_que_importa} vacio="Sin datos: no hay hechos que valorar." />
      <Bloque t="Qué vigilar" l={sd.que_vigilar} vacio="Nada pendiente de vigilar." />
      <div className="kpis">
        <div className="kpi"><small>Señales activas</small><b className="num">{k.senales_activas}</b><em>sin descartadas</em></div>
        <div className="kpi"><small>Oportunidades</small><b className="num" style={{ color: 'var(--opp)' }}>{k.oportunidades}</b><em>{k.plazo_corto} con plazo &lt; 15 días{k.mixtas ? ` · ${k.mixtas} mixtas aparte` : ''}</em></div>
        <div className="kpi"><small>Riesgos</small><b className="num" style={{ color: 'var(--risk)' }}>{k.riesgos}</b><em>{k.riesgos_altos} de prioridad alta</em></div>
        <div className="kpi" title={`${DEF_VERIFICADA}\n${DEF_SIN_VERIFICAR}`}><small>Verificadas</small><b className="num" style={{ color: 'var(--ok)' }}>{k.verificadas}</b><em>{desgloseVerificadas(k)}{textoSinVerificar(k) ? <><br />{textoSinVerificar(k)}</> : null}</em></div>
      </div>
      <p className="note actualizado" title="Los mismos números que recibe AVIA (vigilante.contadores)">
        Datos actualizados a las {horaBolivia(k.actualizado)} (hora de Bolivia){real ? '' : ' · datos de ejemplo'}
        {' · '}<button className="linklike" onClick={() => useStore.getState().openDrawer({ kind: 'glosario' })}>¿Qué es noticia, señal, alerta y recomendación?</button>
      </p>
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
  const senales = useStore((s) => s.senales);
  const real = useStore((s) => s.origen === 'vps');
  const ventana = useStore((s) => s.ventanaHoras);
  const p = calcularPulso(senales, fuentes);
  const d = p.datos;
  const niveles = ['Normal', 'Vigilancia', 'Atención', 'Crítico'] as const;
  return (
    <>
      <div className="gauges">
        <div className="gauge">
          <Ring v={p.riesgo} col="var(--risk)" /><span className="lab">Atención a riesgos</span><span className="lv">{p.nivelRiesgo}</span>
          <small className="gauge-d">{d.riesgos} {d.riesgos === 1 ? 'riesgo activo' : 'riesgos activos'} · {d.riesgosAltos} {d.riesgosAltos === 1 ? 'alto' : 'altos'}{d.riesgosSinDecidir ? ` · ${d.riesgosSinDecidir} sin decidir` : ''}</small>
        </div>
        <div className="gauge">
          <Ring v={p.oportunidad} col="var(--opp)" /><span className="lab">Oportunidad</span><span className="lv">{p.nivelOportunidad}</span>
          <small className="gauge-d">{d.oportunidades} {d.oportunidades === 1 ? 'oportunidad' : 'oportunidades'}{d.plazoCorto ? ` · ${d.plazoCorto} cierran en menos de 15 días` : ''}</small>
        </div>
      </div>
      <div className="scale">
        <div className="scale-bar"><i style={{ left: `${posicionVigilancia(p)}%` }} /></div>
        <div className="scale-l">{niveles.map((n) => <span key={n} className={n === p.vigilancia ? 'on' : undefined}>{n}</span>)}</div>
      </div>
      <p className="note" style={{ margin: '10px 0 0' }}>
        <button className="linklike" onClick={() => useStore.getState().openDrawer({ kind: 'pulso' })}>¿Cómo se calcula el Pulso?</button>{' '}
        {real ? <>Calculado con las {d.activas} señales activas{ventana ? ` de las últimas ${ventana} h` : ''}</> : <>Datos de ejemplo</>}.
        {' '}Los índices miden lo serias que son las señales, no cuántas hay: los riesgos según prioridad, fiabilidad de la evidencia y si ya están verificados; las oportunidades según su relevancia, novedad y fiabilidad, y si el plazo sigue abierto.
        {d.revisionVencida ? <> <b>{d.revisionVencida} con la revisión vencida.</b></> : null}
        {d.fuentesTotal ? <> Fuentes leyendo bien: {d.fuentesOk} de las {d.fuentesTotal} activas{d.fuentesOk < d.fuentesTotal * 0.7 ? ', así que puede haber señales sin detectar' : ''}.</> : null}
      </p>
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
  const k = useContadores();
  const steps: [string, number, string, string][] = [
    ['senales', k.noticias_24h, 'Noticias leídas (24 h)', 'var(--accent)'],
    ['temas', k.senales_activas, 'Señales activas', 'var(--mix)'],
    ['shield', k.verificadas, 'Verificadas', 'var(--ok)'],
    ['oportunidades', k.oportunidades + k.mixtas, 'Oportunidades y mixtas', 'var(--opp)'],
    ['decision', k.alertas_publicadas, 'Alertas publicadas', 'var(--risk)'],
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

function Mapa() {
  const senales = useStore((s) => s.senales);
  const fichas = useStore((s) => s.oportunidades);
  const eventos = useEventos((s) => s.eventos);
  const cambios = useCambios((s) => s.cambios);
  const { go, setMapaSel } = useStore.getState();
  const por = useMemo(() => {
    const a = activeSignals(senales).filter((s) => esReciente(s));
    return Object.fromEntries(DEPS.map((d) => [d, resumenRegion(d, a, fichas, eventos, cambios)]));
  }, [senales, fichas, eventos, cambios]);
  return (
    <>
      <MapaBolivia compacto por={por} sel={null} onSel={(d) => { setMapaSel(d); go('mapa'); }} />
      <div className="map-legend">
        <span><i style={{ background: 'var(--opp)' }} />▲ oportunidades</span>
        <span><i style={{ background: 'var(--risk)' }} />● riesgos</span>
        <span>Toca un departamento para ver su resumen</span>
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
            {s.revisionVencida
              ? <span className="tag vencida" title="Pasó la hora que tiene el analista para revisarla y nadie decidió todavía. No es el plazo de la oportunidad.">Revisión atrasada</span>
              : s.sla ? <span className="sla" title="Tiempo restante para revisar">⏱ {plazoTexto(s.sla)}</span> : <span className="tag">{CATS[s.categoria]}</span>}
            {s.escenario && <span className="tag escenario">Escenario</span>}
          </div>
          <button className="tt" style={{ background: 'none', border: 'none', padding: 0, textAlign: 'left' }} onClick={() => openDrawer({ kind: 'senal', id: s.id })}>{s.titulo}</button>
          <div className="row">
            <span className="note">{s.corr} fuente(s) · fiabilidad {puntuacionesDe(s).fiabilidad.valor}/100</span>
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

function Valoracion() {
  const perfil = useStore((s) => s.perfil);
  const senales = useStore((s) => s.senales);
  const openDrawer = useStore((s) => s.openDrawer);
  const [votos, setVotos] = useState<VotoPublicacion[] | null>(null);
  const [err, setErr] = useState('');
  useEffect(() => {
    if (!supabase || !perfil) return;
    leerVotos().then(setVotos).catch((e: Error) => setErr(e.message));
  }, [perfil]);
  if (!supabase || !perfil) return <Empty title="Sin datos">Inicia sesión para ver los votos de la web pública.</Empty>;
  if (err) return <Empty title="No se pudieron leer los votos">{err}</Empty>;
  if (!votos) return <p className="note">Cargando…</p>;
  const desde = Date.now() - 7 * 864e5;
  const semana = votos.filter((v) => v.publicada_en && Date.parse(v.publicada_en) >= desde);
  const util = semana.reduce((n, v) => n + v.util, 0), no = semana.reduce((n, v) => n + v.no_util, 0);
  const top = [...votos].filter((v) => v.util + v.no_util > 0).sort((a, b) => (b.util + b.no_util) - (a.util + a.no_util)).slice(0, 6);
  return (
    <>
      <div className="vot-sum">
        <div><b>{semana.length}</b><span className="note">publicadas en 7 días</span></div>
        <div><b style={{ color: 'var(--ok)' }}>{util}</b><span className="note">útiles</span></div>
        <div><b style={{ color: 'var(--risk)' }}>{no}</b><span className="note">no útiles</span></div>
      </div>
      {top.length
        ? <ul className="vot-list">{top.map((v) => {
            const s = senales.find((x) => x.id === v.codigo);
            return (
              <li key={v.codigo}>
                <button className="tt linklike" style={{ textAlign: 'left', textDecoration: 'none', color: 'var(--ink)' }} onClick={() => s && openDrawer({ kind: 'senal', id: s.id })}>{s?.titulo ?? v.codigo}</button>
                <span className="mono">👍 {v.util} · 👎 {v.no_util}</span>
              </li>
            );
          })}</ul>
        : <p className="note" style={{ margin: 0 }}>Todavía nadie ha votado en la web pública.</p>}
    </>
  );
}

export const PANEL_BODY: Record<PanelId, () => JSX.Element> = {
  sintesis: Sintesis, pulso: Pulso, fuentes: FuentesMatrix, cadena: Cadena, oportunidades: Oportunidades,
  riesgos: Riesgos, mapa: Mapa, evolucion: LineChart, decision: Decision, actividad: Actividad, temas: Temas, categorias: Categorias,
  valoracion: Valoracion,
};

export function usePanelMeta(id: PanelId): string {
  const fuentesTxt = textoFuentes(useStore((s) => s.fuentes));
  const real = useStore((s) => s.origen === 'vps');
  const nPend = pendingDecision(useStore((s) => s.senales)).length;
  const meta: Record<PanelId, string> = {
    sintesis: 'Borrador de AVIA', fuentes: fuentesTxt, oportunidades: 'por puntuación', riesgos: 'vigentes',
    mapa: '9 departamentos', evolucion: real ? 'VPS' : 'demo', decision: `${nPend} pendientes`, actividad: real ? 'VPS' : 'en vivo', temas: real ? 'VPS' : '7 días',
    cadena: 'hoy', pulso: 'índice', categorias: 'activas', valoracion: 'web pública',
  };
  return meta[id];
}
