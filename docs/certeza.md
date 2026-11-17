# Grado de certeza por señal

Mejora 6 de la PoC (documento del revisor). Antes AVIA contaba igual un hecho comprobado, un paro anunciado para la semana siguiente y un comentario de redes. La fiabilidad (paso 4) dice cuánto respaldo hay, pero no qué tipo de hecho es.

## Las cuatro palabras

| Certeza | Qué significa | Dónde va en una respuesta de AVIA |
| --- | --- | --- |
| **Confirmado** | Ya pasó o está pasando, y lo respalda una fuente oficial, dos fuentes distintas o una persona del equipo. | Hechos |
| **Convocado** | Anunciado por quien lo organiza para una fecha futura (paro, bloqueo, feria, cierre programado, convocatoria). No se sabe si ocurrirá. | Hechos, diciendo que está anunciado («convocó un paro para el jueves», no «hay paro») |
| **Posible** | Hay indicios, pero nadie lo ha confirmado. Los escenarios siempre son «posible». | Pendiente de verificar |
| **Rumor** | Sin fuente identificable, o solo redes o páginas no oficiales sin respaldo. | Pendiente de verificar |

## Quién lo decide

`vigilante.certeza(id)` en `db/generico/24_grado_certeza.sql`, en este orden:

1. **Escenario** → siempre «posible».
2. **Una persona confirmó o publicó la señal** → «confirmado» (o «convocado» si es un evento futuro). El motivo dice quién.
3. **El modelo lo propone** (clasificador-1.3, con motivo) y la base lo comprueba con las fuentes:
   - «confirmado» sin fuente oficial ni dos fuentes distintas → baja a «posible» (o «rumor» si no hay ninguna noticia);
   - «convocado» o «posible» sin ninguna noticia → baja a «rumor»;
   - la base nunca sube lo que propuso el modelo. Cuando lo baja, guarda `propuesto` y lo explica.
4. **Señales antiguas sin propuesta del modelo**: sin noticias → rumor; evento con fecha futura → convocado; fuente oficial o dos fuentes → confirmado; solo una fuente no oficial de redes → rumor; una fuente no oficial → posible.

Resultado: `{"nivel", "motivo", "origen": "persona" | "modelo" | "modelo_ajustado" | "reglas", "propuesto"?}`. Va en cada señal de `vigilante_bd()` como `certeza`.

## Dónde se ve

- Panel: etiqueta de color en cada tarjeta de Señales y en la ficha; la ficha explica el motivo y quién lo decidió. El glosario tiene las cuatro definiciones.
- AVIA (`avia_api.py`, regla 9): cada hecho lleva su certeza entre corchetes; en «Hechos» solo confirmados y convocados; posibles y rumores en «Pendiente de verificar»; nunca sube una certeza.
- Modo local del chat: los mismos bloques con la certeza; «¿qué es un rumor?» o «grado de certeza» abre el glosario y cuenta las señales por nivel.
- Skill de Hermes y prompt del clasificador: mismas definiciones.

## Cómo aplicarlo

1. Supabase: ejecutar `db/generico/24_grado_certeza.sql` (necesita el 23). Comprobar:
   `SELECT codigo, vigilante.certeza(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 5;`
2. VPS: copiar `avia_api.py`, `analizador.py` y `prompt_clasificador.md` (comparar antes con `diff`) y reiniciar `avia-api`.
3. Web: desplegar.

Prueba: `db/generico/99_prueba_certeza.sql` (8 casos, termina en `ROLLBACK`).
