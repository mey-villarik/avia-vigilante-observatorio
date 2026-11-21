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
| `17_tareas_control.sql` | Borrado a los 6 meses que sí alcanza lo publicado, tareas que no se paran entre sí y `vigilante.estado_tareas()` para ver si corren. |
| `99_prueba_tareas_control.sql` | Prueba del 17. Termina en `ROLLBACK`. |
| `19_vigilante_bd_items.sql` | `vigilante_bd()` ya no falla cuando una fuente trae `items` como lista, y panel, chat y web pública muestran solo lo vigente: con fechas hasta el último día; sin fechas, 24 h desde la última noticia (`vigilante.senal_vigente`). Tras el 19, la prueba del 16 que espera ver señales de hace 11 días deja de valer. |
| `20_reparar_fuentes.sql` | Repara Gaceta Oficial (espera 90 s, reintento, respaldo Google News), Conoce Bolivia (nueva dirección `conocebolivia.produccion.gob.bo`) y SENAMHI (sin Apify: tabla de avisos leída directamente). Necesita el recolector 1.2.0. Ver `docs/reparar-fuentes.md`. |
| `18_aprobacion_analista.sql` | Aprobación del analista: plazo de 1 hora, nada se publica sin aprobación, aprobar/rechazar en un clic y botones en un grupo privado de Telegram. Ver `docs/aprobacion-analista.md`. |
| `99_prueba_aprobacion.sql` | Prueba del 18. Termina en `ROLLBACK`. |
| `21_contadores_unicos.sql` | Panel y AVIA cuentan lo mismo: una sola lista visible (`senales_visibles`) y un solo conteo con hora (`contadores`). Ver `docs/contadores.md`. |
| `99_prueba_contadores.sql` | Prueba del 21. Termina en `ROLLBACK`. |
| `22_puntuaciones.sql` | Tres puntuaciones por señal: fiabilidad de la evidencia (base), probabilidad (solo justificada) e impacto turístico. Ver `docs/puntuaciones.md`. |
| `99_prueba_puntuaciones.sql` | Prueba del 22. Termina en `ROLLBACK`. |
| `23_trazabilidad.sql` | Trazabilidad por señal: fuente, enlace, fecha de publicación y de recogida, detección, fuente comprobada y última verificación de una persona. Ver `docs/trazabilidad.md`. |
| `99_prueba_trazabilidad.sql` | Prueba del 23. Termina en `ROLLBACK`. |
| `24_grado_certeza.sql` | Grado de certeza por señal: confirmado, convocado, posible o rumor, con motivo y origen (persona, modelo, modelo ajustado o reglas). `guardar_clasificacion` guarda la propuesta del modelo. Ver `docs/certeza.md`. |
| `99_prueba_certeza.sql` | Prueba del 24 (8 casos). Termina en `ROLLBACK`. |
| `25_recomendaciones_seguras.sql` | Recomendación segura por señal: para quién, con quién verificar (parámetro `verificar_con`), qué falta saber y aviso cuando da algo por habilitado u operativo sin dato oficial de las últimas 24 h. Ver `docs/recomendaciones-seguras.md`. |
| `99_prueba_recomendaciones.sql` | Prueba del 25. Termina en `ROLLBACK`. |
| `26_sintesis_dia.sql` | Síntesis del día en 3 bloques (qué pasa, por qué importa, qué vigilar) armada por la base con las mismas señales que los contadores; parámetro `sintesis_max`. Ver `docs/sintesis-dia.md`. |
| `99_prueba_sintesis.sql` | Prueba del 26. Termina en `ROLLBACK`. |
| `27_comparacion_dia.sql` | Cambios desde ayer: señales nuevas, las que subieron o bajaron de certeza y las resueltas en 24 h. Crea `certeza_registro` y la tarea de pg_cron `vigilante-certezas` (cada 15 min). Ver `docs/comparacion-dia.md`. |
| `28_eventos_compuestos.sql` | Alertas emergentes: la base junta señales que coinciden en departamento y fechas en `eventos_compuestos` (riesgo acumulado, oportunidad combinada, confluencia) con prioridad calculada; Hermes las interpreta por el MCP y el panel avisa. Tarea de pg_cron `vigilante-eventos` (cada 5 min). Prueba `99_prueba_eventos.sql`. Ver `docs/eventos-compuestos.md`. |
| `29_pase_en_bloque.sql` | Pestaña Señales con tres columnas y flechas → / ← entre ellas: `pasar_senales(codigos, destino)` mueve varias en los dos sentidos; sin «Por aprobar» (parámetro `aprobacion_previa`); las de fuente oficial pasan solas a Confirmadas; publicar siempre lo hace una persona. Prueba `99_prueba_pase_en_bloque.sql`. Ver `docs/pase-en-bloque.md`. |
| `30_sin_duplicados.sql` | Sin duplicados: una dirección = una fuente (índice único y juntar las repetidas), un documento = una noticia (índice único + candado) y un hecho = una señal (`guardar_senal` une a la existente por noticia compartida o título parecido con pg_trgm, sin mezclar departamentos ni cifras distintas). `senales_repetidas()` / `juntar_senales_repetidas()` para las de antes. Prueba `99_prueba_sin_duplicados.sql`. Ver `docs/sin-duplicados.md`. |
| `31_cambios_noticias.sql` | Alertas de cambio: cuando una noticia nueva cambia una señal que ya existía (nueva fecha, cancelación, desvío, desmentido…) queda en `cambios_senal` (CAM-0001…) con el antes y el ahora. Lo detectan la base (disparador en `signals`) y el clasificador (`senales_relacionadas` + `cambio`); Hermes lo interpreta; el panel avisa con alarma y ventana. Prueba `99_prueba_cambios.sql`. Ver `docs/cambios-noticias.md`. |
| `32_ficha_aprobacion.sql` | Ficha de aprobación de riesgos: antes de publicar un riesgo, AVIA (skill `avia-ficha-aprobacion`) resume afirmación, evidencia y peso 1-5 (con techo por tipo de fuente), qué falta, riesgo U1-U4, sugerencia y texto prudente. La base comprueba la regla de oro. Se ve en el panel, en el chat y en Telegram. Prueba `99_prueba_ficha_aprobacion.sql`. Ver `docs/ficha-aprobacion.md`. |
| `33_probabilidad_senales.sql` | Probabilidad de ocurrencia, solo en señales confirmadas: al confirmar, la base calcula la probabilidad (peso de la fuente × 0,5 + fuentes distintas × 0,3 + tasa de confirmación de la categoría en 90 días × 0,2) y AVIA (skill `avia-probabilidad`) la ajusta ±0,20 con una frase. Columnas `prob_ocurrencia` y `prob_razon` en `signals`; sale en `puntuaciones()`. Prueba `99_prueba_probabilidad.sql`. Ver `docs/probabilidad-senales.md`. |
| `34_eventos_dinamicos.sql` | Eventos dinámicos: todo evento nuevo salta al momento con alarma y ventana (sin esperar a AVIA; parámetro `eventos_alerta_desde`), el compositor corre cada minuto y el panel enseña cada evento 24 h (`eventos_horas_panel`); después sigue guardado en la base. `marcar_evento_visto(NULL)` marca todos. Prueba `99_prueba_eventos_dinamicos.sql`. Ver `docs/eventos-dinamicos.md`. |
| `35_cambios_24h.sql` | Cambios en noticias 24 h en el panel (`cambios_horas_panel`, antes 3 días): después siguen guardados en la base y AVIA los ve por el MCP. `cambios_recientes()` devuelve `oculta_en`; `marcar_cambio_visto(NULL)` marca solo los visibles. Prueba `99_prueba_cambios_24h.sql`. Ver `docs/cambios-noticias.md`. |
| `36_razones_avia.sql` | Por qué, según AVIA, en texto: en la misma ronda de `avia-probabilidad`, AVIA escribe el porqué de la probabilidad, la fiabilidad y el impacto de cada confirmada (lo que va tras «porque», sin fórmula). Columnas `razon_fiabilidad`, `razon_impacto`, `razones_en` en `signals`; `puntuaciones()` las devuelve en `avia`; las confirmadas sin razones se rellenan solas. Prueba `99_prueba_razones.sql`. Ver `docs/razones-avia.md`. |
| `39_contadores_coherentes.sql` | Contadores que cuadran: «Verificadas» se desglosa en 2 o más fuentes distintas / por fuente oficial / con una sola fuente (suman el total); `fuentes_activas` y `fuentes_en_pausa` para que panel, Pulso y AVIA cuenten las mismas fuentes. Prueba `99_prueba_contadores.sql`. Ver `docs/contadores.md`. |
| `40_verificada_unica.sql` | «Verificada» significa una sola cosa: confirmada o publicada con fuente oficial o 2 o más fuentes distintas (`vigilante.respaldo_senal`). Contadores con `confirmadas_sin_verificar` y `alertas_verificadas`; la web pública y Telegram ponen «Verificada» / «En verificación» con la misma regla. Prueba `99_prueba_contadores.sql`. Ver `docs/contadores.md`. |
| `41_cifra_fuentes.sql` | Una sola cifra de fuentes: `vigilante.contadores()` añade `fuentes_leidas` (activas con última comprobación OK o AVISO) y `fuentes_sin_leer` (CRÍTICO o sin comprobar); activas = leídas + sin leer, igual que el encabezado, el Pulso y la pestaña Fuentes. Prueba `99_prueba_contadores.sql`. Ver `docs/contadores.md`. |
| `99_prueba_comparacion.sql` | Prueba del 27. Termina en `ROLLBACK`. |
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
