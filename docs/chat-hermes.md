# Chat AVIA a través de Hermes (con respaldo DeepSeek)

Desde este cambio, el chat del panel (`POST /chat` de `avia-api`) pregunta **primero a Hermes**, que responde
con sus skills (`avia-auditor`, `avia-radar-decision`, `avia-anticipacion`…) y el MCP del Vigilante. Si Hermes
no está configurado, tarda más de `HERMES_TIMEOUT` o devuelve un error, el chat responde **con DeepSeek directo,
como antes**. Después de un fallo, durante 2 minutos el chat va directo a DeepSeek para no hacer esperar a nadie.

`/analisis` y `/evaluar` no cambian: siguen yendo a DeepSeek directo (son respuestas de formato fijo).

## Qué cambia en `avia_api.py`

- El mensaje de sistema (datos del observatorio, contadores, glosario, formato) es **el mismo** para los dos
  motores. A Hermes se le añade un bloque `HERMES_EXTRA`: qué skills usar, que solo lea con el MCP y que desde
  el chat **no guarde nada** (ni `guardar_senal`, ni terminal, ni archivos, ni cron).
- La respuesta a la web es la misma `{texto, comandos?}`; se añade `motor: "hermes" | "deepseek"`, que la
  web ignora y que sirve para la batería y para el log.
- Tiempos: Hermes tiene `HERMES_TIMEOUT` (35 s); DeepSeek, lo que quede hasta `CHAT_PRESUPUESTO` (55 s),
  porque nginx corta a los 60 s si no se ha cambiado `proxy_read_timeout`.
- Los tokens de Hermes que informe su API quedan en `system_logs` como `avia-chat-hermes`.
- `GET /health` dice qué motor usa el chat ahora: `"chat": "hermes"` o `"deepseek"`.

Variables nuevas en `/root/avia/supabase.env` (nunca en Git):

| Variable | Valor | Para qué |
|---|---|---|
| `HERMES_API_URL` | `http://IP_DEL_CONTENEDOR:8642` | Sin ella, el chat va directo a DeepSeek (como antes) |
| `HERMES_API_KEY` | el `API_SERVER_KEY` de Hermes | Autorización |
| `HERMES_MODEL` | `hermes-agent` (por defecto) | Nombre del modelo que expone Hermes |
| `HERMES_TIMEOUT` | `35` | Segundos que se espera a Hermes |
| `CHAT_PRESUPUESTO` | `55` | Segundos totales del chat, respaldo incluido |

## Pasos en el VPS

Haz los pasos 2 a 5 en **la misma terminal**: usan las variables `$CLAVE` e `$IP`.

### 1. Ver cómo está el contenedor

```bash
docker inspect hermes --format 'cmd={{.Config.Cmd}} red={{.HostConfig.NetworkMode}} puertos={{json .HostConfig.PortBindings}}'
docker exec hermes sh -c 'grep -n "^API_SERVER" /opt/data/.env || echo "API server sin configurar"'
docker logs hermes 2>&1 | grep -i "api server" | tail -3
```

El API server de Hermes solo arranca con el gateway (`hermes gateway`). Si `cmd` no es el gateway, avísame
con la salida y lo vemos.

### 2. Encender el API server de Hermes

```bash
CLAVE=$(openssl rand -hex 24)
cat >> /root/.hermes/.env <<EOT
API_SERVER_ENABLED=true
API_SERVER_HOST=127.0.0.1   # con red «host» (la de ORBITA). Solo con red bridge propia: 0.0.0.0
API_SERVER_PORT=8642
API_SERVER_KEY=$CLAVE
EOT
chown -R 10000:10000 /root/.hermes
docker restart hermes
sleep 15
docker logs hermes 2>&1 | grep -i "api server" | tail -3     # debe decir «listening on http://127.0.0.1:8642»
```

**Nunca `0.0.0.0` con red «host»**: Hermes quedaría abierto a internet con su terminal. Comprueba con `ss -ltnp | grep 8642` que dice `127.0.0.1:8642`.

### 3. Comprobar que el VPS llega a Hermes

```bash
# con red «host» (la de ORBITA) docker no da IP («invalid IP»): se usa 127.0.0.1
if [ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' hermes)" = host ]; then IP=127.0.0.1
else IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' hermes); fi
echo "Hermes en $IP"
curl -s http://$IP:8642/health
curl -s http://$IP:8642/v1/chat/completions -H "Authorization: Bearer $CLAVE" -H 'Content-Type: application/json' \
  -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Di solo: hola"}]}' | head -c 400; echo
```

La IP del contenedor puede cambiar si se recrea el contenedor (no con un `docker restart`). Si cambia, el chat
sigue funcionando con DeepSeek y el log de `avia-api` lo dice; basta con actualizar `HERMES_API_URL`.

### 4. Quitar a Hermes la terminal y los archivos en el API server (recomendado)

El chat lo usan visores. Desde el API server, Hermes no debería poder ejecutar comandos ni tocar archivos:

```bash
docker exec -it hermes hermes tools
```

Elige la plataforma del API server y deja solo lo que necesita el chat (skills, memoria, MCP); quita terminal,
archivos y ejecución de código. **No he podido comprobar el menú exacto en tu versión de Hermes**: si no sale la
plataforma del API server, dímelo y lo buscamos.

### 5. Conectar `avia-api` con Hermes

```bash
cd /root/avia-repo && git fetch origin && git checkout claude/project-thread-tn51vx && git pull
diff /root/avia/avia_api.py hermes/avia-api/avia_api.py | head -40   # por si la copia del VPS tiene parches propios
cp /root/avia/avia_api.py /root/avia/avia_api.py.antes-hermes
cp hermes/avia-api/avia_api.py /root/avia/avia_api.py
cat >> /root/avia/supabase.env <<EOT
HERMES_API_URL=http://$IP:8642
HERMES_API_KEY=$CLAVE
EOT
systemctl restart avia-api
sleep 2
journalctl -u avia-api -n 5 --no-pager      # «chat: Hermes http://…:8642 con respaldo DeepSeek»
curl -s http://127.0.0.1:8099/health; echo  # «"chat": "hermes"»
```

### 6. Probar

Pregunta en el chat del panel y mira qué motor respondió:

```bash
journalctl -u avia-api -f | grep -i hermes   # si aparece «HERMES NO RESPONDE», respondió DeepSeek y dice por qué
```

Y la batería de siempre (`docs/bateria-pruebas.md`), para comparar con la última ronda.

## Volver atrás

Quita (o comenta con `#`) `HERMES_API_URL` en `/root/avia/supabase.env` y `systemctl restart avia-api`:
el chat vuelve a DeepSeek directo sin tocar el código.

## Costes y tiempos

Hermes añade su propio mensaje de sistema y el índice de skills a cada pregunta, y puede consultar el MCP:
cada respuesta gasta más tokens que DeepSeek directo y tarda más (varios segundos). El gasto sale de la misma
cuenta de DeepSeek y se ve en el saldo del panel.
