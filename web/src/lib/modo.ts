// Datos de ejemplo: solo en desarrollo y solo si se piden de forma explícita.
// En producción (npm run build) esta constante es siempre false y la web nunca pinta
// señales, fuentes ni cifras inventadas: mientras no llegan los datos reales muestra «Cargando…».
// Para ver la demo en local: VITE_DEMO=1 npm run dev
export const DEMO = import.meta.env.DEV && import.meta.env.VITE_DEMO === '1';
