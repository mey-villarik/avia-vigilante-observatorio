# Aprobación del analista (alertas de riesgo)

Archivo: `db/generico/18_aprobacion_analista.sql` · prueba: `db/generico/99_prueba_aprobacion.sql`
Función de Telegram: `supabase/functions/telegram-revision`

## Reglas (decisión del 11-11-2026)

- Piden aprobación las señales de **clima, salud, vial y seguridad**, las que vienen de fuentes no oficiales y los escenarios (campo `requiere_revision`, ya existía).
- **Nada que pida aprobación se publica sin que una persona lo apruebe.** Si vence el plazo, la señal se queda sin publicar, con la marca «Plazo vencido», y el bot avisa otra vez a los analistas.
- **Plazo: 1 hora** (parámetro `sla_revision_minutos` = 60), en horario de guardia de 07:00 a 22:00 (hora de Bolivia). Lo que llega de noche vence a las 08:00.
- Un escenario se puede aprobar, pero nunca sale en la web ni en Telegram.

## Qué ve el analista

**En el panel (Señales):**
- Una franja arriba: «N señales esperan aprobación», en rojo si alguna venció. El botón «Ver solo por revisar» deja solo esas, primero las que vencen antes.
- En la ficha de cada una: **Aprobar y publicar** y **Rechazar**, con la nota opcional. Aprobar pasa la señal por las etapas que falten y la publica (web pública + canal de Telegram). Siguen estando los botones de siempre (Confirmar, Publicar, Pedir verificación, Descartar); publicar o descartar a mano también cuenta como decisión.

**En Telegram (grupo privado de analistas):**
- Cuando llega una señal: «🔎 Señal por aprobar», con título, resumen, motivo, fuente, hora límite y los botones **✅ Aprobar y publicar** / **✖️ Rechazar**.
- Si vence: «⏰ Plazo vencido sin aprobación · no se ha publicado», con los mismos botones.
- Al decidir (en Telegram o en la web), el mensaje cambia a «✅ Aprobada y publicada por …» o «✖️ Rechazada por …» y pierde los botones.
- Solo funcionan los botones de quien esté en **Equipo** como analista o administrador con su id de Telegram. Si pulsa otra persona, Telegram le muestra un aviso y no pasa nada.

## Puesta en marcha

1. **SQL.** Pegar `18_aprobacion_analista.sql` en el SQL Editor de Supabase y ejecutarlo.
2. **Grupo de analistas.** En Telegram, crear un grupo privado, añadir el bot (el mismo de las alertas) y los analistas. Para saber el id del grupo: añadir un momento @RawDataBot o @getidsbot, que lo dice (empieza por `-100…`). Guardarlo:
   ```sql
   INSERT INTO vigilante.parametros (cliente_id, clave, valor)
   SELECT id, 'telegram_analistas_chat', '"-100XXXXXXXXXX"' FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
   ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;
   -- opcional: enlace al panel en cada aviso
   INSERT INTO vigilante.parametros (cliente_id, clave, valor)
   SELECT id, 'panel_url', '"https://vigilante-bolivia.duckdns.org/"' FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
   ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;
   ```
   Desde ese minuto los avisos llegan solos (los manda la tarea `vigilante-revision`, que ya corre cada minuto). Sin la función del paso 4 los avisos llegan, pero los botones no hacen nada: se aprueba en la web.
3. **Ids de Telegram de los analistas.** Cada analista escribe a @userinfobot y pasa su número. El administrador lo pone en el panel: Equipo → botón «Telegram» junto a la persona.
4. **Función de los botones** (en el ordenador, con la CLI de Supabase):
   ```bash
   supabase secrets set TELEGRAM_BOT_TOKEN=<token del bot> TELEGRAM_WEBHOOK_SECRET=<clave larga inventada> --project-ref <ref>
   supabase functions deploy telegram-revision --no-verify-jwt --project-ref <ref>
   ```
   Y decir a Telegram adónde mandar los clics (una vez):
   ```bash
   curl "https://api.telegram.org/bot<token>/setWebhook" \
     -d url=https://<ref>.supabase.co/functions/v1/telegram-revision \
     -d secret_token=<la misma clave inventada> \
     -d 'allowed_updates=["callback_query"]'
   ```
   **Ojo:** un bot con webhook ya no puede leer mensajes con `getUpdates`. Si Hermes u otro programa lee ese mismo bot por `getUpdates`, usar un bot distinto para el grupo de analistas (y su token en `TELEGRAM_BOT_TOKEN` y en el Vault).

## Comprobar

```sql
SELECT vigilante.vencer_plazos_revision();          -- {"vencidas": …, "telegram": {"avisos": …, "fallidos": …}}
SELECT * FROM vigilante.avisos_revision ORDER BY id DESC LIMIT 10;   -- estado y error de cada aviso
```

## Funciones

| Función | Quién | Qué hace |
| --- | --- | --- |
| `aprobar_senal(codigo, nota)` | Web (analista/admin) | Aprueba y publica (escenario: solo aprueba) |
| `rechazar_senal(codigo, nota)` | Web (analista/admin) | Descarta |
| `cola_revision()` | Web (analista/admin) | Lo que espera aprobación, por hora límite |
| `decidir_senal_telegram(id, usuario_tg, chat, aprobar)` | Función `telegram-revision` (service_role) | Comprueba grupo y persona, y decide |
| `avisar_analistas()` | `vencer_plazos_revision()` cada minuto | Envía avisos nuevos y cierra los decididos |

Quién decidió y cuándo queda en `signals.revision_decidida_por` / `revision_decidida_en` y en la Bitácora (con «Desde Telegram» en la nota cuando aplica).

`99_prueba_tareas_programadas.sql` prueba el 16 tal cual (publicaba al vencer): ejecutarla antes del 18.
