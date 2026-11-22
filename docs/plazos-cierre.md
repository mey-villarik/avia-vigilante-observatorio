# Plazos de cierre: fecha fija, días al consultar y certeza del plazo aparte (SQL 48)

Tareas CP1, CP2 y CP3 de Carlos (2026-11-22).

## Qué pasaba

- **CP1.** Para la misma señal (IWT, SEN-0027) AVIA respondió «quedan 12 días» y «cierra en 5 días». Había cuatro cuentas distintas y ninguna fija:
  - el chat no sabía qué día es hoy: contaba los días él mismo o copiaba «quedan 12 días» del resumen, escrito el día de la noticia;
  - `vigilante_bd()` daba `fecha_limite` en UTC desde el SQL 19: un plazo guardado a las 23:59 de Bolivia son las 03:59 del día siguiente en UTC, así que el panel veía el cierre **un día más tarde**;
  - `vigilante.dias_para()` (21) sumaba otro día por lo mismo;
  - la web pública y la vista Oportunidades tenían su propia cuenta.
- **CP2.** «Confirmado» se usaba para plazos sin fuente primaria: la certeza del **evento** se aplicaba también a la **fecha**.
- **CP3.** Al pedir «abre las señales de riesgo de La Paz», AVIA respondía «Abrí Señales» aunque no hubiera mandado la orden o el filtro no existiera, y sin decir qué señales se veían.

## Regla única (base, panel, web pública, chat y Hermes)

| | |
| --- | --- |
| Qué se guarda | La **fecha** de cierre (`signals.plazo_hasta`, fin de ese día en Bolivia). Nunca «N días». |
| Días que faltan | Día de cierre − hoy, los dos en hora de Bolivia, **calculados al consultar**. 0 = cierra hoy, 1 = mañana, negativo = ya cerró. |
| Cómo se escribe | «cierra el 30/11/2026, en 8 días» · «cierra hoy (22/11/2026)» · «cierra mañana (23/11/2026)» · «cerró el 20/11/2026». Siempre con la fecha. |
| Plazo **confirmado** | La fecha la da tal cual una fuente primaria (oficial u organismo internacional), o una persona del equipo la comprobó (`verificar_plazo`). |
| Plazo **pendiente de verificar** | Todo lo demás: la fecha la da un medio no oficial, o AVIA la calculó a partir de «quedan N días». Aunque el evento esté [confirmado]. |

Dónde vive: `vigilante.cierre()` y `vigilante.certeza_plazo()` (SQL 48), `web/src/lib/plazo.ts`, `_cierre()` en `hermes/avia-api/avia_api.py`.

## Qué cambia

**Analizador** (`hermes/analizador`, prompt `clasificador-1.11`)
- El modelo copia la frase del plazo en `plazo_cita` y no calcula fechas. Si la fuente dice «quedan 12 días», el programa pone la fecha = día de publicación + 12 (`plazo_origen: calculado`).
- En título, resumen y oportunidad, cada «quedan N días» / «cierra en N días» / «dentro de N semanas» se cambia por su fecha («hasta el 30/11/2026»).

**Base** (`db/generico/48_plazo_absoluto.sql`)
- `dias_para()` con la regla de arriba (contadores, síntesis y Pulso la heredan).
- `fecha_limite` en hora de Bolivia y `cierre` (fecha, días, texto, certeza del plazo y motivo) en `vigilante_bd()`; `fecha_cierre`, `plazo_certeza` y `plazo_motivo` en `alertas_publicas()`; `dias_plazo`, `fecha_cierre` y `certeza_plazo` en `metricas_oportunidades()`; `cierre` en `buscar_senales()`.
- Disparador `zz_plazo_origen`: al guardar la clasificación anota qué noticia dio la fecha, si es oficial y si era calculada. Una fuente oficial no se pisa con un diario que repite la misma fecha.
- `vigilante.verificar_plazo('SEN-0027', '2026-11-30', 'llamada a la organizadora')`: un analista comprueba la fecha → «confirmado».
- `vigilante.reparar_plazos_relativos(false)`: lista las señales viejas con «quedan N días» en el texto y sin fecha; con `true` les pone la fecha (calculada, «pendiente de verificar»).

**Chat** (`avia_api.py`)
- El prompt dice qué día es hoy y cada señal lleva `cierre` calculado en ese momento (también las que nombra el usuario, que antes iban sin compactar). Las cuentas viejas del resumen se tapan con «[plazo: ver «cierre»]».
- Reglas 15 (plazos) y 16 (no decir que abrió algo) en el formato.
- Red de seguridad: en una línea que nombra una sola señal, los días se corrigen a los de hoy y un plazo «confirmado» sin fuente primaria pasa a «pendiente de verificar».
- La orden `abrir` acepta `filtro` (`naturaleza`, `departamento`, `texto`, `revisar`).

**Web**
- `lib/plazo.ts`: la misma cuenta en ficha, tarjetas, Oportunidades, Mapa, síntesis y web pública. El plazo lleva su certeza («Plazo confirmado» / «Plazo pendiente de verificar», con el motivo al pasar el ratón). La web pública añade «Fecha pendiente de verificar».
- CP3: `lib/filtroSenales.ts` es el único filtro de la vista Señales. Cuando AVIA manda abrir una vista o un filtro, el panel lo aplica, **comprueba** que quedó así y escribe debajo de la respuesta «**En pantalla:** Vista Señales abierta con el filtro riesgos · La Paz · recientes. Se muestran 2 señales: SEN-0418, SEN-0414.» Si no pudo (departamento desconocido, señal que no está), lo dice. Las frases del modelo del tipo «ya abrí…» se quitan siempre; si las decía sin mandar la orden, el panel avisa de que no abrió nada.

**Hermes**: descripciones de `guardar_senal`, `guardar_oportunidad` y `metricas_oportunidades` en `servidor.py`, y dos reglas nuevas en la skill `vigilancia-fuentes-bolivia`.

## Instalar

1. Supabase → SQL Editor: pegar `db/generico/48_plazo_absoluto.sql` y Run (necesita el 47).
2. Ver qué señales viejas tienen «quedan N días»: `select vigilante.reparar_plazos_relativos(false);` y, si la lista está bien, `select vigilante.reparar_plazos_relativos(true);`
3. Comprobar SEN-0027: `select codigo, vigilante.cierre(id) from vigilante.signals where codigo = 'SEN-0027';`
4. VPS: copiar `hermes/analizador/analizador.py` y `prompt_clasificador.md`, `hermes/avia-api/avia_api.py` (antes, `diff` con la copia del VPS por si tiene parches propios) y reiniciar `avia-api`; copiar `hermes/mcp-vigilante/servidor.py` y la skill `vigilancia-fuentes-bolivia`.
5. Desplegar la web.
6. Prueba: `99_prueba_plazo_absoluto.sql` (termina en ROLLBACK) y las preguntas 21 a 23 de `hermes/avia-api/bateria.json`.
