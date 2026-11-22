import { useState } from 'react';
import type { EstadoFuente } from '../types';
import { STATE_TXT, catName } from '../data/demo';
import { METODO_TXT } from '../services/fuentes';
import { conProblema, countStates, isAdmin, useStore } from '../store';
import { ago, clock, norm } from '../lib/util';
import { cifrasFuentes, fuenteLeida } from '../lib/contadores';
import { Icon } from '../components/Icon';
import { Histo, StPill } from '../components/common';

const ESTADOS: EstadoFuente[] = ['OK', 'WARN', 'CRIT', 'UNKNOWN', 'MANT'];

const QUIEN: Record<string, string> = { avia: 'AVIA', sincronizacion: 'una búsqueda', 'migracion-15': 'una propuesta antigua' };

const enlace = (url: string) => (/^https?:\/\//.test(url) ? <a href={url} target="_blank" rel="noopener noreferrer">{url}</a> : url);

/**
 * Lo que AVIA encontró en los últimos 30 días (47_fuentes_avia_directas.sql). Ya no hay que aprobar nada:
 * si el sitio es nuevo, AVIA la añade y la vigila; si el sitio ya está en el catálogo (o un usuario lo eliminó), no la repite.
 */
function AviaEncontro() {
  const todas = useStore((s) => s.candidatas);
  const [abierto, setAbierto] = useState(false);
  if (!todas.length) return null;
  const pendientes = todas.filter((c) => c.estado === 'pendiente');
  const anadidas = todas.filter((c) => c.estado === 'aprobada');
  const repetidas = todas.filter((c) => c.estado === 'duplicada');
  const titulo = [
    anadidas.length ? `AVIA añadió ${anadidas.length === 1 ? '1 fuente' : `${anadidas.length} fuentes`}` : '',
    repetidas.length ? `no repitió ${repetidas.length === 1 ? '1 que ya estaba' : `${repetidas.length} que ya estaban`}` : '',
  ].filter(Boolean).join(' y ');

  return (
    <section className="propuestas candidatas avia-encontro" aria-label="Fuentes que encontró AVIA">
      <h2>{titulo || 'Fuentes que encontró AVIA'} <span className="note">· últimos 30 días</span></h2>
      <p className="note">
        Sin aprobación: cuando AVIA encuentra una fuente de un sitio que aún no se vigila, la añade y la vigila desde su próxima ronda.
        No repite un sitio que ya está en el catálogo ni vuelve a meter uno que el usuario eliminó. En la tabla, la columna «Origen» dice cuáles sugirió AVIA; puedes eliminar cualquiera.
      </p>
      {pendientes.length > 0 && (
        <p className="note" style={{ color: 'var(--warn)' }}>
          {pendientes.length === 1 ? 'Queda 1 sugerencia antigua' : `Quedan ${pendientes.length} sugerencias antiguas`} sin activar: se activan (o se descartan si están repetidas) al ejecutar db/generico/47_fuentes_avia_directas.sql en Supabase.
        </p>
      )}
      {(anadidas.length > 0 || repetidas.length > 0) && (
        <button className="btn sm ghost" aria-expanded={abierto} onClick={() => setAbierto(!abierto)}>{abierto ? 'Ocultar detalle' : 'Ver detalle'}</button>
      )}
      {abierto && (
        <ul>
          {[...anadidas, ...repetidas].map((c) => (
            <li key={c.id}>
              <div className="cand-txt">
                <b>{c.nombre}</b> <span className={`tag ${c.estado === 'aprobada' ? 'origen-avia' : ''}`}>{c.estado === 'aprobada' ? `Añadida${c.codigo ? ` · ${c.codigo}` : ''}` : 'Repetida: no se añadió'}</span>
                <div className="srcurl">{enlace(c.url)}</div>
                {c.estado === 'duplicada' && c.nota && <div className="note">{c.nota}</div>}
                {c.estado === 'aprobada' && c.motivo && <div className="note">Por qué: {c.motivo}</div>}
                <div className="note">
                  La encontró {QUIEN[c.propuesta_por] ?? c.propuesta_por} {ago(Math.max(0, (Date.now() - Date.parse(c.decidida_en ?? c.propuesta_en)) / 60000))}
                  {c.veces > 1 && <> · vista {c.veces} veces</>}
                  {c.evidencia.length > 0 && <> · Visto en: {c.evidencia.map((e, i) => (
                    <span key={e.id}>{i > 0 && ' · '}{/^https?:\/\//.test(e.url)
                      ? <a href={e.url} target="_blank" rel="noopener noreferrer">{e.titulo || e.url}</a>
                      : (e.titulo || 'noticia sin título')}</span>
                  ))}</>}
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

type FiltroOrigen = 'todas' | 'usuario' | 'avia';

export function Fuentes() {
  const fuentes = useStore((s) => s.fuentes);
  const role = useStore((s) => s.role);
  const srcFilter = useStore((s) => s.srcFilter);
  const srcQ = useStore((s) => s.srcQ);
  const real = useStore((s) => s.origen === 'vps');
  const todasPropuestas = useStore((s) => s.propuestas);
  const propuestas = todasPropuestas.filter((p) => p.estado === 'pendiente');
  const { setSrcFilter, setSrcQ, openDrawer, checkAll, decideProposal, removeSource } = useStore.getState();
  const [origen, setOrigen] = useState<FiltroOrigen>('todas');
  const admin = isAdmin(role);
  const c = countStates(fuentes);
  const cf = cifrasFuentes(fuentes);

  const list = srcFilter === 'problemas'
    ? fuentes.filter(conProblema)
    : fuentes.filter((s) => (srcFilter === 'all' || s.estado === srcFilter
      || (srcFilter === 'leidas' && s.estado !== 'MANT' && fuenteLeida(s))
      || (srcFilter === 'sinleer' && s.estado !== 'MANT' && !fuenteLeida(s)))
      && (!srcQ || norm(`${s.nombre} ${s.canal} ${s.url}`).includes(norm(srcQ))))
    .filter((s) => origen === 'todas' || (s.origen ?? 'usuario') === origen);
  const deAvia = fuentes.filter((s) => s.origen === 'avia').length;
  const eliminar = (id: string, nombre: string, avia: boolean) => {
    if (window.confirm(`¿Eliminar la fuente «${nombre}»?\n\nAVIA dejará de vigilarla y desaparecerá de la lista. Las señales que ya salieron de ella se conservan.${avia ? ' AVIA no volverá a añadir ese sitio por su cuenta.' : ''} Si la vuelves a añadir con la misma dirección, se recupera.`)) void removeSource(id);
  };

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Supervisión de fuentes</div>
          <h1>Cada fuente, <em>comprobada</em> sin descanso</h1>
          <p className="sub">Como un sistema de supervisión: cada fuente tiene comprobaciones (disponibilidad, frescura, estructura y novedad), un estado y su historial. Si una falla, el Vigilante lo dice antes de que falte información.</p>
        </div>
        <div className="head-actions">
          {isAdmin(role) && <button className="btn" onClick={() => openDrawer({ kind: 'nueva-fuente' })}><Icon name="plus" /> Añadir fuente</button>}
          <button className="btn primary" onClick={checkAll}><Icon name="refresh" /> {real ? 'Recargar datos' : 'Comprobar todas'}</button>
        </div>
      </section>
      <AviaEncontro />
      {propuestas.length > 0 && (
        <section className="propuestas" aria-label="Propuestas de AVIA">
          <h2>AVIA propone cambiar cómo se leen {propuestas.length === 1 ? '1 fuente' : `${propuestas.length} fuentes`}</h2>
          <p className="note">{isAdmin(role) ? 'No cambia nada hasta que lo apruebes. Apify cuesta dinero y tiene un tope al mes.' : 'Las aprueba o rechaza un administrador.'}</p>
          <ul>
            {propuestas.map((p) => (
              <li key={p.id}>
                <div>
                  <b>{p.nombre}</b>: de {METODO_TXT[p.metodo_actual] ?? p.metodo_actual} a <b>{METODO_TXT[p.metodo_propuesto] ?? p.metodo_propuesto}</b>
                  {typeof p.config?.apify_actor === 'string' && <span className="note"> · actor {p.config.apify_actor}</span>}
                  <div className="note">Motivo: {p.motivo} · {ago(Math.max(0, (Date.now() - Date.parse(p.propuesta_en)) / 60000))}</div>
                </div>
                {isAdmin(role) && (
                  <div className="acciones">
                    <button className="btn primary" onClick={() => decideProposal(p.id, true)}>Aprobar</button>
                    <button className="btn ghost" onClick={() => decideProposal(p.id, false)}>Rechazar</button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
      <div className="nag-summary nag-cifras">
        {/* la misma cifra que el encabezado y el Pulso: activas = leídas + sin leer (las en pausa aparte) */}
        <button className={`nag-box st-total ${srcFilter === 'all' && !srcQ ? 'on' : ''}`} onClick={() => { setSrcFilter('all'); setSrcQ(''); }}
          title={cf.enPausa ? `Más ${cf.enPausa} en pausa o propuestas, que no cuentan` : undefined}>
          <b className="num">{cf.total}</b><small>Activas{cf.enPausa ? ` · ${cf.enPausa} en pausa` : ''}</small>
        </button>
        <button className={`nag-box st-OK ${srcFilter === 'leidas' ? 'on' : ''}`} onClick={() => setSrcFilter(srcFilter === 'leidas' ? 'all' : 'leidas')}>
          <b className="num">{cf.leidas}</b><small>Leídas</small>
        </button>
        <button className={`nag-box st-${cf.sinLeer ? 'CRIT' : 'OK'} ${srcFilter === 'sinleer' ? 'on' : ''}`} onClick={() => setSrcFilter(srcFilter === 'sinleer' ? 'all' : 'sinleer')}>
          <b className="num">{cf.sinLeer}</b><small>Sin leer</small>
        </button>
      </div>
      <p className="note nag-nota">Detalle por estado: leídas = OK + Aviso · sin leer = Crítico + Desconocido · Mantenimiento = en pausa, no cuenta.</p>
      <div className="nag-summary nag-estados">
        {ESTADOS.map((k) => (
          <button key={k} className={`nag-box st-${k} ${srcFilter === k ? 'on' : ''}`} onClick={() => setSrcFilter(srcFilter === k ? 'all' : k)}>
            <b className="num">{c[k]}</b><small>{STATE_TXT[k]}</small>
          </button>
        ))}
      </div>
      <div className="toolbar">
        <label className="sr" htmlFor="srcQ">Filtrar fuentes</label>
        <input className="inp" id="srcQ" placeholder="Filtrar por nombre, canal o URL" value={srcQ} onChange={(e) => setSrcQ(e.target.value)} />
        <div className="seg">
          <button className={srcFilter === 'all' ? 'on' : ''} onClick={() => setSrcFilter('all')}>Todas</button>
          <button className={srcFilter === 'problemas' ? 'on' : ''} onClick={() => setSrcFilter('problemas')}>Con problemas</button>
        </div>
        <div className="seg" role="group" aria-label="Origen de la fuente">
          <button className={origen === 'todas' ? 'on' : ''} onClick={() => setOrigen('todas')}>Todo origen</button>
          <button className={origen === 'usuario' ? 'on' : ''} onClick={() => setOrigen('usuario')}>Del usuario</button>
          <button className={origen === 'avia' ? 'on' : ''} onClick={() => setOrigen('avia')}>Sugeridas por AVIA{deAvia ? ` (${deAvia})` : ''}</button>
        </div>
      </div>
      <div className="tbl-wrap">
        <table>
          <thead>
            <tr>
              <th>Estado</th><th>Fuente</th><th>Origen</th><th>Canal</th><th>Última comprobación</th><th className="tech">En este estado</th>
              <th>{real ? 'Historial' : 'Últimas 24'}</th><th className="tech">Información del check</th><th className="tech">{real ? 'Elementos nuevos' : 'Señales 24 h'}</th>
              {admin && <th><span className="sr">Eliminar</span></th>}
            </tr>
          </thead>
          <tbody>
            {list.map((s) => (
              <tr key={s.id} tabIndex={0}
                onClick={() => openDrawer({ kind: 'fuente', id: s.id })}
                onKeyDown={(e) => e.key === 'Enter' && openDrawer({ kind: 'fuente', id: s.id })}>
                <td><StPill s={s.estado} />{s.ack && <div className="ack">✓ reconocido{s.bd?.reconocida_por ? ` por ${s.bd.reconocida_por}` : ''}</div>}{s.flap && <div className="flap">⇅ intermitente</div>}{s.sinLeer && <div className="flap">⚠ AVIA no la lee</div>}{s.bd && !s.sinLeer && s.estado === 'UNKNOWN' && !s.bd.ultima_consulta_en && s.bd.activa && <div className="ack">nueva · en espera</div>}</td>
                <td><div className="srcname">{s.nombre}</div><div className="srcurl">{s.url}</div></td>
                <td>{s.origen === 'avia'
                  ? <span className="tag origen-avia" title={s.bd?.motivo_avia ? `Por qué la añadió AVIA: ${s.bd.motivo_avia}` : 'La encontró AVIA y la añadió sola'}>Sugerida por AVIA</span>
                  : <span className="tag">Usuario</span>}</td>
                <td>{catName(s.canal)}<div className="note">{s.tipo}</div></td>
                <td className="mono">{real && s.last == null ? <span className="note">Aún no</span> : clock(-(s.last ?? Math.floor((s.freq ?? 30) * 0.4)))}{s.freq ? <div className="note">cada {s.freq} min</div> : null}</td>
                <td className="mono tech">{s.desde != null ? ago(s.desde).replace('hace ', '') : '—'}</td>
                <td style={{ minWidth: 130 }}><Histo hist={s.hist} /></td>
                <td className="tech"><div className="info">{s.info}</div></td>
                <td className="mono tech">{s.items}</td>
                {admin && (
                  <td>
                    <button className="btn sm ghost danger" aria-label={`Eliminar ${s.nombre}`} title="Eliminar fuente"
                      onClick={(e) => { e.stopPropagation(); eliminar(s.id, s.nombre, s.origen === 'avia'); }}
                      onKeyDown={(e) => e.stopPropagation()}>
                      <Icon name="papelera" />
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="note">{real
        ? 'Estados de la última lectura de cada fuente (recolector del VPS o ronda de AVIA). La web los vuelve a leer cada 5 minutos.'
        : 'Los estados son de ejemplo. Las URL vienen del catálogo de fuentes; las marcadas «no abierta» o «por confirmar» hay que revisarlas a mano antes de activarlas.'}</p>
    </>
  );
}
