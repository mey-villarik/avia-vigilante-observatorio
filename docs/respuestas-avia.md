# Respuestas de AVIA por bloques

Mejora 3 de la PoC (documento del revisor): AVIA mezclaba hechos e hipótesis, dejaba respuestas incompletas y forzaba cantidades («5 alertas» cuando había 2).

## Formato

**Pregunta simple** (un número, abrir una vista, un dato): 1 a 3 frases, sin bloques.

**Pregunta de análisis** (situación, riesgos, oportunidades, una señal, un destino, un resumen): siempre estos bloques, en este orden.

| Bloque | Qué va | Si no hay nada |
| --- | --- | --- |
| Hechos | Lo que dicen las noticias o las señales confirmadas o publicadas, con código SEN, fuente y fecha | «Sin datos» |
| Pendiente de verificar | Lo que solo cuenta una fuente no oficial o sigue sin confirmar, y qué falta para confirmarlo | «Nada pendiente» |
| Interpretación | La lectura de AVIA, marcada como tal («esto podría…») | «Sin datos» |
| Impacto turístico | A quién afecta (destinos, operadores, visitantes) y cómo | «Sin datos para medirlo» |
| Escenarios | «Si…, entonces…»: posibilidades, no predicciones | «Sin datos suficientes para plantear escenarios» |
| Recomendación | Qué hacer, para quién y qué falta comprobar | «Sin datos» |

## Reglas

1. Un bloque vacío lo dice; no se rellena, no se inventa y no se quita.
2. No se fuerzan cantidades: si piden 5 y hay 2, «Solo hay 2».
3. Se responden todas las partes de la pregunta; si una no tiene datos, se dice en esa parte.
4. Hecho e hipótesis no van en la misma frase; ante la duda, a «Pendiente de verificar».
5. Solo datos del observatorio; si algo no está, «no lo tengo en los datos del observatorio».
6. La respuesta no se corta a medias (el límite subió de 400 a 1100 tokens en el chat y de 800 a 1400 en Análisis).

## Dónde está

- `hermes/avia-api/avia_api.py`: `FORMATO` en el chat y en Análisis (este siempre con los seis bloques).
- `hermes/skills/vigilancia-fuentes-bolivia/SKILL.md`: misma regla para Hermes (radar, Telegram).
- `web/src/services/chat.ts`: `bloques()` arma la misma estructura cuando AVIA no está conectada (modo local) para resúmenes y preguntas por un código SEN.
- `web/src/components/Chat.tsx`: el chat muestra los títulos y listas (markdown).

## Cómo aplicarlo

En el VPS: copiar `avia_api.py`, reiniciar `avia-api` y desplegar la web (ver `docs/contadores.md`). La skill se copia donde Hermes la lea. Sin SQL.
