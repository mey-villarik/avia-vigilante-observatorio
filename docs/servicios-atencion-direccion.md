# Por qué Dirección no mostraba servicios esenciales ni atención turística

2026-11-26. Tras ejecutar el SQL 55 (287 noticias recuperadas), la vista Dirección seguía sin esos dos ejes.

## Lo que pasa, por orden

1. **Cola del analizador.** Las recuperadas entran con puntaje previo bajo (justo por encima de 30). `lote_para_clasificar` sirve primero el puntaje más alto, así que esperan detrás de todo lo demás. El analizador hace como mucho 4 lotes de 10 por ejecución, 2 veces por hora.
2. **Prompt del clasificador 1.11.** Daba por relevante solo lo que «afecta a visitantes, operadores o destinos». Un corte de agua o la falta de diésel sin la palabra «turista» salía como no relevante (`IA: …`), así que no llegaba a ser señal.
3. **Vigencia de 24 h.** Una señal sin fecha solo sale en el panel si tuvo noticia en las últimas 24 h (`senal_vigente`). Esto es así por diseño y no se toca.

La vista Dirección (SQL 49) **no** filtra por estado: cualquier señal no descartada y vigente entra en su eje. `eje_de` ya manda combustible, agua, luz o internet a servicios, y hoteles, vuelos o visitantes a atención.

## Arreglo

| Qué | Dónde |
|---|---|
| Prompt 1.12: servicios esenciales y atención turística son relevantes aunque no nombren a turistas; la subida del combustible sin escasez va con prioridad baja | `hermes/analizador/prompt_clasificador.md` |
| Volver a poner en la cola las recuperadas que la IA rechazó con el prompt viejo | `db/generico/56_reclasificar_recuperadas.sql` |
| Diagnóstico de solo lectura: cola, ritmo, rechazos, señales nuevas por eje, estado de Dirección | `db/generico/diagnostico_recuperadas_55.sql` |

## Pasos

1. Supabase: ejecutar `diagnostico_recuperadas_55.sql` y guardar el resultado (sirve para comparar).
2. VPS: copiar `prompt_clasificador.md` a la carpeta del analizador (comparar antes con `diff`).
3. Supabase: ejecutar `56_reclasificar_recuperadas.sql` (solo cuenta) y después `SELECT vigilante.reclasificar_recuperadas('orbita-bolivia', true);`.
4. VPS: vaciar la cola de una vez, sin esperar al cron: `python3 /root/avia/analizador.py --lotes 40` (respeta su propio candado; sin `flock` delante).
5. Volver a ejecutar el diagnóstico: las filas 6 y 8 tienen que mostrar servicios y atención.

## Actualización 16:58 UTC: la causa real

- El 56 no hizo falta: la IA solo rechazó noticias que no tenían que ver (juicios, turismo en otros países). El freno era la **cola**: con `analizador.py --lotes 40` salieron unas 70 señales en 3 minutos.
- Aun así Dirección seguía vacía porque **`vigilante_bd()` tardaba 12,3 s** (308 señales) y Supabase corta a los 8 s las consultas del rol `authenticated`. El panel fallaba sin avisar y enseñaba el `vigilante.json` viejo («Datos generados 07:11»). En la base, Servicios esenciales estaba en Acción con 91 señales.
- Arreglo inmediato: `ALTER ROLE authenticated SET statement_timeout = '30s'; NOTIFY pgrst, 'reload config';`
- Arreglo de fondo: **`57_panel_en_cache.sql`**. La base guarda los datos del panel cada 2 min (pg_cron `vigilante-panel`) y `vigilante_bd()` lee esa copia en milisegundos, con el estado de cada señal al día. Prueba: `99_prueba_panel_cache.sql`.
- Diagnóstico: `/mnt/project-files/sql/diagnostico_panel_viejo.sql`.
