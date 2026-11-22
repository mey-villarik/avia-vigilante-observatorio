# Sin duplicados: ni fuentes ni noticias ni señales repetidas

Pedido de Meysel (19-11-2026): que el sistema revise y no repita fuentes, para no repetir noticias.

Todo ocurre **en la base** (`db/generico/30_sin_duplicados.sql`), con índices únicos, disparadores y candados. Así vale aunque el recolector, Hermes, la web o dos procesos a la vez escriban al mismo tiempo. El recolector de Python no cambia.

## Las tres reglas

| Nivel | Regla | Cómo se compara | Qué pasa con la repetida |
|---|---|---|---|
| **Fuentes** | Una dirección = una fuente | Dirección normalizada: sin `http(s)://`, sin `www.`, sin barra final, sin `utm_*`, `fbclid`…, en minúsculas | No se puede dar de alta: la base responde «Esa dirección ya se vigila en la fuente X». El catálogo la reconoce escrita de cualquiera de esas formas |
| **Noticias** | Un documento = una fila | La misma dirección del documento (o el mismo id del proveedor en la misma fuente) | No se guarda; cuenta como «repetida» en la comprobación de la fuente |
| **Señales** | Un hecho = una señal | (a) alguna de sus noticias ya está en otra señal, o (b) título muy parecido a una señal viva de los últimos 7 días | No se crea otra: sus noticias se añaden como evidencia a la que ya existe, que conserva su título y resumen |

### Lo que NO se considera repetido (a propósito)

- **El mismo hecho contado por dos medios** (direcciones distintas) se guarda como dos noticias: es corroboración y sube la certeza. Pero las dos acaban en **una sola señal**.
- **Títulos parecidos con departamentos distintos**: «Alerta por lluvias en La Paz» y «Alerta por lluvias en Cochabamba» son dos señales.
- **Títulos parecidos con cifras distintas**: «FIT 2026» y «FIT 2027» son dos señales. (Si una cifra solo aparece en un título, sí se unen.)
- Señales **descartadas o cerradas** no atraen señales nuevas por título (sí por la misma noticia: lo descartado no vuelve a aparecer duplicado).

## Parámetros (editables por cliente en `vigilante.parametros`)

| Clave | Por defecto | Qué controla |
|---|---|---|
| `senal_parecido_min` | `0.6` | Parecido de títulos (0 a 1) para unir. Más alto = une menos |
| `senal_repetida_dias` | `7` | Días hacia atrás en que se buscan señales parecidas |

Ejemplos reales de parecido: «Lanzan nueva ruta turística al Salar de Uyuni» frente a «Bolivia: lanzan nueva ruta…» = 0,85 (se unen). «Boliviana de Aviación abre ruta Santa Cruz–Miami» frente a «BoA abrirá vuelo directo Santa Cruz–Miami» = 0,36 (no se unen por título; si comparten noticia, sí).

## Instalar

1. En Supabase, SQL Editor: ejecutar `db/generico/30_sin_duplicados.sql` (requiere 14 y 15; se puede ejecutar más de una vez). Activa `pg_trgm` si no lo está.
   - Al ejecutarse **junta solo las fuentes con la misma dirección exacta** que ya existan (sus noticias y señales pasan a la que se queda; el código viejo queda como alias) y **marca las noticias copiadas** con `duplicada_de` (no borra nada).
2. Mirar si ya hay señales repetidas de antes:
   ```sql
   select * from vigilante.senales_repetidas();      -- solo mira (últimos 30 días)
   select vigilante.juntar_senales_repetidas();       -- junta: la repetida pasa a «descartada» y apunta a la otra
   ```
   Lo publicado nunca se junta solo; si dos publicadas se repiten, decide una persona. **Desde el 43** sí se juntan (se queda la publicada): ver [mismo-hecho.md](mismo-hecho.md).
3. Para ver fuentes con la misma dirección (debería salir vacío tras el paso 1):
   ```sql
   select * from vigilante.fuentes_misma_direccion();
   ```
4. Prueba (opcional, no deja nada): `db/generico/99_prueba_sin_duplicados.sql`.

No hace falta tocar el VPS ni el cron: `recolector.py`, `analizador.py` y el MCP llaman a las mismas funciones de siempre.

## Qué cambia en las respuestas

- `guardar_comprobacion` / `insertar_noticias`: las copias suben el contador `repetidas`.
- `guardar_senal` (clasificador y Hermes por el MCP): si ya había señal, responde con su `codigo`, `"nueva": false`, `"repetida": true` y `"unida_por"` («misma noticia» o «título parecido (0,85)»).
- Nueva columna `signals.repetidas_unidas`: cuántas veces se intentó crear esa señal otra vez.

## Funciones nuevas

| Función | Para qué |
|---|---|
| `url_fuente(url)` | Dirección normalizada de una fuente |
| `fuentes_misma_direccion()` / `juntar_fuentes_misma_direccion()` | Ver / juntar fuentes con la misma dirección |
| `parecido(a, b)` | Parecido 0–1 de dos textos (pg_trgm) |
| `mismo_hecho(cliente, titulo_a, titulo_b)` | Parecido + sin departamentos ni cifras que se contradigan |
| `senal_existente(cliente, titulo, noticias, departamentos)` | La señal que ya cuenta ese hecho, si la hay |
| `senales_repetidas()` / `juntar_senales_repetidas()` | Ver / juntar señales repetidas anteriores al 30 |

`guardar_senal` del 15 sigue existiendo como `guardar_senal_15`; la nueva `guardar_senal` la envuelve.
