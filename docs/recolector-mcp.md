# Recolector sin IA + MCP propio de AVIA

Diseño acordado con Meysel el 2026-11-08. El documento con el porqué está en [Orquestación del Vigilante AVIA](https://claude.ai/artifact/K36QveWD93X2sZgmBk4Wfn).

```
Fuentes ──► recolector.py (VPS, cron 5 min, SIN IA) ──► Supabase: raw_items + filtro SQL
               │  Apify solo si la fuente lo pide y queda tope                │
               ▼                                                               ▼
        búsquedas que pide AVIA ◄──────── MCP avia-vigilante ◄──── AVIA (Hermes), ronda de 30 min
                                                 │                    · toma noticias pendientes
                                                 ▼                    · guarda señales
                                     Supabase: signals ──► web (panel y pública) + Telegram (13)
                                     propuestas de método ──► el administrador aprueba en la web
```

- **AVIA ya no abre las fuentes.** Eso gastaba tokens en cada ronda aunque no hubiera nada nuevo.
- **El recolector** lee cada fuente según su frecuencia. Si una página no cambió, no hace nada. Lo repetido lo rechaza la base. Cada noticia recibe un puntaje previo (palabras clave de la fuente, territorio, palabras de oportunidad y de alerta) y lo que no llega al umbral se descarta sin IA.
- **AVIA** trabaja con las herramientas del MCP propio: noticias pendientes, guardar señal, buscar señales, métricas de oportunidad, alertas tempranas, pedir búsqueda y proponer método.
- **Apify** solo se usa en las fuentes marcadas «Apify» y en las búsquedas que AVIA pide «por Apify», con un tope de gasto al mes. Con el tope en 0 (valor inicial) está apagado.
- **Cambiar cómo se lee una fuente** lo propone AVIA y lo aprueba un administrador en la pestaña Fuentes.

## Archivos

| Archivo | Qué es |
| --- | --- |
| `db/generico/14_recolector_mcp.sql` | Tablas y funciones (búsquedas, propuestas, filtro previo, señales de AVIA, métricas, alertas, datos para la web) |
| `db/generico/99_prueba_recolector.sql` | Prueba completa; termina en ROLLBACK |
| `hermes/recolector/recolector.py` | El recolector (Python 3.9+, sin dependencias) |
| `hermes/mcp-vigilante/servidor.py` | El MCP propio (stdio, Python 3.9+, sin dependencias) |
| `hermes/skills/vigilancia-fuentes-bolivia/SKILL.md` | Skill 2.0.0: AVIA como analista con el MCP |

## Instalar

### 1. Supabase (una vez)

SQL Editor → New query → pegar `db/generico/14_recolector_mcp.sql` → Run. Se puede repetir.

Valores que se pueden cambiar después (también en el SQL Editor):

```sql
-- tope de Apify al mes en USD (0 = apagado). Ejemplo: 5 USD
insert into vigilante.parametros (cliente_id, clave, valor)
select id, 'apify_tope_usd_mes', '5' from vigilante.clientes where slug = 'orbita-bolivia'
on conflict (cliente_id, clave) do update set valor = excluded.valor;

-- puntaje mínimo para que una noticia llegue a AVIA (0-100, por defecto 30)
insert into vigilante.parametros (cliente_id, clave, valor)
select id, 'umbral_previo', '30' from vigilante.clientes where slug = 'orbita-bolivia'
on conflict (cliente_id, clave) do update set valor = excluded.valor;
```

### 2. VPS: el recolector (por SSH, como root)

Usa el mismo archivo de claves que `fuentes_activas.sh` (`~/avia/supabase.env`, con la clave `sb_secret_…`). Si vas a usar Apify, añade ahí una línea `APIFY_TOKEN=…` (nunca en Git ni en el chat).

```bash
curl -fsSL https://raw.githubusercontent.com/mey-villarik/avia-vigilante-observatorio/claude/project-thread-z696h2/hermes/recolector/recolector.py -o /root/avia/recolector.py
export AVIA_SUPABASE_ENV=/root/avia/supabase.env

# 1) solo mirar: lee las fuentes y enseña lo que guardaría, sin escribir nada
python3 /root/avia/recolector.py --prueba --todas

# 2) de verdad, una vez
python3 /root/avia/recolector.py --todas

# 3) cada 5 minutos (cada fuente se lee según su frecuencia)
(crontab -l 2>/dev/null; echo "*/5 * * * * AVIA_SUPABASE_ENV=/root/avia/supabase.env /usr/bin/python3 /root/avia/recolector.py >> /var/log/avia-recolector.log 2>&1") | crontab -
```

Cada línea del registro dice la fuente, su estado y cuántas noticias eran nuevas, repetidas o descartadas: `tail -f /var/log/avia-recolector.log`.

### 3. VPS: el MCP propio dentro de Hermes

Hermes corre en el contenedor `hermes`; `/root/.hermes` del VPS es `/opt/data` dentro del contenedor.

```bash
mkdir -p /root/.hermes/avia
curl -fsSL https://raw.githubusercontent.com/mey-villarik/avia-vigilante-observatorio/claude/project-thread-z696h2/hermes/mcp-vigilante/servidor.py -o /root/.hermes/avia/servidor.py
install -m 600 /root/avia/supabase.env /root/.hermes/avia/supabase.env

# probar que responde (debe listar 9 herramientas)
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | docker exec -i -e AVIA_SUPABASE_ENV=/opt/data/avia/supabase.env hermes python3 /opt/data/avia/servidor.py \
  | python3 -c "import json,sys; print([t['name'] for t in json.load(sys.stdin)['result']['tools']])"
```

Después, añade el servidor en la configuración de Hermes (`/root/.hermes/config.yaml`). Comprueba el nombre exacto de la sección en la documentación de tu versión de Hermes Agent; en las versiones con MCP es `mcp_servers`:

```yaml
mcp_servers:
  avia-vigilante:
    command: python3
    args: ["/opt/data/avia/servidor.py"]
    env:
      AVIA_SUPABASE_ENV: /opt/data/avia/supabase.env
```

Reinicia Hermes (`docker restart hermes`) y pregúntale en el chat: «¿qué herramientas tienes de avia-vigilante?».

### 4. VPS: la skill y la ronda de AVIA

```bash
curl -fsSL https://raw.githubusercontent.com/mey-villarik/avia-vigilante-observatorio/claude/project-thread-z696h2/hermes/skills/vigilancia-fuentes-bolivia/SKILL.md \
  -o /root/.hermes/skills/vigilancia-fuentes-bolivia/SKILL.md

PROMPT=$(cat <<'EOF'
Ronda de AVIA (cada 30 minutos), con la skill vigilancia-fuentes-bolivia 2.0 y el MCP avia-vigilante.
No abras las fuentes: las lee el recolector.
1. alertas_tempranas: trata primero lo que salga.
2. noticias_pendientes (limite 15). Para cada grupo: si no afecta al turismo de Bolivia, descartar_noticias con el motivo; si ya hay una señal del mismo hecho (buscar_senales), guardar_senal con su codigo; si es nueva, guardar_senal con las noticias de las que sale. Copia cifras, fechas y nombres tal cual; no inventes.
3. Si una fuente lleva días fallando o sin noticias útiles (estado_fuentes), propón otro método con proponer_metodo, una sola vez.
4. Devuelve un resumen corto: señales nuevas, actualizadas y descartadas. Si no hay nada nuevo, dilo en una línea.
EOF
)
docker exec hermes hermes cron edit b3c0d6cbc0ff --name "Ronda AVIA cada 30 min (MCP + recolector)" --prompt "$PROMPT"
docker exec hermes hermes cron run b3c0d6cbc0ff
```

Para el **radar diario de oportunidades**, pide a AVIA en su chat que cree una tarea programada diaria (por ejemplo, a las 7:00 de Bolivia) con este texto: «Usa metricas_oportunidades y escribe el radar de oportunidades del día: qué crece y dónde, qué plazos cierran, qué eventos coinciden, a quién le sirve y el siguiente paso. Marca como escenario cualquier proyección.»

### 5. La web

No hay que hacer nada más. Con sesión, la web junta lo del archivo `vigilante.json` con lo que hay en la base (`vigilante_bd()`): las señales que guarda AVIA por el MCP aparecen solas y, en cada fuente, manda la lectura más reciente. Las propuestas de AVIA salen arriba en la pestaña Fuentes; solo el administrador ve los botones Aprobar y Rechazar.

Cuando todo funcione unos días, el archivo `vigilante.json`, `build.py` y la sincronización 05 se pueden retirar.

## Comprobar

```sql
-- ¿qué ha leído el recolector en la última hora?
select s.codigo, r.estado, r.puntaje_previo, r.titulo
  from vigilante.raw_items r left join vigilante.sources s on s.id = r.source_id
 where r.recolectado_en > now() - interval '1 hour' order by r.id desc limit 30;

-- estado de las fuentes
select codigo, config ->> 'estado' as estado, ultima_consulta_en, errores_seguidos, notas
  from vigilante.sources where activa order by errores_seguidos desc, codigo;

-- gasto de Apify este mes
select sum(costo_usd) from vigilante.system_logs where proceso = 'apify' and created_at >= date_trunc('month', now());
```

## Qué lee el recolector según «Cómo se lee»

| Método | Qué hace | Coste |
| --- | --- | --- |
| RSS | Lee el canal | Gratis |
| Google News | Si la dirección no es un RSS de Google News, busca con `query` (o `q`) de la fuente o con sus palabras clave, en las últimas 24 h | Gratis |
| GDELT | Igual, en la API de GDELT, noticias de medios bolivianos | Gratis |
| Página web | Descarga la página; si cambió, guarda los titulares enlazados (o la página entera si no hay enlaces) | Gratis |
| Apify | Lanza el actor de la fuente (`apify_actor`, `apify_input`) si queda tope | De pago |
| Buscador, API, Vigilante AVIA, Manual | No los lee el recolector | — |
