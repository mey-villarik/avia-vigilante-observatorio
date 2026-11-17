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
| Con 2 o más fuentes | verificadas con 2 o más noticias enlazadas |
| Por verificar | activas detectadas, en análisis o en verificación |
| Esperan aprobación | por verificar que requieren revisión de una persona |
| Alertas publicadas | activas publicadas |
| Noticias 24 h | noticias recogidas en las últimas 24 horas |

Las mismas reglas están en `web/src/lib/contadores.ts` solo para los datos de ejemplo y para el instante entre un cambio en pantalla y la recarga. Si cambias una, cámbiala en los dos sitios.

## Cómo aplicarlo

1. Supabase → SQL Editor: pegar `db/generico/21_contadores_unicos.sql` y Run (necesita el 19).
2. Comprobar: `SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';`
3. Prueba opcional: `99_prueba_contadores.sql` (termina en ROLLBACK).
4. VPS: copiar `hermes/avia-api/avia_api.py` a `/root/avia/avia_api.py` y `systemctl restart avia-api`; copiar `hermes/mcp-vigilante/servidor.py` donde lo use Hermes.
5. Web: `web/desplegar.sh`.
