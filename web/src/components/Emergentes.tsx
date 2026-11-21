// Alerta de evento: en cuanto la base detecta un evento compuesto (o le entran señales nuevas), salta
// una ventana flotante con alarma sonora. La interpretación de AVIA (qué pasa, a quién afecta, qué hacer)
// aparece en la misma ventana cuando llega. El evento se queda en la lista de Eventos 24 h desde que se
// detectó; después sigue guardado en la base pero ya no se muestra aquí (db/generico/34_eventos_dinamicos.sql).
import { useEffect, useRef, useState } from 'react';
import { useStore } from '../store';
import { abierto, alertaPendiente, claveAlerta, EVENTOS_MS, eventosSinVer, TIPO_TXT, useEventos, type EventoCompuesto } from '../services/eventos';
import { cerrarFlotantes } from '../lib/flotantes';
import { Icon } from './Icon';

const TZ = 'America/La_Paz';
const dia = (iso: string) => new Date(iso).toLocaleString('es-BO', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

/** «hace 5 min», «hace 3 h» */
function hace(iso?: string): string {
  if (!iso) return '';
  const min = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000));
  return min < 1 ? 'ahora mismo' : min < 60 ? `hace ${min} min` : `hace ${Math.round(min / 60)} h`;
}

function ventana(e: EventoCompuesto): string {
  const ini = Date.parse(e.ventana_inicio);
  const desde = ini <= Date.now() ? 'en curso' : `desde ${dia(e.ventana_inicio)}`;
  return `${desde} · hasta ${dia(e.ventana_fin)}`;
}

/** Pide los eventos cada 30 s mientras hay sesión de analista o administrador, y al volver a la pestaña */
export function useEventosEmergentes() {
  const perfil = useStore((s) => s.perfil);
  const staff = perfil != null && perfil.rol !== 'visor';
  useEffect(() => {
    if (!staff) { useEventos.setState({ eventos: [] }); return; }
    void useEventos.getState().cargar();
    const t = setInterval(() => void useEventos.getState().cargar(), EVENTOS_MS);
    const vis = () => { if (document.visibilityState === 'visible') void useEventos.getState().cargar(); };
    document.addEventListener('visibilitychange', vis);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', vis); };
  }, [staff]);
}

function Ficha({ e, onSenal }: { e: EventoCompuesto; onSenal: (codigo: string) => void }) {
  const i = e.interpretacion;
  return (
    <div className="evc-ficha">
      <div className="evc-meta">
        <span className={`tag evc-tipo t-${e.tipo}`}>{TIPO_TXT[e.tipo]}</span>
        <span className="tag"><Icon name="mapa" /> {e.territorio}</span>
        <span className="tag"><Icon name="clock" /> {ventana(e)}</span>
        <span className={`tag p-${e.prioridad}`} title={e.calculo?.regla ?? ''}>Prioridad {e.prioridad} · {Math.round(e.puntaje)}/100</span>
      </div>

      {i ? (
        <>
          <p className="evc-sig">{i.significado}</p>
          <div className="evc-bloques">
            <section>
              <h4>A quién afecta</h4>
              <ul>{i.a_quien_afecta.map((a) => <li key={a}>{a}</li>)}</ul>
              {i.impacto && <p className="evc-imp"><b>Impacto {i.impacto.nivel}:</b> {i.impacto.motivo}</p>}
            </section>
            <section className="evc-rec">
              <h4>Qué se recomienda</h4>
              <p><b>{i.recomendacion.accion}</b></p>
              <p className="muted">Para {i.recomendacion.para_quien}{i.recomendacion.cuando ? ` · ${i.recomendacion.cuando}` : ''}</p>
              {i.recomendacion.verificar_con && <p className="muted">Verificar con: {i.recomendacion.verificar_con}</p>}
            </section>
          </div>
          {i.escenarios && i.escenarios.length > 0 && (
            <section>
              <h4>Escenarios</h4>
              <ul>{i.escenarios.map((s) => <li key={s.si}>Si {s.si}, entonces {s.entonces}.</li>)}</ul>
            </section>
          )}
          {i.falta_saber && i.falta_saber.length > 0 && (
            <p className="evc-falta"><b>Falta saber:</b> {i.falta_saber.join(' · ')}</p>
          )}
          {e.prioridad_hermes && e.prioridad_hermes !== e.prioridad_calculada && i.prioridad_motivo && (
            <p className="muted small">AVIA cambió la prioridad calculada ({e.prioridad_calculada}) a {e.prioridad_hermes}: {i.prioridad_motivo}</p>
          )}
        </>
      ) : (
        <p className="evc-espera">AVIA aún no ha interpretado este evento. Abajo están las señales que coinciden.</p>
      )}

      <section>
        <h4>Señales que lo forman ({e.senales.length})</h4>
        <ul className="evc-senales">
          {e.senales.map((s) => (
            <li key={s.codigo}>
              <span className={`dot n-${s.naturaleza}`} aria-hidden="true" />
              <button className="linklike" onClick={() => onSenal(s.codigo)}>{s.codigo}</button>
              <span>{s.titulo}</span>
              {s.certeza?.nivel && <span className="tag">{s.certeza.nivel}</span>}
              {s.nacional && <span className="tag">nacional</span>}
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

function Descartar({ codigo, onHecho }: { codigo: string; onHecho: () => void }) {
  const [abierto, setAbierto] = useState(false);
  const [motivo, setMotivo] = useState('');
  const [error, setError] = useState<string | null>(null);
  const descartar = useEventos((s) => s.descartar);
  if (!abierto) return <button className="btn ghost" onClick={() => setAbierto(true)}>No es relevante…</button>;
  return (
    <form className="evc-desc" onSubmit={(ev) => {
      ev.preventDefault();
      descartar(codigo, motivo).then(onHecho, (e: Error) => setError(e.message));
    }}>
      <input className="inp" autoFocus required placeholder="Motivo (p. ej. «la huelga ya se levantó»)" value={motivo} onChange={(e) => setMotivo(e.target.value)} />
      <button className="btn danger" type="submit" disabled={!motivo.trim()}>Descartar evento</button>
      <button className="btn ghost" type="button" onClick={() => setAbierto(false)}>Cancelar</button>
      {error && <p className="evc-error" role="alert">{error}</p>}
    </form>
  );
}

/** Ventana de alerta: sale sola con la primera alerta sin ver */
export function AlertaEmergente() {
  const eventos = useEventos((s) => s.eventos);
  const pospuestos = useEventos((s) => s.pospuestos);
  const { marcarVisto } = useEventos.getState();
  const openDrawer = useStore((s) => s.openDrawer);
  const e = alertaPendiente(eventos, pospuestos);
  const boton = useRef<HTMLButtonElement>(null);
  useEffect(() => { if (e) boton.current?.focus(); }, [e?.codigo, e?.version]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!e) return null;
  const quedan = eventos.filter((x) => x.alerta && !x.visto && !pospuestos.includes(claveAlerta(x))).length - 1;
  const verSenal = (codigo: string) => { void marcarVisto(e.codigo); openDrawer({ kind: 'senal', id: codigo }); };
  const verEnLista = () => { void marcarVisto(e.codigo); useEventos.getState().setListaAbierta(true, e.codigo); };
  // «nuevo» llega con el 34; sin él, la versión dice si es una actualización
  const nuevo = e.nuevo ?? e.version === 1;
  return (
    <>
      {/* clic fuera o Escape: se cierran todas las ventanas flotantes y el evento queda «sin ver» en «Eventos» */}
      <div className="scrim evc-scrim" onClick={cerrarFlotantes} title="Cerrar (queda sin ver en «Eventos»)" />
      <div className="evc-modal cam-modal" role="alertdialog" aria-modal="true" aria-labelledby="evc-t" aria-describedby="evc-d"
        onKeyDown={(ev) => { if (ev.key === 'Escape') cerrarFlotantes(); }}>
        <div className={`evc-h t-${e.tipo}`}>
          <Icon name="riesgo" />
          <span>{nuevo ? 'Evento nuevo detectado' : `Evento actualizado (v${e.version}): entraron señales nuevas`} · {e.codigo} · {hace(e.version_en ?? e.detectado)}</span>
          {quedan > 0 && <span className="evc-mas">+{quedan} más</span>}
          <button className="icon-btn" aria-label="Cerrar todas las ventanas" title="Cerrar (queda sin ver en «Eventos»)" onClick={cerrarFlotantes}><Icon name="close" /></button>
        </div>
        <div className="evc-b">
          <h2 id="evc-t">{e.titular ?? `${TIPO_TXT[e.tipo]} en ${e.territorio}: ${e.senales.map((s) => s.titulo).slice(0, 2).join(' + ')}`}</h2>
          <div id="evc-d"><Ficha e={e} onSenal={verSenal} /></div>
        </div>
        <div className="evc-f">
          <Descartar codigo={e.codigo} onHecho={() => undefined} />
          <button className="btn ghost" onClick={verEnLista}>Ver en Eventos</button>
          <button ref={boton} className="btn primary" onClick={() => void marcarVisto(e.codigo)}><Icon name="check" /> Entendido</button>
        </div>
      </div>
    </>
  );
}

/** Lista de eventos de las últimas 24 h (botón «Eventos» de la barra superior) */
export function ListaEventos() {
  const abierta = useEventos((s) => s.listaAbierta);
  const sel = useEventos((s) => s.listaSel);
  const eventos = useEventos((s) => s.eventos);
  const cerrados = useEventos((s) => s.cerrados);
  const sonido = useEventos((s) => s.sonido);
  const error = useEventos((s) => s.error);
  const { setListaAbierta, setSonido, marcarVisto } = useEventos.getState();
  const setSel = (codigo: string | null) => useEventos.setState({ listaSel: codigo });
  const openDrawer = useStore((s) => s.openDrawer);
  if (!abierta) return null;
  const cerrar = () => setListaAbierta(false);
  const actual = eventos.find((e) => e.codigo === sel) ?? cerrados.find((e) => e.codigo === sel) ?? null;
  const pendientes = eventosSinVer(eventos);
  return (
    <>
      <div className="scrim" onClick={cerrarFlotantes} />
      <div className="evc-modal ancho" role="dialog" aria-modal="true" aria-labelledby="evc-l" onKeyDown={(ev) => { if (ev.key === 'Escape') cerrarFlotantes(); }}>
        <div className="evc-h">
          <Icon name="cadena" />
          <span id="evc-l">Eventos: señales que coinciden en lugar y fecha</span>
          <button className="icon-btn" aria-label="Cerrar" onClick={cerrar}><Icon name="close" /></button>
        </div>
        <div className="evc-b">
          <div className="cam-barra">
            <label className="evc-sonido"><input type="checkbox" checked={sonido} onChange={(e) => setSonido(e.target.checked)} /> Alarma sonora al detectar un evento</label>
            {pendientes > 0 && <button className="btn ghost" onClick={() => void marcarVisto(null)}><Icon name="check" /> Marcar todo como visto</button>}
          </div>
          {error && <p className="evc-error" role="alert">{error}</p>}
          {eventos.length === 0 && !actual && <p className="muted">No hay eventos abiertos de las últimas 24 horas. Aparecen cuando dos o más señales activas coinciden en el mismo departamento y en las mismas fechas, y saltan con alarma en cuanto se detectan.</p>}
          {eventos.length > 0 && !actual && <p className="muted small">Cada evento se ve aquí 24 horas desde que se detecta (o desde que le entran señales nuevas). Después queda guardado y AVIA lo sigue teniendo en cuenta.</p>}
          {actual ? (
            <>
              <button className="linklike" onClick={() => setSel(null)}>← Todos los eventos</button>
              <h2>{actual.titular ?? `${TIPO_TXT[actual.tipo]} en ${actual.territorio}`}</h2>
              {!abierto(actual) && <p className="evc-cerrado" role="note"><b>{cierreTxt(actual)}</b>{actual.motivo_cierre ? `: ${actual.motivo_cierre}` : ''}</p>}
              <Ficha e={actual} onSenal={(c) => { cerrar(); openDrawer({ kind: 'senal', id: c }); }} />
              {abierto(actual) && <div className="evc-f"><Descartar codigo={actual.codigo} onHecho={() => setSel(null)} /></div>}
            </>
          ) : (
            <ul className="evc-lista">
              {eventos.map((e) => (
                <li key={e.codigo} className={e.visto ? '' : 'cam-nuevo'}>
                  <button onClick={() => { setSel(e.codigo); if (!e.visto) void marcarVisto(e.codigo); }}>
                    <span className={`tag p-${e.prioridad}`}>{e.prioridad}</span>
                    <span className="evc-lt"><b>{!e.visto && <span className="cam-punto" aria-label="sin ver" />}{e.titular ?? `${TIPO_TXT[e.tipo]} en ${e.territorio}`}</b>
                      <small>{e.codigo} · {TIPO_TXT[e.tipo]} · {e.senales.length} señales · detectado {hace(e.version_en ?? e.detectado)}{e.version > 1 ? ` (v${e.version})` : ''} · {ventana(e)}{e.esperando_hermes ? ' · AVIA interpretando' : ''}</small></span>
                  </button>
                </li>
              ))}
            </ul>
          )}
          {!actual && cerrados.length > 0 && (
            <details className="evc-cerrados">
              <summary>Cerrados o descartados en las últimas 24 h ({cerrados.length})</summary>
              <p className="muted small">No suenan ni cuentan como nuevos. Se cierran solos cuando sus señales dejan de coincidir en fechas, caducan o se descartan; se descartan cuando AVIA o un analista dicen que no son relevantes.</p>
              <ul className="evc-lista">
                {cerrados.map((e) => (
                  <li key={e.codigo}>
                    <button onClick={() => setSel(e.codigo)}>
                      <span className="tag">{e.estado}</span>
                      <span className="evc-lt"><b>{e.titular ?? `${TIPO_TXT[e.tipo]} en ${e.territorio}`}</b>
                        <small>{e.codigo} · {cierreTxt(e)}{e.motivo_cierre ? `: ${e.motivo_cierre}` : ''} · detectado {hace(e.version_en ?? e.detectado)}</small></span>
                    </button>
                  </li>
                ))}
              </ul>
            </details>
          )}
        </div>
      </div>
    </>
  );
}

/** «Cerrado solo» o «Descartado por AVIA / por un analista» */
function cierreTxt(e: EventoCompuesto): string {
  if (e.estado === 'cerrado') return 'Cerrado solo';
  const quien = (e.descartado_por ?? '').toLowerCase();
  return quien === 'hermes' || quien === 'avia' ? 'Descartado por AVIA' : quien ? `Descartado por ${e.descartado_por}` : 'Descartado';
}
