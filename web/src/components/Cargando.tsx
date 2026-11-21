import { useStore } from '../store';

/** Pantalla mientras no llegan datos reales: nunca muestra señales, cifras ni fuentes de ejemplo. */
export function Cargando({ texto = 'Cargando…' }: { texto?: string }) {
  const error = useStore((s) => s.errorDatos);
  const cargando = useStore((s) => s.cargando);
  return (
    <main className="empty" role="status" aria-live="polite" style={{ minHeight: '60vh', display: 'grid', placeContent: 'center' }}>
      <b>{texto}</b>
      {error && !cargando && (
        <>
          <span>No se pudieron leer los datos ({error}).</span>
          <button className="btn" style={{ marginTop: 12 }} onClick={() => void useStore.getState().loadRemote()}>Reintentar</button>
        </>
      )}
    </main>
  );
}
