# API de AVIA para la web (propuesta)

La web nunca llama a Hermes ni a un proveedor de IA directamente, y no guarda claves. Habla con un backend propio, que se configura en `VITE_AVIA_API_URL`. Ese backend autentica a la persona (sesión del login de AVIA, en cookie), llama a Hermes y devuelve el resultado.

Este contrato es una propuesta para arrancar. Se puede cambiar; si cambia, hay que actualizar `web/src/services/avia.ts`.

## POST /chat

Conversación de «Pregunta a AVIA».

```json
{
  "mensajes": [{ "role": "user", "content": "¿Qué oportunidades cierran pronto?" }],
  "rol": "Analista"
}
```

Respuesta:

```json
{
  "texto": "Oportunidades por plazo: …",
  "comandos": [
    { "tipo": "abrir", "vista": "oportunidades" },
    { "tipo": "abrir", "senal": "SEN-0417" },
    { "tipo": "tablero", "accion": "agregar", "panel": "mapa" }
  ]
}
```

`comandos` es opcional. Son órdenes para mover la interfaz; la web las aplica y muestra qué hizo. Vistas válidas: `panorama`, `fuentes`, `senales`, `oportunidades`, `analisis`, `bitacora`. Paneles válidos: `sintesis`, `pulso`, `fuentes`, `cadena`, `oportunidades`, `riesgos`, `mapa`, `evolucion`, `decision`, `actividad`, `temas`, `categorias`.

En el prototipo, el modelo tenía cuatro herramientas que el backend debe ofrecer a Hermes:

| Herramienta | Qué hace |
| --- | --- |
| `consultar_senales` | Busca señales por texto, naturaleza, departamento o estado (máximo 10) |
| `estado_fuentes` | Estado de cada fuente y su última comprobación |
| `abrir` | Abre una vista, una señal o una fuente (se traduce en un comando `abrir`) |
| `cambiar_tablero` | Añade o quita un panel (se traduce en un comando `tablero`) |

Instrucciones del prototipo para el asistente:

> Eres AVIA, el asistente del Vigilante de ORBITA, el observatorio turístico de Bolivia. Hablas en español claro y cercano, para cualquier persona (también no técnicas). Respuestas breves: 2 a 6 frases o una lista corta. Usa las herramientas para consultar datos; no inventes señales, cifras ni fuentes. Cita los códigos SEN-xxxx. Cuando des una oportunidad, di quién puede aprovecharla y el siguiente paso. Cuando hables de un riesgo, di qué verificar.

## POST /analisis

```json
{
  "tipo": "panorama | destino | cruce | foda | libre",
  "territorio": "Todo Bolivia",
  "pregunta": "solo si tipo = libre",
  "senales": [{ "id": "SEN-0417", "titulo": "…", "naturaleza": "oportunidad", "…": "…" }]
}
```

Respuesta: `{ "texto": "…" }` en markdown sencillo (títulos `####`, listas con `-`, `**negrita**`). Instrucción del prototipo: trabajar solo con las señales recibidas, citar los códigos SEN-xxxx, lenguaje claro para personas no técnicas, máximo 300 palabras, no inventar datos.

## POST /evaluar

```json
{ "texto": "Noticia pegada por la persona" }
```

Respuesta:

```json
{
  "naturaleza": "oportunidad | riesgo | mixta",
  "categoria": "clima | salud | vial | seguridad | conectividad | eventos | financiacion | mercado | normativa",
  "departamentos": ["La Paz"],
  "destinos": ["Coroico"],
  "relevancia": 8,
  "novedad": 7,
  "confianza": 0.7,
  "titulo": "Titular corto",
  "importancia": "Por qué importa al turismo, 2 frases",
  "acciones": ["3 acciones concretas"],
  "verificar": "Qué hay que comprobar y en qué fuente oficial"
}
```

Si algo no aparece en el texto, el modelo no debe inventarlo.
