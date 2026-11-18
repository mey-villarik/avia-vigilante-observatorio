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

## Qué necesita en el VPS

Nada que instalar: el script solo usa la biblioteca estándar de Python 3 (el VPS ya tiene `python3` para `avia_api.py` y el recolector). Todo lo demás lo saca solo:

| Qué | De dónde lo saca | Si falla |
| --- | --- | --- |
| `AVIA_API_KEY` (la clave que nginx inyecta) | `/root/avia/supabase.env`, el mismo archivo que usa el servicio `avia-api` (también mira `/etc/avia/supabase.env` y `AVIA_SUPABASE_ENV`) | Responde `HTTP 401` en todas las preguntas |
| La sesión (AVIA exige sesión iniciada) | Inicia sesión como el primer administrador activo de `vigilante.users`, con `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` del mismo archivo. Usa un enlace mágico generado en el servidor: **no envía ningún correo** | Exportar `AVIA_BATERIA_EMAIL=correo@…` para elegir otro usuario, o `AVIA_TOKEN=…` con el `access_token` de la web (herramientas de desarrollo → Almacenamiento → cookie `sb-…-auth-token`; caduca en una hora) |
| Señales activas (preguntas 1 y 7) | `vigilante_bd()`, la misma lista que ven el panel y AVIA (los contadores del 21 si ya está desplegado) | `--activas N` con el número que muestra el panel |
| Una señal real (preguntas 9 a 12) | La señal activa de prioridad más alta con más fuentes | `--senal SEN-xxxx`; sin señal, esas cuatro se saltan |
| avia-api escuchando | `http://127.0.0.1:8099/health` | `systemctl status avia-api` |

Nada de esto se guarda en Git ni se imprime: el script solo muestra de qué archivo leyó las claves y con qué correo inició sesión.

### Traer el script al VPS sin fusionar el PR

`bateria.py` no depende de nada más del PR #13, así que se pueden traer solo sus dos archivos, sin tocar el resto de la carpeta:

```bash
cd /root/avia-repo
git fetch origin claude/project-thread-am0qq8
git checkout FETCH_HEAD -- hermes/avia-api/bateria.py hermes/avia-api/bateria.json hermes/avia-api/.gitignore
```

Esto no cambia de rama ni toca `avia_api.py` (y el servicio corre la copia de `/root/avia/`, no la del repo). Cuando el PR se fusione, un `git pull` normal deja los mismos archivos.

## Cómo correrla

```bash
cd /root/avia-repo/hermes/avia-api
python3 bateria.py --etiqueta antes
```

Muestra en pantalla una línea por pregunta (REVISAR, FALLA o SALTADA y el motivo de cada fallo) y al final guarda dos archivos en `informes/`:

- `informes/AAAA-MM-DD_HHMM_antes.md`: el informe para leer, con cada pregunta, lo que hay que revisar a mano y la respuesta completa de AVIA.
- `informes/AAAA-MM-DD_HHMM_antes.json`: los mismos datos, para compararlos con otra ronda.

La carpeta `informes/` no se sube a Git (está en `.gitignore`), así que un `git pull` no la pisa. Tarda unos minutos (una llamada al modelo por pregunta, 20 en total) y sale con código 1 si alguna pregunta falla.

Otras opciones: `--solo 1,15,16` (algunas preguntas), `--activas 8` y `--senal SEN-0418` (forzar los datos del panel), `--salida ruta.md` (otro nombre), `--url` (otra dirección de avia-api) y `--doc` (la tabla de arriba).

## Cómo comparar antes y después de una mejora

1. **Antes** de desplegar el cambio: `python3 bateria.py --etiqueta antes`.
2. Desplegar el cambio (por ejemplo Supabase 21 a 26, `avia_api.py`, `analizador.py`, `prompt_clasificador.md` o la web). Antes de copiar `avia_api.py` al VPS, comparar con `diff` la copia de `/root/avia/` y la del repo por si la del VPS tiene un parche propio.
3. **Después**: `python3 bateria.py --etiqueta despues`.
4. Comparar las dos rondas:

```bash
python3 bateria.py --comparar informes/*_antes.md informes/*_despues.md --salida informes/comparacion.md
```

La comparación da una tabla con el resultado de cada pregunta en las dos rondas y marca **✅ mejora** (fallaba y ahora pasa las reglas), **❌ empeora** (pasaba y ahora falla) o **=**, más los motivos de cada fallo. Sale con código 1 si algo empeoró.

5. Leer a mano las preguntas que quedan en REVISAR en la ronda de después, con el criterio de «Qué se comprueba» (en el informe aparece como «Qué revisar a mano»), y comparar la respuesta con la de antes.

Conviene correr las dos rondas el mismo día y con los mismos datos: si entre una y otra entran señales nuevas, el número de activas y la señal de prueba cambian (el informe anota cuáles usó). Para que las preguntas 9 a 12 usen la misma señal en las dos rondas, pasar la de la primera con `--senal`.

## Qué mide cada criterio y qué requiere revisión manual

| Resultado | Qué significa | Qué hacer |
| --- | --- | --- |
| **FALLA** | La respuesta incumple una regla automática: falta algo obligatorio (la hora de los datos, un bloque, «Sin datos»), dice algo prohibido («la ruta está habilitada», «el Pulso es 62», «confianza de 0,95») o da un número de señales distinto al del panel. También si AVIA no respondió (error HTTP o tiempo agotado) | Es un fallo seguro: leer el motivo y la respuesta |
| **REVISAR** | Pasa todas las reglas automáticas | Una persona lee la respuesta con el criterio de «Qué se comprueba»: que los números coincidan con el panel, que las fuentes y fechas citadas existan, que los hechos estén separados de las hipótesis y que no recomiende nada sin verificar |
| **SALTADA** | No se pudo hacer (sin señal real para las preguntas 9 a 12) | Correr con `--senal` |

Las reglas automáticas son una red de seguridad, no un examen completo: una respuesta que pasa todas puede seguir siendo mala, por eso siempre hay revisión a mano. Las reglas de cada pregunta están en `bateria.json` (`debe`, `no_debe`, `cuenta_activas` y `debe_si_activas_menor_que`) y se pueden afinar sin tocar el script; si se cambian, conviene volver a correr la ronda de antes para comparar con las mismas reglas.

## Qué se probó

El script se probó con un servidor simulado de AVIA: con respuestas buenas las 20 preguntas pasan las reglas y con respuestas malas deliberadas (7 casos: «hay 7 señales», «la ruta está habilitada, se puede viajar», «el aeropuerto está operativo», «el Pulso es 62», «ya hay un paro», «confianza de 0,95» y sin bloques) las 7 fallan. También se probó con un Supabase simulado el arranque automático (lectura de `supabase.env`, inicio de sesión del administrador, señales activas y señal de prueba) y la comparación de dos rondas. **No se ha corrido contra el AVIA real ni contra DeepSeek**: eso lo hace el equipo en el VPS.
