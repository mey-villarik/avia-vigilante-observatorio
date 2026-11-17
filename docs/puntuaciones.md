# Tres puntuaciones separadas por señal

Mejora 4 de la PoC (documento del revisor). Antes salían números como «0,95» o «60 %» sin decir qué medían: la «confianza» del modelo mezclaba si la fuente es buena, si algo va a pasar y si importa al turismo.

Ahora cada señal lleva tres puntuaciones, cada una con nombre, escala y motivo:

| Puntuación | Pregunta | Quién la calcula | Escala |
| --- | --- | --- | --- |
| **Fiabilidad de la evidencia** | ¿Cuánto respaldo tiene? | La base, sin IA (`vigilante.puntuaciones`) | 0-100 · alta ≥ 70, media 40-69, baja < 40 |
| **Probabilidad** | ¿Qué tan probable es que pase o siga pasando? | El modelo, solo si la justifica con un dato del texto | 0-1 o **«sin datos»** |
| **Impacto turístico** | ¿Cuánto afecta al turismo? | El modelo, con motivo; si no lo dio, se deduce de su relevancia (1-10) y se dice | alto / medio / bajo / sin datos |

## Fiabilidad: cómo se suma

| Factor | Puntos |
| --- | --- |
| Alguna fuente oficial u organismo internacional | +50 |
| Fuentes distintas: 1 / 2 / 3 o más | +15 / +30 / +40 |
| Una persona la confirmó o publicó | +10 |
| Tope | 100 |

Ejemplo: aviso del SENAMHI (oficial) + una nota de prensa, confirmado por el analista → 50 + 30 + 10 = **90, alta**. Una sola nota de prensa sin revisar → **15, baja**.

## Reglas

- Las tres no se mezclan: una fuente muy fiable no hace que algo sea probable ni importante.
- La probabilidad nunca se inventa. Sin justificación, «sin datos».
- AVIA las nombra siempre («fiabilidad 90/100, alta»), nunca un número suelto.
- La «confianza» antigua sigue guardada pero ya no se muestra sola.

## Dónde está

- `db/generico/22_puntuaciones.sql`: `vigilante.puntuaciones(señal)`; `vigilante_bd()` la devuelve en cada señal; `guardar_clasificacion` guarda `impacto` y `probabilidad` del modelo. Prueba: `99_prueba_puntuaciones.sql`.
- `hermes/analizador/prompt_clasificador.md` (clasificador-1.2) y `analizador.py`: piden y validan impacto y probabilidad con motivo.
- `hermes/avia-api/avia_api.py`: el chat recibe las puntuaciones y la regla 7.
- Web: ficha de la señal con las tres (pasando el ratón se ve cómo se calcula), «Pendiente de tu decisión» con fiabilidad; `web/src/lib/puntuaciones.ts` repite las reglas solo para datos de ejemplo.

## Cómo aplicarlo

1. Supabase → SQL Editor: pegar `db/generico/22_puntuaciones.sql` y Run (necesita el 21).
2. Comprobar: `SELECT codigo, vigilante.puntuaciones(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 5;`
3. VPS: `git pull` en `/root/avia-repo` y copiar `hermes/analizador/analizador.py` y `prompt_clasificador.md` a `/root/avia/` **después de comparar con `diff`** por si hay cambios locales; igual con `avia_api.py`. Reiniciar `avia-api` y desplegar la web.

Las señales ya guardadas tienen fiabilidad desde el primer momento (sale de sus noticias). Las clasificadas antes del 22 no tienen relevancia, así que su impacto se deduce de su prioridad (alta → alto, media → medio, baja → bajo) y el motivo lo dice. Su probabilidad queda «sin datos»: el analizador no vuelve a clasificar noticias ya procesadas, solo las nuevas traen impacto y probabilidad del modelo.
