# Cómo se calcula el Pulso

Mejora 9 de la PoC (documento del revisor). El Pulso (los dos anillos «Atención a riesgos» y «Oportunidad» y la barra de nivel de vigilancia) se mostraba sin decir de dónde salían los números. Ahora el panel tiene el botón **«¿Cómo se calcula el Pulso?»**, que muestra la cuenta completa con los números de ese momento, y el chat responde lo mismo cuando alguien pregunta por el Pulso.

El cálculo está en `web/src/lib/pulso.ts` (`calcularPulso`); la explicación (`EXPLICA`, `pulsoTexto`) sale de las mismas cifras, así que no puede contradecir al panel.

## Qué mide

La **seriedad** de las señales activas, no su cantidad. Con muchas señales de poca importancia el índice no sube; con pocas graves y confirmadas, sí. Las señales descartadas no entran.

## Riesgos

Cada riesgo activo pesa de 0 a 1: **prioridad × respaldo × etapa**.

| Factor | Valores |
| --- | --- |
| Prioridad | alta 1 · media 0,5 · baja 0,2 |
| Respaldo | 0,5 + 0,5 × fiabilidad de la evidencia (0-100, paso 4: fuente oficial, fuentes distintas, revisión humana). Sin respaldo aún cuenta la mitad |
| Etapa | publicada o confirmada 1 · en verificación 0,85 · detectada o en análisis 0,7. Con la revisión vencida sin decisión cuenta como confirmada: nadie la está mirando |

Las mixtas cuentan la mitad.

## Oportunidades

Cada oportunidad activa pesa de 0 a 1: **valor × etapa**, con valor = 45 % relevancia turística (0-10, la da AVIA) + 25 % novedad (0-10, la da AVIA) + 30 % fiabilidad. Las mixtas y los escenarios cuentan la mitad. Si el plazo ya venció, no suma.

## Índice y niveles

**Índice = 100 × suma de pesos ÷ (número de señales + 2).** Los 2 «vacíos» evitan que una o dos señales sueltas den un índice alto: 1 riesgo alto confirmado y con respaldo completo da ≈ 33; 10 así dan ≈ 83.

| | Niveles |
| --- | --- |
| Riesgo | Bajo < 25 · Moderado 25-49 · Alto 50-74 · Muy alto ≥ 75 |
| Oportunidad | Escasa < 30 · Moderada 30-54 · Favorable ≥ 55 |
| Vigilancia (barra) | Normal < 25 · Vigilancia 25-49 · Atención 50-74 · Crítico ≥ 75, según el índice de riesgo. Con un riesgo alto ya verificado nunca baja de Vigilancia; con cinco o más, nunca de Atención |

## Evolución a 7 y 30 días (DIANA 2.3, `46_pulso_evolucion.sql`)

Debajo de los anillos, el Pulso compara su valor de ahora con el de hace 7 y hace 30 días y dice si **mejora**, **empeora** o está **estable**:

| | Sube | Baja | Menos de 5 puntos de diferencia |
| --- | --- | --- | --- |
| Atención a riesgos | ↑ Empeora (rojo) | ↓ Mejora (verde) | → Estable |
| Oportunidad | ↑ Mejora (verde) | ↓ Empeora (rojo) | → Estable |

De dónde salen los valores pasados:

- `vigilante.pulso_registro` guarda una fila por día (hora de Bolivia). La tarea de pg_cron `vigilante-pulso` la actualiza cada hora (minuto 7); el valor que queda de cada día es el de su última hora.
- `vigilante._pulso_en(cliente, momento)` calcula el Pulso con **las mismas reglas que `calcularPulso()`** (`web/src/lib/pulso.ts`). Para un día pasado usa las señales que ya existían, el estado que tenían ese día (`signal_history`), si seguían vigentes y si su revisión había vencido.
- Al ejecutar el 46 se reconstruyen los 30 días anteriores para que la evolución se vea ya. **Límite:** la prioridad, la relevancia, la novedad y la fiabilidad de esos días son las de hoy (la base no guarda su historial), así que los días reconstruidos son aproximados y el panel los marca con «≈».
- Si ese día aún no había ninguna señal, dice «sin datos» (no un 0 inventado).
- `vigilante.pulso_evolucion(cliente)` lo devuelve (hoy, hace 7, hace 30, la serie diaria) y va en `vigilante_bd()` / `vigilante.json` como `pulso_evolucion`.

Si se cambia una regla del Pulso, hay que cambiarla en `pulso.ts`, en `_pulso_en()` (46) y en este documento. La prueba `99_prueba_pulso_evolucion.sql` comprueba los valores a mano.

## Qué no entra

Las fuentes caídas no entran en los índices (una fuente caída no es un riesgo turístico), pero el panel avisa: con fuentes caídas el Pulso puede quedarse corto.

## Cambio en esta mejora

Antes el respaldo usaba la «confianza» del modelo, un número sin definir. Ahora usa la fiabilidad de la evidencia del paso 4, que la calcula la base con reglas explicadas. Los índices pueden moverse algo respecto a la versión anterior.

## Límites

La relevancia y la novedad las estima AVIA y todavía no se han contrastado con casos reales: el Pulso es una guía de atención, no una medida exacta. Si el equipo del Ministerio quiere otra ponderación, se cambian los pesos en `pulso.ts` y en este documento.

## AVIA

AVIA no calcula el Pulso: `avia_api.py` (regla 12) le indica que no lo invente y que remita al botón del panel. Desde el 46, si preguntan por la tendencia (pulso, evolución, mejora, empeora, última semana o mes…), recibe el bloque «EVOLUCIÓN DEL PULSO» de la base y cita esos valores tal cual. Cuando se pregunta por el Pulso en el chat, la web responde ella misma con la cuenta real.
