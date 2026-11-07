// Control de acceso: nadie ve el Vigilante sin iniciar sesión con correo y clave
// y tener una ficha activa en vigilante.users. Ver src/services/auth.ts.
import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { useStore } from '../store';
import {
  accesoConfigurado, cambiarClave, entrar, leerPerfil, recuperarClave, salir, sinLoginPermitido, supabase, traducir,
} from '../services/auth';
import { BrandMark } from './Shell';
import { Icon } from './Icon';

type Paso = 'cargando' | 'login' | 'olvido' | 'nueva-clave' | 'sin-perfil' | 'sin-config' | 'dentro';

/** cada cuánto se comprueba que el perfil sigue activo */
const REVISION_MS = 5 * 60 * 1000;

export function Acceso({ children }: { children: ReactNode }) {
  const [paso, setPaso] = useState<Paso>(() => (accesoConfigurado ? 'cargando' : sinLoginPermitido ? 'dentro' : 'sin-config'));
  const [aviso, setAviso] = useState('');
  const setSesion = useStore((s) => s.setSesion);

  useEffect(() => {
    if (!supabase) return;
    let vivo = true;

    const comprobar = async () => {
      const { data } = await supabase!.auth.getSession();
      if (!vivo) return;
      if (!data.session) { setSesion(null); setPaso('login'); return; }
      try {
        const p = await leerPerfil();
        if (!vivo) return;
        setSesion(p);
        setPaso(p ? 'dentro' : 'sin-perfil');
      } catch (e) {
        if (!vivo) return;
        setAviso(e instanceof Error ? e.message : 'No se pudo leer tu perfil.');
        setPaso('sin-perfil');
      }
    };

    // el enlace del correo de recuperación (o de invitación) abre la página con una sesión temporal
    const recuperando = /type=(recovery|invite)/.test(location.hash);
    if (recuperando) setPaso('nueva-clave'); else void comprobar();

    const { data: sub } = supabase.auth.onAuthStateChange((ev) => {
      if (ev === 'PASSWORD_RECOVERY') { setPaso('nueva-clave'); return; }
      if (ev === 'SIGNED_OUT') { setSesion(null); setPaso('login'); return; }
      if (ev === 'SIGNED_IN' && !recuperando) setTimeout(() => void comprobar(), 0);
    });
    // si un administrador desactiva a alguien, pierde el acceso en la siguiente revisión
    const t = setInterval(() => void comprobar(), REVISION_MS);
    return () => { vivo = false; sub.subscription.unsubscribe(); clearInterval(t); };
  }, [setSesion]);

  if (paso === 'dentro') return <>{children}</>;

  return (
    <div className="acceso">
      <div className="acceso-box">
        <div className="acceso-marca">
          <BrandMark />
          <div>
            <div className="brand-name">ORBITA <i>Vigilante</i></div>
            <div className="brand-cap">Turismo · Bolivia</div>
          </div>
        </div>
        {paso === 'cargando' && <p className="note" role="status">Comprobando tu sesión…</p>}
        {paso === 'login' && <Login onOlvido={() => setPaso('olvido')} />}
        {paso === 'olvido' && <Olvido onVolver={() => setPaso('login')} />}
        {paso === 'nueva-clave' && <NuevaClave onListo={() => { history.replaceState(null, '', location.pathname + '#panorama'); location.reload(); }} />}
        {paso === 'sin-perfil' && (
          <div className="acceso-f">
            <h1>Sin acceso</h1>
            <p>Tu cuenta existe, pero no tiene un perfil activo en el Vigilante. Pide al administrador que te dé de alta o te reactive.</p>
            {aviso && <p className="acceso-err" role="alert">{aviso}</p>}
            <button className="btn" onClick={() => void salir()}><Icon name="salir" /> Salir</button>
          </div>
        )}
        {paso === 'sin-config' && (
          <div className="acceso-f">
            <h1>Acceso no configurado</h1>
            <p>Esta copia de la web no tiene configurado el inicio de sesión. Hay que definir <code>VITE_SUPABASE_URL</code> y <code>VITE_SUPABASE_ANON_KEY</code> antes de publicarla.</p>
          </div>
        )}
      </div>
    </div>
  );
}

function Login({ onOlvido }: { onOlvido: () => void }) {
  const [email, setEmail] = useState('');
  const [clave, setClave] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError('');
    try { await entrar(email, clave); } catch (err) { setError(err instanceof Error ? err.message : traducir(String(err))); setBusy(false); }
  };
  return (
    <form className="acceso-f" onSubmit={submit}>
      <h1>Iniciar sesión</h1>
      <div className="field"><label htmlFor="acE">Correo</label>
        <input className="inp" id="acE" type="email" autoComplete="username" required autoFocus value={email} onChange={(e) => setEmail(e.target.value)} />
      </div>
      <div className="field"><label htmlFor="acC">Clave</label>
        <input className="inp" id="acC" type="password" autoComplete="current-password" required value={clave} onChange={(e) => setClave(e.target.value)} />
      </div>
      {error && <p className="acceso-err" role="alert">{error}</p>}
      <button className="btn primary" type="submit" disabled={busy}><Icon name="candado" /> {busy ? 'Entrando…' : 'Entrar'}</button>
      <button className="linkbtn" type="button" onClick={onOlvido}>¿Olvidaste tu clave?</button>
      <p className="note">Solo pueden entrar las personas dadas de alta por el administrador.</p>
    </form>
  );
}

function Olvido({ onVolver }: { onVolver: () => void }) {
  const [email, setEmail] = useState('');
  const [estado, setEstado] = useState<'' | 'enviando' | 'enviado'>('');
  const [error, setError] = useState('');
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setEstado('enviando'); setError('');
    try { await recuperarClave(email); setEstado('enviado'); } catch (err) { setError(err instanceof Error ? err.message : String(err)); setEstado(''); }
  };
  return (
    <form className="acceso-f" onSubmit={submit}>
      <h1>Recuperar la clave</h1>
      {estado === 'enviado'
        ? <p role="status">Si el correo está dado de alta, te llegará un enlace para crear una clave nueva.</p>
        : (
          <>
            <p>Escribe tu correo y te enviaremos un enlace para crear una clave nueva.</p>
            <div className="field"><label htmlFor="acR">Correo</label>
              <input className="inp" id="acR" type="email" autoComplete="username" required autoFocus value={email} onChange={(e) => setEmail(e.target.value)} />
            </div>
            {error && <p className="acceso-err" role="alert">{error}</p>}
            <button className="btn primary" type="submit" disabled={estado === 'enviando'}>{estado === 'enviando' ? 'Enviando…' : 'Enviar enlace'}</button>
          </>
        )}
      <button className="linkbtn" type="button" onClick={onVolver}>Volver a iniciar sesión</button>
    </form>
  );
}

export function NuevaClave({ onListo, titulo = 'Crea tu clave nueva' }: { onListo: () => void; titulo?: string }) {
  const [a, setA] = useState('');
  const [b, setB] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (a.length < 8) { setError('Usa al menos 8 caracteres.'); return; }
    if (a !== b) { setError('Las dos claves no coinciden.'); return; }
    setBusy(true); setError('');
    try { await cambiarClave(a); onListo(); } catch (err) { setError(err instanceof Error ? err.message : String(err)); setBusy(false); }
  };
  return (
    <form className="acceso-f" onSubmit={submit}>
      {titulo && <h1>{titulo}</h1>}
      <div className="field"><label htmlFor="ncA">Clave nueva</label>
        <input className="inp" id="ncA" type="password" autoComplete="new-password" required minLength={8} autoFocus value={a} onChange={(e) => setA(e.target.value)} />
      </div>
      <div className="field"><label htmlFor="ncB">Repite la clave</label>
        <input className="inp" id="ncB" type="password" autoComplete="new-password" required minLength={8} value={b} onChange={(e) => setB(e.target.value)} />
      </div>
      {error && <p className="acceso-err" role="alert">{error}</p>}
      <button className="btn primary" type="submit" disabled={busy}>{busy ? 'Guardando…' : 'Guardar clave'}</button>
    </form>
  );
}
