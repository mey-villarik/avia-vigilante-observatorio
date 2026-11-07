# Fuentes de vigilancia para Hermes Agent · ORBITA beta

Preparado el 2026-11-01.

| Archivo | Para qué |
| --- | --- |
| `fuentes.yaml` | Catálogo de 7 fuentes en 6 canales: URL, acceso, frecuencia, qué buscar, palabras clave, severidad, aprobación, verificación y ejemplos. |
| `skills/vigilancia-fuentes-bolivia/SKILL.md` | Skill para Hermes Agent: procedimiento, reglas de fidelidad y formato JSON de salida. |
| `ejemplos_entrenamiento.jsonl` | 10 ejemplos ficticios en formato `messages` (system / user / assistant) para few-shot o ajuste fino. |

## Instalación en Hermes Agent

Copiar la carpeta `skills/vigilancia-fuentes-bolivia/` a `~/.hermes/skills/` y poner `fuentes.yaml` y `ejemplos_entrenamiento.jsonl` dentro de esa misma carpeta (la skill los nombra como archivos de referencia). Comprobar la ruta de skills de la versión de Hermes Agent instalada.

## Estado de las URLs (2026-11-01)

| Fuente | URL principal | Estado |
| --- | --- | --- |
| SENAMHI | https://senamhi.gob.bo/alertas3.php | ✅ Verificada (tabla con alertas 2026) |
| Ministerio de Salud | https://www.minsalud.gob.bo/ | ✅ Verificada (noticias de agosto de 2026) |
| OPS/OMS | https://www.paho.org/es/alertas-actualizaciones-epidemiologicas | ✅ Verificada (entradas de octubre de 2026) |
| ABC transitabilidad | https://transitabilidad.abc.gob.bo/mapa_reporte | ⚠️ No verificada: aparece en buscador, el sitio devolvió error |
| Ministerio de Turismo | https://www.turismoyculturas.gob.bo/ | ⚠️ No verificada: aparece en buscador, el sitio bloquea lectores |
| Gaceta Oficial | http://www.gacetaoficialdebolivia.gob.bo/normas/buscar | ⚠️ No verificada: aparece en buscador, el sitio bloquea lectores |
| DGAC | https://www.dgac.gob.bo/ | ⚠️ No verificada: sin evidencia de sección de avisos actual |

## Correcciones para la base de datos

- `minculturas` en `orbita.sources` apunta a `minculturas.gob.bo`. El ministerio actual es el **Ministerio de Turismo Sostenible, Culturas, Folklore y Gastronomía** (`turismoyculturas.gob.bo`). Conviene renombrar el código a `minturismo` y cambiar la URL.
- `senamhi_alertas` puede apuntar a `https://senamhi.gob.bo/alertas3.php` en vez de a la portada.
- `abc_caminos` puede apuntar a `https://transitabilidad.abc.gob.bo/mapa_reporte`.
