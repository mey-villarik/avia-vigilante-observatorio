# Pestaña Señales: tres columnas y «Pasar todas»

Pedido de Meysel (19-11-2026): menos gestión manual y más protagonismo de AVIA.

## Qué ve el equipo

| Columna | Etapas de la base que junta | Quién trabaja ahí |
|---|---|---|
| **Detectadas** | `detectada`, `en_analisis`, `en_verificacion` | AVIA: detecta, evalúa y corrobora |
| **Confirmadas** | `confirmada` | Listas para publicar |
| **Publicadas** | `publicada` (y `cerrada`) | Salen en la web pública y en Telegram |

Las descartadas no se muestran (debajo del tablero se dice cuántas hay). Para descartar una señal se abre su ficha.

Entre columna y columna hay un botón **Pasar todas (n)**. Pasa de una vez todas las señales visibles de esa columna (respeta los filtros de búsqueda, naturaleza, departamento y periodo). También se puede arrastrar una tarjeta a la columna siguiente.

## Qué NO pasa en bloque

- **Alertas de riesgo** (clima, salud, vial, seguridad) y **escenarios** que esperan aprobación: llevan la etiqueta **Por aprobar** y se quedan en Detectadas hasta que una persona las apruebe una por una desde su ficha o desde Telegram (`aprobar_senal`, del 18).
- Lo que espera aprobación solo porque aún no tiene fuente oficial **sí pasa**: pulsar el botón es la aprobación de esa persona y queda registrada con su nombre (decisión de Meysel, 19-11-2026). La regla «nunca se publica sin aprobación» se mantiene.
- **Escenarios**: aunque estén confirmados, no se publican nunca.

El botón dice cuántas se quedan y por qué.

## Cómo funciona

- Web: `web/src/views/Senales.tsx` (tablero), `passSignals` en `web/src/store.ts`, reglas en `web/src/services/senales.ts` (`columnaDe`, `motivoNoPasa`, `pasarSenales`).
- Base: `vigilante.pasar_senales(p_codigos text[], p_a 'confirmada'|'publicada', p_nota)` en `db/generico/29_pase_en_bloque.sql`. Comprueba de nuevo cada regla en el servidor (aunque la web fallara), no salta etapas (detectada → en_analisis → confirmada → publicada) y deja cada paso en el historial con el nombre de quien pulsó y la nota «Pase en bloque».
- Si el 29 aún no está en Supabase, la web hace lo mismo con `mover_senal` una por una (más lento).

## Instalar

1. Supabase, SQL Editor: pegar entero `db/generico/29_pase_en_bloque.sql` y Run (necesita del 01 al 18).
2. Opcional: `99_prueba_pase_en_bloque.sql` (termina en ROLLBACK, no deja nada).
3. VPS: `cd /root/avia-repo && git fetch origin && git checkout claude/project-thread-emz0kn && bash web/desplegar.sh`
