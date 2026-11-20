# Eventos dinámicos: cada evento nuevo avisa al momento

Pedido de Meysel (2026-11-20): *«los eventos tienen que ser dinámicos, como los cambios: que se queden en Eventos pero que lancen alarmas; cuando se detecte un evento, que lo avise»* y *«cuando pase un día del evento, se guarda pero se deja de mostrar en la ventana de eventos»*.

Es la misma idea que las alertas de cambio (`docs/cambios-noticias.md`), aplicada a los eventos compuestos (`docs/eventos-compuestos.md`).

## Qué cambia

| | Antes (28) | Ahora (34) |
| --- | --- | --- |
| Qué eventos avisan | Solo los de prioridad **alta** | **Todos** (`eventos_alerta_desde = "baja"`; se puede subir a `"media"` o `"alta"`) |
| Cuándo salta la ventana | Cuando AVIA lo interpretaba o a los 20 min | **Al momento** de detectarlo (`eventos_espera_hermes_min = 0`). La lectura de AVIA aparece en la misma ventana cuando llega |
| Cada cuánto busca eventos la base | Cada 5 min (pg_cron) | **Cada minuto** (y el analizador al terminar cada ronda, como antes) |
| Cada cuánto pregunta el panel | Cada minuto | **Cada 30 s**, y al volver a la pestaña |
| Sonido | Apagado por defecto, dos tonos suaves | **Alarma activada** por defecto: tono alto-bajo tres veces (distinta de la de cambios, que sube) |
| Botón de la barra | «Eventos N» (total) | **«Eventos N nuevos»** parpadeando mientras haya sin ver (rojo si alguno es de prioridad alta); sin pendientes vuelve a «Eventos N» |
| Lista de Eventos | Todos los abiertos | Los de las **últimas 24 h**, el más reciente arriba, con punto rojo los no vistos, «Marcar todo como visto» y el interruptor de la alarma |
| Pestaña del navegador | — | «(1) Evento · ORBITA» (o «(3) Avisos» si también hay cambios) |

## La ventana flotante

- Cabecera **«Evento nuevo detectado · EVC-0007 · hace 2 min»**. Si a un evento que ya se vio le entran señales nuevas, sube su versión y vuelve a sonar como **«Evento actualizado (v2): entraron señales nuevas»**.
- Si AVIA aún no lo ha interpretado, enseña las señales que coinciden; la interpretación aparece sola en la misma ventana cuando llega (no vuelve a sonar).
- Botones: **No es relevante…** (descarta para todo el equipo, con motivo), **Ver en Eventos** (abre la lista con ese evento) y **Entendido**.
- Si hay varios, salen de uno en uno en el orden en que se detectaron («+2 más»). Si a la vez hay un cambio, primero el evento y luego el cambio.

Capturas: `capturas/evento-nuevo-alarma.png` y `capturas/eventos-lista-24h.png` en los archivos del proyecto.

## 24 horas en el panel

Cada evento se ve en la lista de Eventos durante `eventos_horas_panel` (24) desde que se detectó, o desde la última vez que le entraron señales nuevas (columna `version_en`). Que AVIA lo interprete no alarga el plazo.

Pasado ese tiempo **no se borra ni se cierra**: sigue en `vigilante.eventos_compuestos` con su interpretación, Hermes lo sigue viendo por el MCP (`eventos_abiertos`) y el compositor lo sigue actualizando. Solo deja de mostrarse en el panel. Se cierra solo, como antes, cuando sus señales dejan de coincidir.

## Cómo ponerlo en marcha

1. **Supabase**: SQL Editor → pega entero `db/generico/34_eventos_dinamicos.sql` → Run. Necesita el 28. Se puede ejecutar varias veces.
   - Comprobar: `SELECT jobname, schedule FROM cron.job WHERE jobname = 'vigilante-eventos';` debe decir `* * * * *`.
   - Prueba sin dejar nada: `99_prueba_eventos_dinamicos.sql` (termina en ROLLBACK).
2. **Web**: publícala como siempre (`bash /root/avia-repo/web/desplegar.sh claude/project-thread-prpoj2`).

No hay que tocar Hermes, el MCP, las skills ni el despertador: el despertador ya lanza la interpretación cada 5 min si hay eventos pendientes.

Al publicar, a cada analista le saltarán una vez los eventos abiertos de las últimas 24 h que aún no ha visto. Con «Marcar todo como visto» en la lista se quitan de golpe.

## Parámetros

| Clave | Por defecto | Qué hace |
| --- | --- | --- |
| `eventos_alerta_desde` | `"baja"` | Prioridad mínima para la ventana con alarma: `"baja"` (todos), `"media"` o `"alta"` |
| `eventos_espera_hermes_min` | `0` | Minutos que la alarma espera a AVIA (el 34 lo pone a 0 solo si seguía en 20) |
| `eventos_horas_panel` | `24` | Horas que un evento se ve en la lista |

Volver al comportamiento del 28: `eventos_alerta_desde = '"alta"'` y `eventos_espera_hermes_min = 20`.
