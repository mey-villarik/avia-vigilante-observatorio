# Publicar señales: web pública y Telegram

Cuando un analista o un administrador pulsa **Publicar** en una señal (o la arrastra a la columna «Publicada»):

1. La señal aparece en la **web pública** (`publico.html`). Cualquiera puede verla sin iniciar sesión y marcar si le fue útil.
2. El **bot de Telegram** la envía al canal del observatorio en menos de un minuto.

Si después la señal se mueve a otra columna (verificación, descartada o cerrada), **se retira de la web**. El mensaje de Telegram ya enviado no se borra.

Lo que AVIA marca como publicado por su cuenta **no se publica**. Siempre lo decide una persona.

Todo está en `db/generico/13_publicar_senales.sql`. Se puede ejecutar más de una vez.

## Pasos (una sola vez)

### 1. Supabase: ejecutar el SQL

En Supabase, abre **SQL Editor → New query**, pega el contenido de `db/generico/13_publicar_senales.sql` y pulsa **Run**.

### 2. Telegram: crear el bot y el canal

1. En Telegram, abre **@BotFather**, escribe `/newbot` y sigue los pasos. Al terminar te da un **token**, parecido a `123456:ABC-…`. No lo pegues en el chat ni en GitHub.
2. Crea un **canal** (por ejemplo, «ORBITA Alertas»). Si es público, ponle un nombre de usuario, por ejemplo `@orbita_alertas`.
3. En el canal: **Administradores → Añadir administrador**, busca tu bot y dale permiso para **publicar mensajes**.

### 3. Supabase: guardar el token y el canal

En el SQL Editor (el token se queda solo dentro de Supabase, cifrado en el Vault):

```sql
-- el token del bot (cámbialo por el tuyo)
select vault.create_secret('PEGA_AQUI_EL_TOKEN', 'telegram_bot_token');

-- el canal y los enlaces (cámbialos por los tuyos)
insert into vigilante.parametros (cliente_id, clave, valor)
select id, x.clave, to_jsonb(x.valor) from vigilante.clientes,
  (values ('telegram_canal', '@orbita_alertas'),
          ('telegram_canal_url', 'https://t.me/orbita_alertas')) as x(clave, valor)
where slug = 'orbita-bolivia'
on conflict (cliente_id, clave) do update set valor = excluded.valor;
```

- Si el canal es privado, `telegram_canal` es su número (empieza por `-100…`). Se ve reenviando un mensaje del canal a @userinfobot.
- Cuando la web pública esté en el VPS, añade también `web_publica_url`. Así cada aviso de Telegram lleva el enlace «Ver todas las alertas».
- Para cambiar el token: `select vault.update_secret((select id from vault.secrets where name = 'telegram_bot_token'), 'TOKEN_NUEVO');`

### 4. Probar

1. En el panel, abre una señal y pulsa **Publicar**.
2. En tu PC: `npm run dev` y abre http://localhost:5173/publico.html. La señal debe aparecer.
3. En menos de un minuto llega el mensaje al canal de Telegram. Si no llega:

```sql
select estado, error, created_at from vigilante.deliveries
 where canal = 'telegram' order by id desc limit 5;
```

- `enviado`: salió bien.
- `fallido` con «chat not found»: el canal está mal escrito.
- `fallido` con «Forbidden»: el bot no es administrador del canal.
- `pendiente` todo el rato: mira la tarea con `select * from cron.job where jobname = 'vigilante-telegram';`.

Para volver a intentar los fallidos: `update vigilante.deliveries set estado = 'pendiente' where canal = 'telegram' and estado = 'fallido';`

## Cómo queda el mensaje

```
⚠️ Riesgo · Clima y desastres
Alerta SENAMHI: vientos fuertes en Santa Cruz

La cuenta del 06/11 confirma vientos de 60-90 km/h.

📍 Santa Cruz
➜ Avisar a operadores
Fuente · Ver todas las alertas
```

Si la señal venía de «En verificación», el mensaje y la web lo indican («en verificación»).

## Funciones (para el programador)

| Función | Quién | Qué hace |
|---|---|---|
| `vigilante.alertas_publicas(cliente)` | cualquiera (anon) | alertas vigentes con sus votos, para `publico.html` |
| `vigilante.votar_alerta(id, util, visitante)` | cualquiera (anon) | «¿Te fue útil?»: un voto por navegador, se puede cambiar |
| `vigilante.publicaciones()` | equipo | cada señal publicada: estado del aviso de Telegram y votos |
| `vigilante.texto_telegram(id)` | sistema | texto del aviso, para ver cómo quedará |
| `vigilante.enviar_telegram_pendientes()` | pg_cron, cada minuto | envía la cola; nunca la llama la web |

En la web, `publico.html` lee `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` y `VITE_CLIENTE_PUBLICO` (por defecto `orbita-bolivia`). Sin Supabase muestra ejemplos.

## Publicar la web en el VPS

La web pública sale en la misma compilación que el panel (`dist/publico.html`), así que se publica junto con él y nginx la sirve tal cual: https://vigilante-bolivia.duckdns.org/publico.html. No hace falta ninguna regla especial.

En el VPS, con el repo en `/root/avia-repo`:

```bash
bash /root/avia-repo/web/desplegar.sh claude/project-thread-3p1koa   # o main, cuando estén unidos los PR
```

El script actualiza el código, crea `web/.env.production` la primera vez a partir de la web ya publicada (solo valores públicos), compila con Node 20 o, si no hay, con Docker, guarda una copia `dist.bak-FECHA` y copia la nueva versión encima. Para volver atrás, copia esa carpeta de nuevo sobre `dist`.

Después, para que cada aviso de Telegram lleve el enlace a la web, en el SQL Editor:

```sql
insert into vigilante.parametros (cliente_id, clave, valor)
select id, 'web_publica_url', to_jsonb('https://vigilante-bolivia.duckdns.org/publico.html'::text)
from vigilante.clientes where slug = 'orbita-bolivia'
on conflict (cliente_id, clave) do update set valor = excluded.valor;
```
