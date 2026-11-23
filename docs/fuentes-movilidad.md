# Fuentes de movilidad: ABC, DGAC y NAABOL (2026-11-22)

El eje de movilidad de la vista Dirección (carreteras y aeropuertos) dependía de dos fuentes que no
daban datos: la ABC estaba en CRÍTICO y la DGAC sin abrir. Este cambio las repara y añade NAABOL,
que es quien publica los cierres de aeropuertos.

## Diagnóstico

Comprobado el 2026-11-22 desde un navegador normal (la nube de Claude no llega a los `.gob.bo`).

| Fuente | Qué pasaba | Por qué | Arreglo |
| --- | --- | --- | --- |
| ABC · mapa de transitabilidad (`transitabilidad.abc.gob.bo`) | CRÍTICO | **Definitivo**: todo el sitio redirige ahora a `/captcha-form` («Verifica que eres humano»), y `/movil_conflictos_sociales` da 404. Un programa no puede leerlo, y no se intenta saltar el CAPTCHA. | Se deja de leer el mapa. |
| ABC · portal (`www.abc.gob.bo`) | — | Responde. Es un WordPress que publica los cortes y reaperturas como **Comunicados** (p. ej. «Circulación vehicular sin restricción en Santa Cruz, Tramo La Angostura – Bermejo», 15/11/2026). Ojo: el RSS general `/feed/` sale vacío porque los comunicados no son «entradas». | Fuente RSS `https://www.abc.gob.bo/feed/?post_type=comunicados`, cada 30 min. |
| DGAC (`www.dgac.gob.bo`) | Sin abrir | Se leía la portada como página. Responde y tiene RSS (`/feed/`), con noticias de noviembre de 2026. Publica sobre todo noticias institucionales y normativa. | Fuente RSS, cada 3 h. |
| NAABOL (`www.naabol.gob.bo`) | No existía | Es quien publica las suspensiones de vuelos: en noviembre, cierre y reanudación en Cochabamba y suspensión en Sucre (Alcantarí) por clima. Drupal sin RSS; la lista de comunicados trae fecha, título y PDF en tarjetas, sin titulares enlazados, así que la lectura normal no veía nada. | Fuente `https://www.naabol.gob.bo/pagina-de-comunicados` con el extractor nuevo **tarjetas** (recolector 1.3.0), cada 60 min. |

Las tres llevan espera de 30 s, un reintento y **respaldo de Google News**: si la web no responde desde
el VPS (como pasó con la Gaceta, que no acepta conexiones desde fuera de Bolivia), se leen las
noticias de prensa sobre esa institución, la fuente queda en AVISO y no en CRÍTICO, y esas noticias van
marcadas como no oficiales (pasan por revisión).

## Qué cambia

- `hermes/recolector/recolector.py` 1.3.0
  - Extractor `"tarjetas"` (en `sources.config.extractor`): cada bloque `<div class="card">` es un
    documento con su título (h1-h6), fecha dd/mm/aaaa y enlace (el PDF primero). Si la tarjeta no tiene
    título, se usa el nombre del PDF. Opciones: `tarjeta_inicio` (otra marca de inicio de tarjeta) y
    `tarjeta_filtro` (texto que debe tener).
  - Los códigos OACI de los PDF de NAABOL (SLCB, SLAL, SLLP…) se traducen al nombre del aeropuerto
    y la ciudad en el resumen, para que el filtro y el clasificador sepan de qué departamento se habla.
  - Los RSS de WordPress con la descripción vacía usan `content:encoded` como resumen.
- `db/generico/51_fuentes_movilidad.sql`: da de alta o actualiza las tres fuentes. Si ya había una
  fuente de la ABC (el mapa), **reutiliza esa fila** (conserva el historial y guarda `url_anterior`);
  cualquier otra fila que siga apuntando al mapa con CAPTCHA se desactiva.
- `hermes/herramientas/diagnosticar_fuentes.py`: prueba también estas cuatro direcciones.
- `hermes/fuentes.yaml`: fichas de ABC, DGAC y NAABOL al día.
- Web (datos de ejemplo): la ABC ya no aparece como el ejemplo de fuente en CRÍTICO.

## Pasos en el VPS

1. Diagnóstico (¿el VPS llega a estas webs?):

   ```bash
   cd /root/avia-repo && git fetch && git checkout claude/project-thread-76q9pq && git pull
   python3 hermes/herramientas/diagnosticar_fuentes.py \
     https://www.abc.gob.bo/feed/?post_type=comunicados \
     https://www.dgac.gob.bo/feed/ \
     https://www.naabol.gob.bo/pagina-de-comunicados
   ```

   `HTTP 200`: perfecto. `TCP … FALLA`: el servidor no acepta al VPS; la fuente funcionará igual con el
   respaldo de Google News (en AVISO).

2. Recolector 1.3.0 (antes de copiar, comprobar que el del VPS no tiene parches propios):

   ```bash
   diff /root/avia/recolector.py hermes/recolector/recolector.py | head -40
   cp /root/avia/recolector.py /root/avia/recolector.py.bak-1.2
   cp hermes/recolector/recolector.py /root/avia/recolector.py
   ```

   El cron no cambia (el recolector ya se protege solo con su candado: no añadir `flock`).

3. Ejecutar `db/generico/51_fuentes_movilidad.sql` en el editor SQL de Supabase. Los avisos (NOTICE)
   dicen qué código quedó para la ABC (`abc_comunicados` si era nueva, o el código de la fila antigua).

4. Probar sin escribir nada:

   ```bash
   python3 /root/avia/recolector.py --prueba --fuente abc_comunicados   # o el código que dio el paso 3
   python3 /root/avia/recolector.py --prueba --fuente dgac
   python3 /root/avia/recolector.py --prueba --fuente naabol_comunicados
   ```

   Lo esperado: `[OK] 10 entradas` para la ABC, `[OK] Página cambiada: 10 tarjetas` para NAABOL. Si sale
   `[WARN] La web no responde … noticias de respaldo`, el VPS no llega a esa web y se está usando la prensa.

## Lo que queda fuera

- El **mapa de transitabilidad** de la ABC (estado tramo a tramo) no se puede leer mientras tenga
  CAPTCHA. Los comunicados cubren los cortes importantes, pero no todos los tramos. Si la Dirección lo
  necesita, lo correcto es pedir a la ABC acceso a sus datos (un servicio o una exportación), no saltar
  el CAPTCHA.
- Los **NOTAM** de NAABOL (`sare.naabol.gob.bo`) son avisos técnicos para pilotos; no se leen de momento.
