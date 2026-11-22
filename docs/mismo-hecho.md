# Un hecho, una señal: el mismo evento con otras palabras

Pedido de Meysel (21-11-2026): «Juntar el mismo evento en una sola señal: derrumbes Cochabamba–Santa Cruz y los dos festivales de la Canción Boliviana. Cada hecho aparece una vez con «2 fuentes».»

Archivo: `db/generico/43_mismo_hecho.sql` (necesita del 01 al 42). Prueba: `db/generico/99_prueba_mismo_hecho.sql`.

## Por qué seguían duplicados tras el 30

El 30 ([sin-duplicados.md](sin-duplicados.md)) unía dos señales solo si **compartían noticia** o si **los títulos se parecían** (trigramas ≥ 0,6). Con los títulos reales no llegaba:

| Señal A | Señal B | Parecido |
|---|---|---|
| Canción Boliviana 2026: preselecciones del 6 y 7 de noviembre; final en Oruro el 20-21 de noviembre | Festival Nacional de la Canción Boliviana 2026: Oruro, 20-21 de noviembre | 0,53 |
| Derrumbes en la carretera Cochabamba–Santa Cruz | Deslizamientos bloquean la ruta Cochabamba - Santa Cruz en el km 120 | 0,33 |

Además, `juntar_senales_repetidas()` **nunca tocaba dos señales publicadas**, así que en la web pública el festival salía dos veces, cada una con una sola fuente y «En verificación».

## Qué hace ahora

### 1. La base compara el hecho, no solo el título

Cada señal guarda sus **palabras clave** (`signals.claves`): las del título sin palabras vacías, cifras ni nombres de lugar, en singular y con sinónimos (derrumbe = deslizamiento = deslave = mazamorra; carretera = ruta = vía = tramo; festival = certamen…).

Dos señales son el **mismo hecho** si no se contradicen:

- misma categoría (clima y vial cuentan como compatibles: un derrumbe puede venir de los dos lados),
- naturaleza compatible (riesgo y oportunidad no se mezclan; mixta sí),
- algún departamento en común (una de todo el país vale para cualquiera),
- fechas de evento que se solapan, plazos iguales, el mismo año y cifras que no chocan,

**y además** se cumple una de estas:

- el título se parece como antes (≥ `senal_parecido_min`, 0,6), o
- comparten **al menos 2 palabras clave** que son **al menos el 60 %** de las del título más corto, y una de ellas **no es débil**. Palabras débiles: vía, bloqueo, alerta, festival, feria, evento… Solas no bastan: «bloqueo de transportistas» y «derrumbe que bloquea» la misma ruta son hechos distintos.

Resultados con los casos reales (están en la prueba):

| A | B | ¿Mismo? | Por qué |
|---|---|---|---|
| Canción Boliviana 2026: preselecciones… final en Oruro | Festival Nacional de la Canción Boliviana 2026: Oruro | Sí | canción, boliviana |
| Derrumbes en la carretera Cochabamba–Santa Cruz | Deslizamientos bloquean la ruta… Cochabamba - Santa Cruz | Sí | derrumbe, vía |
| Bloqueo de transportistas en la carretera Cbba–SCZ | Derrumbe bloquea la carretera Cbba–SCZ | No | solo bloqueo y vía (débiles) |
| Derrumbe en la carretera La Paz–Yungas | Derrumbe en la carretera Cochabamba–Santa Cruz | No | otros departamentos |
| Festival de la Canción Boliviana 2025 | Festival de la Canción Boliviana 2026 | No | otro año |
| Sucre: National Night en Kultur Berlin | Sucre: Sweet Monday en Kultur Berlin | No | solo la sede |

Para probar dos títulos cualesquiera:

```sql
select * from vigilante.mismo_hecho_titulos('orbita-bolivia', 'título A', 'título B');
```

### 2. El clasificador lo confirma (`misma_senal`)

El clasificador ya recibía con cada noticia las señales que pueden hablar de lo mismo; ahora son **hasta 3** y se buscan también por palabras clave. Con el prompt **clasificador-1.9**, si la noticia cuenta el mismo hecho con otras palabras (p. ej. «Tránsito restringido entre Colomi y Villa Tunari» para los derrumbes), responde `"misma_senal": "SEN-…"` y la base la suma a esa señal. Solo vale un código de los que se le mandaron; `analizador.py` descarta cualquier otro.

Si la noticia **cambia** la señal (nueva fecha, desvío, cancelación), sigue el camino del 31 (`cambio`): no se une por parecido, para que la señal nueva cuente lo que pasa ahora.

### 3. Las que ya están repetidas se juntan solas, publicadas incluidas

Tarea de pg_cron **`vigilante-mismo-hecho`** cada 15 minutos: `juntar_senales_repetidas()`.

- **Se queda** la publicada; si las dos lo están, la que tiene más fuentes; luego la más antigua.
- La otra pasa a **«descartada»** con el motivo «Mismo hecho que SEN-…», **su alerta sale de la web** y sus noticias, departamentos y oportunidades pasan a la que se queda, que muestra **«2 fuentes»** (y, si eso la hace verificada, deja de decir «En verificación»).
- La que se queda conserva su título, resumen y categoría; la prioridad nunca baja.
- Todo queda en `vigilante.senales_juntadas`.

¿Se juntaron dos que no eran lo mismo?

```sql
select vigilante.separar_senal('SEN-0123');   -- la repetida vuelve a Detectadas con sus noticias
```

La tarea no vuelve a juntar ese par. Si estaba publicada, una persona la vuelve a publicar.

¿La regla no ve dos que sí son lo mismo?

```sql
select vigilante.juntar_senales('SEN-que-se-queda', 'SEN-repetida');
```

(Si se pasan al revés y la «repetida» es la publicada, se cambian los papeles: siempre se queda la publicada.)

## Instalar

1. Supabase → SQL Editor: pegar entero `db/generico/43_mismo_hecho.sql` y **Run**. Se puede ejecutar más de una vez. Al final muestra los pares que ve repetidos (deberían salir los festivales y los derrumbes).
2. Juntarlos ya, sin esperar a la tarea:
   ```sql
   select vigilante.juntar_senales_repetidas();
   ```
3. VPS: copiar `hermes/analizador/analizador.py` y `hermes/analizador/prompt_clasificador.md` (prompt 1.9). El cron del analizador no cambia.
4. Prueba (opcional, no deja nada): `db/generico/99_prueba_mismo_hecho.sql`.

La web y el MCP no cambian: el panel y la web pública ya cuentan las fuentes con `respaldo_senal`.

## Parámetros (`vigilante.parametros`, editables por cliente)

| Clave | Por defecto | Qué controla |
|---|---|---|
| `hecho_clave_n` | `2` | Palabras clave que deben compartir |
| `hecho_clave_min` | `0.6` | Proporción mínima de las del título más corto |
| `hecho_palabras_debiles` | vía, bloqueo, alerta, festival, feria… | Palabras que solas no bastan |
| `hecho_sinonimos` | derrumbe, vía, bloqueo, inundación, lluvia, incendio… | Grupos de sinónimos |
| `hecho_palabras_vacias` | `[]` | Palabras extra que no cuentan |
| `hecho_vigente_dias` | `60` | Una señal con evento o plazo por llegar se sigue comparando hasta esta antigüedad (antes solo 7 días) |
| `hecho_juntar_publicadas` | `true` | `false`: la tarea no junta dos publicadas (solo las muestra `senales_repetidas()`) |

Si se cambian los sinónimos o las palabras vacías, volver a ejecutar el 43 recalcula `signals.claves`.

## Funciones

| Función | Para qué |
|---|---|
| `palabras_clave(cliente, texto)` | Palabras clave de un título |
| `comparar_hechos(cliente, a, b)` / `mismo_hecho_titulos(cliente, a, b)` | ¿Mismo hecho? con motivo |
| `senal_del_hecho(cliente, señal, noticias)` | La señal que ya cuenta ese hecho (la usa `guardar_senal`) |
| `senales_repetidas()` | Pares repetidos (solo mira), con motivo y cuántas están publicadas |
| `juntar_senales_repetidas()` | Junta los pares (lo hace pg_cron) |
| `juntar_senales(queda, repetida)` / `separar_senal(repetida)` | Juntar a mano / deshacer |

`guardar_clasificacion` del 25 sigue como `guardar_clasificacion_25`; la nueva la envuelve para pasar `misma_senal`.
