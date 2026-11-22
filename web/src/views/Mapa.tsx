// Vista Mapa: Bolivia por departamentos. Cada departamento se colorea según lo que pesa más
// (oportunidades, riesgos o mixtas) y su intensidad según cuántas señales tiene. Al tocar uno se abre
// a la derecha su resumen: señales, oportunidades, riesgos, eventos, cambios, noticias y destinos.
// Todo sale de lo que el panel ya tiene cargado (señales, fichas de oportunidad, eventos y cambios):
// no hace falta SQL nuevo.
import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type MouseEvent } from 'react';
import { CATS, DEPS, STL, catName } from '../data/demo';
import { DEPARTAMENTOS_GEO, DESTINOS_GEO, MAPA_H, MAPA_W, MAPA_X0, TITICACA, VECINOS } from '../data/mapaBolivia';
import { activeSignals, useStore } from '../store';
import { useEventos, TIPO_TXT } from '../services/eventos';
import { useCambios, TIPO_CAMBIO_TXT } from '../services/cambios';
import { useChat } from '../services/chat';
import { Icon } from '../components/Icon';
import { CertezaTag, Empty, AccionTag } from '../components/common';
import { NACIONAL, regionesDeSenal, resumenRegion, tonoDe, type ResumenRegion } from '../lib/regiones';
import { ago, esReciente, norm } from '../lib/util';
import type { Senal } from '../types';
import { enBolivia } from '../lib/hora';
import { ESTADO_COLOR, ESTADO_TXT, nacionalesConPeso, semaforoDepartamentos, type SemaforoDep } from '../lib/direccion';

type Mostrar = 'semaforo' | 'todo' | 'oportunidad' | 'riesgo';

const fechaCorta = (f?: string | null) => {
  if (!f) return '';
  return enBolivia(f, 'diaCorto');
};

/** todos los resúmenes por departamento con los filtros de la vista */
function useResumenes(mostrar: Mostrar, periodo: 'recientes' | 'todo') {
  const senales = useStore((s) => s.senales);
  const fichas = useStore((s) => s.oportunidades);
  const eventos = useEventos((s) => s.eventos);
  const cambios = useCambios((s) => s.cambios);
  return useMemo(() => {
    let l = activeSignals(senales);
    if (periodo === 'recientes') l = l.filter((s) => esReciente(s));
    if (mostrar === 'oportunidad' || mostrar === 'riesgo') l = l.filter((s) => s.naturaleza === mostrar || s.naturaleza === 'mixta');
    const por: Record<string, ResumenRegion> = {};
    DEPS.forEach((d) => { por[d] = resumenRegion(d, l, fichas, eventos, cambios); });
    const nacionales = l.filter((s) => regionesDeSenal(s).includes(NACIONAL));
    const sinLugar = l.filter((s) => !regionesDeSenal(s).length);
    return { por, total: l, nacionales, sinLugar };
  }, [senales, fichas, eventos, cambios, mostrar, periodo]);
}

// ───────── Mapa SVG (también lo usa el panel «Mapa» del Panorama) ─────────

export function MapaBolivia({ por, sel, onSel, compacto = false, destinosActivos = [], semaforo }: {
  por: Record<string, ResumenRegion>;
  sel: string | null;
  onSel: (d: string) => void;
  compacto?: boolean;
  destinosActivos?: string[];
  /** con semáforo, cada departamento va en verde/amarillo/rojo con su motivo (vista Dirección) */
  semaforo?: Record<string, SemaforoDep>;
}) {
  const [hover, setHover] = useState<{ dep: string; x: number; y: number } | null>(null);
  const caja = useRef<HTMLDivElement>(null);
  const max = Math.max(1, ...DEPS.map((d) => por[d]?.senales.length ?? 0));
  const activos = new Set(destinosActivos.map(norm));
  const destinos = compacto ? [] : DESTINOS_GEO.filter((d) => activos.has(norm(d.nombre)));
  // el elegido se dibuja al final para que su borde quede encima
  const orden = [...DEPARTAMENTOS_GEO].sort((a, b) => (a.nombre === sel ? 1 : 0) - (b.nombre === sel ? 1 : 0));

  const mover = (e: MouseEvent, dep: string) => {
    const r = caja.current?.getBoundingClientRect();
    if (r) setHover({ dep, x: e.clientX - r.left, y: e.clientY - r.top });
  };
  const tecla = (e: KeyboardEvent, dep: string) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSel(dep); }
  };
  const h = hover ? por[hover.dep] : null;

  return (
    <div className={`mp ${compacto ? 'mp-compacto' : ''} ${sel ? 'mp-con-sel' : ''}`} ref={caja} onMouseLeave={() => setHover(null)}>
      <svg viewBox={`${MAPA_X0} -10 ${MAPA_W - MAPA_X0 + 10} ${MAPA_H + 20}`} role="group" aria-label="Mapa de Bolivia por departamentos">
        <defs>
          <filter id="mpSombra" x="-10%" y="-10%" width="120%" height="120%">
            <feDropShadow dx="0" dy="6" stdDeviation="10" floodColor="#000" floodOpacity=".28" />
          </filter>
        </defs>
        {!compacto && VECINOS.map((v) => <text key={v.nombre} className="mp-vecino" x={v.p[0]} y={v.p[1]}>{v.nombre}</text>)}
        <g filter="url(#mpSombra)">
          {orden.map((g) => {
            const r = por[g.nombre];
            const n = r?.senales.length ?? 0;
            const sem = semaforo?.[g.nombre];
            const tono = sem ? `sem-${ESTADO_COLOR[sem.estado]}` : r ? tonoDe(r) : 'vacio';
            const k = n ? Math.round(22 + 58 * (n / max)) : 0;
            const etiqueta = sem
              ? `${g.nombre}: ${ESTADO_TXT[sem.estado]}. ${sem.motivo}${sem.recomendacion ? `. Se recomienda: ${sem.recomendacion}` : ''}`
              : `${g.nombre}: ${r?.oportunidades.length ?? 0} oportunidades, ${r?.riesgos.length ?? 0} riesgos, ${r?.mixtas.length ?? 0} mixtas, ${r?.eventos.length ?? 0} eventos`;
            return (
              <path key={g.nombre} d={g.d}
                className={`mp-dep t-${tono} ${sel === g.nombre ? 'on' : ''} ${hover?.dep === g.nombre ? 'hov' : ''}`}
                style={{ '--k': `${k}%` } as CSSProperties}
                role="button" tabIndex={0} aria-pressed={sel === g.nombre} aria-label={etiqueta}
                onClick={() => onSel(g.nombre)} onKeyDown={(e) => tecla(e, g.nombre)}
                onMouseMove={(e) => mover(e, g.nombre)} />
            );
          })}
        </g>
        <path d={TITICACA} className="mp-lago" aria-hidden="true" />
        {!compacto && <text className="mp-lago-t" x={-30} y={474} aria-hidden="true">Lago Titicaca</text>}
        {!compacto && DEPARTAMENTOS_GEO.map((g) => (
          <g key={'c' + g.nombre} className="mp-ciudad" aria-hidden="true">
            <circle cx={g.ciudad[0]} cy={g.ciudad[1]} r={g.nombre === 'Chuquisaca' || g.nombre === 'La Paz' ? 5.5 : 4} />
            {/* el nombre solo si no es el del departamento, para no repetirlo junto a la etiqueta */}
            {!g.capital.startsWith(g.nombre) && <text x={g.ciudad[0] + 9} y={g.ciudad[1] + 4}>{g.capital}</text>}
            <title>{g.capital}</title>
          </g>
        ))}
        {destinos.map((d) => (
          <g key={'d' + d.nombre} className="mp-destino" aria-hidden="true">
            <rect x={d.p[0] - 5} y={d.p[1] - 5} width="10" height="10" transform={`rotate(45 ${d.p[0]} ${d.p[1]})`} />
            <title>{d.nombre}</title>
          </g>
        ))}
        {DEPARTAMENTOS_GEO.map((g) => {
          const r = por[g.nombre];
          const [x, y] = g.etiqueta;
          const ev = r?.eventos.length ?? 0;
          return (
            <g key={'e' + g.nombre} className={`mp-etq ${sel === g.nombre ? 'on' : ''}`} aria-hidden="true">
              <text className="mp-nombre" x={x} y={y}>{g.nombre}</text>
              {semaforo?.[g.nombre] && (
                <text className={`mp-cuenta mp-sem-t sem-${ESTADO_COLOR[semaforo[g.nombre].estado]}`} x={x} y={y + (compacto ? 30 : 24)}>
                  ● {ESTADO_TXT[semaforo[g.nombre].estado]}
                </text>
              )}
              {!semaforo && r && r.senales.length > 0 && (
                <text className="mp-cuenta" x={x} y={y + (compacto ? 30 : 24)}>
                  <tspan className="o">▲{r.oportunidades.length}</tspan>
                  <tspan dx="8" className="r">●{r.riesgos.length}</tspan>
                  {r.mixtas.length > 0 && <tspan dx="8" className="m">◆{r.mixtas.length}</tspan>}
                </text>
              )}
              {ev > 0 && (
                <g className="mp-evento" transform={`translate(${x + (compacto ? 70 : 58)} ${y - 26})`}>
                  <circle className="pulso" r="13" />
                  <circle r="11" />
                  <text y="4">{ev}</text>
                </g>
              )}
            </g>
          );
        })}
      </svg>
      {h && hover && semaforo?.[hover.dep] && (
        <div className="mp-tip" style={{ left: hover.x, top: hover.y }} role="status">
          <b>{hover.dep} · <span className={`sem-txt sem-${ESTADO_COLOR[semaforo[hover.dep].estado]}`}>{ESTADO_TXT[semaforo[hover.dep].estado]}</span></b>
          <span>{semaforo[hover.dep].motivo}</span>
          {semaforo[hover.dep].recomendacion && <small>Se recomienda: {semaforo[hover.dep].recomendacion}</small>}
        </div>
      )}
      {h && hover && !compacto && !semaforo && (
        <div className="mp-tip" style={{ left: hover.x, top: hover.y }} role="status">
          <b>{hover.dep}</b>
          <span><i className="o">▲ {h.oportunidades.length} oportunidades</i><i className="r">● {h.riesgos.length} riesgos</i>{h.mixtas.length > 0 && <i className="m">◆ {h.mixtas.length} mixtas</i>}</span>
          {(h.eventos.length > 0 || h.cambios.length > 0) && <span>{h.eventos.length} evento(s) · {h.cambios.length} cambio(s)</span>}
          {h.senales[0] && <small>{h.senales[0].titulo}</small>}
        </div>
      )}
    </div>
  );
}

// ───────── Panel lateral ─────────

function FilaSenal({ s }: { s: Senal }) {
  const openDrawer = useStore((st) => st.openDrawer);
  return (
    <button className="mp-sig" onClick={() => openDrawer({ kind: 'senal', id: s.id })}>
      <span className={`mp-sig-b ${s.naturaleza}`} />
      <span className="mp-sig-c">
        <span className="mp-sig-t">{s.titulo}</span>
        <span className="mp-sig-m">
          <span className="tag">{catName(s.categoria)}</span>
          {s.naturaleza === 'oportunidad' ? <span className={`tag p-${s.prioridad}`}>Prioridad {s.prioridad}</span> : <AccionTag s={s} />}
          {s.estado !== 'detectada' && <CertezaTag s={s} />}
          {s.plazo != null && s.plazo >= 0 && <span className="tag mp-plazo">{s.plazo === 0 ? 'Vence hoy' : s.plazo === 1 ? 'Vence mañana' : `${s.plazo} días para actuar`}</span>}
          <span className="mp-sig-a">{STL[s.estado]} · {ago(s.min)}</span>
        </span>
      </span>
    </button>
  );
}

function Seccion({ t, n, icon, children, vacio }: { t: string; n?: number; icon: string; children: React.ReactNode; vacio?: string }) {
  return (
    <section className="mp-sec">
      <h3><Icon name={icon} />{t}{n != null && <span className="mp-n">{n}</span>}</h3>
      {n === 0 && vacio ? <p className="mp-vacio">{vacio}</p> : children}
    </section>
  );
}

function Lista({ l, max = 4 }: { l: Senal[]; max?: number }) {
  const [todo, setTodo] = useState(false);
  const ver = todo ? l : l.slice(0, max);
  return (
    <div className="mp-lista">
      {ver.map((s) => <FilaSenal key={s.id} s={s} />)}
      {l.length > max && <button className="linklike mp-mas" onClick={() => setTodo(!todo)}>{todo ? 'Ver menos' : `Ver las ${l.length}`}</button>}
    </div>
  );
}

function Barra({ o, m, r }: { o: number; m: number; r: number }) {
  const t = o + m + r || 1;
  return (
    <div className="mp-barra" role="img" aria-label={`${o} oportunidades, ${m} mixtas, ${r} riesgos`}>
      <i className="o" style={{ width: `${(o / t) * 100}%` }} />
      <i className="m" style={{ width: `${(m / t) * 100}%` }} />
      <i className="r" style={{ width: `${(r / t) * 100}%` }} />
    </div>
  );
}

/** semáforo de un departamento: color, por qué en una frase y qué se recomienda */
export function SemaforoCaja({ sem }: { sem: SemaforoDep }) {
  const openDrawer = useStore((st) => st.openDrawer);
  return (
    <div className={`sem-caja sem-${ESTADO_COLOR[sem.estado]}`}>
      <p className="sem-caja-t"><span className="sem-luz" aria-hidden="true" /><b>{ESTADO_TXT[sem.estado]}</b> · {sem.motivo}</p>
      {sem.recomendacion && <p><small>Se recomienda</small> {sem.recomendacion}</p>}
      {sem.senal && <button className="linklike" onClick={() => openDrawer({ kind: 'senal', id: sem.senal!.id })}>Ver la ficha de {sem.senal.id} →</button>}
    </div>
  );
}

/** lista de departamentos con su luz, el motivo en una frase y (al pasar el ratón) qué se recomienda */
export function ListaSemaforo({ sem, onSel }: { sem: Record<string, SemaforoDep>; onSel: (d: string) => void }) {
  const orden = { accion: 0, atencion: 1, normal: 2 } as const;
  const filas = DEPS.map((d) => sem[d]).filter(Boolean).sort((a, b) => orden[a.estado] - orden[b.estado] || a.dep.localeCompare(b.dep));
  return (
    <ul className="dir-dep-lista">
      {filas.map((f) => (
        <li key={f.dep}>
          <button onClick={() => onSel(f.dep)} title={f.recomendacion ? `Se recomienda: ${f.recomendacion}` : undefined}>
            <span className={`sem-luz sem-${ESTADO_COLOR[f.estado]}`} aria-hidden="true" />
            <span><b>{f.dep}</b> <span className="sr-only">{ESTADO_TXT[f.estado]}.</span><small>{f.motivo}</small></span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function Region({ r, sem }: { r: ResumenRegion; sem?: SemaforoDep }) {
  const geo = DEPARTAMENTOS_GEO.find((g) => g.nombre === r.dep)!;
  const { go, setSigFilter, setMapaSel } = useStore.getState();
  const { openChat } = useChat();
  const abrirEvento = useEventos((s) => s.setListaAbierta);
  const abrirCambios = useCambios((s) => s.setListaAbierta);
  const [verNac, setVerNac] = useState(false);
  const top = r.senales.slice(0, 3);
  const noticias = r.noticias.slice(0, 6);

  return (
    <div className="mp-region">
      <header className="mp-rh">
        <div>
          <div className="eyebrow">Departamento · {geo.iso}</div>
          <h2>{r.dep}</h2>
          <p className="mp-cap"><Icon name="mapa" /> Capital: {geo.capital}{r.dep === 'Chuquisaca' && ' (capital constitucional)'}{r.dep === 'La Paz' && ' (sede de gobierno)'}</p>
        </div>
        <button className="icon-btn" aria-label="Volver a todo Bolivia" title="Volver a todo Bolivia" onClick={() => setMapaSel(null)}><Icon name="close" /></button>
      </header>
      {sem && <SemaforoCaja sem={sem} />}

      <div className="mp-kpis">
        <div><b className="num">{r.senales.length}</b><small>señales</small></div>
        <div className="o"><b className="num">{r.oportunidades.length}</b><small>oportunidades</small></div>
        <div className="r"><b className="num">{r.riesgos.length}</b><small>riesgos</small></div>
        <div className="e"><b className="num">{r.eventos.length}</b><small>eventos</small></div>
      </div>
      {r.senales.length > 0 && <Barra o={r.oportunidades.length} m={r.mixtas.length} r={r.riesgos.length} />}
      {(r.altas > 0 || r.porRevisar > 0 || r.cambios.length > 0) && (
        <p className="mp-nota">
          {r.altas > 0 && <span><b>{r.altas}</b> de prioridad alta</span>}
          {r.porRevisar > 0 && <span><b>{r.porRevisar}</b> esperan revisión</span>}
          {r.cambios.length > 0 && <span><b>{r.cambios.length}</b> cambio(s) en 24 h</span>}
        </p>
      )}

      <div className="mp-acc">
        <button className="btn sm" onClick={() => { setSigFilter({ dep: r.dep, nat: 'all', q: '' }); go('senales'); }}><Icon name="senales" /> Ver señales de {r.dep}</button>
        <button className="btn sm ghost" onClick={() => openChat(`Resume la situación turística de ${r.dep}: oportunidades, riesgos, eventos y qué recomiendas hacer primero.`)}><Icon name="spark" /> Preguntar a AVIA</button>
      </div>

      {!r.senales.length && !r.eventos.length
        ? <Empty title="Sin señales en este periodo">AVIA no ha detectado nada propio de {r.dep}. Abajo están las que afectan a todo el país.</Empty>
        : <Seccion t="Lo más importante" icon="sintesis"><Lista l={top} max={3} /></Seccion>}

      {r.eventos.length > 0 && (
        <Seccion t="Eventos" n={r.eventos.length} icon="riesgo">
          <div className="mp-lista">
            {r.eventos.map((e) => (
              <button key={e.codigo} className={`mp-ev ${e.tipo}`} onClick={() => abrirEvento(true, e.codigo)}>
                <span className="mp-ev-t">{e.titular ?? `${TIPO_TXT[e.tipo]}: ${e.senales.map((s) => s.titulo).slice(0, 2).join(' + ')}`}</span>
                <span className="mp-sig-m">
                  <span className="tag">{TIPO_TXT[e.tipo]}</span>
                  <span className={`tag p-${e.prioridad}`}>Prioridad {e.prioridad}</span>
                  <span className="mp-sig-a">{fechaCorta(e.ventana_inicio)}{e.ventana_fin && e.ventana_fin !== e.ventana_inicio ? ` – ${fechaCorta(e.ventana_fin)}` : ''} · {e.senales.length} señales</span>
                </span>
                {e.interpretacion?.recomendacion?.accion && <span className="mp-ev-r"><b>Qué hacer:</b> {e.interpretacion.recomendacion.accion}</span>}
              </button>
            ))}
          </div>
        </Seccion>
      )}

      <Seccion t="Oportunidades" n={r.oportunidades.length + r.mixtas.length} icon="oportunidades" vacio="Ninguna en este periodo.">
        <Lista l={[...r.oportunidades, ...r.mixtas]} />
        {r.fichas.length > 0 && (
          <button className="linklike mp-mas" onClick={() => useStore.getState().go('oportunidades')}>{r.fichas.length} ficha(s) de oportunidad con beneficiarios y acción →</button>
        )}
      </Seccion>

      <Seccion t="Riesgos" n={r.riesgos.length} icon="riesgo" vacio="Ningún riesgo en este periodo.">
        <Lista l={r.riesgos} />
      </Seccion>

      {r.cambios.length > 0 && (
        <Seccion t="Cambios en las noticias" n={r.cambios.length} icon="refresh">
          <div className="mp-lista">
            {r.cambios.slice(0, 4).map((c) => (
              <button key={c.codigo} className="mp-cam" onClick={() => abrirCambios(true)}>
                <span className="tag">{TIPO_CAMBIO_TXT[c.tipo]}</span>
                <span className="mp-cam-t">{c.titular ?? c.senal.titulo}</span>
                {c.antes && <span className="mp-cam-d"><s>{c.antes}</s> → {c.ahora}</span>}
              </button>
            ))}
          </div>
        </Seccion>
      )}

      <Seccion t="Noticias más importantes" n={r.noticias.length} icon="bitacora" vacio="Las señales de aquí todavía no tienen noticias enlazadas.">
        <ol className="mp-not">
          {noticias.map((n, i) => (
            <li key={i}>
              {n.url ? <a href={n.url} target="_blank" rel="noopener noreferrer">{n.titulo}</a> : <span>{n.titulo}</span>}
              <small>
                {n.oficial && <span className="tag mp-of">Oficial</span>}
                {n.fuente && <span>{n.fuente}</span>}
                {n.fecha && <span>{fechaCorta(n.fecha)}</span>}
                <span className="mp-not-s">· {n.senal.titulo}</span>
              </small>
            </li>
          ))}
        </ol>
      </Seccion>

      {(r.destinos.length > 0 || r.categorias.length > 0) && (
        <Seccion t="Lugares y temas" icon="temas">
          {r.destinos.length > 0 && <div className="mp-chips">{r.destinos.slice(0, 10).map((d) => <span key={d.nombre} className="tag">◇ {d.nombre}{d.n > 1 && <b> {d.n}</b>}</span>)}</div>}
          {r.categorias.length > 0 && <div className="mp-chips">{r.categorias.map((c) => <span key={c.c} className="tag">{CATS[c.c as keyof typeof CATS] ?? c.c} <b>{c.n}</b></span>)}</div>}
        </Seccion>
      )}

      {r.nacionales.length > 0 && (
        <section className="mp-sec">
          <button className="mp-nac" aria-expanded={verNac} onClick={() => setVerNac(!verNac)}>
            <Icon name={verNac ? 'left' : 'right'} />También le afecta: {r.nacionales.length} señal(es) de todo el país
          </button>
          {verNac && <Lista l={r.nacionales} max={5} />}
        </section>
      )}
    </div>
  );
}

function Pais({ por, nacionales, sinLugar, total, semaforo }: { por: Record<string, ResumenRegion>; nacionales: Senal[]; sinLugar: Senal[]; total: Senal[]; semaforo?: Record<string, SemaforoDep> }) {
  const setMapaSel = useStore((s) => s.setMapaSel);
  const eventos = useEventos((s) => s.eventos);
  const filas = DEPS.map((d) => por[d]).sort((a, b) => b.senales.length - a.senales.length || a.dep.localeCompare(b.dep));
  const max = Math.max(1, ...filas.map((f) => f.senales.length));
  const o = total.filter((s) => s.naturaleza === 'oportunidad').length;
  const r = total.filter((s) => s.naturaleza === 'riesgo').length;
  const m = total.filter((s) => s.naturaleza === 'mixta').length;
  return (
    <div className="mp-region">
      <header className="mp-rh">
        <div>
          <div className="eyebrow">Todo el país</div>
          <h2>Bolivia</h2>
          <p className="mp-cap">Toca un departamento en el mapa o en la lista para ver su resumen.</p>
        </div>
      </header>
      <div className="mp-kpis">
        <div><b className="num">{total.length}</b><small>señales</small></div>
        <div className="o"><b className="num">{o}</b><small>oportunidades</small></div>
        <div className="r"><b className="num">{r}</b><small>riesgos</small></div>
        <div className="e"><b className="num">{eventos.length}</b><small>eventos</small></div>
      </div>
      {total.length > 0 && <Barra o={o} m={m} r={r} />}

      {semaforo && (
        <Seccion t="Semáforo por departamento" icon="mapa">
          <ListaSemaforo sem={semaforo} onSel={setMapaSel} />
        </Seccion>
      )}
      {!semaforo && <Seccion t="Departamentos" icon="mapa">
        <div className="mp-rank">
          {filas.map((f) => (
            <button key={f.dep} onClick={() => setMapaSel(f.dep)} aria-label={`${f.dep}: ${f.senales.length} señales`}>
              <span className="mp-rank-n">{f.dep}</span>
              <span className="mp-rank-b">
                <i className="o" style={{ width: `${(f.oportunidades.length / max) * 100}%` }} />
                <i className="m" style={{ width: `${(f.mixtas.length / max) * 100}%` }} />
                <i className="r" style={{ width: `${(f.riesgos.length / max) * 100}%` }} />
              </span>
              <span className="mp-rank-c num">{f.senales.length}{f.eventos.length > 0 && <em title="eventos"> · {f.eventos.length} ev.</em>}</span>
            </button>
          ))}
        </div>
      </Seccion>}

      <Seccion t="Afectan a todo el país" n={nacionales.length} icon="senales" vacio="Ninguna señal nacional en este periodo.">
        <Lista l={nacionales} />
      </Seccion>
      {sinLugar.length > 0 && (
        <Seccion t="Sin lugar reconocido" n={sinLugar.length} icon="fuentes">
          <p className="mp-vacio">Su territorio no es un departamento ni un destino conocido, así que no se pintan en el mapa.</p>
          <Lista l={sinLugar} max={3} />
        </Seccion>
      )}
    </div>
  );
}

// ───────── Vista ─────────

export function Mapa() {
  const sel = useStore((s) => s.mapaSel);
  const setMapaSel = useStore((s) => s.setMapaSel);
  const origen = useStore((s) => s.origen);
  const role = useStore((s) => s.role);
  const senales = useStore((s) => s.senales);
  const [mostrar, setMostrar] = useState<Mostrar>(role === 'analista' ? 'todo' : 'semaforo');
  const [periodo, setPeriodo] = useState<'recientes' | 'todo'>('recientes');
  const { por, total, nacionales, sinLugar } = useResumenes(mostrar, periodo);
  const destinos = useMemo(() => [...new Set(total.flatMap((s) => s.destinos ?? []))], [total]);
  const semaforo = useMemo(() => (mostrar === 'semaforo' ? semaforoDepartamentos(senales) : undefined), [mostrar, senales]);
  const nacPeso = useMemo(() => (mostrar === 'semaforo' ? nacionalesConPeso(senales) : []), [mostrar, senales]);
  const elegir = (d: string) => setMapaSel(sel === d ? null : d);
  const lado = useRef<HTMLElement>(null);
  // en pantallas estrechas el resumen queda debajo del mapa: llevarlo a la vista al elegir
  useEffect(() => {
    if (sel && window.innerWidth <= 1180) lado.current?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }, [sel]);

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Territorio</div>
          <h1>Bolivia <em>por departamentos</em></h1>
          <p className="sub">{mostrar === 'semaforo'
            ? 'Semáforo: rojo si hay un riesgo grave y confirmado que pide decidir hoy, amarillo si algo puede crecer o está sin confirmar, verde si nada pide medidas. Toca un departamento para ver el motivo y qué se recomienda.'
            : 'Dónde están las oportunidades, los riesgos y los eventos que AVIA vigila. El color dice qué pesa más en cada departamento y su intensidad, cuántas señales tiene.'}</p>
        </div>
        <div className="head-actions">
          <div className="seg" role="group" aria-label="Qué mostrar">
            {([['semaforo', 'Semáforo'], ['todo', 'Todo'], ['oportunidad', 'Oportunidades'], ['riesgo', 'Riesgos']] as [Mostrar, string][]).map(([k, t]) => (
              <button key={k} className={mostrar === k ? 'on' : ''} aria-pressed={mostrar === k} onClick={() => setMostrar(k)}>{t}</button>
            ))}
          </div>
          <select className="inp" style={{ width: 'auto' }} aria-label="Periodo" value={periodo} onChange={(e) => setPeriodo(e.target.value as 'recientes' | 'todo')}>
            <option value="recientes">Recientes (7 días y plazos abiertos)</option>
            <option value="todo">Todo lo guardado</option>
          </select>
        </div>
      </section>

      <div className="mp-layout">
        <section className="panel mp-card">
          <div className="panel-h">
            <h2><Icon name="mapa" />Mapa de Bolivia</h2>
            <span className="meta">{origen === 'vps' ? 'datos reales' : 'ejemplo'}</span>
          </div>
          <div className="panel-b">
            <MapaBolivia por={por} sel={sel} onSel={elegir} destinosActivos={destinos} semaforo={semaforo} />
            {semaforo ? (
              <div className="map-legend mp-leyenda">
                <span><i style={{ background: 'var(--ok)' }} />Normal: nada pide medidas</span>
                <span><i style={{ background: 'var(--opp)' }} />Atención: preparar</span>
                <span><i style={{ background: 'var(--crit)' }} />Acción: decidir hoy</span>
                {nacPeso.length > 0 && <span className="tag">Todo el país: {nacPeso.length} riesgo(s) con peso, no tiñen el mapa</span>}
              </div>
            ) : (
            <div className="map-legend mp-leyenda">
              <span><i style={{ background: 'var(--opp)' }} />Pesan las oportunidades</span>
              <span><i style={{ background: 'var(--risk)' }} />Pesan los riesgos</span>
              <span><i style={{ background: 'var(--mix)' }} />Mixto</span>
              <span><i className="mp-ley-ev" />Evento compuesto activo</span>
              <span><i className="mp-ley-dest" />Destino con señales</span>
              {nacionales.length > 0 && (
                <button className="tag mp-ley-nac" onClick={() => setMapaSel(null)}>Todo el país: {nacionales.length} señal(es)</button>
              )}
            </div>
            )}
          </div>
        </section>
        <aside className="panel mp-lado" aria-live="polite" ref={lado}>
          {sel && por[sel]
            ? <Region key={sel} r={por[sel]} sem={semaforo?.[sel]} />
            : <Pais por={por} nacionales={nacionales} sinLugar={sinLugar} total={total} semaforo={semaforo} />}
        </aside>
      </div>
    </>
  );
}
