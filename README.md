# AVIA Vigilante · Observatorio

Vigilante de inteligencia del observatorio: lee fuentes, junta noticias dispersas en señales, las verifica y propone oportunidades y acciones. Primer cliente: ORBITA, turismo en Bolivia.

Los agentes de cara al usuario se llaman **AVIA**. Hermes Agent es el motor interno.

## Qué hay en el repositorio

| Carpeta | Contenido |
| --- | --- |
| `web/` | Aplicación del Vigilante en React (Vite + TypeScript). Llega por pull request. |
| `poc/` | Prototipos HTML originales: `vigilante.html` (panel del analista) y `web-publica.html` (web pública conectada a Hermes). Referencia para la conversión a React. |
| `db/` | Base de datos PostgreSQL / Supabase. `generico/` es el esquema multicliente `vigilante` que usará el producto; la raíz es el esquema `orbita` de la primera versión. |
| `hermes/` | Fuentes vigiladas (`fuentes.yaml`), skill de vigilancia y ejemplos para Hermes Agent. |
| `integraciones/hermes-web/` | Conexión Hermes → n8n → web (SQL, workflow y guía). |
| `docs/` | Especificación de la beta, roadmap y diagrama de conexiones. |

## Reglas

- Ninguna clave ni contraseña en el repositorio. Van en `.env` (ignorado por Git) o en los Secrets de GitHub.
- Todo cambio entra por pull request a `main`.
- Los datos de los prototipos son de ejemplo e inventados.
