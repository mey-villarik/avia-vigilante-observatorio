# Seguimiento de recomendaciones

Cierra el ciclo **actuar** (P2 de la auditoría para la Dirección, 22/11/2026): de cada recomendación que da AVIA queda qué se recomendó, qué se hizo y qué pasó.

## Qué se ve

- **En la ficha de cada señal**, justo debajo de «Acción recomendada · Plazo · Cómo verificar»: el estado del seguimiento, la última nota, quién la registró y cuándo, y el historial (últimos 5 cambios, cada uno con la recomendación que había en ese momento).
- **En «Decisiones de hoy»** (vista Dirección): el mismo recuadro, en corto, debajo de cada ficha.
- **Panel «Seguimiento de recomendaciones»** (vista Dirección, debajo de las decisiones): cuántas hay pendientes, en curso, resueltas y sin efecto, y la lista. «Abiertas» = pendientes y en curso; «Cerradas (7 días)» = resueltas o sin efecto en la última semana, con lo que pasó.
- **Chat AVIA**: cada señal lleva su seguimiento y, si la pregunta habla de seguimiento, pendientes, qué se hizo o en qué quedó, recibe el bloque SEGUIMIENTO (regla 18). AVIA no cambia estados ni dice que algo se resolvió si no está guardado.

## Reglas

| Estado | Significa |
|---|---|
| Pendiente | Nadie la ha tomado todavía. Es el estado si no hay nada guardado. |
| En curso | Alguien está actuando. |
| Resuelta | Se actuó y quedó resuelto. |
| Sin efecto | No hizo falta, no se pudo o no sirvió. |

- Solo **analistas y administradores** cambian el estado; el visor lo ve.
- Para **Resuelta** y **Sin efecto** hay que escribir una nota: qué se hizo, quién actuó y qué pasó. Para En curso y Pendiente la nota es opcional.
- **No hay campo de responsable** (la Dirección no tiene responsables por eje). Quién actuó va en la nota; la base guarda además quién registró el cambio.
- Se guarda el texto de la recomendación en el momento del cambio. Si después AVIA cambia la recomendación, la ficha avisa: «AVIA cambió la recomendación desde entonces».
- El panel cuenta como **por atender** las recomendaciones que pesan para la Dirección: riesgos en Acción o Atención y oportunidades que cierran o empiezan en 7 días. Lo demás no sale como pendiente para no llenar la lista.

## Dónde vive

- Base: `db/generico/50_seguimiento_recomendaciones.sql`: tablas `vigilante.seguimiento_recomendaciones` y `vigilante.seguimiento_historial`, `vigilante.seguir_recomendacion(codigo, estado, nota)` (la web), `seguimiento_senal(id)` y `seguimiento_resumen(cliente)`. `vigilante_bd()` y `vigilante_json()` añaden `seguimiento` a cada señal y, arriba, el resumen. Prueba: `99_prueba_seguimiento.sql`.
- Web: `web/src/lib/seguimiento.ts` (mismas reglas), `services/seguimiento.ts`, `components/SeguimientoReco.tsx`, panel en `views/Direccion.tsx`, acción `followUp` en `store.ts`.
- Chat: `avia_api.py`, regla 18 y bloque SEGUIMIENTO.

## Cómo instalarlo

1. Supabase, SQL Editor: pegar entero `db/generico/50_seguimiento_recomendaciones.sql` y Run (necesita el 49). Si más adelante se vuelve a ejecutar el 49, ejecutar después otra vez el 50 (los dos redefinen `vigilante_bd()`).
2. VPS: copiar `hermes/avia-api/avia_api.py` y reiniciar el servicio del chat.
3. Desplegar la web: `bash /root/avia-repo/web/desplegar.sh claude/project-thread-cgtcig`.

Comprobar: `SELECT jsonb_pretty(vigilante.seguimiento_resumen(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';`
