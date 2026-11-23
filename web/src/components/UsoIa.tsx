// Uso de tokens de IA: botón en la barra superior y panel lateral con el detalle.
// Solo con sesión de analista o administrador (nunca en la web pública). Datos: services/usoIa.ts.
import { useEffect } from 'react';
import { useStore } from '../store';
import { enBolivia } from '../lib/hora';
import { Icon } from './Icon';
import { PROCESO_TXT, dinero, restanteMes, tokensCorto, tokensLargo, useUsoIa } from '../services/usoIa';

const USO_MS = 5 * 60_000;

/** estado del límite del mes: verde hasta el 75 %, ámbar hasta el 90 %, rojo después */
const nivel = (usado: number, limite: number) => (usado / limite >= 0.9 ? 'CRIT' : usado / limite >= 0.75 ? 'WARN' : 'OK');

export function BotonUsoIa() {
  const perfil = useStore((s) => s.perfil);
  const staff = perfil != null && perfil.rol !== 'visor';
  const uso = useUsoIa((s) => s.uso);
  const saldo = useUsoIa((s) => s.saldo);
  const disponible = useUsoIa((s) => s.disponible);
  useEffect(() => {
    if (!staff) return;
    void useUsoIa.getState().cargar();
    const t = setInterval(() => void useUsoIa.getState().cargar(), USO_MS);
    return () => clearInterval(t);
  }, [staff]);
  if (!staff || (!disponible && !saldo?.saldos?.length)) return null;

  const r = restanteMes(uso);
  const s0 = saldo?.saldos?.[0];
  const st = r ? nivel(r.usado, r.limite) : saldo?.disponible === false ? 'CRIT' : 'OK';
  const hoy = uso ? `${tokensCorto(uso.hoy.tokens)} hoy` : 'IA';
  const titulo = [
    uso && `Tokens de IA hoy: ${tokensLargo(uso.hoy.tokens)} · este mes: ${tokensLargo(uso.mes.tokens)}`,
    r?.texto,
    s0 && `Saldo de la cuenta ${saldo?.proveedor ?? ''}: ${dinero(s0.total, s0.moneda)}`,
    saldo?.disponible === false && 'La cuenta del modelo no tiene saldo: AVIA dejará de responder',
  ].filter(Boolean).join('\n');
  return (
    <button className={`pill hide-sm st-${st}`} title={titulo || 'Uso de IA'} aria-label={`Uso de IA: ${titulo}`}
      onClick={() => useStore.getState().openDrawer({ kind: 'uso-ia' })}>
      <Icon name="spark" /><span>{hoy}{r ? ` · queda ${r.unidad === 'usd' ? dinero(r.queda) : tokensCorto(r.queda)}` : s0 ? ` · saldo ${dinero(s0.total, s0.moneda)}` : ''}</span>
    </button>
  );
}

export function UsoIaDetalle() {
  const closeDrawer = useStore((s) => s.closeDrawer);
  const { uso, saldo, cargando, error, disponible } = useUsoIa();
  useEffect(() => { void useUsoIa.getState().cargar(); }, []);
  const r = restanteMes(uso);
  const max = Math.max(1, ...(uso?.serie_14d ?? []).map((d) => d.tokens));

  return (
    <>
      <div className="drawer-h">
        <Icon name="spark" /> Uso de IA
        <button className="icon-btn" aria-label="Cerrar" onClick={closeDrawer}><Icon name="close" /></button>
      </div>
      <div className="drawer-b uso-ia">
        <h2>Tokens consumidos</h2>
        {!disponible && <p className="note">La base todavía no tiene el conteo de tokens: falta aplicar <code>db/generico/52_uso_tokens.sql</code>.</p>}
        {error && <p className="note" role="alert">{error}</p>}
        {uso ? (
          <>
            <div className="dl uso-kpis">
              {([['Hoy', uso.hoy], ['Este mes', uso.mes], ['Acumulado', uso.acumulado]] as const).map(([n, p]) => (
                <div key={n}>
                  <small>{n}</small>
                  <b>{tokensCorto(p.tokens)}</b>
                  <small>{dinero(p.costo_usd)}{uso.costo_estimado ? ' aprox.' : ''} · {p.llamadas} llamada{p.llamadas === 1 ? '' : 's'}</small>
                </div>
              ))}
            </div>
            <p className="note">
              Entrada {tokensLargo(uso.mes.entrada)} · salida {tokensLargo(uso.mes.salida)} tokens este mes.
              {uso.acumulado.desde ? ` Acumulado desde el ${enBolivia(uso.acumulado.desde, 'fecha')} (los registros se borran a los 6 meses).` : ''}
            </p>
          </>
        ) : disponible && <p className="note">{cargando ? 'Cargando…' : 'Sin datos de uso todavía.'}</p>}

        <h3 className="sec-h">Lo que queda</h3>
        {r ? (
          <div className="uso-limite">
            <div className={`uso-barra st-${nivel(r.usado, r.limite)}`} role="meter" aria-valuemin={0} aria-valuemax={r.limite} aria-valuenow={r.usado}
              aria-label={r.texto}>
              <i style={{ width: `${Math.min(100, (r.usado / r.limite) * 100)}%` }} />
            </div>
            <p><b>{r.texto}</b> <small className="muted">({Math.round((r.usado / r.limite) * 100)} % usado)</small></p>
          </div>
        ) : (
          <p className="note">No hay un presupuesto mensual guardado, así que solo se muestra lo consumido. Un administrador puede fijarlo en
            parámetros con <code>ia_presupuesto_usd_mes</code> (USD) o <code>ia_tope_tokens_mes</code> (tokens).</p>
        )}
        {saldo?.saldos?.length ? (
          <div className="dl">
            {saldo.saldos.map((s) => (
              <div key={s.moneda}>
                <small>Saldo de la cuenta {saldo.proveedor ?? 'del modelo'}</small>
                <b className={saldo.disponible === false ? 'crit' : ''}>{dinero(s.total, s.moneda)}</b>
                <small>{saldo.consultado ? `consultado a las ${enBolivia(saldo.consultado, 'hora')}` : ''}</small>
              </div>
            ))}
          </div>
        ) : saldo?.motivo ? <p className="note">{saldo.motivo}.</p> : null}
        {saldo?.disponible === false && <p className="note" role="alert"><b>La cuenta del modelo no tiene saldo.</b> AVIA y el clasificador dejarán de responder hasta que se recargue.</p>}

        {uso && (
          <>
            <h3 className="sec-h">Últimos 14 días</h3>
            <div className="uso-serie" role="img" aria-label={`Tokens por día en los últimos 14 días: ${uso.serie_14d.map((d) => `${enBolivia(d.dia, 'diaCorto')} ${tokensCorto(d.tokens)}`).join(', ')}`}>
              {uso.serie_14d.map((d) => (
                <span key={d.dia} title={`${enBolivia(d.dia, 'diaSemana')}: ${tokensLargo(d.tokens)} tokens · ${dinero(d.costo_usd)}`}>
                  <i style={{ height: `${Math.max(d.tokens ? 4 : 0, (d.tokens / max) * 100)}%` }} />
                </span>
              ))}
            </div>
            <div className="uso-serie-ejes"><small>{enBolivia(uso.serie_14d[0]?.dia, 'diaCorto')}</small><small>hoy</small></div>

            <h3 className="sec-h">Quién gasta este mes</h3>
            {uso.por_proceso.length ? (
              <ul className="uso-procesos">
                {uso.por_proceso.map((p) => (
                  <li key={p.proceso}>
                    <span>{PROCESO_TXT[p.proceso] ?? p.proceso}</span>
                    <b>{tokensCorto(p.tokens)}</b>
                    <small className="muted">{dinero(p.costo_usd)}</small>
                  </li>
                ))}
              </ul>
            ) : <p className="note">Nada este mes.</p>}
          </>
        )}

        <p className="note">
          Cuenta lo que anotan el clasificador y el chat de AVIA. Lo que Hermes gasta en sus propias tareas no se anota aquí: solo se refleja en el saldo de la cuenta.
          {uso?.costo_estimado && uso.tarifa ? ` El coste es aproximado cuando el registro no lo trae: ${dinero(uso.tarifa.entrada_usd_millon)} por millón de tokens de entrada y ${dinero(uso.tarifa.salida_usd_millon)} de salida.` : ''}
        </p>
        <button className="btn sm ghost" onClick={() => void useUsoIa.getState().cargar()} disabled={cargando}>{cargando ? 'Actualizando…' : 'Actualizar'}</button>
      </div>
    </>
  );
}
