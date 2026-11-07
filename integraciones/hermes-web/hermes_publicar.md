# Cómo publica Hermes (Vigía) sus hallazgos en ORBITA

Hermes no escribe en la web ni en la base de datos. Envía cada señal a un webhook de n8n, y n8n hace el resto (guardar, pedir aprobación, publicar).

## 1. Añadir este paso al final de la skill `vigilancia-fuentes-bolivia/SKILL.md`

Pegar debajo de "Formato de salida":

```markdown
## Publicar la señal

Cuando tengas el JSON de una señal (o un `{"descartar": true, ...}`), envíalo a ORBITA con la herramienta de terminal:

    curl -sS -X POST "$ORBITA_WEBHOOK" \
      -H "Content-Type: application/json" \
      -H "X-Orbita-Key: $ORBITA_KEY" \
      --data-binary @senal.json

(Escribe primero el JSON en `senal.json`, una señal por envío.)

Lee la respuesta:
- `"accion": "en_revision"` → quedó esperando al analista. No la anuncies como confirmada.
- `"accion": "publicada"` → ya está en la web.
- `"accion": "duplicada"` → ya existía; no la reenvíes.
- `"ok": false` → corrige el campo que indica `error` y vuelve a enviar una sola vez.
- `departamentos_no_reconocidos` con valores → usa los nombres oficiales: La Paz, Oruro, Potosí, Cochabamba, Chuquisaca, Tarija, Santa Cruz, Beni, Pando.
```

## 2. Variables en el servidor donde corre Hermes

En el archivo de entorno de Hermes Agent (por ejemplo `~/.hermes/.env`):

```
ORBITA_WEBHOOK=https://TU-N8N/webhook/orbita-senal
ORBITA_KEY=una-clave-larga-que-solo-conocen-hermes-y-n8n
```

La misma clave va en la credencial "ORBITA clave Hermes" de n8n (tipo Header Auth, nombre de cabecera `X-Orbita-Key`).

Comprobar en la documentación de la versión instalada de Hermes Agent dónde lee las variables de entorno y que la herramienta de terminal esté habilitada para el bot Vigía.

## 3. Ejemplo de JSON que envía Hermes

```json
{
  "fuente_id": "senamhi_alertas",
  "titulo": "Aviso naranja por lluvias intensas en Yungas (La Paz), 2 y 3 de noviembre",
  "resumen": "SENAMHI emite aviso naranja por precipitaciones de 40 a 60 mm en los Yungas de La Paz.",
  "recomendacion": "Reprogramar salidas por la carretera a Coroico y avisar a operadores de ciclismo.",
  "naturaleza": "riesgo",
  "categoria": "clima",
  "prioridad": "alta",
  "motivos_prioridad": ["senamhi_naranja"],
  "departamentos": ["La Paz"],
  "alcance_nacional": false,
  "fecha_evento_inicio": "2026-11-02T00:00:00-04:00",
  "fecha_evento_fin": "2026-11-03T23:59:00-04:00",
  "plazo_hasta": null,
  "fuente_oficial": true,
  "enlace_oficial": "https://senamhi.gob.bo/alertas3.php",
  "requiere_revision": true,
  "es_escenario": false,
  "confianza": 0.9
}
```

(Ejemplo ficticio: las cifras no vienen de un aviso real.)

## 4. Prueba sin Hermes

Desde cualquier terminal:

```
curl -sS -X POST "https://TU-N8N/webhook/orbita-senal" \
  -H "Content-Type: application/json" -H "X-Orbita-Key: TU-CLAVE" \
  --data-binary @ejemplo.json
```

Debe responder `{"ok": true, "accion": "en_revision", ...}` y llegar un mensaje de Telegram al analista con los botones Aprobar / Descartar.
