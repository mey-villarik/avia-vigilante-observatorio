// Evolución del Pulso de ejemplo (solo con VITE_DEMO=1): hace 7 días guardado, hace 30 reconstruido.
import type { PulsoEvolucion } from '../types';

const dia = (n: number) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);

export const PULSO_EVOLUCION_DEMO: PulsoEvolucion = {
  hace_7: { dia: dia(7), riesgo: 22, oportunidad: 44, vigilancia: 'Vigilancia', reconstruido: false },
  hace_30: { dia: dia(30), riesgo: 52, oportunidad: 41, vigilancia: 'Atención', reconstruido: true },
  desde: dia(40),
  registro_desde: dia(12),
  umbral_estable: 5,
};
