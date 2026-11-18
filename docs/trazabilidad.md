# Trazabilidad mínima por señal

Mejora 5 de la PoC (documento del revisor). Antes cada enlace llevaba una sola «fecha» que mezclaba cuándo publicó la fuente con cuándo la recogió AVIA, y no se veía cuándo se comprobó por última vez ni quién.

## Qué lleva cada señal

| Dato | De dónde sale |
| --- | --- |
| Fuente (nombre, si es oficial) | `sources` de cada noticia enlazada; la oficial va primero |
| Enlace | `raw_items.url` de la noticia |
| Fecha de publicación | La que da la fuente (`raw_items.publicado_en`). Si no la da: «la fuente no da fecha» |
| Fecha de recogida | Cuándo la leyó AVIA (`raw_items.recolectado_en`) |
| Detectada | Cuándo AVIA creó la señal (`signals.created_at`) |
| Última noticia | La más reciente que la alimentó |
| Fuente comprobada | Última vez que AVIA volvió a leer alguna de esas fuentes |
| Última verificación | Última decisión de una **persona** (pidió verificación, confirmó, publicó o descartó), con quién y cuándo. Si no hay: «Sin verificar por una persona» |

Las señales antiguas copiadas de `vigilante.json` (sin noticias enlazadas) muestran sus enlaces con «fecha sin distinguir»: no se sabe si es publicación o recogida, y se dice.

## Dónde se ve

- **Ficha de la señal**: sección «Trazabilidad» con las fechas y cada noticia (Publicada / Recogida, sello «Oficial»).
- **AVIA** (regla 8 en `avia_api.py`): en «Hechos», cada hecho con fuente, enlace y fecha de publicación; si no hay fecha, lo dice; nunca inventa fechas ni enlaces. Recibe hasta 3 fuentes por señal.
- **Gestión interna fuera del chat** (regla 15 de AVIA): quién verificó una señal y cuándo se ve en la ficha del panel, pero AVIA no lo dice en el chat salvo que se le pregunte de forma explícita.
- **Modo local** (`bloques()`): mismo formato.

## Dónde está

- `db/generico/23_trazabilidad.sql`: `vigilante.trazabilidad(señal)`; `vigilante_bd()` la devuelve en cada señal. Prueba: `99_prueba_trazabilidad.sql`.
- `web/src/lib/trazabilidad.ts`: formato de fechas en hora de Bolivia y, solo para datos de ejemplo, la misma estructura sin inventar fechas.

## Cómo aplicarlo

1. Supabase → SQL Editor: pegar `db/generico/23_trazabilidad.sql` y Run (necesita el 22).
2. Comprobar: `SELECT codigo, vigilante.trazabilidad(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 3;`
3. VPS: `git pull`, comparar con `diff` y copiar `avia_api.py`; reiniciar `avia-api`; desplegar la web.

La «última verificación» solo cuenta cambios hechos por una persona con sesión iniciada (su id de Supabase Auth). Los cambios automáticos (tareas programadas, Hermes) no cuentan como verificación.
