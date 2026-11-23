# Ronda de AVIA: 5 al día en lugar de cada 30 minutos

Pedido de Meysel (2026-11-23): quitar la ronda de Hermes cada 30 min (`b3c0d6cbc0ff`, el mayor gasto de DeepSeek,
~USD 70–240/mes) y dejar **5 rondas al día**. Además, poner freno a `despertar_hermes.py` para que no relance a Hermes
cada 5 minutos si no consigue guardar.

## Qué cambia

| Antes | Ahora |
| --- | --- |
| `b3c0d6cbc0ff` «Ronda AVIA cada 30 min (lista viva + vigilante.json)», 48 veces al día. Con el prompt viejo del 08-nov: Hermes **abre él mismo las fuentes** y escribe partes para `vigilante.json`. Eso ya lo hace el recolector (sin IA). | `b3c0d6cbc0ff` **en pausa** (no se borra: se puede reactivar). |
| — | Tarea nueva «Ronda AVIA 5 al día»: `0 1,10,14,17,21 * * *` (UTC) = **06:00, 10:00, 13:00, 17:00 y 21:00 de Bolivia**. Hace la ronda de la skill `vigilancia-fuentes-bolivia` 3.0: `tomar_tareas` (corroborar, contradicciones, relacionar, oportunidades inferidas) y, si no hay tareas, termina sin gastar. |
| `despertar_hermes.py` relanza a Hermes cada 5 min mientras haya pendientes, aunque no avance. | Freno: mínimo 10 min entre lanzamientos de la misma tarea; tras 2 lanzamientos seguidos sin que bajen los pendientes (o si el lanzamiento falla), espera 30 min, 60, 120, 240 y como máximo 6 h; tope de 48 lanzamientos por tarea y día. En cuanto avanza o no queda nada, vuelve a lo normal. Lo anota en `system_logs` (nivel `warn`). |

Una tarea con 5 horas es lo mismo que 5 tareas con una hora cada una, y se pausa o se cambia de una vez.
Las horas de Hermes son UTC (la lista muestra `+00:00`). Bolivia = UTC−4, sin horario de verano.

Las demás tareas no se tocan: `c805ba25abb9` (mañana, 08:00 UTC), `36e2f7bf4e47` (cambios y eventos),
`4ea59fdde61d` (probabilidad) y `dc295d87a8b0` (pausada). Las dos que despierta el script
(`36e2f7bf4e47`, `4ea59fdde61d`) siguen igual, ahora con freno.

Gasto esperado: la ronda pasa de 48 a 5 ejecuciones al día y ya no lee fuentes. Con el resto, el sistema queda en
~USD 36/mes en el peor caso (estimación del 2026-11-23).

## Comandos (VPS, como root)

### 1. Copia de seguridad de las tareas de Hermes

```bash
cp /root/.hermes/cron/jobs.json /root/.hermes/cron/jobs.json.bak-2026-11-23
```

### 2. Pausar la ronda de 30 minutos

```bash
docker exec hermes hermes cron pause b3c0d6cbc0ff
```

Si en ese momento está corriendo, termina esa ejecución y ya no vuelve.

### 3. Crear la ronda de 5 al día

```bash
PROMPT=$(cat <<'EOT'
Ronda de AVIA (5 al día: 06:00, 10:00, 13:00, 17:00 y 21:00 de Bolivia), con la skill vigilancia-fuentes-bolivia 3.0 y el MCP avia-vigilante.
No abras las fuentes ni escribas partes ni vigilante.json: las lee el recolector y las clasifica el analizador.
1. tomar_tareas (5 como máximo). Si no hay ninguna, responde «Sin tareas» y termina: no busques trabajo.
2. Atiende cada tarea según su tipo, como dice la skill (corroborar, contradiccion, relacionar, oportunidad_inferida), y ciérrala con terminar_tarea.
3. Copia cifras, fechas y nombres tal cual; no inventes fuentes ni enlaces.
4. Devuelve un resumen de 3 líneas: tareas cerradas, señales actualizadas y oportunidades propuestas.
EOT
)
docker exec hermes hermes cron create "0 1,10,14,17,21 * * *" "$PROMPT" \
  --name "Ronda AVIA 5 al día (06-10-13-17-21 Bolivia)" \
  --skill vigilancia-fuentes-bolivia --deliver local
```

### 4. Comprobar

```bash
docker exec hermes hermes cron list
```

Debe salir `b3c0d6cbc0ff [paused]` y la tarea nueva `[active]` con `Schedule: 0 1,10,14,17,21 * * *` y
`Next run` en la siguiente de estas horas UTC: 01:00, 10:00, 14:00, 17:00 o 21:00.

### 5. Freno de `despertar_hermes.py`

El del VPS puede tener cambios locales: se baja al lado, se compara y solo entonces se reemplaza.

```bash
curl -fsSL https://raw.githubusercontent.com/mey-villarik/avia-vigilante-observatorio/claude/project-thread-xzw3y1/hermes/eventos/despertar_hermes.py \
  -o /root/avia/despertar_hermes.py.nuevo
diff /root/avia/despertar_hermes.py /root/avia/despertar_hermes.py.nuevo | head -80
```

Si el diff solo muestra el freno (líneas nuevas `decidir`, `anotar_lanzamiento`, `HERMES_ESPERA_MIN`…), reemplaza:

```bash
cp /root/avia/despertar_hermes.py /root/avia/despertar_hermes.py.bak-2026-11-23
mv /root/avia/despertar_hermes.py.nuevo /root/avia/despertar_hermes.py
AVIA_SUPABASE_ENV=/root/avia/supabase.env python3 /root/avia/despertar_hermes.py --contar
AVIA_SUPABASE_ENV=/root/avia/supabase.env python3 /root/avia/despertar_hermes.py --estado
```

El crontab no cambia (sigue `*/5`, sin `flock`: el script tiene su propio candado). A los 10 minutos:

```bash
tail -20 /var/log/avia-eventos.log
```

Si el freno actúa verás «no lanzo …: N lanzamientos seguidos sin que bajen los pendientes: espero 30 min».
Tras arreglar la causa a mano, `python3 /root/avia/despertar_hermes.py --reiniciar-freno` lo pone a cero.

Variables opcionales (en `/root/avia/supabase.env`): `HERMES_ESPERA_MIN` (10), `HERMES_INTENTOS_SIN_AVANCE` (2),
`HERMES_ESPERA_MAX_MIN` (360), `HERMES_MAX_DIA` (48), `HERMES_ESTADO` (`/root/avia/despertar_estado.json`).

## Volver atrás

```bash
docker exec hermes hermes cron pause <id de la tarea nueva>
docker exec hermes hermes cron resume b3c0d6cbc0ff
cp /root/avia/despertar_hermes.py.bak-2026-11-23 /root/avia/despertar_hermes.py
```
