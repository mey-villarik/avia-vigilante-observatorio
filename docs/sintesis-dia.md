# Síntesis del día en 3 bloques

Mejora 8 de la PoC (documento del revisor). Antes la síntesis era un párrafo libre (o el texto que dejaba Hermes) que mezclaba hechos, importancia y pendientes, y podía no cuadrar con los contadores.

## Los tres bloques

La base los arma sin IA (`vigilante.sintesis_dia()` en `db/generico/26_sintesis_dia.sql`), con las mismas señales visibles que usan los contadores del paso 1. Va en `vigilante_bd()` como `sintesis_dia`.

| Bloque | Qué lleva | Orden |
| --- | --- | --- |
| **Qué pasa** | Los hechos: señales con certeza *confirmado* o *convocado* (nunca posibles, rumores ni escenarios), con su certeza, resumen y territorio | Prioridad alta primero, luego impacto alto |
| **Por qué importa** | El impacto turístico de esos mismos hechos, con su motivo y a quién afecta. Si el impacto es «sin datos», lo dice | El mismo que «Qué pasa» |
| **Qué vigilar** | Riesgos sin confirmar (posible o rumor, prioridad media o alta) con lo que falta saber; recomendaciones que dan algo por operativo sin dato oficial; convocados en los próximos 7 días; oportunidades que cierran en menos de 15 días; señales con la revisión vencida; fuentes que no se pueden leer | Por tipo y prioridad |

Más una línea de totales (la misma de los contadores: «11 señales activas: 4 riesgos, 6 oportunidades y 1 mixta; 40 noticias revisadas en 24 h»).

Reglas: máximo `sintesis_max` elementos por bloque (parámetro, 3 por defecto; «Qué vigilar» admite el doble). No se rellena: si no hay nada, el bloque dice «Sin novedades» o «Sin datos». No hay texto de IA que pueda contradecir los contadores.

## Dónde se ve

- Panel: la Síntesis del día muestra los tres bloques con la etiqueta de certeza y enlaces a cada señal; debajo, los contadores y la hora de los datos. Para datos de ejemplo y `vigilante.json` antiguos se arma en la web con las mismas reglas (`web/src/lib/sintesis.ts`).
- AVIA (`avia_api.py`, regla 11): ante «resumen», «síntesis» o «panorama» responde con EXACTAMENTE tres bloques copiados de la síntesis de la base, sin añadir hechos ni cambiar certezas. Modo local del chat: igual.
- Skill de Hermes: misma regla.

## Cómo aplicarlo

1. Supabase: ejecutar `db/generico/26_sintesis_dia.sql` (necesita el 25). Comprobar:
   `SELECT jsonb_pretty(vigilante.sintesis_dia(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';`
2. VPS: copiar `avia_api.py` (comparar antes con `diff`) y reiniciar `avia-api`.
3. Web: desplegar.

Cambiar el tamaño: `INSERT INTO vigilante.parametros (cliente_id, clave, valor) SELECT id, 'sintesis_max', '4', ... ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;`

Prueba: `db/generico/99_prueba_sintesis.sql` (termina en `ROLLBACK`).

## Aviso de revisiones vencidas, arriba de todo (45_aviso_revisiones_vencidas.sql)

Las señales a las que se les pasó el plazo de revisión y siguen sin decidir (Detectada, En análisis o
En verificación) ya no van como una línea más de «Qué vigilar». `sintesis_dia()` las devuelve aparte en
`revisiones_vencidas` (`total`, las 5 más antiguas, `responsable`, `responsable_origen`) y el panel las
pone en un recuadro rojo encima de la síntesis, con enlace a cada señal y el botón «Revisar ahora».

Responsable: el parámetro `responsable_revision` del cliente si el administrador lo puso; si no, los
analistas activos del equipo; si no hay ninguno, el panel dice «Sin responsable asignado».

Las ya confirmadas, publicadas, cerradas o descartadas no cuentan aunque se decidieran tarde (antes el 26
sí las contaba, así que la cifra puede bajar).
