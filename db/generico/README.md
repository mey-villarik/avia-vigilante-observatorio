# AVIA Vigilante · base de datos genérica (multicliente)

Versión genérica del esquema de ORBITA para replicar el vigilante en otros sectores y países. Probado en PostgreSQL 16; compatible con Supabase. Convive con el esquema `orbita` en la misma base.

## Archivos

| Archivo | Qué hace |
| --- | --- |
| `01_vigilante_schema.sql` | Esquema `vigilante`: 24 tablas, reglas, funciones, vistas, RLS por cliente y parámetros por defecto. |
| `02_cliente_orbita_bolivia.sql` | Ejemplo de alta: ORBITA turismo Bolivia (territorios, categorías, fuentes rápidas y el Vigilante por MCP). |
| `03` a `13` | Acceso web, sincronización con `vigilante.json`, fuentes desde la web y publicación (ver `docs/`). |
| `14_recolector_mcp.sql` | Recolector sin IA (noticias con filtro previo), búsquedas que pide AVIA, propuestas de método, señales por el MCP, métricas de oportunidad y alertas tempranas. Ver `docs/recolector-mcp.md`. |
| `99_prueba_recolector.sql` | Prueba del 14. Termina en `ROLLBACK`. |
| `15_catalogo_versiones_analisis.sql` | Catálogo cerrado (candidatas y alias), documentos con versiones, análisis guardado por versión, oportunidades explícitas e inferidas, tareas para Hermes y `vigilante.json` generado desde la base. Ver `docs/reestructura-vigilante.md`. |
| `99_prueba_catalogo_versiones.sql` | Prueba del 15. Termina en `ROLLBACK`. |
| `16_tareas_programadas.sql` | Tareas automáticas con pg_cron (plazo de revisión, resumen diario, recordatorios, borrado a los 6 meses) y ventana de 7 días en la web. Ver `docs/tareas-programadas.md`. |
| `99_prueba_tareas_programadas.sql` | Prueba del 16. Termina en `ROLLBACK`. |
| `99_prueba_multicliente.sql` | Prueba el flujo completo con dos clientes y comprueba que no se mezclan. Termina en `ROLLBACK`. |

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01_vigilante_schema.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02_cliente_orbita_bolivia.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 99_prueba_multicliente.sql
```

En Supabase: añadir `vigilante` en Settings → API → Exposed schemas.

## Qué cambia respecto a ORBITA

| Antes (ORBITA) | Ahora (genérico) |
| --- | --- |
| Un solo cliente | Tabla `clientes`; todas las tablas llevan `cliente_id` |
| `departamentos` fijos de Bolivia | `territorios` por cliente, con jerarquía (país, región, ciudad...) |
| Categorías, fuentes y parámetros globales | Por cliente; los parámetros sin cliente son el valor por defecto |
| Dedupe global por hash | Dedupe por cliente: la misma noticia puede servir a dos clientes |
| Zona horaria de Bolivia fija | Cada cliente tiene su zona horaria y su horario de guardia |
| RLS por rol | RLS por rol **y** por cliente: nadie ve datos de otro cliente |
| — | `alta_cliente()` crea un vigilante nuevo copiando otro como plantilla |
| — | `sources.rapida` marca las fuentes del ciclo de 30 min; vista `v_fuentes_pendientes` |
| — | `signals.contexto_vigilante` guarda lo que devolvió el MCP del Vigilante |

Las tablas hijas (revisiones, alertas, envíos, feedback...) heredan `cliente_id` de su padre con un trigger: quien inserta no tiene que pasarlo, y la base rechaza mezclar datos de dos clientes (por ejemplo, enviar una alerta de ORBITA a un usuario de otro cliente).

## Pendiente

- Adaptar `02_base_conocimiento_pgvector.sql` y las funciones de la conexión Hermes → web (`conexion-web/03_conexion_hermes_web.sql`) al esquema `vigilante`.
- Si AVIA necesita un operador que vea todos los clientes desde la web, añadir un rol de plataforma; hoy eso se hace con `service_role`.
