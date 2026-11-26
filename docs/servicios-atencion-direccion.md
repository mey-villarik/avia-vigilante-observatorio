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
