# Por qué, según AVIA: fiabilidad, probabilidad e impacto en texto (36)

Pedido de Meysel (2026-11-20): al pasar el ratón por la fiabilidad, la probabilidad o el impacto de una
señal confirmada no debe salir la fórmula, sino **la interpretación de AVIA en una frase**:

> AVIA determina que la fiabilidad es del 40 % porque estos hechos se repiten cada invierno en estas fechas
> y la fuente es un medio de prensa, no un aviso oficial.

## Cómo se determina cada número (no cambia)

| Puntuación | Quién pone el número | Qué explica AVIA |
|---|---|---|
| Fiabilidad (0-100) | La base, sin IA (22): tipo de fuente, fuentes distintas, si la confirmó una persona | Por qué hay ese respaldo: qué fuentes son, si son oficiales, si se repite |
| Probabilidad de que ocurra | La base al confirmar (33) y AVIA la ajusta ±0,20 | Época, fechas, zona, historial de la categoría, tipo de fuente |
| Impacto turístico | El analizador de AVIA (alto/medio/bajo) o su relevancia (22) | A quién afecta y por qué importa al turismo |

AVIA **no cambia** la fiabilidad ni el impacto: solo explica por qué son así. La probabilidad la sigue ajustando como en el 33.

## Cómo funciona

1. Es la **misma ronda** de la skill `avia-probabilidad` (sin tareas ni llamadas nuevas al modelo): `probabilidades_por_ajustar`
   trae ahora también `fiabilidad` (valor, fuentes con su tipo en palabras) e `impacto` (nivel y motivo).
2. AVIA devuelve, por señal, `prob`, `razon`, `razon_fiabilidad` y `razon_impacto`. Cada razón es **lo que va después de «porque»**,
   sin número ni fórmula.
3. `guardar_probabilidades` las limpia (quita «porque» y el punto final, máx. 200 caracteres) y las guarda en `signals`:
   `prob_razon`, `razon_fiabilidad`, `razon_impacto`, `razones_en`.
4. `puntuaciones()` devuelve cada una en la clave `avia`, y el panel compone la frase con el número guardado:
   «AVIA determina que la probabilidad de que ocurra es del 82 % porque …». Así el número siempre es el real, aunque la base recorte el ajuste.
5. **Si AVIA aún no lo explicó, el ratón muestra solo el número** («Probabilidad: 62 %»).

Cuándo se rehacen:
- **Confirmadas que ya tenían probabilidad sin razones**: entran solas en las siguientes rondas (las de los últimos 30 días,
  parámetro `razones_dias`); AVIA repite su probabilidad (`ya_ajustada`) y solo escribe las razones.
- **Llega una noticia nueva** a la señal: se borra la razón de la fiabilidad y AVIA la vuelve a escribir.
- **El analizador vuelve a valorar** la señal: se borra la razón del impacto.
- **La señal vuelve atrás** (detectada, en análisis, descartada): se borran las tres.
- Nada de esto cuenta como «señal actualizada» (no reaparece como reciente).

## Dónde se ve

- Tarjeta de Confirmadas: ratón sobre «N % probable»; la línea de abajo dice «Porque …».
- Ficha de la señal → Puntuaciones: ratón sobre cada recuadro, y la frase de AVIA en el propio recuadro
  (en fiabilidad sustituye a la lista de puntos «+50, +30…»).

Captura con datos de ejemplo: `capturas/porque-avia-puntuaciones.png` (carpeta del proyecto).

## Cómo instalarlo

1. **Supabase**: SQL Editor → pegar `db/generico/36_razones_avia.sql` → Run (necesita del 01 al 33; se puede ejecutar varias veces).
   ```sql
   SELECT vigilante.probabilidades_pendientes_hermes('orbita-bolivia');   -- ahora cuenta también las que esperan razones
   ```
2. **VPS: MCP 2.4.1 y skill 1.1.0** (rama `claude/project-thread-cfau27`):
   ```bash
   cd /root/avia-repo && git fetch origin claude/project-thread-cfau27 && git checkout claude/project-thread-cfau27
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py
   cp -r hermes/skills/avia-probabilidad /root/.hermes/skills/
   chown -R 10000:10000 /root/.hermes/avia /root/.hermes/skills/avia-probabilidad
   docker restart hermes
   ```
   La tarea «Probabilidad de señales» y `HERMES_CRON_PROB` del 33 sirven tal cual: no hay tarea nueva.
3. **Web**: `bash /root/avia-repo/web/desplegar.sh claude/project-thread-cfau27`.

## Parámetros (`vigilante.parametros`)

| Clave | Por defecto | Qué hace |
|---|---|---|
| `razones_activas` | `true` | `false` = AVIA no rellena razones de confirmadas antiguas (solo las nuevas, al ajustar) |
| `razones_dias` | `30` | Hasta cuántos días atrás rellena razones de confirmadas que no las tienen |

Prueba: `db/generico/99_prueba_razones.sql` (termina en ROLLBACK).
