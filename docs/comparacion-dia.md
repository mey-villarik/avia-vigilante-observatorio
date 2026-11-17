# Cambios desde ayer

Complemento de la [síntesis del día](sintesis-dia.md): la síntesis dice cómo está todo ahora; esto dice qué cambió en las últimas 24 h.

## Qué devuelve la base

`vigilante.comparacion_dia(cliente)` en `db/generico/27_comparacion_dia.sql`. Va en `vigilante_bd()` como `comparacion_dia`.

| Clave | Qué lleva |
| --- | --- |
| `senales_nuevas` | Señales activas creadas en las últimas 24 h (código, título, certeza, naturaleza) |
| `subieron_certeza` | Señales cuya certeza es mayor que hace 24 h (`antes`, `ahora`). Orden: rumor < posible < convocado < confirmado |
| `bajaron_certeza` | Lo contrario |
| `resueltas` | Cerradas o descartadas en 24 h (`como`: `cerrada`, `descartada`), o cuyo evento o plazo terminó en ese tiempo (`terminada`) |
| `conteos` | Totales de cada lista (las listas traen como máximo 10) |
| `comparable` | `false` mientras no haya 24 h de registro de certezas: subieron/bajaron van vacías y se dice |

## Por qué hay una tabla nueva

La certeza no se guarda: se calcula con las fuentes y el estado de la señal ([certeza.md](certeza.md)). `updated_at` solo dice que algo cambió, no qué certeza había ayer. Por eso `vigilante.certeza_registro` guarda una fila cada vez que cambia el nivel de una señal, y la tarea de pg_cron `vigilante-certezas` (cada 15 min) llama a `vigilante.registrar_certezas()`. El 27 hace la primera foto al aplicarse: la subida y bajada de certeza se pueden comparar a partir de 24 h después.

## Dónde se ve

- **Panel**, en la Síntesis del día: un recuadro «Cambios desde ayer» con los conteos (N señales nuevas, N subieron de certeza, N bajaron, N resueltas). Si todo es 0 o la base aún no lo trae, no se muestra. Al pasar el ratón por cada conteo salen los títulos.
- **AVIA** (`hermes/avia-api/avia_api.py`): si la última pregunta habla de qué cambió, novedades, «comparado con ayer», «desde ayer» o «últimas 24 h», el prompt lleva el bloque CAMBIOS DESDE AYER y la regla 13 le pide responder en cuatro bloques (Nuevas, Subieron de certeza, Bajaron de certeza, Resueltas) sin recalcular nada.
