// Panel lateral de detalle: fuente, señal, catálogo de paneles, accesibilidad y formularios.
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import type { Etapa, Fuente } from '../types';
import { CATS, PANELS, STATE_TXT, STL, catName } from '../data/demo';
import { canDecide, isAdmin, useStore } from '../store';
import { ago, clock } from '../lib/util';
import { Icon } from './Icon';
import { Histo, NatPill, StPill } from './common';
import { useChat } from '../services/chat';
import { planPrompt } from '../views/Oportunidades';
import { Equipo, MiClave } from './Equipo';

function Head({ icon, children }: { icon?: string; children: ReactNode }) {
  const closeDrawer = useStore((s) => s.closeDrawer);
  return (
    <div className="drawer-h">
      {icon && <Icon name={icon} />} {children}
      <button className="icon-btn" aria-label="Cerrar" onClick={closeDrawer}><Icon name="close" /></button>
    </div>
  );
}

const hostOf = (u: string) => { try { return new URL(u).hostname; } catch { return u; } };

const Lock = ({ children }: { children: ReactNode }) => <div className="lock"><Icon name="shield" /> {children}</div>;

function checksFor(s: Fuente): [Fuente['estado'], string, string][] {
  const st = s.estado;
  if (st === 'MANT') return [['MANT', 'Disponibilidad', 'En mantenimiento programado'], ['MANT', 'Frescura', '—'], ['MANT', 'Estructura', '—'], ['MANT', 'Novedad', '—']];
  if (st === 'UNKNOWN') return [['UNKNOWN', 'Disponibilidad', 'Sin datos: URL por confirmar'], ['UNKNOWN', 'Frescura', '—'], ['UNKNOWN', 'Estructura', '—'], ['UNKNOWN', 'Novedad', '—']];
  const abc = s.id === 'abc_caminos';
  return [
    [abc ? 'CRIT' : (s.lat ?? 0) > 5000 ? 'WARN' : 'OK', 'Disponibilidad', abc ? 'Sin respuesta en 30 s (3/3)' : `HTTP 200 en ${((s.lat ?? 0) / 1000).toFixed(1)} s`],
    [abc ? 'CRIT' : 'OK', 'Frescura', abc ? 'Último dato hace 48 min (umbral 45)' : 'Último elemento dentro del plazo'],
    [s.id === 'minsalud' ? 'WARN' : abc ? 'UNKNOWN' : 'OK', 'Estructura', s.id === 'minsalud' ? 'El selector no encontró la lista de comunicados' : abc ? 'No evaluable' : 'Campos extraídos: título, fecha, enlace'],
    [s.items ? 'OK' : st === 'OK' ? 'OK' : 'WARN', 'Novedad', s.items ? `${s.items} elemento(s) nuevo(s)` : 'Sin elementos nuevos'],
  ];
}

function FuenteDetalle({ id }: { id: string }) {
  const s = useStore((st) => st.fuentes.find((f) => f.id === id));
  const role = useStore((st) => st.role);
  const real = useStore((st) => st.origen === 'vps');
  const { recheck, ackSource, toggleMant } = useStore.getState();
  if (!s) return null;
  return (
    <>
      <Head icon="fuentes">Fuente · {s.id}</Head>
      <div className="drawer-b">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <StPill s={s.estado} /><span className="tag">{catName(s.canal)}</span><span className="tag">{s.tipo}</span>{s.verif !== '—' && <span className="tag">URL {s.verif}</span>}
        </div>
        <h2>{s.nombre}</h2>
        <p className="lead mono" style={{ fontSize: 12, wordBreak: 'break-all' }}>{s.url}</p>
        <div className="dl">
          <div><small>Método</small><b>{s.metodo}</b></div>
          {s.freq ? <div><small>Frecuencia</small><b>cada {s.freq} min</b></div> : null}
          {s.lat ? <div><small>Tiempo de respuesta</small><b className="mono">{(s.lat / 1000).toFixed(1)} s</b></div> : null}
          {s.last != null && real ? <div><small>Última comprobación</small><b className="mono">{clock(-s.last)}</b></div> : null}
          <div><small>{real ? 'Elementos nuevos' : 'Señales en 24 h'}</small><b className="mono">{s.items}</b></div>
        </div>
        {real ? (
          <>
            <div className="sect">Última comprobación de AVIA</div>
            <p style={{ margin: 0 }}>{s.info || 'Sin información.'}</p>
          </>
        ) : (
          <>
            <div className="sect">Comprobaciones</div>
            <div className="checks">
              {checksFor(s).map(([k, n, d]) => <div className="check" key={n}><StPill s={k} /><span>{n}<small>{d}</small></span></div>)}
            </div>
          </>
        )}
        <div className="sect">Historial ({s.hist.length} comprobaciones)</div>
        <Histo hist={s.hist} height={22} titles />
        {s.flap && <p className="note" style={{ margin: 0 }}>⇅ Estado intermitente: cambió 4 veces en las últimas 24 comprobaciones. Conviene revisar la forma de acceso.</p>}
        <div className="sect">Acciones</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <button className="btn primary" onClick={() => recheck(s.id)}><Icon name="refresh" /> {real ? 'Recargar datos' : 'Comprobar ahora'}</button>
          {canDecide(role) && ['WARN', 'CRIT'].includes(s.estado) && !s.ack && (
            <button className="btn" onClick={() => ackSource(s.id)}><Icon name="check" /> Reconocer problema</button>
          )}
          {isAdmin(role) && (
            <button className="btn ghost" onClick={() => toggleMant(s.id)}><Icon name="clock" /> {s.enBd ? (s.estado === 'MANT' ? 'Reactivar (AVIA vuelve a vigilarla)' : 'Pausar (AVIA deja de vigilarla)') : (s.estado === 'MANT' ? 'Quitar mantenimiento' : 'Poner en mantenimiento')}</button>
          )}
        </div>
        <Lock>Reconocer un problema avisa al resto del equipo de que alguien lo está atendiendo. {real ? (s.enBd ? 'Reconocer todavía solo cambia este navegador; pausar y reactivar sí se guardan y AVIA las respeta en su siguiente ronda.' : 'Por ahora solo cambia este navegador: no se guarda en el VPS.') : 'En la demo solo cambia este navegador.'}</Lock>
      </div>
    </>
  );
}

function SenalDetalle({ id }: { id: string }) {
  const s = useStore((st) => st.senales.find((x) => x.id === id));
  const fuentes = useStore((st) => st.fuentes);
  const role = useStore((st) => st.role);
  const enBd = useStore((st) => st.enBd);
  const real = useStore((st) => st.origen === 'vps');
  const { moveSignal, closeDrawer } = useStore.getState();
  const { openChat } = useChat();
  const [sol, setSol] = useState<number | null>(null);
  const [note, setNote] = useState('');
  if (!s) return null;
  const evid = s.fuentes.map((f) => fuentes.find((x) => x.id === f)).filter((x): x is Fuente => Boolean(x));

  const decide = (to: Etapa) => {
    const n = ((sol != null ? 'Acción: ' + s.soluciones[sol].t + '. ' : '') + note).trim();
    closeDrawer();
    moveSignal(s.id, to, n);
  };

  return (
    <>
      <Head icon="senales">Señal {s.id}{real ? '' : ' · ejemplo'}</Head>
      <div className="drawer-b">
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <NatPill n={s.naturaleza} /><span className="tag">{STL[s.estado]}</span><span className="tag">{CATS[s.categoria]}</span><span className="tag">Prioridad {s.prioridad}</span>
        </div>
        <h2>{s.titulo}</h2>
        <p className="lead">{s.resumen}</p>
        <div className="dl">
          <div><small>Territorio</small><b>{s.deps.join(', ')}</b></div>
          <div><small>Destinos</small><b>{s.destinos.join(', ')}</b></div>
          <div><small>Relevancia · Novedad</small><b className="mono">{s.rel}/10 · {s.nov}/10</b></div>
          <div><small>Confianza</small><b className="mono">{Math.round(s.conf * 100)}%</b></div>
          {s.plazo != null ? <div><small>Plazo</small><b>{s.plazo} días</b></div> : null}
          <div><small>Detectada</small><b>{ago(s.min)}</b></div>
          {s.revision ? <div><small>Próxima revisión</small><b className="mono">{s.revision}</b></div> : null}
        </div>
        {s.actualizacion && <><div className="sect">Última actualización</div><p style={{ margin: 0 }}>{s.actualizacion}</p></>}
        <div className="sect">Por qué importa al turismo</div>
        <p style={{ margin: 0 }}>{s.importancia}</p>
        <div className="sect">Evidencia y corroboración</div>
        {evid.map((f) => <div className="evi" key={f.id}><Icon name="shield" /><span>{f.nombre}<small>{f.url}</small></span></div>)}
        {(s.enlaces ?? []).map((e) => (
          <div className="evi" key={e.url}>
            <Icon name="link" />
            <span><a href={e.url} target="_blank" rel="noopener noreferrer">{e.nombre || e.url}</a><small>{e.fecha ? e.fecha + ' · ' : ''}{hostOf(e.url)}</small></span>
          </div>
        ))}
        {s.corr < 2 && <div className="evi pend"><Icon name="riesgo" /><span>Falta una segunda fuente independiente<small>AVIA sigue buscando corroboración</small></span></div>}
        <div className="sect">Soluciones y acciones que propone AVIA</div>
        {s.soluciones.map((o, i) => (
          <label className="sol" key={i}>
            <input type="radio" name="sol" checked={sol === i} onChange={() => setSol(i)} />
            <span><b>{o.t}</b><small>{o.d}</small></span>
          </label>
        ))}
        {canDecide(role) ? (
          <>
            <div className="field">
              <label htmlFor="decNote">Nota de la decisión</label>
              <textarea className="inp" id="decNote" placeholder="Motivo, condiciones o comentarios" value={note} onChange={(e) => setNote(e.target.value)} />
            </div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              <button className="btn gold" onClick={() => decide('confirmada')}><Icon name="check" /> Confirmar</button>
              <button className="btn" onClick={() => decide('publicada')}>Publicar</button>
              <button className="btn" onClick={() => decide('en_verificacion')}>Pedir verificación</button>
              <button className="btn ghost" onClick={() => decide('descartada')}>Descartar</button>
            </div>
          </>
        ) : <p className="note" style={{ margin: 0 }}>Entraste como visor: puedes consultar pero no decidir.</p>}
        <button className="btn ghost" onClick={() => openChat(planPrompt(s.id, s.titulo))}><Icon name="spark" /> Preguntar a AVIA por esta señal</button>
        {s.historial && s.historial.length > 0 && (
          <>
            <div className="sect">Historial</div>
            {s.historial.map((h, i) => (
              <div className="evi" key={i}><Icon name="clock" /><span>{STL[h.de]} → {STL[h.a]} · {h.quien}<small>{h.cuando}{h.nota ? ' · ' + h.nota : ''}</small></span></div>
            ))}
          </>
        )}
        <Lock>{real ? (enBd ? 'Señal real publicada por AVIA. Al cambiar su etapa se guarda en la base de datos, con tu nombre y la nota, y queda en la Bitácora.' : 'Señal real publicada por AVIA. Por ahora las decisiones solo cambian este navegador: no se guardan en el VPS y se pierden al recargar los datos.') : 'Señal de ejemplo. Las decisiones solo cambian esta demostración en tu navegador.'}</Lock>
      </div>
    </>
  );
}

function Catalogo() {
  const layout = useStore((s) => s.layout);
  const { addPanel, closeDrawer } = useStore.getState();
  return (
    <>
      <Head icon="plus">Catálogo de paneles</Head>
      <div className="drawer-b">
        <p className="lead">Elige qué quieres ver. Cada panel se puede mover, ensanchar o quitar después.</p>
        <div className="catalog">
          {(Object.entries(PANELS) as [keyof typeof PANELS, (typeof PANELS)[keyof typeof PANELS]][]).map(([k, d]) => {
            const inn = layout.some((p) => p.id === k);
            return (
              <button key={k} className={`cat-item ${inn ? 'in' : ''}`} aria-disabled={inn || undefined}
                onClick={() => { if (!inn) { addPanel(k); closeDrawer(); } }}>
                <b><Icon name={d.i} />{d.t}</b><small>{d.d}</small>
              </button>
            );
          })}
        </div>
        <div className="sect">Escalable</div>
        <p className="note" style={{ margin: 0 }}>Cada panel es un módulo independiente que lee la misma base de señales. Añadir uno nuevo (por ejemplo, ocupación hotelera o vuelos) no cambia los demás.</p>
      </div>
    </>
  );
}

function A11y() {
  const theme = useStore((s) => s.theme);
  const fs = useStore((s) => s.fs);
  const contrast = useStore((s) => s.contrast);
  const simple = useStore((s) => s.simple);
  const setPrefs = useStore((s) => s.setPrefs);
  return (
    <>
      <Head>Accesibilidad y apariencia</Head>
      <div className="drawer-b">
        <div className="field"><label>Tema</label>
          <div className="seg">
            <button className={!theme ? 'on' : ''} onClick={() => setPrefs({ theme: null })}>Del sistema</button>
            <button className={theme === 'dark' ? 'on' : ''} onClick={() => setPrefs({ theme: 'dark' })}>Oscuro</button>
            <button className={theme === 'light' ? 'on' : ''} onClick={() => setPrefs({ theme: 'light' })}>Claro</button>
          </div>
        </div>
        <div className="field"><label>Tamaño del texto</label>
          <div className="seg">
            {([[0.9, 'Pequeño'], [1, 'Normal'], [1.15, 'Grande'], [1.3, 'Muy grande']] as [number, string][]).map(([v, n]) => (
              <button key={v} className={fs === v ? 'on' : ''} onClick={() => setPrefs({ fs: v })}>{n}</button>
            ))}
          </div>
        </div>
        <div className="field"><label>Contraste</label>
          <div className="seg">
            <button className={contrast === 'normal' ? 'on' : ''} onClick={() => setPrefs({ contrast: 'normal' })}>Normal</button>
            <button className={contrast === 'alto' ? 'on' : ''} onClick={() => setPrefs({ contrast: 'alto' })}>Alto</button>
          </div>
        </div>
        <div className="field"><label>Modo sencillo</label>
          <div className="seg">
            <button className={!simple ? 'on' : ''} onClick={() => setPrefs({ simple: false })}>Completo</button>
            <button className={simple ? 'on' : ''} onClick={() => setPrefs({ simple: true })}>Sencillo</button>
          </div>
          <p className="note" style={{ margin: 0 }}>El modo sencillo oculta datos técnicos (tiempos de respuesta, puntuaciones) y deja lo esencial.</p>
        </div>
        <div className="sect">Atajos de teclado</div>
        <p className="note" style={{ margin: 0 }}><span className="kbd">Ctrl K</span> buscar · <span className="kbd">H</span> abrir AVIA · <span className="kbd">E</span> editar tablero · <span className="kbd">Esc</span> cerrar</p>
      </div>
    </>
  );
}

function GuardarTablero() {
  const saveBoard = useStore((s) => s.saveBoard);
  const [name, setName] = useState('');
  const submit = (e: FormEvent) => { e.preventDefault(); if (name.trim()) saveBoard(name.trim()); };
  return (
    <>
      <Head icon="save">Guardar tablero</Head>
      <div className="drawer-b">
        <form className="field" onSubmit={submit}>
          <label htmlFor="saveName">Nombre del tablero</label>
          <input className="inp" id="saveName" maxLength={30} placeholder="Por ejemplo: Mi semana" required value={name} onChange={(e) => setName(e.target.value)} />
          <button className="btn gold" style={{ marginTop: 8, alignSelf: 'flex-start' }}><Icon name="save" /> Guardar</button>
        </form>
        <p className="note">Aparecerá en «Tableros guardados». Se guarda solo en este navegador.</p>
      </div>
    </>
  );
}

function NuevaFuente() {
  const addSource = useStore((s) => s.addSource);
  const conBd = useStore((s) => Boolean(s.perfil));
  const [f, setF] = useState({ nombre: '', url: '', canal: 'clima', tipo: 'oficial', metodo: 'http_html', freq: 60, queBuscar: '', palabras: '' });
  const [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    await addSource({ ...f, nombre: f.nombre.trim(), url: f.url.trim() });
    setBusy(false);
  };
  return (
    <>
      <Head icon="plus">Añadir fuente</Head>
      <div className="drawer-b">
        <form style={{ display: 'flex', flexDirection: 'column', gap: 12 }} onSubmit={submit}>
          <div className="field"><label htmlFor="nsN">Nombre</label>
            <input className="inp" id="nsN" required placeholder="Por ejemplo: Viceministerio de Defensa Civil" value={f.nombre} onChange={(e) => setF({ ...f, nombre: e.target.value })} />
          </div>
          <div className="field"><label htmlFor="nsU">Dirección web</label>
            <input className="inp" id="nsU" type="url" required placeholder="https://" value={f.url} onChange={(e) => setF({ ...f, url: e.target.value })} />
          </div>
          <div className="field"><label htmlFor="nsC">Canal</label>
            <select id="nsC" value={f.canal} onChange={(e) => setF({ ...f, canal: e.target.value })}>
              {Object.entries(CATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </div>
          <div className="field"><label htmlFor="nsT">Tipo de fuente</label>
            <select id="nsT" value={f.tipo} onChange={(e) => setF({ ...f, tipo: e.target.value })}>
              <option value="oficial">Oficial (gobierno, ministerio)</option>
              <option value="organismo_internacional">Organismo internacional</option>
              <option value="medio">Medio de comunicación</option>
              <option value="no_oficial">Otra (no oficial)</option>
            </select>
          </div>
          <div className="field"><label htmlFor="nsM">Cómo se lee</label>
            <select id="nsM" value={f.metodo} onChange={(e) => setF({ ...f, metodo: e.target.value })}>
              <option value="http_html">Página web</option>
              <option value="rss">RSS</option>
              <option value="google_news_rss">Búsqueda en Google News</option>
            </select>
          </div>
          <div className="field"><label htmlFor="nsF">Comprobar cada</label>
            <select id="nsF" value={f.freq} onChange={(e) => setF({ ...f, freq: +e.target.value })}>
              <option value={30}>30 min</option><option value={60}>1 hora</option><option value={360}>6 horas</option><option value={1440}>1 día</option>
            </select>
          </div>
          <div className="field"><label htmlFor="nsQ">Qué debe buscar AVIA aquí</label>
            <textarea className="inp" id="nsQ" rows={2} placeholder="Por ejemplo: declaratorias de emergencia que afecten a destinos turísticos" value={f.queBuscar} onChange={(e) => setF({ ...f, queBuscar: e.target.value })} />
          </div>
          <div className="field"><label htmlFor="nsP">Palabras clave (separadas por comas)</label>
            <input className="inp" id="nsP" placeholder="emergencia, desastre, inundación" value={f.palabras} onChange={(e) => setF({ ...f, palabras: e.target.value })} />
          </div>
          <button className="btn gold" style={{ alignSelf: 'flex-start' }} disabled={busy}><Icon name="plus" /> {busy ? 'Guardando…' : 'Añadir'}</button>
        </form>
        <p className="note">{conBd
          ? 'Se guarda en la base de datos. AVIA la incluye en su lista de fuentes en la siguiente ronda; hasta entonces aparece como pendiente de la primera comprobación.'
          : `La fuente entra como ${STATE_TXT.UNKNOWN} hasta su primera comprobación. Sin inicio de sesión solo se añade en este navegador.`}</p>
      </div>
    </>
  );
}

export function Drawer() {
  const drawer = useStore((s) => s.drawer);
  const closeDrawer = useStore((s) => s.closeDrawer);
  const ref = useRef<HTMLElement>(null);
  const lastFocus = useRef<Element | null>(null);
  const kind = drawer?.kind;

  useEffect(() => {
    if (!kind) {
      (lastFocus.current as HTMLElement | null)?.focus?.();
      return;
    }
    lastFocus.current = document.activeElement;
    ref.current?.querySelector<HTMLElement>('button,input,textarea')?.focus();
  }, [kind]);

  if (!drawer) return null;
  let body: ReactNode = null;
  switch (drawer.kind) {
    case 'fuente': body = <FuenteDetalle id={drawer.id} />; break;
    case 'senal': body = <SenalDetalle key={drawer.id} id={drawer.id} />; break;
    case 'catalogo': body = <Catalogo />; break;
    case 'a11y': body = <A11y />; break;
    case 'guardar': body = <GuardarTablero />; break;
    case 'nueva-fuente': body = <NuevaFuente />; break;
    case 'equipo': body = <Equipo />; break;
    case 'mi-clave': body = <MiClave />; break;
  }
  return (
    <>
      <div className="scrim" onClick={closeDrawer} />
      <aside ref={ref} className="drawer" role="dialog" aria-modal="true" aria-label="Detalle">{body}</aside>
    </>
  );
}
