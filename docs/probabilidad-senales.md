# Probabilidad de ocurrencia en las señales confirmadas

Cada señal **confirmada** dice ahora qué tan probable es que ocurra (o que siga ocurriendo) y **por qué, en una frase**. Solo las confirmadas: las detectadas no la llevan, y si una confirmada vuelve a Detectadas o se descarta, se borra.


## Cómo se calcula: la base cuenta, AVIA matiza

**1. La base de datos (sin IA, gratis)**, en el momento en que la señal pasa a Confirmada (a mano, con las flechas o sola por ser oficial):

```
base = (peso de la mejor fuente / 5) × 0,5
     + (fuentes distintas, hasta 4) / 4 × 0,3
     + tasa de confirmación de su categoría (90 días) × 0,2
```

| Factor | De dónde sale |
| --- | --- |
| Peso de la fuente | El mismo del 32: 5 oficial, 4 organismo internacional, 3 medio, 2 búsqueda, 1 no oficial |
| Fuentes distintas | Las fuentes de las noticias enlazadas a la señal |
| Tasa de la categoría | Confirmadas ÷ (confirmadas + descartadas) de esa categoría en 90 días. Con menos de 3 decididas, 0,5 |

Nunca baja de 5 % ni pasa de 95 %. Se guarda con su razón («Cálculo base: fuente oficial (SENAMHI), 2 fuentes distintas y 75 % de las señales de clima confirmadas en 90 días»), así que la tarjeta muestra algo aunque AVIA no haya pasado. Si llega una noticia nueva antes de que AVIA la ajuste, la base se recalcula.

**2. AVIA (Hermes con la skill `avia-probabilidad`)** recibe en lote, hasta 10 señales por llamada, solo esto por señal (unos 120-150 tokens):

```json
{"codigo": "SEN-0142", "titulo": "…", "naturaleza": "riesgo", "categoria": "clima", "cuando": "2026-11-21",
 "base": 0.80, "factores": {"peso_fuente": 5, "fuentes": 2, "tasa_categoria": 0.75},
 "contexto": ["Época: noviembre, temporada de lluvias (noviembre a marzo)",
              "Zona: La Paz",
              "Historial 90 días en clima: confirmadas 12, descartadas 4; en esta zona 5 señales, 4 confirmadas"]}
```

y devuelve lo mínimo, en una sola llamada para todo el lote:

```json
[{"codigo": "SEN-0142", "prob": 0.86, "razon": "Aviso del SENAMHI con fecha, en plena temporada de lluvias en Los Yungas."}]
```

La base no deja que AVIA se aleje más de **±0,20** de su cálculo (lo recorta y lo dice). Coste estimado con DeepSeek: menos de USD 0,001 por señal. Si el clasificador ya había estimado una probabilidad con justificación, va en la entrada (`clasificador`) sin coste extra.

**3. Se guarda en la señal**: `prob_ocurrencia` (la final), `prob_razon` (la frase), `prob_base`, `prob_origen` (`base` o `avia`), `prob_factores` y `prob_calculada_en`.

## Dónde se ve

- **Panel, columna Confirmadas**: en cada tarjeta, «78 % probable», una barra y la razón (dos líneas como máximo). La etiqueta dice «cálculo base» o «AVIA».
- **Ficha de la señal**: en Puntuaciones, «Probabilidad de que ocurra», con la razón y, si la ajustó AVIA, cuánto había calculado la base.
- **Chat de AVIA y `vigilante_bd()`**: salen en `puntuaciones.probabilidad` (la función del 22 ahora usa la del 33 en las confirmadas).

El color es neutro a propósito: una probabilidad alta no es buena ni mala (puede ser un riesgo o una oportunidad).

## Cómo instalarlo

1. **Supabase**: SQL Editor → pegar `db/generico/33_probabilidad_senales.sql` → Run (necesita del 01 al 32). Las señales que ya están confirmadas reciben su cálculo base al momento. Comprobar:
   ```sql
   SELECT codigo, prob_ocurrencia, prob_razon FROM vigilante.signals WHERE estado = 'confirmada' ORDER BY updated_at DESC LIMIT 5;
   SELECT vigilante.probabilidades_pendientes_hermes('orbita-bolivia');
   ```
2. **VPS: MCP 2.4 y skill**:
   ```bash
   cd /root/avia-repo && git fetch origin claude/project-thread-49dzs6 && git checkout claude/project-thread-49dzs6
   cp hermes/mcp-vigilante/servidor.py /root/.hermes/avia/servidor.py
   cp -r hermes/skills/avia-probabilidad /root/.hermes/skills/
   chown -R 10000:10000 /root/.hermes/avia /root/.hermes/skills/avia-probabilidad
   docker restart hermes
   ```
3. **VPS: tarea de Hermes «Probabilidad de señales»**, igual que la de fichas, sin horario (la lanza el despertador), con este prompt, y apunta su id:
   > Usa la skill avia-probabilidad. Llama a probabilidades_por_ajustar; si devuelve [], termina. Ajusta todas y guárdalas en una sola llamada a guardar_probabilidades. Termina con una línea: cuántas ajustaste.
4. **VPS: despertador**:
   ```bash
   cp hermes/eventos/despertar_hermes.py /root/avia/
   echo 'HERMES_CRON_PROB=<id de la tarea del paso 3>' >> /root/avia/supabase.env
   python3 /root/avia/despertar_hermes.py --contar
   ```
   Sin `HERMES_CRON_PROB`, las confirmadas se quedan con el cálculo base (sin gastar tokens). El cron de cada 5 minutos que ya existe sirve: **sin flock en el crontab**.
5. **Web**: `bash /root/avia-repo/web/desplegar.sh claude/project-thread-49dzs6`.

## Parámetros (`vigilante.parametros`)

| Clave | Por defecto | Qué hace |
| --- | --- | --- |
| `prob_activa` | `true` | Apaga o enciende el cálculo al confirmar |
| `prob_ajuste_max` | `0.20` | Cuánto puede mover AVIA la base (máximo 0,5) |
| `prob_tasa_dias` | `90` | Días de historial para la tasa de la categoría |
| `prob_horas_avia` | `72` | AVIA solo ajusta señales creadas o actualizadas en estas horas |

## Prueba

`db/generico/99_prueba_probabilidad.sql` (termina en `ROLLBACK`): cálculo al confirmar, sin probabilidad en las detectadas, recálculo al llegar una noticia sin tocar `updated_at`, oficial que entra sola en Confirmadas, entrada corta para AVIA con tres líneas de contexto, reserva, guardado en lote con recorte a ±0,20 y a 95 %, errores sin romper el lote, se conserva al publicar y retirar, se borra al volver a Detectadas y se recalcula al reconfirmar, y sale en `vigilante.json`.
