# Vigilante AVIA · recoger con código, IA solo para lo nuevo

Revisión del 2026-11-09. Sustituye el reparto de trabajo de [recolector-mcp.md](recolector-mcp.md) (2026-11-08): el recolector sigue igual en lo esencial, pero Hermes deja de clasificar noticias y pasa a ser solo el agente que investiga.

## El problema

| Antes | Qué fallaba | Ahora |
| --- | --- | --- |
| Hermes consultaba, interpretaba y generaba `vigilante.json` completo | Mezclaba hechos recogidos con contenido generado | Recolección, análisis y publicación separados |
| La skill decía «no inventes fuentes» | Una instrucción no impide guardar una fuente inventada | **Catálogo cerrado** en Supabase: lo desconocido no entra; va a *candidatas* |
| Hermes decidía cuándo consultar | Dependía del modelo y su contexto | La base guarda `proxima_revision_en` de cada fuente |
| El agente decidía si algo estaba repetido | Gastaba tokens y podía equivocarse | Id del proveedor / URL normalizada / huella del texto, **antes** de la IA |
| El fichero era el estado completo | Arrastraba datos viejos o pisaba decisiones | Tablas en Supabase; el fichero se **genera** desde la base |
| «Siempre incluye enlace oficial» | Empujaba a rellenarlo | Solo enlaces recogidos; si falta, vacío y la señal pide verificación |
| `12_fuentes_repetidas` juntaba por dominio | Un sitio puede tener varios canales legítimos | Alias controlados (`source_aliases`) |

## Cómo queda

```
                    ┌──────────── Supabase (la referencia) ────────────┐
 n8n / cron         │ sources (catálogo cerrado) ─ source_aliases       │
   │                │ source_candidates (pendientes de un admin)        │
   ├─► recolector ──┤ raw_items = documento ─ raw_item_versions         │  sin IA
   │   (5 min)      │   · 304 / misma huella → nada                     │
   │                │   · ruido evidente → descartado                   │
   │                │   · filtro de puntaje → descartado / nuevo        │
   ├─► analizador ──┤ analisis (1 por versión) ─ signals ─ oportunidades│  IA breve, en lote
   │   (10 min)     │   procedencia puesta por la base                  │
   │                │ tareas_agente (corroborar, contradicción...)      │
   ├─► Hermes ──────┤ ◄── solo si hay tareas (MCP avia-vigilante 2.0)   │  agente
   │   (30 min)     │                                                   │
   └─► exportar ────┤ vigilante_json() → archivo / Storage (opcional)   │
                    └───────────────┬───────────────────────────────────┘
                                    ▼
                web (lee vigilante_bd) · web pública · Telegram (13, pg_cron)
```

| Componente | Responsabilidad | IA |
| --- | --- | --- |
| n8n (o cron) | Programar, coordinar, reintentar, avisar de fallos | No |
| `hermes/recolector/recolector.py` | Leer fuentes del catálogo cuando les toca; ETag / Last-Modified; huella del texto útil | No |
| Supabase | Fuentes, documentos, versiones, análisis, señales, oportunidades, decisiones | No |
| `hermes/analizador/analizador.py` | Clasificar y resumir **solo versiones nuevas**, en lote, con instrucciones breves | Sí, barata |
| Hermes Agent (skill `vigilancia-fuentes-bolivia` 3.0) | Investigar: corroborar, contradicciones, relacionar, oportunidades inferidas, radar diario | Sí |
| Web | Consultar lo guardado y revisar | No |

## Qué cambia en Supabase (`db/generico/15_catalogo_versiones_analisis.sql`)

**Fuentes**
- `sources.proxima_revision_en`, `etag`, `last_modified`. La base calcula la próxima revisión: la frecuencia normal, o el doble cada vez que falla (hasta `max_espera_fallos_min`, 24 h).
- `source_aliases`: otros nombres de una fuente (códigos antiguos). Los juntados por el 12 pasan a alias.
- `source_candidates`: fuentes propuestas. Entran desde Hermes (`proponer_fuente`, **con evidencia**) o desde un `vigilante.json` antiguo. No se vigilan hasta que un administrador las aprueba (`decidir_candidata`, que crea la fuente con `alta_fuente`).
- `fuente_canonica` ya no junta por dominio: código, alias, código fusionado o la misma dirección exacta.
- `sincronizar_vigilante` (compatibilidad): las fuentes que no están en el catálogo **ya no se crean** (ni en pausa); van a candidatas.

**Documentos y versiones**

| Objeto | Cómo se identifica |
| --- | --- |
| Fuente | Código del catálogo (y sus alias) |
| Noticia (documento) | Id del proveedor (`guid` del RSS) o URL normalizada (`url_doc`: sin `www`, sin `utm_*`, sin ancla) |
| Versión de la noticia | Huella sha256 del texto útil (`hash_texto`), en `raw_item_versions` |
| Mismo hecho en varios medios | Varias noticias enlazadas a una señal (`signal_raw_items`): son evidencias distintas |

Una noticia actualizada conserva su identidad y suma una versión; solo esa versión vuelve al clasificador, y actualiza **la misma señal**.

**Ruido sin IA** (tomado del nodo «Filtro Ruido 1» del n8n de AVIA): títulos de menos de 15 caracteres, portadas, `/login`, `/tag/`, `/categoria/`, paginaciones… Editable en el parámetro `ruido_url`.

**Análisis guardado**: `analisis` tiene una fila por (noticia, versión). Abrir la web o recargar no vuelve a llamar al modelo.

**Señales con procedencia del programa** (`guardar_senal`):
- una señal nueva necesita al menos una noticia recogida;
- `fuente`, `fuente_oficial` y `enlace_oficial` salen de sus noticias (se ignora lo que diga el modelo);
- un enlace que no es de sus noticias ni del catálogo se descarta; sin enlace oficial, la señal pide revisión.

**Oportunidades en dos niveles** (`oportunidades`)

| Nivel | Ejemplo | Cómo se resuelve |
| --- | --- | --- |
| Explícita | Convocatoria, licitación, inscripción a una feria | Reglas (`reglas_oportunidad`) marcan candidatas sin IA; el clasificador extrae tipo, plazo, beneficiarios y acción |
| Inferida | Una nueva ruta aérea podría favorecer paquetes en un destino | Hermes, con evidencias y contexto; obligatoria la `interpretacion` |

Cada oportunidad separa **hecho**, **interpretación**, **beneficiarios**, **acción** y **evidencias** (ids de noticias).

**Tareas para Hermes** (`tareas_agente`): las crea el clasificador cuando hace falta investigar, o una regla (prioridad alta sin fuente oficial → corroborar). Hermes solo arranca si hay tareas.

**Publicación**: `vigilante_bd()` (web con sesión) y `vigilante_json(cliente)` (VPS) salen de la misma función e incluyen `oportunidades`.

## Qué cambia en el código

| Archivo | Cambio |
| --- | --- |
| `hermes/recolector/recolector.py` 1.1 | Manda `If-None-Match` / `If-Modified-Since` (304 = no descarga nada). Huella sobre el texto útil: sin menú, cabecera, pie, barras, formularios ni horas («hace 5 minutos»); usa `<main>`/`<article>` si existen. Guarda el `guid` del RSS. Una página sin titulares es un documento con versiones (ya no `#h…`). Funciona también con una base sin el 15 |
| `hermes/analizador/analizador.py` (nuevo) | Pide un lote, llama al modelo una vez, valida (solo claves del lote, sin fuente ni enlace) y guarda. Si no hay nada nuevo, no llama al modelo. Si el modelo falla, devuelve las noticias a la cola |
| `hermes/analizador/prompt_clasificador.md` (nuevo) | Instrucciones breves del clasificador (versión `clasificador-1.0`, se guarda con cada análisis) |
| `hermes/mcp-vigilante/servidor.py` 2.0 | Hermes ya no tiene `noticias_pendientes` ni `descartar_noticias`. Nuevas: `tomar_tareas`, `terminar_tarea`, `guardar_oportunidad`, `proponer_fuente` |
| `hermes/skills/vigilancia-fuentes-bolivia/SKILL.md` 3.0 | Solo agente investigador. Quitadas la orden de consultar fuentes, la de construir `vigilante.json` y «siempre incluye enlace oficial» |
| `hermes/herramientas/exportar_vigilante_json.py` (nuevo) | Genera `vigilante.json` desde la base (disco y/o Storage), solo si cambió |
| `web/src/store.ts` | Con sesión, la web lee la base; el archivo del VPS solo si la base no tiene datos. Ya no los mezcla |

## n8n: qué workflows usar

n8n solo programa, coordina y reintenta; cada paso es un script. Es el mismo patrón que «AVIA Vigilante · Tecnología» del n8n de AVIA. Si n8n no está en el mismo VPS que los scripts, usa el nodo **SSH** (Execute Command); si está en el mismo, **Execute Command**.

| Workflow nuevo | Disparo | Pasos | Reintentos / errores |
| --- | --- | --- | --- |
| ORBITA · 1 Recolectar | Cada 5 min | SSH `python3 /root/avia/recolector.py` | 2 reintentos; si falla → «SYS - Manejador Global de Errores» |
| ORBITA · 2 Analizar | Cada 10 min (o al terminar el 1) | SSH `python3 /root/avia/analizador.py` | 2 reintentos; el script ya devuelve a la cola lo que no se pudo clasificar |
| ORBITA · 3 Agente Hermes | Cada 30 min | HTTP a Supabase: `GET /rest/v1/tareas_agente?estado=eq.pendiente&select=id&limit=1` (perfil `vigilante`) → IF hay alguna → SSH: lanzar Hermes con la skill | Sin tareas no se arranca Hermes: cero tokens |
| ORBITA · 4 Radar diario | 07:30 | SSH: Hermes con «radar diario» → Telegram (nodo de «AVIA Vigilante · Tecnología») | 1 reintento |
| ORBITA · 5 Exportar json (opcional) | Al terminar el 2 | SSH `python3 /root/avia/exportar_vigilante_json.py --archivo /var/www/data/vigilante.json` | Solo si alguna pantalla aún lee el archivo |

La publicación (web pública y Telegram) no necesita n8n: la hace Supabase al pasar una señal a «Publicada» (13).

**De tu n8n actual**: conservar «SYS - Manejador Global de Errores» y «[SUB] Registrar Coste»; copiar el patrón de «AVIA Vigilante · Tecnología»; mantener el MCP de AVIA solo para corroborar. «1. Scrapping Web Diario», «2. Filtrado Ruido», «3. Cosecha» y «4. Article Extractor» no hacen falta para ORBITA (su regla de ruido ya está en la base). El comando exacto para lanzar Hermes depende de cómo esté instalado en el VPS.

Con cron en lugar de n8n:

```cron
*/5  * * * * python3 /root/avia/recolector.py  >> /var/log/avia-recolector.log 2>&1
*/10 * * * * python3 /root/avia/analizador.py  >> /var/log/avia-analizador.log 2>&1
```

## Instalar (en orden)

1. **Supabase**: SQL Editor → pegar `db/generico/15_catalogo_versiones_analisis.sql` → Run (requiere el 14). Se puede repetir.
2. **Revisar las propuestas antiguas en pausa** y pasarlas a candidatas:
   ```sql
   select * from vigilante.propuestas_a_candidatas(false);  -- solo mira
   select * from vigilante.propuestas_a_candidatas(true);   -- las pasa
   ```
3. **Quitar del cron del VPS** `subir_vigilante_json.sh` y, si estaba, la tarea `vigilante-sincronizar` del 05 (`select cron.unschedule('vigilante-sincronizar');`). Llevaban el archivo de Hermes a la base y ahora pisarían lo que guardan el recolector y el analizador.
4. **VPS**: copiar `recolector.py`, `analizador.py`, `prompt_clasificador.md` (en la misma carpeta que el analizador) y `exportar_vigilante_json.py` a `/root/avia/`. Añadir a `/etc/avia/supabase.env`: `LLM_API_KEY=` (la de DeepSeek), y opcionalmente `LLM_MODEL`, `LLM_PRECIO_ENTRADA`, `LLM_PRECIO_SALIDA` para anotar el coste.
5. Probar: `python3 /root/avia/analizador.py --prueba` (clasifica un lote y lo muestra sin guardar).
6. **Hermes**: copiar la skill 3.0 a `~/.hermes/skills/` y el `servidor.py` 2.0 del MCP. Quitar de Hermes cualquier tarea programada que lea fuentes o escriba `vigilante.json`.
7. **n8n**: crear los workflows 1 a 3 (y 4 y 5 si se quieren) o dejar el cron.
8. **Web**: desplegar. Con sesión leerá la base.

## Lo que no está comprobado

- No he visto qué versión corre en el VPS ni cómo se lanza Hermes allí: el comando del workflow 3 queda por completar.
- La huella del texto útil cambia de cálculo: la primera lectura de cada página tras instalar crea una versión nueva (una sola clasificación extra por página).
- La web todavía no tiene pantallas para **candidatas** ni para **oportunidades**: los datos ya están (`candidatas_web`, `decidir_candidata`, `oportunidades_web` y `oportunidades` dentro de `vigilante_bd`). Es el siguiente paso.

## Probar la base

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/generico/99_prueba_catalogo_versiones.sql   # termina en ROLLBACK
```
Comprueba: ruido sin IA, repetidas, 304, espera creciente al fallar, lote solo con lo nuevo, enlace y fuente inventados rechazados, versión nueva que actualiza la misma señal, oportunidad explícita e inferida con evidencias, candidatas que no entran en el catálogo y aprobación por un administrador.
