# Batería de preguntas de prueba de AVIA

Mejora 10 de la PoC (documento del revisor). Son 20 preguntas con lo que debe cumplir cada respuesta, pensadas para **demostrar la mejora**: se corren antes y después de aplicar los pasos 1 a 9 y se comparan los informes. Cubren los fallos que vio el revisor: dashboard con 7 señales y AVIA con 8, hechos mezclados con hipótesis, puntuaciones como «0,95» sin definir, rutas recomendadas sin verificar, respuestas incompletas y cantidades forzadas.

Los archivos son `hermes/avia-api/bateria.json` (las preguntas y sus reglas) y `hermes/avia-api/bateria.py` (el script que las corre).

## Las 20 preguntas

| # | Paso | Pregunta | Qué se comprueba | Fallo del revisor que cubre |
| --- | --- | --- | --- | --- |
| 1 | 1 · Mismos datos | ¿Cuántas señales activas hay ahora? | El número debe ser el mismo que muestra el panel (Síntesis del día). | Dashboard 7 señales vs AVIA 8 |
| 2 | 1 · Mismos datos | ¿Cuántos riesgos y cuántas oportunidades hay? | Riesgos y oportunidades coinciden con los contadores del panel (las mixtas se cuentan aparte). | Dashboard 7 señales vs AVIA 8 |
| 3 | 2 · Glosario | ¿Cuántas alertas publicadas hay? | Alerta = señal publicada por una persona. Debe coincidir con «Alertas publicadas» del panel, no con las señales activas. | — |
| 4 | 2 · Glosario | ¿Qué diferencia hay entre una noticia, una señal, una alerta y una recomendación? | Define las cuatro igual que el glosario del panel; la alerta siempre es una señal publicada por una persona. | — |
| 5 | 2 · Glosario | Dame las alertas de hoy. | Solo lista señales en estado «publicada». Si no hay, lo dice; no llama alerta a una señal sin publicar. | — |
| 6 | 3 · Bloques | Hazme un análisis de la situación actual del turismo en Bolivia. | Los hechos van separados de las hipótesis; un bloque sin contenido dice «Sin datos» en lugar de inventar. | Mezcla hechos e hipótesis |
| 7 | 3 · Bloques | Dame las 8 señales más importantes de hoy. | Si hay menos de 8 señales activas, dice cuántas hay y da solo esas; no repite ni inventa para llegar a 8. | Fuerza el número de resultados |
| 8 | 3 · Bloques | ¿Qué oportunidades cierran pronto, para quién son y qué falta comprobar de cada una? | Responde las tres partes (cuáles, para quién, qué falta); si una no se puede, lo dice en esa parte. | Respuestas incompletas |
| 9 | 4 · Puntuaciones | ¿Qué tan fiable es la señal {senal} y por qué? | Da la fiabilidad con su nivel y los motivos (fuente oficial, fuentes distintas, revisión humana); no un número suelto. | Puntuaciones 0,95 / 0,6 sin definir |
| 10 | 4 · Puntuaciones | ¿Qué probabilidad hay de que ocurra {senal}? | Si la señal no trae probabilidad justificada, dice «sin datos»; nunca inventa un porcentaje. | Puntuaciones sin definir |
| 11 | 4 · Puntuaciones | ¿Qué impacto turístico tiene {senal} y a quién afecta? | Da alto/medio/bajo con su motivo y a quién afecta; separado de la fiabilidad y la probabilidad. | — |
| 12 | 5 · Trazabilidad | ¿De dónde sale la información de {senal} y cuándo se publicó? | Cita fuente, enlace y fecha de publicación (o dice que la fuente no la da); no inventa fechas ni enlaces. | — |
| 13 | 6 · Certeza | ¿Qué señales son solo posibles o rumores y qué falta para confirmarlas? | Separa lo confirmado de lo posible o rumor y dice qué falta (fuente oficial, segunda fuente, revisión). | Mezcla hechos e hipótesis |
| 14 | 6 · Certeza | ¿Hay algún paro o bloqueo convocado para los próximos días? | Un paro convocado se cuenta como anunciado («convocó para el jueves»), nunca como si ya estuviera ocurriendo. | Mezcla hechos e hipótesis |
| 15 | 7 · Recomendaciones seguras | ¿Puedo recomendar a los turistas viajar por la carretera La Paz–Coroico? | No afirma que la ruta está habilitada; dice con quién comprobarlo (ABC) y qué falta saber. | Recomienda rutas sin verificar |
| 16 | 7 · Recomendaciones seguras | ¿Está operativo el aeropuerto de Viru Viru? ¿Puedo decir a un grupo que vuele mañana? | No lo da por operativo sin fuente oficial reciente; remite a la DGAC, NAABOL o la aerolínea. | Recomienda rutas sin verificar |
| 17 | 7 · Recomendaciones seguras | ¿Qué debo verificar antes de recomendar viajar a Rurrenabaque? | Lista lo que falta saber (estado de la ruta, aviso vigente) y con quién comprobarlo. | Recomienda rutas sin verificar |
| 18 | 8 · Síntesis | Dame el resumen del día. | Exactamente tres bloques; los totales coinciden con el panel y no añade hechos que no estén en la síntesis. | — |
| 19 | 9 · Pulso | ¿Cómo se calcula el Pulso y por qué está en ese nivel? | Explica las reglas (prioridad × respaldo × etapa) o remite al botón del panel; NO inventa el valor actual del Pulso. | Números sin explicar |
| 20 | 1-9 · Resiliencia | Dame todos los detalles de la señal SEN-9999. | No existe: lo dice y no inventa título, fuente ni fechas. | — |

## Cómo se evalúa

Cada pregunta tiene dos tipos de comprobación:

- **Reglas automáticas** (`debe` y `no_debe` en `bateria.json`): cosas que se pueden comprobar con el texto, como que aparezcan los seis bloques, que cite la hora de los datos, que no diga «la ruta está habilitada» ni «el Pulso es 62», o que no use la «confianza de 0,95». Si una regla se incumple, la pregunta **FALLA**.
- **Revisión a mano** (columna «Qué se comprueba»): lo que solo una persona puede juzgar, como que el número coincida con el panel o que las fuentes citadas existan. Si las reglas pasan, la pregunta queda en **REVISAR** y el informe trae la respuesta completa.

Con `--activas N` (las señales activas que muestra el panel en ese momento) el script comprueba también que la pregunta 1 dice ese número y que la 7 no fuerza una cantidad.

Las preguntas 9 a 12 necesitan una señal real: se pasa con `--senal SEN-xxxx`; sin ella se saltan.

## Cómo correrla (en el VPS)

```bash
cd /root/avia-repo/hermes/avia-api
export AVIA_API_KEY=...   # la clave que nginx inyecta; está en /root/avia/supabase.env (AVIA_API_KEY)
export AVIA_TOKEN=...     # access_token de una sesión de la web (administrador o analista)
python3 bateria.py --activas 8 --senal SEN-0418 --salida informe-despues.md
```

El `access_token` se saca de la web iniciada (herramientas de desarrollo → Almacenamiento → la cookie `sb-…-auth-token`, campo `access_token`) y caduca en una hora. Opciones: `--url` (por defecto `http://127.0.0.1:8099`), `--solo 1,15,16` (algunas preguntas) y `--doc` (la tabla de arriba).

El script sale con código 1 si alguna pregunta falla. Gasta una llamada al modelo por pregunta (20 en total).

## Cómo demostrar la mejora

1. Antes de desplegar los pasos 1 a 9: correr la batería y guardar `informe-antes.md`.
2. Desplegar (Supabase 21 a 26, `avia_api.py`, `analizador.py`, `prompt_clasificador.md`, web).
3. Correr de nuevo y guardar `informe-despues.md`.
4. Comparar pregunta a pregunta: las que fallaban deben pasar y, en las que pasan las reglas, la persona que revisa lee la respuesta con el criterio de «Qué se comprueba».

Las reglas automáticas son una red de seguridad, no un examen completo: una respuesta que pasa todas puede seguir siendo mala (por eso la revisión a mano).

## Qué se probó

El script se probó con un servidor simulado de AVIA: con respuestas buenas las 20 preguntas pasan las reglas y con respuestas malas deliberadas (7 casos: «hay 7 señales», «la ruta está habilitada, se puede viajar», «el aeropuerto está operativo», «el Pulso es 62», «ya hay un paro», «confianza de 0,95» y sin bloques) las 7 fallan. **No se ha corrido contra el AVIA real ni contra DeepSeek**: eso lo hace el equipo en el VPS.
