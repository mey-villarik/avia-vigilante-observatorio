import { useEffect, useRef, useState, type ReactNode } from 'react';
import { CATS, STL } from '../data/demo';
import { activeSignals, canDecide, useStore } from '../store';
import { Icon } from '../components/Icon';
import { NatPill } from '../components/common';
import { useChat } from '../services/chat';
import type { Oportunidad } from '../services/recolector';

export const planPrompt = (id: string, titulo: string) =>
  `Dame un plan de acción para ${id} (${titulo}). ¿Quién puede aprovecharlo o a quién afecta y qué hago primero?`;

const TIPO_TXT: Record<string, string> = {
  convocatoria: 'Convocatoria', licitacion: 'Licitación', evento: 'Evento', conectividad: 'Conectividad',
  financiamiento: 'Financiamiento', formacion: 'Formación', normativa: 'Normativa', demanda: 'Demanda',
};
const ESTADO_TXT: Record<Oportunidad['estado'], string> = { propuesta: 'Por revisar', validada: 'Validada', descartada: 'Descartada' };

/** días enteros hasta la fecha AAAA-MM-DD (hora de Bolivia), negativo si ya pasó */
const diasHasta = (f?: string) => {
  if (!f) return null;
  const fin = Date.parse(`${f}T23:59:59-04:00`);
  return Number.isNaN(fin) ? null : Math.ceil((fin - Date.now()) / 86400000) - 1;
};
const fecha = (f: string) => new Date(`${f}T12:00:00-04:00`).toLocaleDateString('es-BO', { day: 'numeric', month: 'long' });
const esEnlace = (u: string) => /^https?:\/\//.test(u);

function FichaDetalle({ o, cerrar }: { o: Oportunidad; cerrar: () => void }) {
  const role = useStore((s) => s.role);
  const senales = useStore((s) => s.senales);
  const { openDrawer, decideOpportunity } = useStore.getState();
  const { openChat } = useChat();
  const dias = diasHasta(o.plazo_hasta);
  const senal = o.senal ? senales.find((s) => s.id === o.senal) : undefined;
  const titulo = senal?.titulo ?? o.hecho;

  return (
    <article className={`opp ficha ficha-detalle ${o.estado}`}>
      <div className="ficha-tags">
        <span className={`tag nivel ${o.nivel}`} title={o.nivel === 'explicita' ? 'La fuente lo dice' : 'AVIA lo deduce de las noticias'}>
          {o.nivel === 'explicita' ? 'Explícita' : 'Inferida'}
        </span>
        <span className="tag">{TIPO_TXT[o.tipo] ?? o.tipo}</span>
        <span className={`tag est-${o.estado}`}>{ESTADO_TXT[o.estado]}</span>
      </div>
      <div className="ot" id="oppDetT">{titulo}</div>
      <div className="ficha-campo">
        <b>Hecho <small>(lo que dice la fuente)</small></b>
        <p>{o.hecho}</p>
      </div>
      {o.interpretacion && (
        <div className="ficha-campo">
          <b>Interpretación <small>(lo que podría aprovecharse)</small></b>
          <p>{o.interpretacion}</p>
        </div>
      )}
      {dias == null
        ? <div className="countdown"><small>Sin fecha límite</small></div>
        : dias < 0
          ? <div className="countdown"><small>El plazo terminó el {fecha(o.plazo_hasta!)}</small></div>
          : <div className="countdown"><b className="num">{dias}</b><small>{dias === 1 ? 'día' : 'días'} para actuar · hasta el {fecha(o.plazo_hasta!)}</small></div>}
      {o.beneficiarios && o.beneficiarios.length > 0 && (
        <div className="actors" aria-label="A quién le sirve">{o.beneficiarios.map((a) => <span className="tag" key={a}>{a}</span>)}</div>
      )}
      {o.accion && <div className="propose"><b>Siguiente paso</b>{o.accion}</div>}
      {o.evidencias && o.evidencias.length > 0 && (
        <div className="evidencias">
          <b>Evidencias ({o.evidencias.length})</b>
          <ul>
            {o.evidencias.map((e) => (
              <li key={e.id}>
                {esEnlace(e.url)
                  ? <a href={e.url} target="_blank" rel="noopener noreferrer">{e.titulo || e.url}</a>
                  : <span>{e.titulo || 'Noticia sin título'}</span>}
                {e.fuente && <span className="note"> · {e.fuente}</span>}
              </li>
            ))}
          </ul>
        </div>
      )}
      <div className="ficha-acciones">
        {senal && <button className="btn sm" onClick={() => { cerrar(); openDrawer({ kind: 'senal', id: senal.id }); }}><Icon name="eye" /> Ver señal</button>}
        <button className="btn sm ghost" onClick={() => { cerrar(); openChat(planPrompt(o.senal ?? `la oportunidad ${o.id}`, titulo)); }}><Icon name="spark" /> Plan con AVIA</button>
        {canDecide(role) && o.estado !== 'validada' && <button className="btn sm primary" onClick={() => void decideOpportunity(o.id, 'validada')}>Validar</button>}
        {canDecide(role) && o.estado !== 'descartada' && <button className="btn sm ghost" onClick={() => void decideOpportunity(o.id, 'descartada')}>Descartar</button>}
        {canDecide(role) && o.estado !== 'propuesta' && <button className="btn sm ghost" onClick={() => void decideOpportunity(o.id, 'propuesta')}>Volver a revisar</button>}
      </div>
    </article>
  );
}

/** «N días para actuar» compacto, o el texto si no hay plazo o ya pasó */
function Plazo({ dias, hasta }: { dias: number | null; hasta?: string }) {
  if (dias == null) return <div className="countdown"><small>Sin fecha límite</small></div>;
  if (dias < 0) return <div className="countdown"><small>Plazo cerrado{hasta ? ` el ${fecha(hasta)}` : ''}</small></div>;
  return <div className="countdown"><b className="num">{dias}</b><small>{dias === 1 ? 'día' : 'días'} para actuar{hasta ? ` · hasta el ${fecha(hasta)}` : ''}</small></div>;
}

/** Recuadro corto: título, días para actuar, Ver detalles y Plan con AVIA */
function Recuadro({ tags, titulo, plazo, verDetalles, plan, className = '' }: {
  tags: ReactNode; titulo: string; plazo: ReactNode; verDetalles: () => void; plan: () => void; className?: string;
}) {
  return (
    <article className={`opp opp-corta ${className}`}>
      <div className="ficha-tags">{tags}</div>
      <button type="button" className="ot opp-corta-t" onClick={verDetalles} aria-haspopup="dialog">{titulo}</button>
      {plazo}
      <div className="ficha-acciones">
        <button className="btn sm" onClick={verDetalles}><Icon name="eye" /> Ver detalles</button>
        <button className="btn sm ghost" onClick={plan}><Icon name="spark" /> Plan con AVIA</button>
      </div>
    </article>
  );
}

/** Ventana flotante (<dialog> nativo: Esc cierra, el foco queda dentro) */
function Ventana({ children, cerrar }: { children: ReactNode; cerrar: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dlg = ref.current;
    if (dlg && !dlg.open) dlg.showModal(); // al desmontarse, el <dialog> sale de la página y se cierra solo
  }, []);
  return (
    <dialog ref={ref} className="opp-ventana" aria-labelledby="oppDetT" onClose={cerrar}
      onClick={(e) => { if (e.target === e.currentTarget) cerrar(); }}>
      <button type="button" className="opp-cerrar" onClick={cerrar} aria-label="Cerrar">×</button>
      {children}
    </dialog>
  );
}

function Ficha({ o, abrir }: { o: Oportunidad; abrir: () => void }) {
  const senales = useStore((s) => s.senales);
  const { openChat } = useChat();
  const senal = o.senal ? senales.find((s) => s.id === o.senal) : undefined;
  const titulo = senal?.titulo ?? o.hecho;
  return (
    <Recuadro
      className={`ficha ${o.estado}`}
      tags={<>
        <span className={`tag nivel ${o.nivel}`}>{o.nivel === 'explicita' ? 'Explícita' : 'Inferida'}</span>
        <span className={`tag est-${o.estado}`}>{ESTADO_TXT[o.estado]}</span>
      </>}
      titulo={titulo}
      plazo={<Plazo dias={diasHasta(o.plazo_hasta)} />}
      verDetalles={abrir}
      plan={() => openChat(planPrompt(o.senal ?? `la oportunidad ${o.id}`, titulo))}
    />
  );
}

type Filtro = 'todas' | 'explicita' | 'inferida';

export function Oportunidades() {
  const senales = useStore((s) => s.senales);
  const oportunidades = useStore((s) => s.oportunidades);
  const real = useStore((s) => s.origen === 'vps');
  const openDrawer = useStore((s) => s.openDrawer);
  const { openChat } = useChat();
  const [filtro, setFiltro] = useState<Filtro>('todas');
  const [verDescartadas, setVerDescartadas] = useState(false);
  const [abierta, setAbierta] = useState<string | null>(null);
  const cerrar = () => setAbierta(null);
  const oAbierta = abierta ? oportunidades.find((o) => String(o.id) === abierta) : undefined;

  const fichas = oportunidades
    .filter((o) => (filtro === 'todas' || o.nivel === filtro) && (verDescartadas || o.estado !== 'descartada'))
    .sort((a, b) => (diasHasta(a.plazo_hasta) ?? 9999) - (diasHasta(b.plazo_hasta) ?? 9999));
  const descartadas = oportunidades.filter((o) => o.estado === 'descartada').length;
  const conFicha = new Set(oportunidades.map((o) => o.senal).filter(Boolean));
  const l = activeSignals(senales)
    .filter((s) => s.naturaleza !== 'riesgo' && !conFicha.has(s.id))
    .sort((a, b) => (a.plazo ?? 999) - (b.plazo ?? 999));

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Oportunidades</div>
          <h1>Lo que se puede <em>aprovechar</em> ahora</h1>
          <p className="sub">Cada oportunidad separa el <b>hecho</b> (lo que dice la fuente) de la <b>interpretación</b> (lo que podría aprovecharse), con a quién le sirve, el siguiente paso y las noticias que la respaldan. Ordenadas por plazo.</p>
        </div>
        <div className="head-actions">
          <button className="btn gold" onClick={() => openChat('Mirando todas las señales, ¿qué oportunidades nuevas propones que todavía no estén planteadas? Combina señales cuando tenga sentido.')}>
            <Icon name="spark" /> Proponer oportunidades nuevas
          </button>
        </div>
      </section>

      <div className="toolbar">
        <div className="seg" role="group" aria-label="Tipo de oportunidad">
          <button className={filtro === 'todas' ? 'on' : ''} onClick={() => setFiltro('todas')}>Todas</button>
          <button className={filtro === 'explicita' ? 'on' : ''} onClick={() => setFiltro('explicita')} title="La fuente lo dice: convocatoria, licitación, feria, inscripción">Explícitas</button>
          <button className={filtro === 'inferida' ? 'on' : ''} onClick={() => setFiltro('inferida')} title="AVIA lo deduce de las noticias">Inferidas</button>
        </div>
        {descartadas > 0 && (
          <label className="note chk">
            <input type="checkbox" checked={verDescartadas} onChange={(e) => setVerDescartadas(e.target.checked)} /> Ver descartadas ({descartadas})
          </label>
        )}
      </div>
      {fichas.length > 0
        ? <div className="opp-grid">{fichas.map((o) => <Ficha key={o.id} o={o} abrir={() => setAbierta(String(o.id))} />)}</div>
        : <p className="note vacio">{oportunidades.length
          ? 'Ninguna oportunidad con este filtro.'
          : real
            ? 'Todavía no hay oportunidades con ficha. Las crea el analizador cuando una noticia trae una convocatoria, una feria o un plazo, y AVIA cuando deduce una a partir de varias noticias.'
            : 'Sin oportunidades con ficha.'}</p>}
      {!real && oportunidades.length > 0 && <p className="note">Estas fichas son de ejemplo.</p>}
      {oAbierta && <Ventana key={abierta} cerrar={cerrar}><FichaDetalle o={oAbierta} cerrar={cerrar} /></Ventana>}

      {l.length > 0 && (
        <>
          <h2 className="sec-h">Otras señales de oportunidad <small>todavía sin ficha</small></h2>
          <div className="opp-grid">
            {l.map((s) => (
              <Recuadro
                key={s.id}
                tags={<><NatPill n={s.naturaleza} /><span className="tag">{s.tipoOpp || CATS[s.categoria]}</span><span className="tag">{STL[s.estado]}</span></>}
                titulo={s.titulo}
                plazo={s.plazo
                  ? <Plazo dias={s.plazo} />
                  : <div className="countdown"><small>Sin plazo: tendencia en seguimiento</small></div>}
                verDetalles={() => openDrawer({ kind: 'senal', id: s.id })}
                plan={() => openChat(planPrompt(s.id, s.titulo))}
              />
            ))}
          </div>
        </>
      )}
    </>
  );
}
