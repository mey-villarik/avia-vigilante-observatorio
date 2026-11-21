# Panel y AVIA cuentan lo mismo

Mejora 1 de la PoC (documento del revisor): el panel decía **7 señales** y AVIA **8**.

## Por qué pasaba

Los dos leían la misma base (`vigilante_bd()`), pero cada uno filtraba y contaba a su manera:

| | Panel | Chat AVIA |
| --- | --- | --- |
| Descartadas | las quitaba | las contaba |
| Señal «cerrada» en la base | la mostraba como «detectada» y la contaba | la veía como cerrada |
| Oportunidad con la ficha vencida | la quitaba (en el navegador) | la contaba |
| Ficha de oportunidad vencida ayer | la quitaba | seguía un día más |
| Cuántas veía | todas | las 10 últimas, y el modelo contaba la lista |
| Momento | recarga cada 5 min | caché de 2 min |

## Cómo queda

Una sola lista y un solo conteo, en la base (`db/generico/21_contadores_unicos.sql`):

- `vigilante.senales_visibles(cliente)`: lo que se muestra (retención, vigencia del 19, sin cerradas, sin oportunidades con la ficha vencida). Panel, chat y `vigilante.json` salen de aquí.
- `vigilante.contadores(cliente)`: los números con la hora del cálculo. `vigilante_bd()` los devuelve en `contadores`.
- El panel muestra esos números tal cual y debajo **«Datos actualizados a las HH:MM (hora de Bolivia)»**.
- El chat (`hermes/avia-api/avia_api.py`) recibe los mismos contadores y la hora, con la orden de usarlos tal cual y citarlos («según los datos actualizados a las HH:MM»). Recibe hasta 40 señales activas (antes 10, con descartadas).
- Hermes tiene la herramienta `contadores` en el MCP (`hermes/mcp-vigilante/servidor.py`) para Telegram y otros canales.
- Al preguntar a AVIA, si los datos del panel tienen más de 1 minuto, el panel se recarga a la vez, para que pantalla y respuesta sean del mismo momento.

## Definiciones

| Contador | Qué cuenta |
| --- | --- |
| Señales activas | visibles que no están descartadas |
| Oportunidades / Riesgos / Mixtas | activas de cada naturaleza (las tres suman las activas) |
| Plazo corto | activas que no son riesgo con plazo en menos de 15 días |
| Riesgos altos | riesgos de prioridad alta |
| Verificadas | activas confirmadas o publicadas, que no son escenario, con fuente oficial **o** 2 o más fuentes distintas (regla única, desde el 40) |
| Con 2 o más fuentes | verificadas con noticias de 2 o más fuentes **distintas** |
| Por fuente oficial | verificadas con menos de 2 fuentes pero con fuente oficial (las dos partes suman las verificadas) |
| Confirmadas sin verificar | confirmadas o publicadas con una sola fuente no oficial (o escenarios): **no** son verificadas (desde el 40) |
| Alertas verificadas | publicadas que son verificadas; las demás publicadas salen «En verificación» en la web pública |
| Por verificar | activas detectadas, en análisis o en verificación |
| Esperan aprobación | por verificar que requieren revisión de una persona |
| Alertas publicadas | activas publicadas |
| Noticias 24 h | noticias recogidas en las últimas 24 horas |
| Fuentes activas | fuentes del catálogo que AVIA vigila (no eliminadas, ni en pausa, ni propuestas sin aprobar) |
| Fuentes en pausa | en pausa o propuestas por AVIA sin aprobar; no cuentan como activas |

## Contadores que cuadran (39)

Se veía «Verificadas 59 · 2 con 2 o más fuentes» y «39 fuentes» en Panorama frente a «Fuentes leyendo bien: X de 33» en el Pulso.

- **Verificadas**: no faltaban 57. Desde el 29 las señales de fuente oficial pasan solas a Confirmadas con una sola noticia. Ahora el panel muestra el desglose completo y las tres partes suman el total: «2 con 2 o más fuentes · 55 por fuente oficial · 2 con una sola fuente». Además «2 fuentes» cuenta fuentes distintas, no noticias (dos notas del mismo medio son una fuente).
- **Fuentes**: las 39 incluían las 6 en pausa o propuestas; el Pulso solo miraba las 33 activas. Ahora Panorama, la cabecera del panel Fuentes, el aviso de carga y el Pulso dicen «33 fuentes activas · 6 en pausa». La pestaña Fuentes sigue mostrando el total del catálogo con las activas al lado.
- Si la base aún no tiene el 39, la web completa el desglose con su propio cálculo sin cambiar el total de la base.

Las mismas reglas están en `web/src/lib/contadores.ts` solo para los datos de ejemplo y para el instante entre un cambio en pantalla y la recarga. Si cambias una, cámbiala en los dos sitios.

## «Verificada» significa una sola cosa (40)

Seguía viéndose «Verificadas 59» frente a «2 con 2 o más fuentes», y la palabra quería decir tres cosas:
el contador contaba toda señal confirmada o publicada (también las pasadas en bloque con una sola noticia
no oficial), la web pública ponía «Verificada» a toda alerta que no venía de «En verificación», y AVIA
llamaba «confirmado» a lo que tenía fuente oficial, dos fuentes o una persona.

Regla única, en la base (`vigilante.respaldo_senal`, `db/generico/40_verificada_unica.sql`), en la web
(`web/src/lib/verificada.ts`) y en AVIA (`_verificada` en `hermes/avia-api/avia_api.py`):

> **Verificada** = confirmada o publicada, no escenario, y respaldada por una **fuente oficial** (u organismo
> internacional) **o** por **2 o más fuentes distintas**. Lo demás confirmado es **«Confirmada sin verificar»**.

- Panel: el recuadro dice «Verificadas 57 · 55 por fuente oficial · 2 con 2 o más fuentes» y debajo
  «2 confirmadas sin verificar (una sola fuente)». Las tarjetas de Confirmadas y Publicadas llevan la
  etiqueta «Verificada» o «Sin verificar» con el porqué al pasar el ratón.
- Web pública y Telegram: la base pone «Verificada» / «En verificación» con la misma regla al publicar y
  cada vez que cambian las noticias de la señal (una segunda fuente la pasa a «Verificada» sola).
- AVIA: recibe el mismo contador, `confirmadas_sin_verificar` y `verificada: true/false` en cada señal.
- Si la base aún no tiene el 40, la web y AVIA reordenan los números del 39 con la misma regla (restan
  las de una sola fuente), así que el «59» deja de salir en cuanto se despliegan.
- El grado de certeza («Confirmado», «Posible»…) es otra cosa: dice qué tan seguro es el hecho y todavía
  cuenta como «Confirmado» lo que una persona confirmó, aunque tenga una sola fuente.

## Cómo aplicarlo

1. Supabase → SQL Editor: pegar `db/generico/21_contadores_unicos.sql` y Run (necesita el 19).
   Después pegar `db/generico/39_contadores_coherentes.sql` y Run (desglose de verificadas y fuentes activas),
   y por último `db/generico/40_verificada_unica.sql` (regla única de «Verificada»).
2. Comprobar: `SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';`
3. Prueba opcional: `99_prueba_contadores.sql` (termina en ROLLBACK).
4. VPS: copiar `hermes/avia-api/avia_api.py` a `/root/avia/avia_api.py` y `systemctl restart avia-api`; copiar `hermes/mcp-vigilante/servidor.py` donde lo use Hermes.
5. Web: `web/desplegar.sh`.

## Una sola cifra de fuentes (41)

Meysel vio tres cifras de fuentes distintas: el encabezado daba una pastilla por estado (con las en pausa), el Pulso decía «leyendo bien X de Y» contando solo las OK, y la pestaña Fuentes mostraba un «Total» con las en pausa.

Ahora las tres (y Panorama, el aviso de carga, el contador del menú y AVIA) dicen lo mismo: **«28 de 33 leídas · 5 sin leer»**.

| Cifra | Qué cuenta |
| --- | --- |
| Activas | fuentes que AVIA vigila (sin las en pausa ni las propuestas sin aprobar) |
| Leídas | activas cuya última comprobación dio OK o AVISO (AVIA obtuvo respuesta; la misma regla con la que la base pone `ultimo_exito_en`) |
| Sin leer | activas en CRÍTICO (no se pudo leer) o DESCONOCIDO (aún sin comprobar) |

Activas = leídas + sin leer. Las en pausa van aparte y no cuentan.

Dónde vive: `web/src/lib/contadores.ts` → `cifrasFuentes()` (la web cuenta su propia lista, así la tabla de Fuentes cuadra con las cifras), `vigilante.contadores()` → `fuentes_leidas` y `fuentes_sin_leer` (`db/generico/41_cifra_fuentes.sql`), y `_cifras_fuentes` / `_fuentes_txt` en `hermes/avia-api/avia_api.py` (si la base aún no tiene el 41, AVIA cuenta la lista de `vigilante_bd()` con la misma regla). En la pestaña Fuentes, los recuadros Activas / Leídas / Sin leer filtran la tabla; debajo queda el detalle por estado (leídas = OK + Aviso, sin leer = Crítico + Desconocido).

Cualquier contador nuevo de fuentes usa `cifrasFuentes()`; no contar estados sueltos.
