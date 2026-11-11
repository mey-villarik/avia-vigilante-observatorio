# Tareas automáticas y ventana de 7 días

Cierra los huecos que encontró la auditoría de la web contra la especificación de la beta (10-11-2026).
Las tareas las hace **Supabase sola** con su programador interno (pg_cron): no usan IA ni dependen de Hermes, del VPS ni de n8n.

## Qué hace

| Tarea | Cuándo | Qué pasa |
| --- | --- | --- |
| Plazo de revisión | cada minuto | Una señal que pide revisión (salud, clima, vías, seguridad, fuente no oficial o predicción) tiene 15 minutos en horario de guardia (07:00–22:00). Si vence sin decisión, el panel la marca **«Plazo vencido»**. |
| Publicar al vencer (apagado) | cada minuto | Solo si se enciende `publicar_al_vencer`: lo que reproduce un aviso oficial con enlace se publica solo con la etiqueta «En verificación». |
| Resumen diario | 08:00 hora de Bolivia | Las 7 alertas más importantes de las últimas 24 h, en un mensaje al canal de Telegram y arriba de la web pública. Sin alertas: «No hay alertas confirmadas en este momento». |
| Recordatorios | cada 5 minutos | Convocatorias a 30, 15 y 5 días del cierre; eventos a 90, 60 y 30 días. Al canal de Telegram. |
| Borrado | 03:00 hora de Bolivia | Lo que tenga más de 6 meses: señales (salvo convocatorias o eventos aún por delante) con sus alertas y votos, noticias que ninguna señal usa, resúmenes, registros y el historial de pg_cron de más de 14 días. |
| Envío a Telegram | cada minuto | Saca de la cola alertas, resúmenes y recordatorios (tarea del 13). |

En la **web pública**, por defecto se ven los riesgos y avisos de los últimos 7 días y las oportunidades mientras su plazo siga abierto. El botón «Ver anteriores» y el filtro de fecha muestran el resto de lo guardado. También hay filtros de categoría y prioridad.

En el **panel**, la vista Señales muestra por defecto lo mismo (más lo que espera decisión) y «Todo lo guardado» enseña los 6 meses. Las predicciones llevan la etiqueta «Escenario» y nunca salen al público. El panel «Valoración del público» cuenta los votos útil / no útil para la revisión semanal.

## Cómo instalarlo

1. Supabase → **Database → Extensions**: comprueba que `pg_cron` y `http` están activas (ya lo estaban para Telegram).
2. Supabase → **SQL Editor** → pega `db/generico/16_tareas_programadas.sql` → **Run**. Al final dice «Tareas programadas: …».
3. Compila la web en tu PC (`npm run build` dentro de `web/`) y copia el contenido de `web/dist` al VPS en `/var/www/avia-vigilante-bolivia/web/dist`.

4. Supabase → **SQL Editor** → pega `db/generico/17_tareas_control.sql` → **Run**. Termina con una tabla del estado de cada tarea.

## Comprobar que corren

```sql
SELECT * FROM vigilante.estado_tareas();
```

Una fila por tarea (`vigilante-revision`, `vigilante-telegram`, `vigilante-tareas`, `vigilante-retencion`) con la última vez que corrió, cuántas veces en 24 h, cuántas fallaron y el último error. La última fila, «(envíos Telegram)», dice si falta el token del bot o si Telegram rechazó mensajes. La columna `estado` resume: `OK`, `FALLA`, `FALTA` o `Aún no ha corrido`.

Si una parte de la tarea de cada 5 minutos falla (resumen o recordatorios), la otra sigue y el error queda en `vigilante.system_logs` con `proceso = 'tareas'`. El borrado nocturno también deja ahí cuánto borró.

Para lanzarlas a mano: `SELECT vigilante.tareas_programadas();` · `SELECT vigilante.tarea_retencion();`. También se ven en Supabase → **Integrations → Cron**.

## Ajustes (tabla `vigilante.parametros`)

| Clave | Por defecto | Para qué |
| --- | --- | --- |
| `resumen_hora` | `"08:00"` | Hora local del resumen diario |
| `resumen_canal` | `"telegram"` | `"ninguno"` para no enviarlo (sigue saliendo en la web) |
| `resumen_max_alertas` | `7` | Alertas del resumen |
| `web_dias_visibles` | `7` | Días que se ven riesgos y avisos en la web |
| `sla_revision_minutos` | `15` | Plazo de revisión |
| `guardia_inicio` / `guardia_fin` | `"07:00"` / `"22:00"` | Horario en que corre el plazo |
| `publicar_al_vencer` | `false` | Publicar «En verificación» lo oficial con enlace al vencer el plazo |
| `retencion_meses` | `6` | Cuánto se guarda |

Ejemplo, encender la publicación al vencer solo para ORBITA:

```sql
INSERT INTO vigilante.parametros (cliente_id, clave, valor)
SELECT id, 'publicar_al_vencer', 'true' FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;
```
