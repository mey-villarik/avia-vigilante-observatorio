# Recomendaciones seguras

Mejora 7 de la PoC (documento del revisor). Antes AVIA podía recomendar «la ruta está habilitada, se puede viajar» sin que una fuente oficial lo hubiera dicho hace poco, y no decía qué faltaba saber antes de actuar.

## Qué lleva cada recomendación

`vigilante.recomendacion_segura(id)` en `db/generico/25_recomendaciones_seguras.sql`:

| Campo | Qué es |
| --- | --- |
| `texto` | La recomendación. Si afirma algo sin verificar, empieza por «Sin confirmar:» |
| `para_quien` | A quién va (lo da el modelo; si no, los actores de la señal) |
| `verificar_con` | Con quién comprobarlo según el tema: parámetro `verificar_con` del cliente (ABC para vial, DGAC/NAABOL para vuelos, SENAMHI para clima…) |
| `falta_saber` | Lo que propuso el modelo + lo que añade la base (ver abajo) |
| `afirma_sin_verificar` y `aviso` | El texto da algo por habilitado, operativo, transitable, normal, abierto al tránsito o seguro, o dice «se puede viajar», y no hay fuente oficial recogida ni persona que lo verificara en las últimas 24 h |
| `dato_oficial` | Hora del último dato oficial de la señal |

Lo que añade la base a «falta saber»:
- certeza posible o rumor → confirmar que el hecho es cierto;
- convocado → si se mantiene en la fecha anunciada;
- vial, conectividad o clima sin dato oficial de las últimas 24 h → el estado actual, con la hora del último dato oficial;
- oportunidad de financiamiento o eventos sin plazo → la fecha límite.

Las negaciones («no está habilitada», «no se puede viajar») no cuentan como afirmación: son prudentes. La base no reescribe el texto de AVIA; lo marca y el panel y AVIA muestran el aviso.

## Dónde se ve

- Panel: en la ficha, encima de las recomendaciones, un recuadro con «Para», «Verificar con», «Falta saber» y, si toca, el aviso en rojo; la recomendación marcada lleva «Sin confirmar:».
- AVIA (`avia_api.py`, regla 10): cada recomendación dice qué hacer, para quién, con quién verificar y «Falta saber:». Nunca da por operativa una ruta, vuelo o destino sin fuente oficial de las últimas 24 h, y cita la fuente y la hora cuando la hay. Si la señal trae `afirma_sin_verificar`, no recibe la frase original.
- Modo local del chat: el bloque «Recomendación» y las listas de riesgos y oportunidades usan las mismas reglas (`web/src/lib/recomendacion.ts`).
- Clasificador 1.4: pide `para_quien` y `falta_saber` y prohíbe esas afirmaciones; `analizador.py` los valida.

## Cómo aplicarlo

1. Supabase: ejecutar `db/generico/25_recomendaciones_seguras.sql` (necesita el 24). Comprobar:
   `SELECT codigo, vigilante.recomendacion_segura(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 5;`
2. VPS: copiar `avia_api.py`, `analizador.py` y `prompt_clasificador.md` (comparar antes con `diff`) y reiniciar `avia-api`.
3. Web: desplegar.

Para cambiar con quién se verifica cada tema: `UPDATE vigilante.parametros SET valor = valor || '{"vial": "..."}' WHERE clave = 'verificar_con' AND cliente_id = (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');`

Prueba: `db/generico/99_prueba_recomendaciones.sql` (termina en `ROLLBACK`).
