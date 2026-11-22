// Vista «Internacional»: lo que llega de OPS/OMS, CEPAL y la prensa internacional y cómo afecta a Bolivia
// (db/generico/37_fuentes_internacionales.sql). Apartado separado, pero cada señal de aquí también entra
// en Señales, eventos compuestos y oportunidades, y da contexto a las señales nacionales que refuerza.
import { useEffect, useMemo, useState } from 'react';
import { catName } from '../data/demo';
import { useStore } from '../store';
import { Icon } from '../components/Icon';
import { NatPill } from '../components/common';
import {
  AMBITO_TXT, INTERNACIONAL_MS, PLAZO_TXT, useInternacional,
  type Ambito, type FuenteInternacional, type SenalCorta, type SenalInternacional,
} from '../services/internacional';

/** Pide los datos internacionales al arrancar y cada 5 minutos (lo usa App: Señales marca las internacionales) */
export function useDatosInternacional() {
  const real = useStore((s) => s.origen === 'vps' && s.perfil != null);
  useEffect(() => {
    void useInternacional.getState().cargar(real);
    if (!real) return;
    const t = setInterval(() => void useInternacional.getState().cargar(true), INTERNACIONAL_MS);
    return () => clearInterval(t);
  }, [real]);
}

/** códigos de la base que la web llama de otra forma (como en services/datos.ts) */
const CAT_ALIAS: Record<string, string> = { financiamiento: 'financiacion', mercados: 'mercado' };

const hace = (iso?: string) => {
  if (!iso) return 'nunca';
  const min = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000));
  return min < 60 ? `hace ${min} min` : min < 2880 ? `hace ${Math.round(min / 60)} h` : `hace ${Math.round(min / 1440)} días`;
};

function EstadoFuente({ f }: { f: FuenteInternacional }) {
  const mal = (f.errores_seguidos ?? 0) > 0;
  const tono = !f.activa ? 'MANT' : mal ? 'WARN' : f.ultimo_exito_en || f.noticias_7d ? 'OK' : 'UNKNOWN';
  return (
    <div className="intl-fuente">
      <span className={`intl-dot h-${tono}`} aria-hidden="true" />
      <span className="intl-fuente-c">
        <b>{f.nombre}</b>
        <small>
          {f.institucion ? f.institucion + ' · ' : ''}
          {!f.activa ? 'en pausa' : `leída ${hace(f.ultima_consulta_en)}`}
          {f.noticias_7d != null ? ` · ${f.noticias_7d} noticias en 7 días` : ''}
          {f.senales_30d != null ? ` · ${f.senales_30d} con impacto en 30 días` : ''}
        </small>
        {mal && f.ultimo_error && <small className="intl-error">Último error: {f.ultimo_error}</small>}
      </span>
    </div>
  );
}

function Nacional({ n }: { n: SenalCorta }) {
  const existe = useStore((s) => s.senales.some((x) => x.id === n.codigo));
  const openDrawer = useStore((s) => s.openDrawer);
  return (
    <button className="intl-nac" disabled={!existe} title={existe ? 'Abrir la señal nacional' : 'Esa señal ya no está en el panel'}
      onClick={() => openDrawer({ kind: 'senal', id: n.codigo })}>
      <NatPill n={n.naturaleza} /><span className="mono">{n.codigo}</span><span className="intl-nac-t">{n.titulo}</span>
    </button>
  );
}

function Tarjeta({ s }: { s: SenalInternacional }) {
  const enPanel = useStore((st) => st.senales.some((x) => x.id === s.codigo));
  const openDrawer = useStore((st) => st.openDrawer);
  const ib = s.impacto_bolivia;
  return (
    <article className={`intl-card nivel-${ib?.nivel ?? 'bajo'}`}>
      <div className="intl-tags">
        <NatPill n={s.naturaleza} />
        <span className="tag">{catName(CAT_ALIAS[s.categoria] ?? s.categoria)}</span>
        {ib?.nivel && <span className={`tag intl-nivel ${ib.nivel}`}>Impacto {ib.nivel}</span>}
        {ib?.plazo && <span className="tag">{PLAZO_TXT[ib.plazo]}</span>}
        {!s.internacional && <span className="tag" title="Un medio boliviano ya cuenta lo mismo: la señal es nacional con contexto internacional">También en fuente nacional</span>}
      </div>
      <h3 className="intl-t">{s.titulo}</h3>
      {s.resumen && <p className="intl-r">{s.resumen}</p>}
      {ib?.via && (
        <div className="intl-via">
          <small>Cómo llega a Bolivia</small>
          <p>{ib.via}</p>
          {ib.ambitos && ib.ambitos.length > 0 && (
            <div className="intl-ambitos">{ib.ambitos.map((a: Ambito) => <span key={a} className={`amb amb-${a}`}>{AMBITO_TXT[a] ?? a}</span>)}</div>
          )}
        </div>
      )}
      {s.refuerza && s.refuerza.length > 0 && (
        <div className="intl-refuerza">
          <small>Da contexto a {s.refuerza.length === 1 ? 'esta señal nacional' : `${s.refuerza.length} señales nacionales`}</small>
          {s.refuerza.map((n) => <Nacional key={n.codigo} n={n} />)}
        </div>
      )}
      <div className="intl-pie">
        <span>{(s.fuentes ?? []).join(' · ')}{s.departamentos?.length ? ` · ${s.departamentos.join(', ')}` : ''}</span>
        <span className="intl-acc">
          {s.enlace && <a className="btn ghost sm" href={s.enlace} target="_blank" rel="noopener noreferrer"><Icon name="link" /> Fuente</a>}
          {enPanel && <button className="btn sm" onClick={() => openDrawer({ kind: 'senal', id: s.codigo })}>Ver señal {s.codigo}</button>}
        </span>
      </div>
    </article>
  );
}

type Filtro = 'todo' | Ambito;

export function Internacional() {
  const { datos, origen, error, cargado } = useInternacional();
  const [filtro, setFiltro] = useState<Filtro>('todo');
  const ambitos = useMemo(() => [...new Set(datos.senales.flatMap((s) => s.impacto_bolivia?.ambitos ?? []))] as Ambito[], [datos]);
  const lista = filtro === 'todo' ? datos.senales : datos.senales.filter((s) => s.impacto_bolivia?.ambitos?.includes(filtro));
  const conContexto = Object.keys(datos.contexto).length;

  return (
    <>
      <section className="head">
        <div>
          <div className="eyebrow">Fuera de Bolivia</div>
          <h1>Internacional <em>con impacto en Bolivia</em></h1>
          <p className="sub">Lo que publican la OPS/OMS, la CEPAL y la prensa internacional (BBC Mundo, Reuters, AP). AVIA solo deja lo que llega a Bolivia y dice por qué vía; cada señal entra también en Señales, eventos y oportunidades, y da contexto a las señales nacionales del mismo tema.</p>
        </div>
        {ambitos.length > 0 && (
          <div className="head-actions">
            <div className="seg intl-seg" role="group" aria-label="Ámbito">
              <button className={filtro === 'todo' ? 'on' : ''} aria-pressed={filtro === 'todo'} onClick={() => setFiltro('todo')}>Todo</button>
              {ambitos.map((a) => (
                <button key={a} className={filtro === a ? 'on' : ''} aria-pressed={filtro === a} onClick={() => setFiltro(a)}>{AMBITO_TXT[a] ?? a}</button>
              ))}
            </div>
          </div>
        )}
      </section>

      {origen === 'sin_instalar' && <p className="note">Falta ejecutar <b>db/generico/37_fuentes_internacionales.sql</b> en Supabase. Hasta entonces esta vista está vacía.</p>}
      {origen === 'error' && error && <p className="note">No se pudieron leer los datos internacionales: {error}</p>}

      <div className="intl-layout">
        <section className="panel intl-lista">
          <div className="panel-h">
            <h2><Icon name="globo" />Señales con impacto en Bolivia</h2>
            <span className="meta">{origen === 'ejemplo' ? 'ejemplo' : `${lista.length} en 30 días`}</span>
          </div>
          <div className="panel-b">
            {!cargado ? <p className="note">Cargando…</p>
              : lista.length === 0
                ? <p className="note">Todavía no hay noticias internacionales con impacto en Bolivia{filtro !== 'todo' ? ' en este ámbito' : ''}. Las que no afectan a Bolivia se descartan solas.</p>
                : lista.map((s) => <Tarjeta key={s.codigo} s={s} />)}
          </div>
        </section>
        <aside className="intl-lado">
          <section className="panel">
            <div className="panel-h"><h2><Icon name="fuentes" />Fuentes internacionales</h2><span className="meta">{datos.fuentes.length}</span></div>
            <div className="panel-b">
              {datos.fuentes.length === 0 ? <p className="note">Sin fuentes internacionales todavía.</p>
                : datos.fuentes.map((f) => <EstadoFuente key={f.codigo} f={f} />)}
            </div>
          </section>
          <section className="panel">
            <div className="panel-h"><h2><Icon name="cadena" />Cómo influye</h2></div>
            <div className="panel-b intl-como">
              <p><b>{conContexto}</b> {conContexto === 1 ? 'señal nacional tiene' : 'señales nacionales tienen'} contexto internacional: lo verás en su ficha.</p>
              <p>Una noticia de fuera nunca confirma sola un hecho en Bolivia: sirve para anticipar y para reforzar lo que dicen las fuentes bolivianas.</p>
              <p>Si coincide en zona y fechas con señales nacionales, entra en los eventos compuestos con alarma.</p>
            </div>
          </section>
        </aside>
      </div>
    </>
  );
}
