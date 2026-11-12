# Reparar fuentes que fallan (2026-11-12)

Tres fuentes del Vigilante ORBITA Bolivia fallaban. Este cambio las repara sin Apify y deja una
herramienta para saber, desde el VPS, si un fallo es pasajero o definitivo.

| Fuente | Fallo | Diagnóstico | Arreglo |
| --- | --- | --- | --- |
| Gaceta Oficial | Tiempo de espera agotado | Servidor muy lento y solo por http. Es **pasajero/crónico**: la web existe, pero tarda más que los 25 s del recolector. | Espera 90 s, 1 reintento, lee el listado por fecha (`/normas/listadofec`) y, si no responde, el buscador (`/normas/buscar`). Si tampoco responde, lee las noticias sobre la Gaceta en Google News y queda en **aviso**, no en fallo. |
| Conoce Bolivia | El dominio no responde | **Definitivo**: `conocebolivia.turismoyculturas.gob.bo` dejó de funcionar. El portal (WordPress) aparece ahora en `conocebolivia.produccion.gob.bo` (los buscadores indexan allí sus catálogos y guías de 2025). | Nueva dirección `https://conocebolivia.produccion.gob.bo/`, espera 45 s y respaldo de noticias «Conoce Bolivia». Si el diagnóstico dice que el dominio nuevo tampoco responde desde el VPS, el SQL trae al final el bloque para dejarla **inactiva**. |
| SENAMHI (Apify) | Sin saldo en Apify | **Definitivo** mientras no haya Apify. Pero Apify no hace falta: la tabla de avisos de `senamhi.gob.bo/alertas3.php` llega ya escrita en el HTML (número, fecha, nivel, inicio, fin y enlace al PDF). | Lectura directa con el recolector: cada fila de la tabla es un aviso con su PDF como enlace. Si la página no responde: `alertasanteriores1.php` y, al final, noticias «Senamhi alerta» de Google News marcadas como no oficiales. La fuente de Apify se desactiva si ya existe la directa. |

> Las direcciones no se pudieron abrir desde la nube de Claude (la red las bloquea), así que el
> diagnóstico definitivo se hace en el VPS con `diagnosticar_fuentes.py` (paso 1).

## Pasos

### 1. Diagnóstico en el VPS (2 minutos)

```bash
cd /root/avia-repo && git fetch && git checkout claude/project-thread-kg0ibb
python3 hermes/herramientas/diagnosticar_fuentes.py --veces 2
```

Cómo leer el resultado de cada dirección:

- `DNS FALLA … DEFINITIVO`: el dominio ya no existe. No se arregla esperando.
- `TCP … FALLA`: servidor caído o bloquea la IP del VPS. Repetir más tarde; si sigue, es definitivo.
- `NO RESPONDE en 90 s`: servidor lento. El respaldo de Google News cubre esos días.
- `HTTP 200 en N s`: funciona. Si N pasa de 25, por eso fallaba antes.

### 2. Instalar el recolector 1.2.0

```bash
cp /root/avia-repo/hermes/recolector/recolector.py /root/avia/recolector.py
cp /root/avia-repo/hermes/herramientas/diagnosticar_fuentes.py /root/avia/
```

Es compatible con todas las fuentes que ya existen: las opciones nuevas solo se usan si la fuente las tiene.

### 3. Ejecutar el SQL en Supabase

Supabase → SQL Editor → pegar `db/generico/20_reparar_fuentes.sql` → Run. Al final muestra cómo
quedaron las fuentes. Se puede ejecutar más de una vez.

### 4. Probar cada fuente sin escribir nada

```bash
cd /root/avia
python3 recolector.py --prueba --fuente gaceta_oficial
python3 recolector.py --prueba --fuente senamhi_alertas
python3 recolector.py --prueba --fuente <código de Conoce Bolivia>
```

(Los códigos exactos salen en la tabla que muestra el paso 3.) Cuando salgan bien, el cron de cada
30 minutos ya las lee solas.

## Opciones nuevas por fuente (`sources.config`)

| Opción | Para qué | Ejemplo |
| --- | --- | --- |
| `timeout_s` | Segundos de espera de esa fuente (25 por defecto, máximo 180) | `90` |
| `reintentos` | Nuevos intentos si no responde o da 5xx/429 (0 por defecto, máximo 3) | `1` |
| `urls_alternativas` | Otras direcciones que se prueban en orden si falla la principal | `["http://…/normas/buscar"]` |
| `extractor` | `"tabla"`: una noticia por fila de tabla (con su primer enlace) | `"tabla"` |
| `tabla_filtro` | Texto o expresión que debe tener la fila | `"ALERTA\|AVISO"` |
| `respaldo` | Si nada responde, lee noticias sobre la fuente y queda en aviso (WARN) | `{"metodo": "google_news_rss", "query": "…"}` |

Las noticias que llegan por respaldo llevan `extra.no_oficial = true`: son prensa sobre la fuente,
no la fuente oficial, y el analista debe tenerlo en cuenta al aprobar alertas de riesgo.
