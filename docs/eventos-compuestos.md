# Alertas emergentes: eventos compuestos

Primer paso para que el Vigilante pase de mostrar datos a ayudar a decidir. Antes cada señal se veía sola. Ahora, cuando dos o más señales coinciden en el mismo departamento y en las mismas fechas, el sistema las junta en un **evento compuesto**. AVIA explica qué significa, a quién afecta y qué hacer, y el panel lo muestra como **alerta emergente**.

> Ejemplo: «Riesgo acumulado en La Paz: huelga de transporte + lluvia fuerte prevista. Afecta a operadores de turismo receptivo y alojamientos con llegadas mañana. Recomendación: avisar a los clientes hoy y prever traslado alternativo; verificar con ABC y SENAMHI».

## Quién hace qué

| Paso | Lo hace | Dónde |
| --- | --- | --- |
| 1. Detectar que varias señales coinciden | La base, sin IA | `vigilante.componer_eventos()` en `db/generico/28_eventos_compuestos.sql`. La lanzan pg_cron (cada 5 min) y el analizador al terminar cada ronda |
| 2. Avisar a Hermes solo si hay algo | Script, sin IA | `hermes/eventos/despertar_hermes.py` (cron del VPS, cada 5 min). Si no hay eventos, no gasta tokens |
| 3. Interpretar | **Hermes (el cerebro)** | Skill `hermes/skills/interpretar-eventos/SKILL.md` + MCP (`eventos_por_interpretar` y `guardar_interpretacion_evento`) |
| 4. Avisar al equipo | Panel React | `web/src/components/Emergentes.tsx`. Pide los eventos cada minuto y muestra la ventana de alerta |

Todo es **interno**. Nada sale a la web pública ni a Telegram sin que una persona lo apruebe.

## Cómo se detecta un evento (paso 1)

- **Señales que cuentan**: las activas del panel (`senales_visibles`), menos las descartadas, las cerradas y las duplicadas.
- **Ventana de cada señal**:
  - Con fechas de evento, va del inicio al fin. Si no tiene fin, cuenta todo el día del inicio.
  - Sin fechas de evento, va desde la última noticia hasta 72 h después (`eventos_horizonte_horas`).
  - El plazo de una convocatoria no cuenta, porque es una fecha límite y no algo que pase en el territorio.
  - Una **oportunidad sin fechas** (un anuncio, una programación habitual de un hotel) no entra, porque no pasa en unas fechas concretas. Se puede cambiar con `eventos_oportunidad_sin_fecha = true`.
- **Territorio**: el departamento. Una ciudad o zona cuenta dentro de su departamento.
- **Señales nacionales** (`alcance_total`, o territorio «Bolivia»): se suman a los departamentos que ya tienen alguna señal propia en esa ventana. Se puede apagar con `eventos_incluir_nacional = false`.
- **Agrupación**: en cada departamento se unen las ventanas que se solapan. Un grupo es un evento si tiene 2 señales o más y al menos una del propio departamento.
- **Tipo**:
  - `riesgo_acumulado`: todas las señales son riesgos.
  - `oportunidad_combinada`: todas son oportunidades.
  - `confluencia`: hay de las dos, o alguna mixta.
- **Si entra una señal nueva** en un evento abierto, la versión sube, vuelve a Hermes y el aviso sale otra vez.
- **Si las señales dejan de coincidir** o caducan, el evento se cierra solo.
- **Si Hermes o un analista lo descartó**, no vuelve a salir hasta que entre una señal nueva.

### Prioridad calculada (sin IA, explicable)

```
peso de cada señal = prioridad (alta 3, media 2, baja 1) × certeza (confirmado 1, convocado 0,8, posible 0,5, rumor 0,25)
   (en la misma categoría, la señal más fuerte cuenta entera y cada una de las demás la mitad)
puntaje = 10 × suma de pesos
        + 8 por cada categoría distinta después de la primera
        + 15 si la ventana ya empezó o empieza en 48 h (8 si empieza en 7 días)
        + 5 si alguna señal viene de fuente oficial
máximo 100 · alta desde 70 (eventos_umbral_alta) · media desde 45 (eventos_umbral_media)
```

Ejemplo: huelga alta confirmada (3) + lluvia media convocada (1,6) = 46, más 8 por ser dos categorías, 15 porque empieza mañana y 5 por la fuente oficial: **74, alta**.

El desglose se guarda en `calculo`. Hermes puede subir o bajar la prioridad **un nivel**, siempre con motivo. La base rechaza saltos mayores.

## Qué escribe Hermes (paso 3)

`titular`, `significado` (hechos con certeza y después la interpretación), `a_quien_afecta`, `impacto`, `recomendacion` (`accion`, `para_quien`, `cuando`, `verificar_con`), `escenarios`, `falta_saber` y, si hace falta, `prioridad` con motivo. También puede decir que **no es un evento real** (`es_confluencia: false` con motivo), y entonces se descarta.

La base solo comprueba que la respuesta está completa y la recorta. Lo que no está previsto no se guarda. La skill pesa la evidencia con el método de la skill **avia-auditor**, que ya está instalada en Hermes, y usa el glosario y las reglas de certeza de **vigilancia-fuentes-bolivia**. **No inventa cifras**: «3 operadores afectados» solo aparece si las señales lo dicen. Hoy el sistema no tiene un registro de operadores.

## Qué ve el panel (paso 4)

- **Botón «Eventos N»** en la barra superior: rojo si hay alguno de prioridad alta. Abre la lista de eventos abiertos con su ficha.
- **Ventana de alerta**: sale sola para cada evento de prioridad **alta** que la persona aún no ha visto. Aparece cuando Hermes ya lo interpretó, o pasados 20 minutos sin interpretación (`eventos_espera_hermes_min`), en cuyo caso muestra las señales y avisa de que AVIA aún no lo ha interpretado.
  - **Entendido** la marca como vista para esa persona.
  - **No es relevante…** la descarta para todo el equipo, con motivo.
  - Cada código de señal abre su ficha.
- **Sonido**: opcional, se activa en la lista. Es un aviso corto de dos tonos. La preferencia se guarda en ese navegador.
- Solo lo ven **analistas y administradores**. A un visor la base le devuelve una lista vacía.

## Cómo ponerlo en marcha

1. **Supabase**: en el SQL Editor, pega entero `db/generico/28_eventos_compuestos.sql` y pulsa Run. Necesita del 01 al 27. Al terminar hace una primera composición con las señales que ya hay.
   - Comprobar: `SELECT codigo, tipo, territorio_nombre, prioridad, estado FROM vigilante.eventos_compuestos;`
   - Prueba sin dejar nada: `99_prueba_eventos.sql`, que termina en ROLLBACK.
2. **VPS: MCP y analizador**. En `/root/avia-repo`, trae la rama y copia los archivos **después de comparar con `diff`**:
   ```bash
   cd /root/avia-repo && git fetch origin claude/project-thread-1uhjud && git checkout FETCH_HEAD -- hermes/
   diff hermes/analizador/analizador.py /root/avia/analizador.py   # revisar antes de copiar
   cp hermes/analizador/analizador.py /root/avia/analizador.py
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py   # si ya lo tienes conectado
   ```
   El analizador ya tiene su propio candado. **No le pongas flock en el crontab.**
   Si Hermes aún no tiene el MCP `avia-vigilante` (`grep -n -A6 "^mcp_servers" /root/.hermes/config.yaml` no devuelve nada sin `#`), conéctalo así. `/root/.hermes` del VPS es `/opt/data` dentro del contenedor, y Hermes trabaja con el usuario uid 10000, que debe poder leer el `.env`:
   ```bash
   mkdir -p /root/.hermes/avia
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py
   install -m 600 /root/avia/supabase.env /root/.hermes/avia/supabase.env
   chown -R 10000:10000 /root/.hermes/avia
   cat >> /root/.hermes/config.yaml <<'YAML'

   mcp_servers:
     avia-vigilante:
       command: python3
       args: ["/opt/data/avia/servidor.py"]
       env:
         AVIA_SUPABASE_ENV: /opt/data/avia/supabase.env
   YAML
   docker restart hermes
   ```
   Si el MCP no arranca, mira `docker exec hermes tail /opt/data/logs/mcp-stderr.log`.
3. **VPS: skill**. Copia la carpeta y reinicia Hermes:
   ```bash
   cp -r /root/avia-repo/hermes/skills/interpretar-eventos /root/.hermes/skills/
   docker restart hermes
   ```
4. **VPS: tarea de Hermes «Interpretar eventos»**. Créala igual que la ronda de AVIA, con este prompt, y apunta su id:
   > Usa la skill interpretar-eventos. Llama a eventos_por_interpretar; si devuelve [], termina. Para cada evento, interprétalo y guárdalo con guardar_interpretacion_evento. Termina con 2 líneas: interpretados y descartados.

   No le pongas horario, o pon uno muy espaciado: la lanza el script del paso 5. Para ver cómo se crea en tu versión: `docker exec hermes hermes cron --help`. No lo he podido comprobar desde aquí.
5. **VPS: script que despierta a Hermes**:
   ```bash
   cp /root/avia-repo/hermes/eventos/despertar_hermes.py /root/avia/
   echo 'HERMES_CRON_EVENTOS=<id de la tarea del paso 4>' >> /root/avia/supabase.env
   python3 /root/avia/despertar_hermes.py --contar      # debe decir cuántos eventos esperan
   (crontab -l; echo "*/5 * * * * AVIA_SUPABASE_ENV=/root/avia/supabase.env /usr/bin/python3 /root/avia/despertar_hermes.py >> /var/log/avia-eventos.log 2>&1") | crontab -
   ```
   Tiene su propio candado (`/tmp/avia-eventos.lock`). **Sin flock en el crontab.**
6. **Web**: publica el panel como siempre (`web/desplegar.sh`).

## Parámetros (`vigilante.parametros`, por cliente o por defecto)

| Clave | Por defecto | Qué hace |
| --- | --- | --- |
| `eventos_horizonte_horas` | 72 | Ventana de una señal sin fechas de evento |
| `eventos_anticipacion_dias` | 30 | Solo se juntan señales que empiezan antes de estos días |
| `eventos_incluir_nacional` | true | Las señales nacionales se suman a los departamentos |
| `eventos_umbral_alta` | 70 | Desde aquí, alerta emergente |
| `eventos_umbral_media` | 45 | Desde aquí, prioridad media |
| `eventos_espera_hermes_min` | 20 | Minutos que el panel espera la interpretación antes de avisar igual |
| `eventos_oportunidad_sin_fecha` | false | Si es true, las oportunidades sin fechas de evento también entran |

## Skills de Hermes para decidir

| Skill | Para qué | Origen |
| --- | --- | --- |
| `interpretar-eventos` | Interpreta cada evento compuesto (lo usa la alerta emergente) | Nueva |
| `avia-radar-decision` | «¿Qué hacemos con…?»: pasaporte de decisión con opciones, escenarios optimista/realista/adverso, reversibilidad y GO / GO condicionado / NO-GO | GPT «Radar AVIA Siesta», adaptado |
| `avia-anticipacion` | Radar semanal: señales débiles, tendencias y posibles eventos que aún no coinciden | GPT «AVIA TransmediaVigilance», adaptado |

Las tres toman de `avia-auditor` (ya instalada) el método para pesar la evidencia, con fuentes de Bolivia, y de `vigilancia-fuentes-bolivia` el glosario y las reglas de certeza. Se copian igual que la primera: `cp -r hermes/skills/<nombre> /root/.hermes/skills/` y `docker restart hermes`. El MCP 2.1 añade `eventos_abiertos` para que las skills y el chat lean los eventos sin reservarlos.

## Siguientes pasos posibles

- Que el chat de AVIA conozca los eventos abiertos («¿qué se está juntando esta semana?»).
- Registrar en el panel si la recomendación fue útil, para medir la calidad de Hermes.
- Correlaciones que no sean de lugar y fecha: la misma causa en varios departamentos, o temas que crecen juntos.
- Aviso por Telegram al grupo de analistas, nunca público, para las alertas emergentes.
