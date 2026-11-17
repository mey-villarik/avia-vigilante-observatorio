// Paneles laterales de cuenta: gestión del equipo (administrador) y cambio de la propia clave.
import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from 'react';
import type { Rol } from '../types';
import { useStore } from '../store';
import { ROLE_NAME } from '../lib/util';
import { actualizarPersona, altaPersona, crearCuenta, listarEquipo, ponerClave, type Persona } from '../services/equipo';
import { Icon } from './Icon';
import { NuevaClave } from './Acceso';

function Cabecera({ icon, children }: { icon: string; children: ReactNode }) {
  const closeDrawer = useStore((s) => s.closeDrawer);
  return (
    <div className="drawer-h">
      <Icon name={icon} /> {children}
      <button className="icon-btn" aria-label="Cerrar" onClick={closeDrawer}><Icon name="close" /></button>
    </div>
  );
}

const ROLES: [Rol, string][] = [
  ['visor', 'Visor: consulta'],
  ['analista', 'Analista: verifica y decide'],
  ['admin', 'Administrador: fuentes y equipo'],
];

export function Equipo() {
  const perfil = useStore((s) => s.perfil);
  const toast = useStore((s) => s.toast);
  const [gente, setGente] = useState<Persona[] | null>(null);
  const [error, setError] = useState('');
  const [nueva, setNueva] = useState({ nombre: '', email: '', rol: 'visor' as Rol, clave: '' });
  const [busy, setBusy] = useState(false);
  const [aviso, setAviso] = useState('');
  const [claveDe, setClaveDe] = useState<{ p: Persona; modo: 'clave' | 'crear' } | null>(null);

  const cargar = useCallback(async () => {
    try { setGente(await listarEquipo()); setError(''); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }, []);
  useEffect(() => { void cargar(); }, [cargar]);

  if (!perfil) return null;

  const cambiar = async (p: Persona, c: { rol?: Rol; activo?: boolean }) => {
    try {
      await actualizarPersona(p.id, c);
      toast(c.activo === false ? `${p.nombre} ya no puede entrar.` : c.activo ? `${p.nombre} puede volver a entrar.` : `${p.nombre} ahora es ${ROLE_NAME[c.rol!]}.`);
      await cargar();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  // id de Telegram (número): lo da el bot @userinfobot. Sirve para aprobar señales desde el grupo de analistas.
  const ponerTelegram = async (p: Persona) => {
    const v = window.prompt(`Id de Telegram de ${p.nombre} (un número; @userinfobot lo dice). Vacío para quitarlo.`, p.telegram ? String(p.telegram) : '');
    if (v === null) return;
    const t = v.trim();
    if (t && !/^\d{4,15}$/.test(t)) { setError('El id de Telegram es un número (por ejemplo 123456789).'); return; }
    try {
      await actualizarPersona(p.id, { telegram: t ? Number(t) : null });
      toast(t ? `${p.nombre} ya puede aprobar desde Telegram si es analista.` : `Se quitó el Telegram de ${p.nombre}.`);
      await cargar();
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  const alta = async (e: FormEvent) => {
    e.preventDefault();
    if (nueva.clave && nueva.clave.length < 8) { setError('La clave inicial necesita al menos 8 caracteres.'); return; }
    setBusy(true); setError(''); setAviso('');
    try {
      const a = await altaPersona(nueva, perfil);
      if (a) setAviso(a);
      else toast(nueva.clave ? `${nueva.nombre} ya puede entrar con su correo y la clave inicial.` : `Se envió una invitación a ${nueva.email}.`);
      setNueva({ nombre: '', email: '', rol: 'visor', clave: '' });
      await cargar();
    } catch (err) { setError(err instanceof Error ? err.message : String(err)); }
    setBusy(false);
  };

  return (
    <>
      <Cabecera icon="equipo">Equipo de {perfil.clienteNombre}</Cabecera>
      <div className="drawer-b">
        {error && <p className="acceso-err" role="alert">{error}</p>}
        {gente === null && !error && <p className="note">Cargando…</p>}
        {gente && (
          <ul className="equipo">
            {gente.map((p) => {
              const yo = p.id === perfil.id;
              return (
                <li key={p.id} className={p.activo ? '' : 'off'}>
                  <div className="eq-n">
                    <b>{p.nombre}{yo && ' (tú)'}</b>
                    <small>{p.email ?? 'sin correo'}{!p.conCuenta && ' · sin cuenta de acceso'}{!p.activo && ' · desactivada'}{p.telegram ? ' · Telegram ' + p.telegram : ''}</small>
                  </div>
                  <select aria-label={`Rol de ${p.nombre}`} value={p.rol} disabled={yo} onChange={(e) => void cambiar(p, { rol: e.target.value as Rol })}>
                    {ROLES.map(([k]) => <option key={k} value={k}>{ROLE_NAME[k]}</option>)}
                  </select>
                  <div className="eq-a">
                    {!yo && <button className="btn sm" onClick={() => void cambiar(p, { activo: !p.activo })}>{p.activo ? 'Quitar acceso' : 'Devolver acceso'}</button>}
                    {!yo && p.email && p.conCuenta && <button className="btn sm ghost" onClick={() => setClaveDe({ p, modo: 'clave' })}>Poner clave</button>}
                    <button className="btn sm ghost" title="Para aprobar señales con los botones del grupo de analistas" onClick={() => void ponerTelegram(p)}>Telegram</button>
                    {p.email && !p.conCuenta && p.activo && <button className="btn sm primary" onClick={() => setClaveDe({ p, modo: 'crear' })}>Crear cuenta</button>}
                  </div>
                </li>
              );
            })}
          </ul>
        )}

        {claveDe && <PonerClave key={claveDe.p.id + claveDe.modo} persona={claveDe.p} modo={claveDe.modo} onFin={() => { setClaveDe(null); void cargar(); }} />}

        <h3 className="eq-t">Dar de alta a una persona</h3>
        <form className="eq-f" onSubmit={alta}>
          <div className="field"><label htmlFor="eqN">Nombre</label>
            <input className="inp" id="eqN" required value={nueva.nombre} onChange={(e) => setNueva({ ...nueva, nombre: e.target.value })} />
          </div>
          <div className="field"><label htmlFor="eqE">Correo (es su usuario)</label>
            <input className="inp" id="eqE" type="email" required value={nueva.email} onChange={(e) => setNueva({ ...nueva, email: e.target.value })} />
          </div>
          <div className="field"><label htmlFor="eqR">Perfil</label>
            <select id="eqR" value={nueva.rol} onChange={(e) => setNueva({ ...nueva, rol: e.target.value as Rol })}>
              {ROLES.map(([k, t]) => <option key={k} value={k}>{t}</option>)}
            </select>
          </div>
          <div className="field"><label htmlFor="eqC">Clave inicial (opcional)</label>
            <input className="inp" id="eqC" type="password" autoComplete="new-password" minLength={8} value={nueva.clave} onChange={(e) => setNueva({ ...nueva, clave: e.target.value })} />
          </div>
          <p className="note">Si dejas la clave vacía, la persona recibe un correo de invitación para crearla. Si la pones, dásela por un canal seguro y pídele que la cambie al entrar.</p>
          {aviso && <p className="acceso-warn" role="status">{aviso}</p>}
          <button className="btn gold" style={{ alignSelf: 'flex-start' }} disabled={busy}><Icon name="plus" /> {busy ? 'Dando de alta…' : 'Dar de alta'}</button>
        </form>
      </div>
    </>
  );
}

function PonerClave({ persona, modo, onFin }: { persona: Persona; modo: 'clave' | 'crear'; onFin: () => void }) {
  const toast = useStore((s) => s.toast);
  const [clave, setClave] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const crear = modo === 'crear';
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if ((!crear || clave) && clave.length < 8) { setError('Usa al menos 8 caracteres.'); return; }
    setBusy(true); setError('');
    try {
      if (crear) {
        await crearCuenta(persona.email!, clave);
        toast(clave ? `${persona.nombre} ya puede entrar con su correo y esa clave.` : `Se envió una invitación a ${persona.email}.`);
      } else {
        await ponerClave(persona.email!, clave);
        toast(`Clave nueva para ${persona.nombre}.`);
      }
      onFin();
    } catch (err) { setError(err instanceof Error ? err.message : String(err)); setBusy(false); }
  };
  return (
    <form className="eq-f eq-clave" onSubmit={submit}>
      <div className="field"><label htmlFor="pcC">{crear ? `Clave inicial para ${persona.nombre} (opcional)` : `Clave nueva para ${persona.nombre}`}</label>
        <input className="inp" id="pcC" type="password" autoComplete="new-password" minLength={8} required={!crear} autoFocus value={clave} onChange={(e) => setClave(e.target.value)} />
      </div>
      {crear && <p className="note">Si la dejas vacía, le llega un correo de invitación para crear su clave.</p>}
      {error && <p className="acceso-err" role="alert">{error}</p>}
      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn primary sm" disabled={busy}>{crear ? 'Crear cuenta' : 'Guardar'}</button>
        <button className="btn sm ghost" type="button" onClick={onFin}>Cancelar</button>
      </div>
    </form>
  );
}

export function MiClave() {
  const closeDrawer = useStore((s) => s.closeDrawer);
  const toast = useStore((s) => s.toast);
  return (
    <>
      <Cabecera icon="candado">Cambiar mi clave</Cabecera>
      <div className="drawer-b">
        <NuevaClave titulo="" onListo={() => { toast('Clave cambiada.'); closeDrawer(); }} />
      </div>
    </>
  );
}
