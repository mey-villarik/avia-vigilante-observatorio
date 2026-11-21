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
| Verificadas | activas confirmadas o publicadas |
| Con 2 o más fuentes | verificadas con noticias de 2 o más fuentes **distintas** (desde el 39) |
| Por fuente oficial | verificadas con menos de 2 fuentes pero con fuente oficial: pasaron solas a Confirmadas (29) |
| Con una sola fuente | verificadas con una sola fuente no oficial (las movió una persona) |
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

## Cómo aplicarlo

1. Supabase → SQL Editor: pegar `db/generico/21_contadores_unicos.sql` y Run (necesita el 19).
   Después pegar `db/generico/39_contadores_coherentes.sql` y Run (desglose de verificadas y fuentes activas).
2. Comprobar: `SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';`
3. Prueba opcional: `99_prueba_contadores.sql` (termina en ROLLBACK).
4. VPS: copiar `hermes/avia-api/avia_api.py` a `/root/avia/avia_api.py` y `systemctl restart avia-api`; copiar `hermes/mcp-vigilante/servidor.py` donde lo use Hermes.
5. Web: `web/desplegar.sh`.
