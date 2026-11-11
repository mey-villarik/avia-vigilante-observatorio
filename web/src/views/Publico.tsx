// Web pública: lo que el equipo publicó desde el panel (Señales → Publicar). Sin login.
import { useEffect, useMemo, useRef, useState } from 'react';
import type { Naturaleza } from '../types';
import { NatPill } from '../components/common';
import { ago, norm } from '../lib/util';
import { leerPublicas, votar, votoGuardado, type AlertaPublica, type Publicas } from '../services/publico';

const REFRESCO_MS = 5 * 60 * 1000;
const NAT_OPTS: [Naturaleza | 'all', string][] = [['all', 'Todas'], ['oportunidad', 'Oportunidades'], ['riesgo', 'Riesgos'], ['mixta', 'Mixtas']];

const minutosDesde = (iso: string) => Math.max(0, (Date.now() - new Date(iso).getTime()) / 60000);
const fecha = (iso: string) => new Date(iso).toLocaleDateString('es-BO', { day: 'numeric', month: 'short' });

function Voto({ a }: { a: AlertaPublica }) {
  const [mio, setMio] = useState<boolean | null>(() => votoGuardado(a.id));
  const [msg, setMsg] = useState('');
  const enviar = async (util: boolean) => {
    try { await votar(a.id, util); setMio(util); setMsg('Gracias por tu opinión.'); }
    catch (e) { setMsg((e as Error).message); }
  };
  return (
    <div className="pub-voto" role="group" aria-label="¿Te fue útil esta alerta?">
      <span>¿Te fue útil?</span>
      <button className={`btn sm ${mio === true ? 'on' : ''}`} aria-pressed={mio === true} onClick={() => void enviar(true)}>Sí</button>
      <button className={`btn sm ${mio === false ? 'on' : ''}`} aria-pressed={mio === false} onClick={() => void enviar(false)}>No</button>
      {msg && <small role="status">{msg}</small>}
    </div>
  );
}

function Detalle({ a }: { a: AlertaPublica }) {
  const plazo = a.plazo_hasta ? Math.ceil((new Date(a.plazo_hasta).getTime() - Date.now()) / 864e5) : null;
  return (
    <article className={`pub-card pub-detalle nat-b-${a.naturaleza}`}>
      <div className="pub-meta">
        <NatPill n={a.naturaleza} />
        {a.verificacion === 'en_verificacion'
          ? <span className="tag pub-verif" title="Publicada con fuente, pero el equipo sigue comprobándola">En verificación</span>
          : <span className="tag pub-ok">Verificada</span>}
        {a.categoria_nombre && <span className="tag">{a.categoria_nombre}</span>}
        {a.prioridad === 'alta' && <span className="tag pub-alta">Prioridad alta</span>}
        {!a.actual && <span className="tag">Anterior</span>}
      </div>
      <h2 id="pubDetT">{a.titulo}</h2>
      <p>{a.texto}</p>
      {a.importancia && <><h3>Por qué importa al turismo</h3><p>{a.importancia}</p></>}
      {a.recomendacion && <><h3>Qué se recomienda</h3><p>{a.recomendacion}</p></>}
      <dl className="pub-dl">
        {a.deps.length > 0 && <div><dt>Dónde</dt><dd>{a.deps.join(', ')}</dd></div>}
        {a.destinos.length > 0 && <div><dt>Destinos</dt><dd>{a.destinos.join(', ')}</dd></div>}
        {plazo != null && plazo >= 0 && <div><dt>Plazo</dt><dd>{plazo === 0 ? 'Hoy' : `${plazo} días`} ({fecha(a.plazo_hasta!)})</dd></div>}
        {plazo != null && plazo < 0 && <div><dt>Plazo</dt><dd>Cerrado el {fecha(a.plazo_hasta!)}</dd></div>}
        {a.fecha_evento && <div><dt>Fecha del evento</dt><dd>{fecha(a.fecha_evento)}</dd></div>}
        <div><dt>Publicada</dt><dd>{ago(minutosDesde(a.publicada_en))}</dd></div>
      </dl>
      <div className="pub-pie">
        {a.enlace
          ? <a href={a.enlace} target="_blank" rel="noopener noreferrer">Ver la fuente original</a>
          : <span />}
        <Voto a={a} />
      </div>
    </article>
  );
}

// Recuadro de la cuadrícula: solo lo necesario para decidir si abrirla.
function Recuadro({ a, abrir }: { a: AlertaPublica; abrir: () => void }) {
  const lugar = a.deps.length ? a.deps.join(', ') : a.destinos.join(', ');
  return (
    <button type="button" className={`pub-recuadro nat-b-${a.naturaleza}${a.actual ? '' : ' pub-anterior'}`} onClick={abrir}
      aria-haspopup="dialog">
      <span className="pub-meta">
        <NatPill n={a.naturaleza} />
        {a.verificacion === 'en_verificacion' && <span className="tag pub-verif">En verificación</span>}
        {a.prioridad === 'alta' && <span className="tag pub-alta">Prioridad alta</span>}
      </span>
      <span className="pub-recuadro-t">{a.titulo}</span>
      <span className="pub-recuadro-s">
        {[a.categoria_nombre, lugar, ago(minutosDesde(a.publicada_en))].filter(Boolean).join(' · ')}
      </span>
    </button>
  );
}

// Ventana flotante con la noticia entera. <dialog> nativo: Esc cierra y el foco se queda dentro.
function Ventana({ a, cerrar }: { a: AlertaPublica; cerrar: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dlg = ref.current;
    if (dlg && !dlg.open) dlg.showModal();
    return () => dlg?.close();
  }, []);
  return (
    <dialog ref={ref} className="pub-ventana-flot" aria-labelledby="pubDetT" onClose={cerrar}
      onClick={(e) => { if (e.target === e.currentTarget) cerrar(); }}>
      <button type="button" className="pub-cerrar" onClick={cerrar} aria-label="Cerrar">×</button>
      <Detalle a={a} />
    </dialog>
  );
}

type Periodo = 'actuales' | '30' | 'todo';
const PERIODOS: [Periodo, string][] = [['actuales', 'Actuales'], ['30', 'Últimos 30 días'], ['todo', 'Todo lo guardado']];
const PRIOS: ['all' | 'alta' | 'media' | 'baja', string][] = [['all', 'Cualquier prioridad'], ['alta', 'Prioridad alta'], ['media', 'Prioridad media'], ['baja', 'Prioridad baja']];

function Resumen({ d }: { d: Publicas }) {
  const r = d.resumen;
  if (!r) return null;
  const items = r.alertas.map((id) => d.alertas.find((a) => a.id === id)).filter((a): a is AlertaPublica => Boolean(a));
  return (
    <section className="pub-resumen" aria-labelledby="pubResumenT">
      <h2 id="pubResumenT">Resumen del día <small>{fecha(r.fecha + 'T12:00:00')}</small></h2>
      {items.length
        ? <ol>{items.map((a) => <li key={a.id}><a href={`#alerta-${a.id}`}>{a.titulo}</a>{a.deps.length > 0 && <small> · {a.deps.join(', ')}</small>}</li>)}</ol>
        : <p>{r.texto || d.mensajeVacio}</p>}
    </section>
  );
}

export function Publico() {
  const [d, setD] = useState<Publicas | null>(null);
  const [err, setErr] = useState('');
  const [nat, setNat] = useState<Naturaleza | 'all'>('all');
  const [dep, setDep] = useState('all');
  const [cat, setCat] = useState('all');
  const [prio, setPrio] = useState<'all' | 'alta' | 'media' | 'baja'>('all');
  const [periodo, setPeriodo] = useState<Periodo>('actuales');
  const [q, setQ] = useState('');
  const anteriores = periodo !== 'actuales';
  const idDeHash = () => { const m = /^#alerta-(-?\d+)$/.exec(window.location.hash); return m ? Number(m[1]) : null; };
  const [abierta, setAbierta] = useState<number | null>(idDeHash);
  useEffect(() => {
    const h = () => setAbierta(idDeHash());
    window.addEventListener('hashchange', h);
    return () => window.removeEventListener('hashchange', h);
  }, []);
  const abrir = (id: number) => { window.location.hash = `alerta-${id}`; };
  const cerrar = () => {
    setAbierta(null);
    if (window.location.hash) history.replaceState(null, '', window.location.pathname + window.location.search);
  };

  useEffect(() => {
    const cargar = () => leerPublicas(anteriores).then((x) => { setD(x); setErr(''); }).catch((e: Error) => setErr(e.message));
    void cargar();
    const t = setInterval(() => void cargar(), REFRESCO_MS);
    return () => clearInterval(t);
  }, [anteriores]);

  useEffect(() => { if (d) document.title = `Alertas · ${d.nombre}`; }, [d]);

  const todas = d?.alertas ?? [];
  const deps = useMemo(() => [...new Set(todas.flatMap((a) => a.deps))].sort(), [todas]);
  const cats = useMemo(() => [...new Map(todas.map((a) => [a.categoria, a.categoria_nombre || a.categoria])).entries()]
    .sort((x, y) => x[1].localeCompare(y[1])), [todas]);
  const desde = periodo === '30' ? Date.now() - 30 * 864e5 : 0;
  const lista = todas.filter((a) => (nat === 'all' || a.naturaleza === nat)
    && (dep === 'all' || a.deps.includes(dep))
    && (cat === 'all' || a.categoria === cat)
    && (prio === 'all' || a.prioridad === prio)
    && (!desde || a.actual || new Date(a.publicada_en).getTime() >= desde)
    && (!q || norm(`${a.titulo} ${a.texto} ${a.destinos.join(' ')} ${a.deps.join(' ')}`).includes(norm(q))));
  const alertaAbierta = abierta != null ? todas.find((a) => a.id === abierta) ?? null : null;
  const filtrando = nat !== 'all' || dep !== 'all' || cat !== 'all' || prio !== 'all' || q !== '';

  return (
    <div className="pub">
      <header className="pub-head">
        <div className="eyebrow">Alertas para el turismo</div>
        <h1>{d?.nombre ?? 'Observatorio'}</h1>
        <p className="sub">Oportunidades y riesgos que pueden afectar al turismo. AVIA las detecta en fuentes oficiales y medios, y el equipo del observatorio las revisa antes de publicarlas.</p>
        {d?.telegramUrl && <a className="btn primary" href={d.telegramUrl} target="_blank" rel="noopener noreferrer">Recibir avisos por Telegram</a>}
        {d?.ejemplo && <p className="note">Ejemplo: esta página aún no está conectada a la base de datos.</p>}
      </header>

      {d && !anteriores && !filtrando && <Resumen d={d} />}

      <div className="toolbar">
        <label className="sr" htmlFor="pubQ">Buscar</label>
        <input className="inp" id="pubQ" placeholder="Buscar por tema, lugar o destino" value={q} onChange={(e) => setQ(e.target.value)} />
        <div className="seg">
          {NAT_OPTS.map(([k, n]) => <button key={k} className={nat === k ? 'on' : ''} aria-pressed={nat === k} onClick={() => setNat(k)}>{n}</button>)}
        </div>
      </div>
      <div className="toolbar pub-filtros">
        <label className="sr" htmlFor="pubDep">Departamento</label>
        <select id="pubDep" value={dep} onChange={(e) => setDep(e.target.value)}>
          <option value="all">Todos los departamentos</option>
          {deps.map((x) => <option key={x}>{x}</option>)}
        </select>
        <label className="sr" htmlFor="pubCat">Categoría</label>
        <select id="pubCat" value={cat} onChange={(e) => setCat(e.target.value)}>
          <option value="all">Todas las categorías</option>
          {cats.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
        </select>
        <label className="sr" htmlFor="pubPrio">Prioridad</label>
        <select id="pubPrio" value={prio} onChange={(e) => setPrio(e.target.value as typeof prio)}>
          {PRIOS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
        </select>
        <label className="sr" htmlFor="pubPer">Fecha</label>
        <select id="pubPer" value={periodo} onChange={(e) => setPeriodo(e.target.value as Periodo)}>
          {PERIODOS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
        </select>
      </div>
      {d && !anteriores && <p className="note pub-ventana">Se ven los riesgos y avisos de los últimos {d.dias} días y las oportunidades con plazo abierto.</p>}

      {err && <p className="pub-err" role="alert">No se pudieron cargar las alertas: {err}</p>}
      {!d && !err && <p className="note">Cargando…</p>}
      {d && lista.length === 0 && (
        <p className="pub-vacio">{todas.length ? 'Ninguna alerta coincide con el filtro.' : d.mensajeVacio}</p>
      )}
      <div className="pub-lista">{lista.map((a) => <Recuadro key={a.id} a={a} abrir={() => abrir(a.id)} />)}</div>
      {alertaAbierta && <Ventana key={alertaAbierta.id} a={alertaAbierta} cerrar={cerrar} />}

      {d && !anteriores && d.nAnteriores > 0 && (
        <p className="pub-mas"><button className="btn" onClick={() => setPeriodo('todo')}>Ver anteriores ({d.nAnteriores})</button></p>
      )}
      {d && anteriores && (
        <p className="pub-mas"><button className="btn ghost" onClick={() => setPeriodo('actuales')}>Volver a las actuales</button></p>
      )}

      <footer className="pub-foot">
        Información revisada por personas antes de publicarse. Lo que dice «En verificación» tiene fuente, pero el equipo aún la está comprobando. Se actualiza cada 5 minutos.
      </footer>
    </div>
  );
}
