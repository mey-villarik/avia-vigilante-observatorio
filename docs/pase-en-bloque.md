# Pestaña Señales: tres columnas, flechas y menos trabajo manual

Decisiones de Meysel (19-11-2026): menos gestión humana y AVIA como protagonista.

## Qué ve el equipo

| Columna | Etapas de la base que junta | Quién trabaja ahí |
|---|---|---|
| **Detectadas** | `detectada`, `en_analisis`, `en_verificacion` | AVIA: detecta, evalúa y corrobora |
| **Confirmadas** | `confirmada` | Listas para publicar. Las de **fuente oficial** llegan aquí solas |
| **Publicadas** | `publicada` (y `cerrada`) | Salen en la web pública y en Telegram |

Las descartadas no se muestran (debajo del tablero se dice cuántas hay). Para descartar una señal se abre su ficha.

Entre columna y columna hay dos botones pequeños, uno debajo del otro:

- **→ n**: pasa todas las de la izquierda a la derecha.
- **← n**: devuelve todas las de la derecha a la izquierda. Al devolver desde Publicadas pide confirmación: la alerta se retira de la web pública (el mensaje ya enviado a Telegram no se borra).

Actúan sobre las señales visibles (respetan búsqueda, naturaleza, departamento y periodo). Lo mismo se puede hacer de una en una arrastrando la tarjeta a otra columna, en los dos sentidos.

## Reglas

- **Ya no hay «Por aprobar»**: ninguna señal espera a un analista para moverse (parámetro `aprobacion_previa` = false; ponerlo en true vuelve a la regla del 18 y a sus avisos por Telegram).
- **Publicar lo hace siempre una persona**: AVIA nunca pasa nada a Publicadas por su cuenta.
- **Fuente oficial → Confirmadas directa** (parámetro `oficiales_directo_confirmadas` = true). No se aplica a escenarios ni a una señal que una persona movió a mano (si la devuelves a Detectadas, se queda ahí).
- **Un escenario nunca se publica.**
- Las etapas no se saltan; cada paso queda en el historial con el nombre de quien lo hizo y la nota «Pase en bloque».

## Cómo funciona

- Web: `web/src/views/Senales.tsx` (tablero y componente `Pase`), `passSignals` en `web/src/store.ts`, reglas en `web/src/services/senales.ts` (`columnaDe`, `motivoNoPasa`, `pasosHasta`, `pasarSenales`).
- Base: `db/generico/29_pase_en_bloque.sql`:
  - `vigilante.pasar_senales(p_codigos text[], p_a 'en_analisis'|'confirmada'|'publicada', p_nota)`.
  - `transicion_valida` admite confirmada → en_analisis y publicada → confirmada.
  - Trigger `zz_sin_aprobacion_y_oficiales`: quita `requiere_revision` y pasa las oficiales a confirmada.
- Si el 29 aún no está en Supabase, la web mueve con `mover_senal` una por una (hacia atrás no funciona hasta ejecutar el 29).
- `99_prueba_aprobacion.sql` (del 18) da otro resultado con `aprobacion_previa` = false: es lo esperado.

## Instalar

1. Supabase, SQL Editor: pegar entero `db/generico/29_pase_en_bloque.sql` y Run (necesita del 01 al 18). Al terminar ya quita «Por aprobar» y pasa a Confirmadas las oficiales que había.
2. Opcional: `99_prueba_pase_en_bloque.sql` (termina en ROLLBACK, no deja nada).
3. VPS: `cd /root/avia-repo && git fetch origin && git checkout claude/project-thread-emz0kn && git pull && bash web/desplegar.sh`
