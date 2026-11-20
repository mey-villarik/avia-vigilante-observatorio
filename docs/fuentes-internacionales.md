# Fuentes internacionales que afectan a Bolivia (SQL 37)

## Qué cambia

El Vigilante lee tres fuentes de fuera de Bolivia, en un apartado propio, pero lo que encuentra
entra en la misma cadena que todo lo demás (señales, oportunidades, eventos compuestos).

| Fuente | Qué aporta | Cómo se lee | Cada |
| --- | --- | --- | --- |
| **OPS/OMS** (`ops_alertas`) | Alertas y actualizaciones epidemiológicas de la región: dengue, sarampión, oropouche, fiebre amarilla… | RSS `paho.org/es/rss.xml`; respaldo Google News | 3 h |
| **CEPAL** (`cepal_comunicados`) | Proyecciones económicas, comercio, inversión, turismo y cooperación en la región y en Bolivia | Listado de comunicados de `cepal.org`; respaldo Google News | 12 h |
| **Prensa internacional** (`prensa_internacional`) | BBC Mundo, Reuters y AP cuando hablan de Bolivia o de la región andina (clima, política, economía) | Google News con `site:bbc.com OR site:reuters.com OR site:apnews.com` | 1 h |

La OPS ya existía (venía en el 02): el 37 la actualiza, no la duplica.

## Cómo influye en las decisiones

1. **Filtro sin IA** (igual que siempre): pasa lo que nombra Bolivia, un país vecino o un tema vigilado.
2. **Analizador** (prompt `clasificador-1.8`): cada noticia de fuente internacional llega marcada
   `internacional: true` junto con hasta 4 señales nacionales abiertas del mismo tema. El modelo decide
   `impacto_bolivia`:
   - `hay_impacto` (si es `false`, la noticia se descarta: «sin impacto en Bolivia»)
   - `ambitos`: turismo, salud, economía, clima, infraestructura
   - `via`: por dónde llega a Bolivia, en una frase (sin vía concreta, el analizador la descarta)
   - `nivel` (alto, medio, bajo) y `plazo` (inmediato, semanas, meses)
   - `refuerza`: las señales nacionales a las que da contexto (solo de las que recibió)
3. **Base**: la señal guarda `impacto_bolivia` y `refuerza`. Es `internacional` solo si todas sus
   noticias vienen de fuera; si un medio boliviano cuenta lo mismo, pasa a señal nacional y conserva
   el impacto que vio la fuente internacional.
4. **Señales, eventos y oportunidades**: una señal internacional es una señal normal. Si coincide en
   departamento y fechas con señales nacionales, entra en los **eventos compuestos** con alarma; si trae
   algo concreto que aprovechar, crea su **oportunidad**.
5. **AVIA (Hermes)**: herramienta nueva del MCP `contexto_internacional` (MCP 2.5.0). Una noticia de
   fuera nunca confirma sola un hecho en Bolivia.

## En el panel

- Vista nueva **Internacional** (menú lateral): señales con impacto en Bolivia, cómo llegan, ámbitos,
  nivel y plazo, señales nacionales que refuerzan, y el estado de las tres fuentes. Filtro por ámbito.
- En **Señales** y en la ficha: etiqueta 🌐 «Internacional» o 🌐 «Contexto internacional», y en la ficha
  de una señal nacional, el bloque «Contexto internacional» con lo que dicen las fuentes de fuera.

Captura: `capturas/internacional-vista.png` y `capturas/internacional-contexto-senal.png` (datos de ejemplo).

## Instalación

1. **Supabase → SQL Editor**: ejecutar `db/generico/37_fuentes_internacionales.sql` (requiere el 31).
   Al final muestra las tres fuentes. Se puede ejecutar varias veces.
   Prueba opcional en una base de pruebas: `99_prueba_internacional.sql` (termina en ROLLBACK).
2. **VPS**: copiar el analizador nuevo (el recolector no cambia):
   ```bash
   cd /root/avia-repo && git fetch && git checkout <rama-del-PR> && git pull
   cp hermes/analizador/analizador.py hermes/analizador/prompt_clasificador.md ~/avia/
   python3 ~/avia/analizador.py --prueba     # un lote, sin guardar
   ```
3. **MCP de Hermes** (opcional, para que AVIA lo use en el chat): copiar `hermes/mcp-vigilante/servidor.py`
   a la carpeta del MCP y `chown -R 10000:10000 /root/.hermes/avia`.
4. **Web**: publicar como siempre (`bash /root/avia-repo/web/desplegar.sh <rama>`).

## Comprobar después

```sql
-- ¿se leen las tres fuentes?
SELECT codigo, ultima_consulta_en, ultimo_exito_en, errores_seguidos, ultimo_error
  FROM vigilante.sources WHERE internacional;
-- ¿qué decidió el analizador sobre las noticias de fuera?
SELECT r.titulo, a.salida -> 'impacto_bolivia' AS impacto, a.relevante
  FROM vigilante.analisis a JOIN vigilante.raw_items r ON r.id = a.raw_item_id
  JOIN vigilante.sources s ON s.id = r.source_id
 WHERE s.internacional ORDER BY a.id DESC LIMIT 20;
```

## Sin verificar

- El listado de CEPAL (`cepal.org/es/listado/cepal_pr`) no se pudo abrir desde aquí: si el VPS no lo lee,
  la fuente entra por su respaldo de Google News y queda en aviso, no en fallo.
- Reuters y AP pueden llegar en inglés: el analizador escribe siempre en español.
