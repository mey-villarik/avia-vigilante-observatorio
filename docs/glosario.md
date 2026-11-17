# Glosario del observatorio

Mejora 2 de la PoC (documento del revisor). Panel, web pública, AVIA y Hermes usan estas cuatro palabras siempre con este significado. Van en orden: de la noticia a la recomendación.

| Palabra | Qué es | Qué no es | En la base |
| --- | --- | --- | --- |
| **Noticia** | Lo que publica una fuente, tal cual: nota de prensa, comunicado oficial, norma, convocatoria. AVIA la recoge con su enlace y su fecha. | No es una conclusión: una sola noticia puede ser parcial o falsa. | `raw_items` |
| **Señal** | Un hecho que importa al turismo, armado por AVIA a partir de una o varias noticias sobre lo mismo. Tiene naturaleza (oportunidad, riesgo o mixta), territorio y etapa (detectada, en análisis, en verificación, confirmada, publicada, descartada). | No es una alerta: casi todas se quedan en el panel del equipo. | `signals` |
| **Alerta** | Una señal que una persona del equipo confirmó y publicó en la web pública o en Telegram. Puede ser riesgo u oportunidad. | No hay alerta sin aprobación de una persona; un escenario (predicción) nunca es alerta. | `alerts` (señal en «publicada») |
| **Recomendación** | Lo que AVIA propone hacer ante una señal: acción concreta, para quién y qué falta comprobar antes de actuar. | No es una orden ni un hecho: la decide una persona. | `soluciones` de la señal, `accion` de la ficha de oportunidad, `recomendacion` de la alerta |

**Ojo con el SENAMHI:** sus «alertas naranja/roja» son el nombre del aviso de la fuente. Se citan como «aviso naranja del SENAMHI» y no cuentan como alertas del observatorio.

## Dónde se aplica

- Web: `web/src/lib/glosario.ts` (fuente del texto), ventana «Glosario» desde la Síntesis del día y desde el chat («¿qué es una señal?»).
- Etiquetas cambiadas: «Soluciones y acciones» → «Recomendaciones de AVIA»; «Siguiente paso» → «Recomendación»; «Evidencia» → «Noticias que la sostienen»; web pública «avisos» → «alertas»; Cadena del conocimiento con «Alertas publicadas».
- Contadores (21): «alertas publicadas» = señales en «publicada»; «señales activas» no incluye noticias ni alertas aparte.
- AVIA: `GLOSARIO` en `hermes/avia-api/avia_api.py` (chat y análisis), sección Glosario en la skill de Hermes y en el prompt del clasificador.

Si cambias una definición, cámbiala en `glosario.ts`, `avia_api.py` y aquí.
