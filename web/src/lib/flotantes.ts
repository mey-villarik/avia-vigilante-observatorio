// Ventanas flotantes (alertas de eventos y de cambios, y sus listas): un clic fuera, o Escape, las
// cierra TODAS de una vez y se vuelve a la página (Meysel, 2026-11-21: «que no te obligue a darle
// aceptar»). Las alertas cerradas así no se marcan como vistas: quedan «sin ver» en los botones
// «Eventos» y «Cambios» y no vuelven a saltar en esta sesión, salvo que el evento reciba señales nuevas.
import { useCambios } from '../services/cambios';
import { useEventos } from '../services/eventos';

export function cerrarFlotantes(): void {
  useEventos.getState().posponer();
  useCambios.getState().posponer();
  useEventos.getState().setListaAbierta(false);
  useCambios.getState().setListaAbierta(false);
}
