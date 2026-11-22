// Vista Dirección (P1, auditoría para la Dirección de Turismo, 2026-11-22).
// Una sola pantalla, sin editar ni aprobar nada: semáforo de Bolivia, los 3 ejes de la premisa
// (movilidad, servicios esenciales, atención turística), las 3 decisiones de hoy con su ficha
// «Acción · Responsable · Plazo · Cómo verificar», el semáforo por departamento y «Lo que viene».
// Es la pantalla de entrada del visor y del administrador; todos la ven. Reglas en lib/direccion.ts.
import { useMemo, useState } from 'react';
import { useStore } from '../store';
import { useChat } from '../services/chat';
import { Icon } from '../components/Icon';
import { AccionTag, CertezaTag, Empty } from '../components/common';
import { FichaDireccion } from '../components/FichaDireccion';
import { ListaSemaforo, MapaBolivia, SemaforoCaja } from './Mapa';
import {
  EJE_AYUDA, EJE_TXT, ESTADO_AYUDA, ESTADO_COLOR, ESTADO_TXT, TIPO_VIENE_TXT, VENTANA_TXT,
  ejeDe, loQueViene, nacionalesConPeso, resumenEjes, semaforoBolivia, semaforoDepartamentos, topDecisiones,
  type EstadoEje, type ResumenEje, type Ventana,
} from '../lib/direccion';
import { DEPS } from '../data/demo';
import { resumenRegion, type ResumenRegion } from '../lib/regiones';
import { clock } from '../lib/util';
import { enBolivia } from '../lib/hora';
import { storage } from '../lib/util';

function Luz({ e, grande = false }: { e: EstadoEje; grande?: boolean }) {
  return <span className={`sem-luz sem-${ESTADO_COLOR[e]}${grande ? ' grande' : ''}`} aria-hidden="true" />;
}

function TarjetaEje({ r }: { r: ResumenEje }) {
  const openDrawer = useStore((s) => s.openDrawer);
  const { openChat } = useChat();
  const ver = r.senales.filter((s) => s.naturaleza !== 'oportunidad').slice(0, 3);
  return (
    <section className={`panel eje-card sem-${ESTADO_COLOR[r.estado]}`} aria-label={`${EJE_TXT[r.eje]}: ${ESTADO_TXT[r.estado]}`}>
      <div className="eje-h">
        <h2 title={EJE_AYUDA[r.eje]}>{EJE_TXT[r.eje]}</h2>
        <span className={`sem-pill sem-${ESTADO_COLOR[r.estado]}`} title={ESTADO_AYUDA[r.estado]}><Luz e={r.estado} />{ESTADO_TXT[r.estado]}</span>
      </div>
      <p className="eje-motivo">{r.motivo}</p>
      <p className="eje-cuenta">
        {r.cuenta.accion > 0 && <span className="c-acc"><b>{r.cuenta.accion}</b> para actuar hoy</span>}
        {r.cuenta.atencion > 0 && <span className="c-ate"><b>{r.cuenta.atencion}</b> para preparar</span>}
        {r.cuenta.oportunidades > 0 && <span><b>{r.cuenta.oportunidades}</b> oportunidad(es)</span>}
        {!r.cuenta.accion && !r.cuenta.atencion && !r.cuenta.oportunidades && <span>Sin señales activas</span>}
      </p>
      {ver.length > 0 && (
        <ul className="eje-lista">
          {ver.map((s) => (
            <li key={s.id}><button className="linklike" onClick={() => openDrawer({ kind: 'senal', id: s.id })}>{s.titulo}</button> <AccionTag s={s} /></li>
          ))}
        </ul>
      )}
      <p className="eje-resp"><Icon name="usuario" /> {r.responsable}</p>
      <button className="btn sm ghost" onClick={() => openChat(`¿Cómo está la ${EJE_TXT[r.eje].toLowerCase()} para el turismo en Bolivia? Qué hay que hacer, quién y hasta cuándo.`)}><Icon name="spark" /> Preguntar a AVIA</button>
    </section>
  );
}

function Decisiones() {
  const senales = useStore((s) => s.senales);
  const openDrawer = useStore((s) => s.openDrawer);
  const top = useMemo(() => topDecisiones(senales), [senales]);
  return (
    <section className="panel dir-decisiones">
      <div className="panel-h"><h2><Icon name="decision" />Decisiones de hoy</h2><span className="meta">las 3 más urgentes</span></div>
      <div className="panel-b">
        {!top.length
          ? <Empty title="Nada que decidir ahora">Ningún riesgo pide medidas y ninguna convocatoria cierra en los próximos 7 días.</Empty>
          : (
            <ol className="dec-lista">
              {top.map((s, i) => {
                const eje = ejeDe(s);
                return (
                  <li key={s.id} className="dec">
                    <div className="dec-h">
                      <span className="dec-n num">{i + 1}</span>
                      <button className="linklike dec-t" onClick={() => openDrawer({ kind: 'senal', id: s.id })}>{s.titulo}</button>
                    </div>
                    <div className="dec-tags">
                      {eje && <span className="tag">{EJE_TXT[eje]}</span>}
                      {s.naturaleza === 'oportunidad' ? <span className="tag nat-oportunidad">Oportunidad</span> : <AccionTag s={s} />}
                      <CertezaTag s={s} />
                      <span className="tag mono">{s.id}</span>
                    </div>
                    <FichaDireccion s={s} compacta />
                  </li>
                );
              })}
            </ol>
          )}
      </div>
    </section>
  );
}

function SemaforoDepartamentos() {
  const senales = useStore((s) => s.senales);
  const responsables = useStore((s) => s.responsables);
  const [sel, setSel] = useState<string | null>(null);
  const sem = useMemo(() => semaforoDepartamentos(senales, responsables), [senales, responsables]);
  const nac = useMemo(() => nacionalesConPeso(senales), [senales]);
  // el mapa pide un resumen por departamento; aquí solo se usa para la etiqueta del departamento
  const por = useMemo(() => {
    const o: Record<string, ResumenRegion> = {};
    DEPS.forEach((d) => { o[d] = resumenRegion(d, senales.filter((s) => s.estado !== 'descartada'), [], [], []); });
    return o;
  }, [senales]);
  const elegido = sel ? sem[sel] : null;
  return (
    <section className="panel dir-mapa">
      <div className="panel-h"><h2><Icon name="mapa" />Semáforo por departamento</h2><span className="meta">toca uno para ver por qué</span></div>
      <div className="panel-b dir-mapa-b">
        <MapaBolivia por={por} sel={sel} onSel={(d) => setSel(sel === d ? null : d)} compacto semaforo={sem} />
        <div className="dir-deps">
          {elegido ? (
            <>
              <div className="dir-dep-h"><b>{elegido.dep}</b><button className="linklike" onClick={() => setSel(null)}>Ver todos</button></div>
              <SemaforoCaja sem={elegido} />
            </>
          ) : (
            <ListaSemaforo sem={sem} onSel={setSel} />
          )}
          {nac.length > 0 && (
            <p className="note dir-nac"><Icon name="riesgo" /> Además, {nac.length} riesgo(s) de todo el país: {nac.slice(0, 2).map((s) => s.titulo).join(' · ')}{nac.length > 2 ? '…' : ''}</p>
          )}
        </div>
      </div>
    </section>
  );
}

const VENTANAS: Ventana[] = [1, 3, 7];

function LoQueViene() {
  const senales = useStore((s) => s.senales);
  const openDrawer = useStore((s) => s.openDrawer);
  const [v, setV] = useState<Ventana>(() => storage.get<Ventana>('dir-ventana', 3));
  const cambiar = (x: Ventana) => { setV(x); storage.set('dir-ventana', x); };
  const items = useMemo(() => loQueViene(senales, v), [senales, v]);
  // agrupado por día
  const dias = useMemo(() => {
    const g = new Map<string, typeof items>();
    items.forEach((it) => g.set(it.fecha, [...(g.get(it.fecha) ?? []), it]));
    return [...g.entries()];
  }, [items]);
  const nombreDia = (fecha: string, n: number) => n === 0 ? 'Hoy' : n === 1 ? 'Mañana' : enBolivia(fecha, 'diaSemana');
  return (
    <section className="panel dir-viene">
      <div className="panel-h">
        <h2><Icon name="clock" />Lo que viene</h2>
        <div className="seg" role="group" aria-label="Ventana">
          {VENTANAS.map((x) => <button key={x} className={v === x ? 'on' : ''} aria-pressed={v === x} onClick={() => cambiar(x)}>{VENTANA_TXT[x]}</button>)}
        </div>
      </div>
      <div className="panel-b">
        <p className="note" style={{ marginTop: 0 }}>Por fecha en que ocurre, no por cuándo lo detectó AVIA: marchas y paros anunciados, eventos, cierres de convocatorias y avisos del SENAMHI con fecha.</p>
        {!dias.length
          ? <Empty title={`Nada con fecha en ${VENTANA_TXT[v]}`}>Ninguna señal activa tiene una fecha de ocurrencia o de cierre en esta ventana.</Empty>
          : (
            <ol className="viene">
              {dias.map(([fecha, l]) => (
                <li key={fecha} className="viene-dia">
                  <div className="viene-f"><b>{nombreDia(fecha, l[0].dias)}</b><small>{enBolivia(fecha, 'fecha')}</small></div>
                  <ul>
                    {l.map((it) => (
                      <li key={it.senal.id + it.tipo} className={`viene-it t-${it.tipo}`}>
                        <button className="linklike" onClick={() => openDrawer({ kind: 'senal', id: it.senal.id })}>{it.senal.titulo}</button>
                        <span className="viene-tags">
                          <span className="tag">{TIPO_VIENE_TXT[it.tipo]}</span>
                          {it.eje && <span className="tag">{EJE_TXT[it.eje]}</span>}
                          <CertezaTag s={it.senal} />
                          {it.fin && it.fin !== it.fecha && <span className="tag">hasta el {enBolivia(it.fin, 'diaCorto')}</span>}
                          {it.senal.deps.length > 0 && <small>{it.senal.deps.slice(0, 3).join(', ')}</small>}
                        </span>
                      </li>
                    ))}
                  </ul>
                </li>
              ))}
            </ol>
          )}
      </div>
    </section>
  );
}

export function Direccion() {
  const senales = useStore((s) => s.senales);
  const responsables = useStore((s) => s.responsables);
  const generado = useStore((s) => s.generado);
  const { openChat } = useChat();
  const ejes = useMemo(() => resumenEjes(senales, responsables), [senales, responsables]);
  const bo = semaforoBolivia(ejes);
  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Dirección · hoy</div>
          <h1 className="dir-titulo"><Luz e={bo.estado} grande />Bolivia:&nbsp;<em className={`sem-txt sem-${ESTADO_COLOR[bo.estado]}`}>{ESTADO_TXT[bo.estado]}</em></h1>
          <p className="sub">{bo.motivo} {ESTADO_AYUDA[bo.estado]}</p>
        </div>
        <div className="head-actions">
          <span className="updated">{generado ? `Datos generados ${clock(-(Date.now() - Date.parse(generado)) / 60000)}` : `Última comprobación ${clock(-1)}`}</span>
          <button className="btn gold" onClick={() => openChat('Para la Dirección: qué decisiones hay que tomar hoy en movilidad, servicios esenciales y atención turística, quién y hasta cuándo.')}><Icon name="sintesis" /> Preguntar a AVIA</button>
        </div>
      </section>
      <div className="dir-ejes">
        {ejes.map((r) => <TarjetaEje key={r.eje} r={r} />)}
      </div>
      <Decisiones />
      <div className="dir-fila">
        <SemaforoDepartamentos />
        <LoQueViene />
      </div>
    </>
  );
}
