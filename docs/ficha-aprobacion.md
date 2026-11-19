# Ficha de aprobación de riesgos

Antes de que una persona publique una alerta de riesgo, AVIA le prepara una **ficha de seis líneas** con la evidencia. Sale del GPT «AVIA-Auditor» (AVIA-Fake), el verificador de afirmaciones del ecosistema AVIA, adaptado a las fuentes de Bolivia.

| Línea | Qué dice | Ejemplo (ficticio) |
| --- | --- | --- |
| 1. Afirmación | Lo que diría la alerta, en una frase | Anuncian un bloqueo en la ruta La Paz–Copacabana desde el lunes 24 |
| 2. Evidencia | Las noticias que la sostienen y su peso, de 1 a 5 | Peso 2 · un medio que cita a un dirigente, sin comunicado de la ABC |
| 3. Falta | El documento que cerraría la duda | Comunicado de la ABC sobre la ruta |
| 4. Riesgo | El daño si la alerta es falsa o exagerada, de U1 a U4 | U3 · puede dejar varados a visitantes del lago Titicaca |
| 5. Sugerencia | Publicar, esperar o no publicar, con el motivo | Esperar · riesgo alto con una sola fuente no oficial |
| 6. Texto prudente | Cómo contarlo sin alarmismo | «Según La Razón, transportistas anuncian un bloqueo… Pendiente de confirmación de la ABC.» |

La ficha **no publica ni mueve nada**. Publicar sigue siendo de una persona.

## Pesos y regla de oro

La base pone el techo de peso según el tipo de fuente, y AVIA no puede pasarlo:

| Peso | Fuente | Tipo en el catálogo |
| --- | --- | --- |
| 5 | Oficial primaria: SENAMHI, ABC, Ministerio de Salud, DGAC, Gaceta Oficial… | `oficial` |
| 4 | Organismo internacional: OPS, CAF, BID… | `organismo_internacional` |
| 3 | Medio (de referencia con documento, o dos medios) | `medio` |
| 2 | Noticia de búsqueda sin fuente del catálogo, o un medio sin documento | — |
| 1 | Redes o páginas no oficiales | `no_oficial` |

| Riesgo | Cuándo | Para sugerir «publicar» |
| --- | --- | --- |
| U1 | Molestia menor | Peso 2 o más |
| U2 | Afecta planes de algunos viajeros | Peso 2 o más |
| U3 | Cancelaciones o gente varada | Peso 4 o más |
| U4 | Vida, salud o daño grave | Peso 5 |

Un rumor (peso 1) nunca se sugiere publicar. La base rechaza la ficha que no cumple estas reglas y AVIA la corrige.

## Qué señales llevan ficha

Riesgos y mixtas (y cualquier señal de una categoría con revisión obligatoria: clima, salud, vial, seguridad) que cumplen todo esto:

- no están publicadas, cerradas ni descartadas, y no son escenarios;
- tienen prioridad media o alta;
- se crearon o cambiaron en las últimas 72 horas.

Una ficha por señal. Solo se rehace si llegan noticias nuevas; mientras tanto se sigue viendo la anterior, marcada como desactualizada.

## Cuánto gasta

Una llamada de Hermes por señal de riesgo, solo con las noticias que ya están en la base (sin buscar en la web). Hermes solo se despierta si hay alguna ficha pendiente. Para gastar menos, sube `ficha_prioridad_min` a `"alta"`.

## Dónde se ve

- **Panel**: en la ficha de la señal, encima de los botones Confirmar / Publicar, con un borde verde (publicar), naranja (esperar) o rojo (no publicar). Solo analistas y administradores.
- **Chat de AVIA**: «¿publico la SEN-0142?» → AVIA lee la ficha con la herramienta `ficha_senal`.
- **Telegram** (grupo de analistas, `telegram_analistas_chat` del 18):
  - con aprobación previa (`aprobacion_previa = true`), como respuesta al aviso «Señal por aprobar»;
  - sin ella (como ahora), solo si pones `ficha_telegram_siempre = true`; si no, la ficha solo está en el panel.

## Cómo instalarlo

1. **Supabase**: SQL Editor → pegar `db/generico/32_ficha_aprobacion.sql` → Run (necesita del 01 al 31). Comprobar:
   ```sql
   SELECT vigilante.fichas_pendientes_hermes('orbita-bolivia');
   ```
   Crea la tarea de pg_cron `vigilante-fichas` (cada 2 min) para Telegram.
2. **VPS: MCP 2.3 y skill**:
   ```bash
   cd /root/avia-repo && git fetch origin claude/project-thread-7miava && git checkout claude/project-thread-7miava
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py
   cp -r hermes/skills/avia-ficha-aprobacion /root/.hermes/skills/
   chown -R 10000:10000 /root/.hermes/avia /root/.hermes/skills/avia-ficha-aprobacion
   docker restart hermes
   ```
3. **VPS: tarea de Hermes «Fichas de aprobación»**. Créala igual que la de eventos, sin horario (la lanza el despertador), con este prompt, y apunta su id:
   > Usa la skill avia-ficha-aprobacion. Llama a fichas_por_preparar; si devuelve [], termina. Para cada señal, prepara la ficha y guárdala con guardar_ficha_aprobacion. Termina con 2 líneas: cuántas fichas y cuántas con cada sugerencia.

   Para ver cómo se crea en tu versión: `docker exec hermes hermes cron --help`.
4. **VPS: despertador**:
   ```bash
   cp hermes/eventos/despertar_hermes.py /root/avia/
   echo 'HERMES_CRON_FICHAS=<id de la tarea del paso 3>' >> /root/avia/supabase.env
   python3 /root/avia/despertar_hermes.py --contar
   ```
   Sin `HERMES_CRON_FICHAS`, las fichas no despiertan a Hermes. El cron de cada 5 minutos que ya existe sirve: **sin flock en el crontab** (el script tiene su propio candado).
5. **Web**: publícala como siempre (`bash /root/avia-repo/web/desplegar.sh claude/project-thread-7miava`).

## Parámetros (`vigilante.parametros`, por cliente o por defecto)

| Clave | Por defecto | Qué hace |
| --- | --- | --- |
| `ficha_activa` | `true` | Apaga o enciende las fichas |
| `ficha_prioridad_min` | `"media"` | Prioridad mínima: `"baja"`, `"media"` o `"alta"` |
| `ficha_horas` | `72` | Solo señales creadas o cambiadas en estas horas |
| `ficha_naturalezas` | `["riesgo", "mixta"]` | Naturalezas con ficha (además, las categorías con revisión obligatoria) |
| `ficha_telegram_siempre` | `false` | `true` = la ficha va al grupo de analistas aunque no haya aviso de aprobación |

## Prueba

`db/generico/99_prueba_ficha_aprobacion.sql` (termina en `ROLLBACK`): qué señales llevan ficha, reserva, las reglas de la base (peso por encima del techo, regla de oro, rumor, falta, texto que da algo por seguro, noticias de otra señal, señal publicada), lectura y ficha desactualizada al llegar una noticia.
