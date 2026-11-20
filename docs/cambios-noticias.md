# Alertas de cambio en noticias ya recogidas

Cuando una noticia nueva **cambia** algo que el Vigilante ya sabía, el panel lo avisa al momento con una **alarma sonora y una ventana flotante**, y lo deja marcado en el botón **«Cambios N»**, junto a «Eventos», hasta que la persona lo mira.

> Ejemplos: «viene un ciclón a Santa Cruz» → «el ciclón se desvió hacia Paraguay». «Feria el 5 de diciembre» → «la feria se aplaza al 12». «Bloqueo en la ruta Oruro–Uyuni» → «levantan el bloqueo».

Es complementario de los eventos compuestos (`docs/eventos-compuestos.md`): un evento junta señales **distintas** que coinciden; un cambio es **la misma** señal que ya no dice lo mismo.

## Quién hace qué

| Paso | Lo hace | Dónde |
| --- | --- | --- |
| 1. Ver cambios de datos (fecha del evento, plazo, riesgo ↔ oportunidad, sube a alta o deja de serlo) | La base, sin IA | Disparador `zz_cambio_datos` en `signals` (`db/generico/31_cambios_noticias.sql`) |
| 2. Ver cambios de sentido (cancelado, desviado, resuelto, desmentido…) | El clasificador breve (DeepSeek), en la misma llamada de siempre | Recibe con cada noticia las señales abiertas parecidas (`senales_relacionadas`) y devuelve `cambio` (prompt `clasificador-1.7`). Disparador `zz_cambio_clasificador` en `analisis` |
| 3. Avisar | Panel React | `web/src/components/Cambios.tsx`: pide los cambios cada 30 s; ventana + alarma; botón «Cambios N» |
| 4. Interpretar y confirmar | **Hermes** (skill `interpretar-cambios`) | MCP 2.2: `cambios_por_interpretar` → `guardar_interpretacion_cambio`. Puede descartar falsos cambios y registrar los que encuentre investigando (`registrar_cambio`) |

La alerta **no espera a Hermes** (parámetro `cambios_espera_hermes_min = 0`): sale en cuanto se detecta con el antes y el ahora; la lectura de AVIA (qué significa, qué hacer) aparece en la misma ficha cuando llega. Si Hermes decide que no era un cambio, desaparece del panel.

Todo es **interno**. No toca la web pública ni Telegram.

## Qué NO cuenta como cambio

- Lo que una persona mueve o edita en el panel (ya lo sabe).
- Rellenar un dato que faltaba (no había fecha y ahora sí).
- Prioridad media ↔ baja, o pasar a/desde «mixta».
- Otra noticia que repite el mismo cambio en las 24 h siguientes: se suma al cambio (cuenta «+N fuentes lo repiten»), sin volver a sonar.

## Qué ve el panel

- **Ventana flotante** con alarma (tres tonos, dos veces): tipo de cambio, importancia, **Antes** (tachado) y **Ahora**, la señal, las noticias que lo traen y, cuando llega, la lectura de AVIA. Si la señal está **publicada**, avisa en rojo de que la alerta pública aún dice lo de antes.
  - **Entendido** lo marca como visto para esa persona. **Ver la señal** abre su ficha. **No es un cambio…** lo descarta para todo el equipo, con motivo.
  - Si a la vez hay una alerta de evento, sale primero la del evento y después la del cambio.
- **Botón «Cambios N»** junto a «Eventos»: N = cambios sin ver; rojo y con el punto parpadeando si alguno es de importancia alta. Abre la lista de las últimas 24 horas (desde el 35; antes 3 días), con «Marcar todo como visto» y el interruptor de la alarma.
- La **pestaña del navegador** también avisa: «(2) Cambios · ORBITA».
- La **alarma viene activada**. Los navegadores no dejan sonar nada hasta que la persona ha hecho clic una vez en la página; después suena siempre.
- Solo analistas y administradores.

Si la señal que cambia forma parte de un evento compuesto, el evento vuelve a Hermes para que actualice su interpretación (sin repetir su alerta).

## Cómo ponerlo en marcha

1. **Supabase**: SQL Editor → pega entero `db/generico/31_cambios_noticias.sql` → Run. Necesita del 01 al 30.
   - Comprobar: `SELECT codigo, tipo, antes, ahora, importancia, estado FROM vigilante.cambios_senal ORDER BY id DESC;` (vacío al principio: los cambios empiezan a contar desde ahora).
   - Prueba sin dejar nada: `99_prueba_cambios.sql` (termina en ROLLBACK).
2. **VPS: analizador y su prompt** (comparar antes de copiar):
   ```bash
   cd /root/avia-repo && git fetch origin claude/project-thread-ujemax && git checkout FETCH_HEAD -- hermes/
   diff hermes/analizador/analizador.py /root/avia/analizador.py
   cp hermes/analizador/analizador.py hermes/analizador/prompt_clasificador.md /root/avia/
   ```
   El analizador ya tiene su propio candado: **sin flock en el crontab**.
3. **VPS: MCP y skill** (Hermes corre como uid 10000):
   ```bash
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py
   cp -r hermes/skills/interpretar-cambios hermes/skills/interpretar-eventos /root/.hermes/skills/
   chown -R 10000:10000 /root/.hermes/avia /root/.hermes/skills/interpretar-cambios /root/.hermes/skills/interpretar-eventos
   docker restart hermes
   ```
4. **VPS: despertador**: `cp hermes/eventos/despertar_hermes.py /root/avia/`. Ahora cuenta eventos **y** cambios. Comprueba con `python3 /root/avia/despertar_hermes.py --contar`.
5. **Tarea de Hermes**: la misma «Interpretar eventos» (`HERMES_CRON_EVENTOS`) sirve, cambiando su prompt a:
   > Usa las skills interpretar-cambios e interpretar-eventos. Llama a cambios_por_interpretar y guarda cada uno con guardar_interpretacion_cambio. Después llama a eventos_por_interpretar y guarda cada uno con guardar_interpretacion_evento. Si los dos devuelven [], termina. Termina con 2 líneas: interpretados y descartados.

   Si prefieres una tarea aparte, créala con el prompt de los cambios y pon su id en `HERMES_CRON_CAMBIOS` en `/root/avia/supabase.env`.
6. **Web**: publícala como siempre (`bash /root/avia-repo/web/desplegar.sh claude/project-thread-ujemax`).

## 24 horas en la lista (35)

Pedido de Meysel (2026-11-20): *«los cambios también quiero que se quiten de la lista a las 24 horas, se guarden en la BD pero no se muestren, para evitar listas muy largas»*.

- Cada cambio se ve en la lista «Cambios» durante `cambios_horas_panel` (24) desde que se detectó. Las repeticiones (otra noticia con el mismo cambio) no alargan el plazo.
- Pasado ese tiempo no se borra ni se descarta: sigue en `vigilante.cambios_senal`, y AVIA lo sigue viendo por el MCP (`cambios_abiertos`, 3 días por defecto).
- «Marcar todo como visto» marca solo los que se ven en la lista.
- Igual que los eventos (34, `docs/eventos-dinamicos.md`).

Ponerlo en marcha: SQL Editor de Supabase → pega entero `db/generico/35_cambios_24h.sql` → Run (necesita el 31; se puede ejecutar varias veces), y desplegar la web. Prueba: `99_prueba_cambios_24h.sql`.

## Parámetros (`vigilante.parametros`, por cliente o por defecto)

| Clave | Por defecto | Qué hace |
| --- | --- | --- |
| `cambios_alerta_desde` | `"baja"` | Importancia mínima para que salga la ventana con sonido (`baja` = todos; `media`; `alta`). Los demás solo se marcan en el botón |
| `cambios_espera_hermes_min` | `0` | Minutos que la ventana espera a la interpretación de AVIA |
| `cambios_horas_panel` | `24` | Horas que un cambio se ve en la lista desde que se detectó (35). Después sigue guardado en la base y AVIA lo ve por el MCP |
| `cambios_dias_panel` | `3` | Ya no se usa desde el 35 |
| `cambios_repetido_horas` | `24` | Un cambio igual en la misma señal dentro de este plazo se junta con el anterior |
| `cambios_parecido_min` | `0.25` | Parecido de títulos para mandar una señal al clasificador como posible relacionada |
| `cambios_buscar_dias` | `30` | Antigüedad máxima de esas señales |

## Coste

El clasificador ya leía cada noticia; ahora recibe además hasta 2 señales parecidas por noticia (unos cientos de tokens por lote, céntimos al mes con DeepSeek). Hermes solo se despierta si hay cambios.
