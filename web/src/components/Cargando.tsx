import { useStore } from '../store';
import { LogoCargando } from './LogoCargando';

/** Pantalla mientras no llegan datos reales: nunca muestra señales, cifras ni fuentes de ejemplo. */
export function Cargando({ texto = 'Cargando…' }: { texto?: string }) {
  const error = useStore((s) => s.errorDatos);
  const cargando = useStore((s) => s.cargando);
  const fallo = error && !cargando;
  return (
    <main className="cargando-pantalla" role="status" aria-live="polite">
      <LogoCargando size={88} parado={!!fallo} />
      <div className="cargando-marca">ORBITA <i>Vigilante</i></div>
      <b>{fallo ? 'No se pudieron leer los datos' : texto}</b>
      {fallo && (
        <>
          <span>{error}</span>
          <button className="btn" style={{ marginTop: 12 }} onClick={() => void useStore.getState().loadRemote()}>Reintentar</button>
        </>
      )}
    </main>
  );
}
