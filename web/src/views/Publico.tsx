// Web pública: lo que el equipo publicó desde el panel (Señales → Publicar). Sin login.
import { useEffect, useMemo, useState } from 'react';
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

function Tarjeta({ a }: { a: AlertaPublica }) {
  const plazo = a.plazo_hasta ? Math.ceil((new Date(a.plazo_hasta).getTime() - Date.now()) / 864e5) : null;
  return (
    <article className={`pub-card nat-b-${a.naturaleza}`}>
      <div className="pub-meta">
        <NatPill n={a.naturaleza} />
        {a.verificacion === 'en_verificacion'
          ? <span className="tag pub-verif" title="Publicada con fuente, pero el equipo sigue comprobándola">En verificación</span>
          : <span className="tag pub-ok">Verificada</span>}
        {a.categoria_nombre && <span className="tag">{a.categoria_nombre}</span>}
        {a.prioridad === 'alta' && <span className="tag pub-alta">Prioridad alta</span>}
      </div>
      <h2>{a.titulo}</h2>
      <p>{a.texto}</p>
      {a.importancia && <><h3>Por qué importa al turismo</h3><p>{a.importancia}</p></>}
      {a.recomendacion && <><h3>Qué se recomienda</h3><p>{a.recomendacion}</p></>}
      <dl className="pub-dl">
        {a.deps.length > 0 && <div><dt>Dónde</dt><dd>{a.deps.join(', ')}</dd></div>}
        {a.destinos.length > 0 && <div><dt>Destinos</dt><dd>{a.destinos.join(', ')}</dd></div>}
        {plazo != null && plazo >= 0 && <div><dt>Plazo</dt><dd>{plazo === 0 ? 'Hoy' : `${plazo} días`} ({fecha(a.plazo_hasta!)})</dd></div>}
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

export function Publico() {
  const [d, setD] = useState<Publicas | null>(null);
  const [err, setErr] = useState('');
  const [nat, setNat] = useState<Naturaleza | 'all'>('all');
  const [dep, setDep] = useState('all');
  const [q, setQ] = useState('');

  useEffect(() => {
    const cargar = () => leerPublicas().then((x) => { setD(x); setErr(''); }).catch((e: Error) => setErr(e.message));
    void cargar();
    const t = setInterval(() => void cargar(), REFRESCO_MS);
    return () => clearInterval(t);
  }, []);

  useEffect(() => { if (d) document.title = `Alertas · ${d.nombre}`; }, [d]);

  const deps = useMemo(() => [...new Set((d?.alertas ?? []).flatMap((a) => a.deps))].sort(), [d]);
  const lista = (d?.alertas ?? []).filter((a) => (nat === 'all' || a.naturaleza === nat)
    && (dep === 'all' || a.deps.includes(dep))
    && (!q || norm(`${a.titulo} ${a.texto} ${a.destinos.join(' ')} ${a.deps.join(' ')}`).includes(norm(q))));

  return (
    <div className="pub">
      <header className="pub-head">
        <div className="eyebrow">Alertas para el turismo</div>
        <h1>{d?.nombre ?? 'Observatorio'}</h1>
        <p className="sub">Oportunidades y riesgos que pueden afectar al turismo. AVIA las detecta en fuentes oficiales y medios, y el equipo del observatorio las revisa antes de publicarlas.</p>
        {d?.telegramUrl && <a className="btn primary" href={d.telegramUrl} target="_blank" rel="noopener noreferrer">Recibir avisos por Telegram</a>}
        {d?.ejemplo && <p className="note">Ejemplo: esta página aún no está conectada a la base de datos.</p>}
      </header>

      <div className="toolbar">
        <label className="sr" htmlFor="pubQ">Buscar</label>
        <input className="inp" id="pubQ" placeholder="Buscar por tema, lugar o destino" value={q} onChange={(e) => setQ(e.target.value)} />
        <div className="seg">
          {NAT_OPTS.map(([k, n]) => <button key={k} className={nat === k ? 'on' : ''} aria-pressed={nat === k} onClick={() => setNat(k)}>{n}</button>)}
        </div>
        {deps.length > 1 && (
          <>
            <label className="sr" htmlFor="pubDep">Departamento</label>
            <select id="pubDep" style={{ width: 'auto' }} value={dep} onChange={(e) => setDep(e.target.value)}>
              <option value="all">Todos los departamentos</option>
              {deps.map((x) => <option key={x}>{x}</option>)}
            </select>
          </>
        )}
      </div>

      {err && <p className="pub-err" role="alert">No se pudieron cargar las alertas: {err}</p>}
      {!d && !err && <p className="note">Cargando…</p>}
      {d && lista.length === 0 && (
        <p className="pub-vacio">{d.alertas.length ? 'Ninguna alerta coincide con el filtro.' : 'No hay alertas publicadas ahora mismo.'}</p>
      )}
      <div className="pub-lista">{lista.map((a) => <Tarjeta key={a.id} a={a} />)}</div>

      <footer className="pub-foot">
        Información revisada por personas antes de publicarse. Lo que dice «En verificación» tiene fuente, pero el equipo aún la está comprobando. Se actualiza cada 5 minutos.
      </footer>
    </div>
  );
}
