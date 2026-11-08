// Barra lateral, barra superior y avisos.
import type { EstadoFuente, Rol } from '../types';
import { PRESETS, STATE_TXT, VIEWS } from '../data/demo';
import { activeSignals, countStates, isAdmin, pendingDecision, useStore } from '../store';
import { accesoConfigurado, salir } from '../services/auth';
import { ROLE_NAME } from '../lib/util';
import { Icon } from './Icon';
import { clock } from '../lib/util';

export const BrandMark = () => (
  <svg className="brand-mark" viewBox="0 0 44 44" fill="none" aria-hidden="true">
    <circle cx="22" cy="22" r="18" stroke="var(--bo-red)" strokeWidth="2" strokeDasharray="37.7 75.4" transform="rotate(-90 22 22)" />
    <circle cx="22" cy="22" r="18" stroke="var(--bo-yel)" strokeWidth="2" strokeDasharray="0 37.7 37.7 37.7" transform="rotate(-90 22 22)" />
    <circle cx="22" cy="22" r="18" stroke="var(--bo-grn)" strokeWidth="2" strokeDasharray="0 75.4 37.7 0" transform="rotate(-90 22 22)" />
    <ellipse cx="22" cy="22" rx="18" ry="7" stroke="currentColor" strokeWidth="1.3" transform="rotate(-24 22 22)" />
    <circle cx="22" cy="22" r="6.5" fill="currentColor" opacity=".18" />
    <circle cx="22" cy="22" r="3.4" fill="currentColor" />
    <circle cx="37.5" cy="14.8" r="2.2" fill="currentColor" />
  </svg>
);

export function Sidebar() {
  const view = useStore((s) => s.view);
  const role = useStore((s) => s.role);
  const preset = useStore((s) => s.preset);
  const custom = useStore((s) => s.custom);
  const sideOpen = useStore((s) => s.sideOpen);
  const real = useStore((s) => s.origen === 'vps');
  const enBd = useStore((s) => s.enBd);
  const senales = useStore((s) => s.senales);
  const fuentes = useStore((s) => s.fuentes);
  const perfil = useStore((s) => s.perfil);
  const { go, applyPreset, setRole, openDrawer } = useStore.getState();

  const c = countStates(fuentes);
  const cnt: Partial<Record<string, [number, boolean]>> = {
    fuentes: [c.CRIT + c.WARN + fuentes.filter((f) => f.sinLeer).length, c.CRIT > 0],
    senales: [pendingDecision(senales).length, false],
    oportunidades: [activeSignals(senales).filter((s) => s.naturaleza !== 'riesgo' && s.plazo).length, false],
  };

  return (
    <aside className={`side ${sideOpen ? 'open' : ''}`} aria-label="Navegación">
      <div className="brand">
        <BrandMark />
        <div>
          <div className="brand-name">ORBITA <i>Vigilante</i></div>
          <div className="brand-cap">
            <span className="bo" aria-hidden="true"><i style={{ background: 'var(--bo-red)' }} /><i style={{ background: 'var(--bo-yel)' }} /><i style={{ background: 'var(--bo-grn)' }} /></span>
            Turismo · Bolivia
          </div>
        </div>
      </div>
      <div className="side-label">Vistas</div>
      <nav className="nav">
        {VIEWS.map(([id, n, i]) => {
          const k = cnt[id];
          return (
            <button key={id} className={view === id ? 'on' : ''} aria-current={view === id ? 'page' : 'false'} onClick={() => go(id)}>
              <Icon name={i} /><span>{n}</span>
              {k && k[0] > 0 && <span className={`count ${k[1] ? 'hot' : ''}`}>{k[0]}</span>}
            </button>
          );
        })}
      </nav>
      <div className="side-label">Tableros guardados</div>
      <div className="views-list">
        {Object.entries(PRESETS).map(([k, p]) => (
          <button key={k} className={preset === k ? 'on' : ''} onClick={() => applyPreset(k)}><span className="dot" />{p.n}</button>
        ))}
        {Object.keys(custom).map((k) => (
          <button key={'c:' + k} className={preset === 'c:' + k ? 'on' : ''} onClick={() => applyPreset('c:' + k)}><span className="dot" />{k}</button>
        ))}
      </div>
      <div className="side-foot">
        {perfil ? (
          <div className="cuenta">
            <div className="cuenta-q"><Icon name="usuario" /><span><b>{perfil.nombre}</b><small>{ROLE_NAME[perfil.rol]} · {perfil.clienteNombre}</small></span></div>
            <div className="cuenta-b">
              {isAdmin(role) && <button className="btn sm" onClick={() => openDrawer({ kind: 'equipo' })}><Icon name="equipo" /> Equipo</button>}
              <button className="btn sm ghost" onClick={() => openDrawer({ kind: 'mi-clave' })}><Icon name="candado" /> Clave</button>
              <button className="btn sm ghost" onClick={() => void salir()}><Icon name="salir" /> Salir</button>
            </div>
          </div>
        ) : !accesoConfigurado && (
          <div className="role">
            <label htmlFor="role">Entrar como (solo desarrollo)</label>
            <select id="role" value={role} onChange={(e) => setRole(e.target.value as Rol)}>
              <option value="visor">Visor (consulta)</option>
              <option value="analista">Analista (verifica y decide)</option>
              <option value="admin">Administrador (fuentes y equipo)</option>
            </select>
          </div>
        )}
        {real
          ? <div className="demo-card"><strong>Datos reales</strong>Señales y fuentes publicadas por AVIA en el VPS. {enBd ? 'Las etapas de las señales se guardan en la base de datos.' : 'Las decisiones que tomes aquí todavía no se guardan en el servidor.'}</div>
          : <div className="demo-card"><strong>Demostración</strong>Todas las señales, cifras y estados son ejemplos inventados. Las URL de fuentes son las del catálogo real.</div>}
      </div>
    </aside>
  );
}

const ESTADOS: EstadoFuente[] = ['OK', 'WARN', 'CRIT', 'UNKNOWN', 'MANT'];

export function Topbar() {
  const view = useStore((s) => s.view);
  const fuentes = useStore((s) => s.fuentes);
  const live = useStore((s) => s.live);
  const sideOpen = useStore((s) => s.sideOpen);
  const fs = useStore((s) => s.fs);
  const origen = useStore((s) => s.origen);
  const generado = useStore((s) => s.generado);
  const cargando = useStore((s) => s.cargando);
  const errorDatos = useStore((s) => s.errorDatos);
  const { go, setLive, setSearchOpen, setPrefs, openDrawer, setSideOpen, loadRemote } = useStore.getState();
  const minGen = generado ? (Date.now() - Date.parse(generado)) / 60000 : null;
  const c = countStates(fuentes);
  const crumb = (VIEWS.find((v) => v[0] === view) ?? VIEWS[0])[1];

  return (
    <header className="top">
      <div className="top-in">
        <button className="icon-btn menu-btn" aria-label="Abrir menú" onClick={() => setSideOpen(!sideOpen)}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><path d="M4 7h16M4 12h16M4 17h16" /></svg>
        </button>
        <div className="crumb"><span className="hide-sm">ORBITA</span><span className="hide-sm">/</span><strong>{crumb}</strong></div>
        <div className="top-right">
          <button className="health" title="Estado de las fuentes vigiladas" onClick={() => go('fuentes')}>
            <span className="lbl">FUENTES</span>
            <span>{ESTADOS.filter((k) => c[k]).map((k, i) => <span key={k}>{i > 0 && ' '}<span className={`pill st-${k}`} title={STATE_TXT[k]}>{c[k]}</span></span>)}</span>
          </button>
          {origen === 'vps' ? (
            <button className={`pill hide-sm ${errorDatos ? 'st-WARN' : 'st-OK'}`}
              title={errorDatos ? `Última actualización fallida: ${errorDatos}. Pulsa para reintentar.` : 'Datos de vigilante.json en el VPS. Pulsa para recargar.'}
              onClick={() => void loadRemote()}>
              <span className="d" /><span>{cargando ? 'Actualizando…' : `Datos del VPS${minGen != null && !Number.isNaN(minGen) ? ' · ' + clock(-minGen) : ''}`}</span>
            </button>
          ) : (
            <button className={`pill hide-sm ${live ? 'st-OK live' : 'st-UNKNOWN'}`} title="Datos de ejemplo. Pausar o reanudar la simulación de comprobaciones" onClick={() => setLive(!live)}>
              <span className="d" /><span>{cargando ? 'Conectando…' : live ? 'Ejemplo · simulación activa' : 'Ejemplo · simulación en pausa'}</span>
            </button>
          )}
          <button className="icon-btn" aria-label="Buscar (Ctrl+K)" title="Buscar (Ctrl+K)" onClick={() => setSearchOpen(true)}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4.2-4.2" /></svg>
          </button>
          <button className="icon-btn hide-sm" aria-label="Reducir texto" title="Reducir texto" onClick={() => setPrefs({ fs: Math.max(0.85, Math.round((fs - 0.1) * 100) / 100) })}>
            <span style={{ fontSize: 12, fontWeight: 700 }}>A−</span>
          </button>
          <button className="icon-btn hide-sm" aria-label="Aumentar texto" title="Aumentar texto" onClick={() => setPrefs({ fs: Math.min(1.3, Math.round((fs + 0.1) * 100) / 100) })}>
            <span style={{ fontSize: 15, fontWeight: 700 }}>A+</span>
          </button>
          <button className="icon-btn" aria-label="Accesibilidad y apariencia" title="Accesibilidad y apariencia" onClick={() => openDrawer({ kind: 'a11y' })}>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><circle cx="12" cy="4.5" r="1.8" /><path d="M5 8.5c2.3.7 4.6 1 7 1s4.7-.3 7-1M12 9.5V14m0 0-3 6m3-6 3 6" /></svg>
          </button>
        </div>
      </div>
      <div className="flag" aria-hidden="true"><i /><i /><i /></div>
      <div className="aguayo" aria-hidden="true" />
    </header>
  );
}

export function Toasts() {
  const toasts = useStore((s) => s.toasts);
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => <div className="toast" key={t.id}><Icon name="check" /><span>{t.msg}</span></div>)}
    </div>
  );
}
