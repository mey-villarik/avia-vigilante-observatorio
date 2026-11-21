// Alerta de cambio: una noticia nueva cambia una señal que ya existía («el ciclón se desvió»).
// Sale como ventana flotante con alarma sonora, y queda marcada junto al botón «Eventos» hasta que la
// persona la mira. La interpretación de AVIA llega después; la ventana no la espera.
import { useEffect, useRef, useState } from 'react';
import { useStore } from '../store';
import { useEventos, alertaPendiente, eventosSinVer } from '../services/eventos';
import { CAMBIOS_MS, cambioPendiente, sinVer, TIPO_CAMBIO_TXT, useCambios, type Cambio } from '../services/cambios';
import { Icon } from './Icon';
import { cerrarFlotantes } from '../lib/flotantes';

const TZ = 'America/La_Paz';
const hora = (iso: string) => new Date(iso).toLocaleString('es-BO', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const dia = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString('es-BO', { timeZone: 'UTC', weekday: 'short', day: 'numeric', month: 'short' });
const CAMPO_TXT: Record<string, string> = {
  fecha_evento_inicio: 'Empieza', fecha_evento_fin: 'Termina', plazo_hasta: 'Plazo', naturaleza: 'Tipo', prioridad: 'Prioridad',
};

/** Pide los cambios cada 30 s mientras hay sesión de analista o administrador, y marca la pestaña si hay sin ver */
export function useCambiosNoticias() {
  const perfil = useStore((s) => s.perfil);
  const staff = perfil != null && perfil.rol !== 'visor';
  const pendientes = useCambios((s) => sinVer(s.cambios));
  const eventos = useEventos((s) => eventosSinVer(s.eventos));
  useEffect(() => {
    if (!staff) { useCambios.setState({ cambios: [] }); return; }
    void useCambios.getState().cargar();
    const t = setInterval(() => void useCambios.getState().cargar(), CAMBIOS_MS);
    // al volver a la pestaña, se pide al momento
    const vis = () => { if (document.visibilityState === 'visible') void useCambios.getState().cargar(); };
    document.addEventListener('visibilitychange', vis);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', vis); };
  }, [staff]);
  // la pestaña del navegador también avisa: «(2) Cambios · ORBITA», «(1) Evento · ORBITA», «(3) Avisos · ORBITA»
  useEffect(() => {
    const base = document.title.replace(/^\(\d+\) (Cambios?|Eventos?|Avisos) · /, '');
    const n = pendientes + eventos;
    const que = pendientes && eventos ? 'Avisos' : pendientes ? (n === 1 ? 'Cambio' : 'Cambios') : (n === 1 ? 'Evento' : 'Eventos');
    document.title = n > 0 ? `(${n}) ${que} · ${base}` : base;
  }, [pendientes, eventos]);
}

function AntesAhora({ c }: { c: Cambio }) {
  const campos = Object.entries(c.campos ?? {});
  const val = (v: string) => (/^\d{4}-\d{2}-\d{2}$/.test(v) ? dia(v) : v);
  // si lo vio la base, los datos exactos; si lo leyó el clasificador o AVIA, sus frases
  const datos = campos.length > 0 && c.origen === 'datos';
  const antes = datos ? campos.map(([k, v]) => `${CAMPO_TXT[k] ?? k}: ${val(v.antes)}`) : [c.antes ?? c.senal.titulo];
  const ahora = datos ? campos.map(([k, v]) => `${CAMPO_TXT[k] ?? k}: ${val(v.ahora)}`) : [c.ahora];
  return (
    <div className="cam-aa">
      <div className="cam-antes"><span className="cam-et">Antes</span>{antes.map((t) => <p key={t}>{t}</p>)}</div>
      <div className="cam-ahora"><span className="cam-et">Ahora</span>{ahora.map((t) => <p key={t}>{t}</p>)}</div>
    </div>
  );
}

function Ficha({ c, onSenal }: { c: Cambio; onSenal: (codigo: string) => void }) {
  const i = c.interpretacion;
  return (
    <div className="evc-ficha">
      <div className="evc-meta">
        <span className={`tag cam-tipo k-${c.tipo}`}>{TIPO_CAMBIO_TXT[c.tipo]}</span>
        <span className={`tag p-${c.importancia}`}>Importancia {c.importancia}</span>
        {c.senal.departamentos?.length ? <span className="tag"><Icon name="mapa" /> {c.senal.departamentos.join(', ')}</span> : null}
        <span className="tag"><Icon name="clock" /> {hora(c.detectado)}</span>
        {c.repeticiones > 0 && <span className="tag" title="Otras noticias que cuentan el mismo cambio">+{c.repeticiones} fuentes lo repiten</span>}
      </div>

      {c.publicada && (
        <p className="cam-pub" role="note"><Icon name="riesgo" /><span>Esta señal está <b>publicada</b>: la alerta pública todavía dice lo de antes. Revísala.</span></p>
      )}

      <AntesAhora c={c} />

      {i ? (
        <>
          <p className="evc-sig">{i.significado}</p>
          <div className="evc-bloques">
            {i.a_quien_afecta && i.a_quien_afecta.length > 0 && (
              <section>
                <h4>A quién afecta</h4>
                <ul>{i.a_quien_afecta.map((a) => <li key={a}>{a}</li>)}</ul>
              </section>
            )}
            <section className="evc-rec">
              <h4>Qué se recomienda</h4>
              <p><b>{i.recomendacion.accion}</b></p>
              <p className="muted">Para {i.recomendacion.para_quien}{i.recomendacion.cuando ? ` · ${i.recomendacion.cuando}` : ''}</p>
              {i.recomendacion.verificar_con && <p className="muted">Verificar con: {i.recomendacion.verificar_con}</p>}
            </section>
          </div>
          {i.falta_saber && i.falta_saber.length > 0 && <p className="evc-falta"><b>Falta saber:</b> {i.falta_saber.join(' · ')}</p>}
        </>
      ) : (
        <p className="evc-espera">AVIA está interpretando este cambio. Mientras tanto, compruébalo en las noticias de abajo.</p>
      )}

      <section>
        <h4>Señal</h4>
        <ul className="evc-senales">
          <li>
            <span className={`dot n-${c.senal.naturaleza}`} aria-hidden="true" />
            <button className="linklike" onClick={() => onSenal(c.senal.codigo)}>{c.senal.codigo}</button>
            <span>{c.senal.titulo}</span>
            <span className="tag">{c.senal.estado}</span>
          </li>
          {c.senal_nueva && (
            <li>
              <span className={`dot n-${c.senal_nueva.naturaleza}`} aria-hidden="true" />
              <button className="linklike" onClick={() => onSenal(c.senal_nueva!.codigo)}>{c.senal_nueva.codigo}</button>
              <span>{c.senal_nueva.titulo}</span>
              <span className="tag">la noticia nueva</span>
            </li>
          )}
        </ul>
        {c.eventos && c.eventos.length > 0 && (
          <p className="muted small">Forma parte de {c.eventos.join(', ')}: AVIA vuelve a interpretar ese evento con el dato nuevo.</p>
        )}
      </section>

      {c.noticias.length > 0 && (
        <section>
          <h4>Noticias que traen el cambio</h4>
          <ul className="cam-noticias">
            {c.noticias.map((n) => (
              <li key={n.id}>
                {n.url ? <a href={n.url} target="_blank" rel="noreferrer">{n.titulo}</a> : <span>{n.titulo}</span>}
                <small className="muted"> · {n.fuente}{n.fuente_tipo === 'oficial' ? ' (oficial)' : ''}{n.publicado_en ? ` · ${hora(n.publicado_en)}` : ''}</small>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}

function Descartar({ codigo, onHecho }: { codigo: string; onHecho: () => void }) {
  const [abierto, setAbierto] = useState(false);
  const [motivo, setMotivo] = useState('');
  const [error, setError] = useState<string | null>(null);
  const descartar = useCambios((s) => s.descartar);
  if (!abierto) return <button className="btn ghost" onClick={() => setAbierto(true)}>No es un cambio…</button>;
  return (
    <form className="evc-desc" onSubmit={(ev) => {
      ev.preventDefault();
      descartar(codigo, motivo).then(onHecho, (e: Error) => setError(e.message));
    }}>
      <input className="inp" autoFocus required placeholder="Motivo (p. ej. «es otra feria», «la fecha está mal leída»)" value={motivo} onChange={(e) => setMotivo(e.target.value)} />
      <button className="btn danger" type="submit" disabled={!motivo.trim()}>Descartar cambio</button>
      <button className="btn ghost" type="button" onClick={() => setAbierto(false)}>Cancelar</button>
      {error && <p className="evc-error" role="alert">{error}</p>}
    </form>
  );
}

const titulo = (c: Cambio) => c.titular ?? `${TIPO_CAMBIO_TXT[c.tipo]}: ${c.senal.titulo}`;

/** Ventana flotante: sale sola con cada cambio sin ver (si no hay antes una alerta de evento) */
export function AlertaCambio() {
  const cambios = useCambios((s) => s.cambios);
  const eventos = useEventos((s) => s.eventos);
  const posEventos = useEventos((s) => s.pospuestos);
  const pospuestos = useCambios((s) => s.pospuestos);
  const { marcarVisto } = useCambios.getState();
  const openDrawer = useStore((s) => s.openDrawer);
  const c = alertaPendiente(eventos, posEventos) ? null : cambioPendiente(cambios, pospuestos);
  const boton = useRef<HTMLButtonElement>(null);
  useEffect(() => { if (c) boton.current?.focus(); }, [c?.codigo]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!c) return null;
  const quedan = cambios.filter((x) => x.alerta && !x.visto && !pospuestos.includes(x.codigo)).length - 1;
  const verSenal = (codigo: string) => { void marcarVisto(c.codigo); openDrawer({ kind: 'senal', id: codigo }); };
  return (
    <>
      {/* clic fuera o Escape: se cierran todas las ventanas flotantes y queda «sin ver» en «Cambios» */}
      <div className="scrim evc-scrim" onClick={cerrarFlotantes} title="Cerrar (queda sin ver en «Cambios»)" />
      <div className="evc-modal cam-modal" role="alertdialog" aria-modal="true" aria-labelledby="cam-t" aria-describedby="cam-d"
        onKeyDown={(ev) => { if (ev.key === 'Escape') cerrarFlotantes(); }}>
        <div className={`evc-h cam-h i-${c.importancia}`}>
          <Icon name="actividad" />
          <span>Cambio en una noticia · {c.codigo}</span>
          {quedan > 0 && <span className="evc-mas">+{quedan} más</span>}
          <button className="icon-btn" aria-label="Cerrar todas las ventanas" title="Cerrar (queda sin ver en «Cambios»)" onClick={cerrarFlotantes}><Icon name="close" /></button>
        </div>
        <div className="evc-b">
          <h2 id="cam-t">{titulo(c)}</h2>
          <div id="cam-d"><Ficha c={c} onSenal={verSenal} /></div>
        </div>
        <div className="evc-f">
          <Descartar codigo={c.codigo} onHecho={() => undefined} />
          <button className="btn ghost" onClick={() => verSenal(c.senal.codigo)}>Ver la señal</button>
          <button ref={boton} className="btn primary" onClick={() => void marcarVisto(c.codigo)}><Icon name="check" /> Entendido</button>
        </div>
      </div>
    </>
  );
}

/** Lista de cambios recientes (botón «Cambios» junto a «Eventos») */
export function ListaCambios() {
  const abierta = useCambios((s) => s.listaAbierta);
  const cambios = useCambios((s) => s.cambios);
  const sonido = useCambios((s) => s.sonido);
  const error = useCambios((s) => s.error);
  const { setListaAbierta, setSonido, marcarVisto } = useCambios.getState();
  const openDrawer = useStore((s) => s.openDrawer);
  const [sel, setSel] = useState<string | null>(null);
  useEffect(() => { if (!abierta) setSel(null); }, [abierta]);
  if (!abierta) return null;
  const cerrar = () => { setListaAbierta(false); setSel(null); };
  const actual = cambios.find((c) => c.codigo === sel) ?? null;
  const pendientes = sinVer(cambios);
  return (
    <>
      <div className="scrim" onClick={cerrarFlotantes} />
      <div className="evc-modal ancho" role="dialog" aria-modal="true" aria-labelledby="cam-l" onKeyDown={(ev) => { if (ev.key === 'Escape') cerrarFlotantes(); }}>
        <div className="evc-h">
          <Icon name="actividad" />
          <span id="cam-l">Cambios en noticias ya recogidas</span>
          <button className="icon-btn" aria-label="Cerrar" onClick={cerrar}><Icon name="close" /></button>
        </div>
        <div className="evc-b">
          <div className="cam-barra">
            <label className="evc-sonido"><input type="checkbox" checked={sonido} onChange={(e) => setSonido(e.target.checked)} /> Alarma sonora al llegar un cambio</label>
            {pendientes > 0 && <button className="btn ghost" onClick={() => void marcarVisto(null)}><Icon name="check" /> Marcar todo como visto</button>}
          </div>
          {error && <p className="evc-error" role="alert">{error}</p>}
          {cambios.length === 0 && <p className="muted">No hay cambios de las últimas 24 horas. Aparecen cuando una noticia nueva cambia una señal que ya existía: otra fecha, una cancelación, un desvío, el fin de una alerta…</p>}
          {cambios.length > 0 && !actual && <p className="muted small">Cada cambio se ve aquí 24 horas desde que se detecta. Después queda guardado y AVIA lo sigue teniendo en cuenta.</p>}
          {actual ? (
            <>
              <button className="linklike" onClick={() => setSel(null)}>← Todos los cambios</button>
              <h2>{titulo(actual)}</h2>
              <Ficha c={actual} onSenal={(s) => { void marcarVisto(actual.codigo); cerrar(); openDrawer({ kind: 'senal', id: s }); }} />
              <div className="evc-f"><Descartar codigo={actual.codigo} onHecho={() => setSel(null)} /></div>
            </>
          ) : (
            <ul className="evc-lista">
              {cambios.map((c) => (
                <li key={c.codigo} className={c.visto ? '' : 'cam-nuevo'}>
                  <button onClick={() => { setSel(c.codigo); if (!c.visto) void marcarVisto(c.codigo); }}>
                    <span className={`tag p-${c.importancia}`}>{c.importancia}</span>
                    <span className="evc-lt"><b>{!c.visto && <span className="cam-punto" aria-label="sin ver" />}{titulo(c)}</b>
                      <small>{c.codigo} · {TIPO_CAMBIO_TXT[c.tipo]} · {c.senal.codigo} · {hora(c.detectado)}{c.publicada ? ' · publicada' : ''}{c.esperando_hermes ? ' · AVIA interpretando' : ''}</small></span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </>
  );
}

/** Indicador junto a «Eventos»: se queda encendido mientras haya cambios sin ver */
export function BotonCambios() {
  const cambios = useCambios((s) => s.cambios);
  const disponible = useCambios((s) => s.disponible);
  const perfil = useStore((s) => s.perfil);
  if (!perfil || perfil.rol === 'visor' || !disponible) return null;
  const pendientes = sinVer(cambios);
  const altas = cambios.some((c) => !c.visto && c.importancia === 'alta');
  return (
    <button className={`pill cam-pill ${pendientes ? (altas ? 'st-CRIT cam-vivo' : 'st-WARN cam-vivo') : 'st-UNKNOWN'}`}
      title={pendientes ? `${pendientes} ${pendientes === 1 ? 'cambio' : 'cambios'} sin ver en noticias ya recogidas` : 'Cambios en noticias ya recogidas'}
      aria-label={pendientes ? `Cambios: ${pendientes} sin ver` : 'Cambios'}
      onClick={() => useCambios.getState().setListaAbierta(true)}>
      <span className="d" /><span>Cambios{pendientes ? ` ${pendientes}` : ''}</span>
    </button>
  );
}
