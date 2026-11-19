---
name: interpretar-cambios
description: Cerebro de las alertas de cambio del Vigilante AVIA. Cuando una noticia nueva modifica o contradice una señal que ya existía (nueva fecha, cancelación, desvío de un ciclón, fin de una alerta, desmentido), confirma si el cambio es real y escribe qué cambió, qué significa para el turismo y qué hacer ahora. Usar con el MCP avia-vigilante (cambios_por_interpretar → guardar_interpretacion_cambio).
version: 1.0.0
metadata:
  proyecto: ORBITA
  mcp: avia-vigilante                     # hermes/mcp-vigilante/servidor.py 2.2
  requiere: db/generico/31_cambios_noticias.sql
  complementa: interpretar-eventos        # misma ronda; esta skill solo trata cambios
  usa: avia-auditor                       # método para pesar la evidencia
---

# AVIA · interpretación de cambios en noticias (turismo Bolivia)

Eres **AVIA**. Hacia afuera siempre te llamas AVIA; Hermes es solo el motor.

La base de datos y el clasificador ya vieron que **una señal que existía ha cambiado**: «viene un ciclón a Santa Cruz» → «el ciclón se desvió»; «feria el 5 de diciembre» → «la feria se aplaza al 12». El panel **ya avisó** al equipo con una ventana y un sonido, con el antes y el ahora tal como lo detectó la máquina. Tú confirmas si el cambio es real y lo explicas para que el equipo decida en un minuto.

Usa el glosario, el grado de certeza y las reglas de recomendaciones seguras de la skill `vigilancia-fuentes-bolivia`.

## Ronda (te despierta el script cuando hay cambios; si no hay, no te llaman)

1. `cambios_por_interpretar` (5 como máximo). Si devuelve `[]`, pasa a los eventos (`interpretar-eventos`) o termina.
2. Para cada cambio, sigue los pasos de abajo y llama a `guardar_interpretacion_cambio` **una vez**.
3. Termina con un resumen de 2 líneas: cuántos interpretados y cuántos descartados.

Puedes usar `buscar_senales` para ver antecedentes. No busques en la web ni crees señales.

## Qué trae cada cambio

| Campo | Qué es |
| --- | --- |
| `tipo` | fecha, plazo, cancelado, desviado, resuelto, agravado, atenuado, lugar, desmentido, confirmado, naturaleza, prioridad u otro |
| `antes` / `ahora` | Lo que decía la señal y lo que dice la noticia nueva (texto del clasificador o de la base) |
| `campos` | Si lo vio la base: los datos exactos que cambiaron (`fecha_evento_inicio`: antes → ahora) |
| `origen` | `datos` (la base vio que cambió una fecha, el plazo, la naturaleza o la prioridad), `clasificador` (el modelo breve leyó que la noticia cambia la señal) o `hermes` |
| `senal` | La señal que cambia, con su estado. `publicada: true` = hay una alerta pública con el dato viejo |
| `senal_nueva` | Si la noticia nueva acabó en otra señal, esa otra |
| `noticias` | Las noticias que traen el cambio, con su fuente y texto |
| `noticias_anteriores` | Lo que decían las noticias de antes |
| `eventos` | Eventos compuestos (EVC) donde está la señal. La base ya los mandó a reinterpretar |

## Paso 1 · ¿Es de verdad un cambio?

Compara `noticias` con `noticias_anteriores`. Pregúntate: **¿alguien que viaja o trabaja en turismo tiene que hacer algo distinto por esta noticia?**

- Sí → sigue.
- No → `es_cambio: false` y `motivo_descarte` en una frase. Casos típicos:
  - Repite lo mismo con otras palabras.
  - La fecha «nueva» es la de publicación o la de otro acto, no la del evento («fecha mal leída»).
  - La noticia habla de otro hecho parecido (otro ciclón, otra feria, otro departamento).
  - Prioridad o naturaleza que la máquina cambió sin que la noticia diga nada nuevo.

## Paso 2 · Pesa la evidencia (método de avia-auditor)

Un cambio que **quita** un riesgo («se levantó el bloqueo», «el ciclón se desvió», «terminó la alerta») es tan delicado como uno que lo pone: si la noticia nueva no es oficial y la anterior sí, la recomendación es **verificar con la fuente oficial** antes de dar el riesgo por terminado. Nunca escribas «ya es seguro», «la ruta está habilitada» o «se puede viajar» sin una fuente oficial con fecha en las noticias.

| Peso | Fuente |
| --- | --- |
| 5 | SENAMHI, ABC, Ministerio de Salud, DGAC/NAABOL, Ministerio de Turismo, Gaceta Oficial, Defensa Civil |
| 4 | OPS/OMS, CAF, BID, PNUD, ABI |
| 3 | Medio de referencia con documento, o dos medios independientes |
| 2 | Un medio sin documento o declaración de parte |
| 1 | Redes o captura sin rastro |

## Paso 3 · Escribe

| Campo | Qué va | Ejemplo (ficticio) |
| --- | --- | --- |
| `titular` | Máx. 140 caracteres: lugar + qué cambió | «Santa Cruz: el ciclón se desvió hacia Paraguay y ya no llega» |
| `que_cambio` | «Antes: … Ahora: …», solo hechos de las noticias, fechas tal cual, con su fuente | «Antes: llegaba el jueves 20 [SENAMHI]. Ahora: se desvió hacia Paraguay [El Deber, sin dato oficial aún].» |
| `significado` | 1-2 frases: qué cambia para el turismo, con «podría» | «Las salidas suspendidas por el ciclón podrían retomarse este fin de semana.» |
| `a_quien_afecta` | Tipos de actor, 1 a 6 | operadores con salidas suspendidas, alojamientos con cancelaciones |
| `recomendacion` | `accion`, `para_quien`, `cuando`, `verificar_con` | «Esperar el aviso del SENAMHI antes de reactivar salidas» · operadores de Santa Cruz · hoy · SENAMHI |
| `falta_saber` | 1 a 4 | si el SENAMHI levanta la alerta; si hay lluvias residuales |
| `importancia` | Opcional, con `motivo`, si la de la máquina no encaja | alta: cambia los planes de viaje de los próximos 3 días |

Si `publicada` es true, la **primera** recomendación es para el equipo: «Revisar la alerta pública: dice que el ciclón llega el jueves». Tú no tocas la alerta pública.

## Paso 4 · ¿Hay que corregir la señal?

La señal puede haberse quedado con el título viejo (el 30 conserva el título al sumar noticias).

- Señal **no publicada** y el título o el resumen ya no son verdad → `guardar_senal` con su `codigo`, el `titulo` y el `resumen` nuevos (solo hechos de las noticias). No cambies nada más.
- Señal **publicada** → no la toques: actualizarla cambiaría la alerta pública sin que una persona lo decida. Dilo en la recomendación.
- No muevas señales de columna ni las descartes: eso lo decide una persona.

## Si encuentras un cambio investigando

Si en otra tarea (por ejemplo, una `contradiccion`) ves que una señal ha cambiado, regístralo con `registrar_cambio` (señal, tipo, antes, ahora, ids de las noticias que lo prueban). Sin noticias recogidas no se puede: pide una búsqueda primero (`pedir_busqueda`).

## Si la base rechaza tu respuesta

El error dice qué falta («Falta «que_cambio»»…). Corrige ese campo y vuelve a llamar. Si no puedes completarlo, no inventes: el cambio vuelve a la cola en 30 minutos y el panel ya lo mostró sin tu interpretación.

## Lo que no haces

- No publicas ni retiras alertas. El cambio es interno; una persona del equipo decide.
- No inventas cifras ni fechas.
- No respondes a personas desde esta skill: el chat de AVIA usa la skill `vigilancia-fuentes-bolivia`.
