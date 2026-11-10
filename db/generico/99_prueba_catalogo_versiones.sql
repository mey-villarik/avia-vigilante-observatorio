-- Prueba de 15_catalogo_versiones_analisis.sql: catálogo cerrado, documentos con versiones,
-- análisis guardado por versión, oportunidades en dos niveles y tareas para Hermes.
-- Requiere 01 a 15 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 1. Primera lectura: una convocatoria (oportunidad explícita), una alerta, ruido evidente
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', '5 noticias', '[
  {"id": "g-1", "titulo": "Ministerio de Turismo abre convocatoria de fondos para emprendimientos en Uyuni", "url": "https://ej.bo/conv?utm_source=x", "resumen": "Las postulaciones cierran el 30 de noviembre."},
  {"titulo": "Bloqueo total en la carretera La Paz - Oruro por conflicto vecinal", "url": "https://ej.bo/bloqueo"},
  {"titulo": "Inicia sesión", "url": "https://ej.bo/login"},
  {"titulo": "Portada del diario con todas las noticias de hoy", "url": "https://www.ej.bo/"},
  {"titulo": "Etiqueta: turismo en Bolivia y otras cosas", "url": "https://ej.bo/tag/turismo"}
]'::jsonb, NULL, 'prueba-1', '"etag-1"', 'Mon, 09 Nov 2026 10:00:00 GMT') AS primera;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE motivo_descarte LIKE 'ruido:%') = 3, 'login, portada y etiqueta son ruido sin IA';
  ASSERT (SELECT tipos_oportunidad FROM vigilante.raw_items WHERE id_externo = 'g-1') @> ARRAY['convocatoria'], 'la regla marca la convocatoria';
  ASSERT (SELECT url_doc FROM vigilante.raw_items WHERE id_externo = 'g-1') = 'ej.bo/conv', 'sin parámetros de seguimiento';
  ASSERT (SELECT etag FROM vigilante.sources WHERE codigo = 'gnews_turismo') = '"etag-1"', 'guarda el ETag';
  ASSERT (SELECT proxima_revision_en > now() + interval '25 minutes' FROM vigilante.sources WHERE codigo = 'gnews_turismo'), 'próxima revisión según frecuencia';
END $$;

-- 2. La misma lectura otra vez: todo repetido (mismo id, misma dirección limpia, mismo texto)
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', 'igual', '[
  {"id": "g-1", "titulo": "Ministerio de Turismo abre convocatoria de fondos para emprendimientos en Uyuni", "url": "https://ej.bo/conv", "resumen": "Las postulaciones cierran el 30 de noviembre."},
  {"titulo": "Bloqueo total en la carretera La Paz - Oruro por conflicto vecinal", "url": "https://ej.bo/bloqueo/"}
]'::jsonb) AS segunda;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.raw_items) = 5, 'no se duplica nada';
END $$;

-- 3. 304 Not Modified: no se guarda nada y se conserva el ETag
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', 'Sin cambios (304)', '[]', NULL, NULL, NULL, NULL, true) AS no_modificado;
DO $$ BEGIN
  ASSERT (SELECT etag FROM vigilante.sources WHERE codigo = 'gnews_turismo') = '"etag-1"', '304 conserva el ETag';
END $$;

-- 4. Una fuente que falla espera más la próxima vez
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'senamhi_alertas', 'CRIT', 'HTTP 503');
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'senamhi_alertas', 'CRIT', 'HTTP 503');
DO $$ BEGIN
  ASSERT (SELECT proxima_revision_en > now() + interval '3 hours' FROM vigilante.sources WHERE codigo = 'senamhi_alertas'), 'espera creciente al fallar';
END $$;

-- 5. Lote para el clasificador: solo lo que pasó el filtro
SELECT jsonb_pretty(vigilante.lote_para_clasificar('orbita-bolivia', 10)) AS lote;
DO $$ BEGIN
  ASSERT jsonb_array_length(vigilante.lote_para_clasificar('orbita-bolivia', 10)) = 0, 'lo enviado queda en cola';
END $$;

-- 6. Resultado del clasificador (la procedencia NO la manda el modelo)
SELECT vigilante.guardar_clasificacion('orbita-bolivia', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM vigilante.raw_items WHERE id_externo = 'g-1'), 'relevante', true,
    'titulo', 'Uyuni: convocatoria de fondos para emprendimientos turísticos', 'resumen', 'El Ministerio abre postulaciones hasta el 30 de noviembre.',
    'naturaleza', 'oportunidad', 'categoria', 'financiamiento', 'prioridad', 'media', 'departamentos', jsonb_build_array('Potosí'),
    'plazo_hasta', '2026-11-30', 'confianza', 0.8,
    'fuente_id', 'inventada_por_el_modelo', 'enlace_oficial', 'https://ministerio-inventado.bo/convocatoria',
    'oportunidad', jsonb_build_object('tipo', 'convocatoria', 'hecho', 'Fondos para emprendimientos turísticos en Uyuni; cierre 30/11.',
      'beneficiarios', jsonb_build_array('operadores', 'alojamientos'), 'accion', 'Preparar la postulación', 'importancia', 4)),
  jsonb_build_object('clave', (SELECT id FROM vigilante.raw_items WHERE url_doc = 'ej.bo/bloqueo'), 'relevante', true,
    'titulo', 'Bloqueo en la carretera La Paz - Oruro', 'resumen', 'Bloqueo total por conflicto vecinal.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'alta', 'departamentos', jsonb_build_array('La Paz', 'Oruro')),
  jsonb_build_object('clave', 999999999, 'relevante', true, 'titulo', 'x', 'resumen', 'y')
), 'modelo-prueba', 'clasificador-1.0', '{"tokens_entrada": 1200, "tokens_salida": 300, "costo_usd": 0.0004}') AS clasificacion;

SELECT codigo, titulo, categoria, fuente_oficial, enlace_oficial, requiere_revision, motivo_revision, salida_modelo ? 'fuente_id' AS guarda_fuente_modelo
  FROM vigilante.signals ORDER BY codigo;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.signals) = 2, 'dos señales; la clave inventada se ignora';
  ASSERT (SELECT enlace_oficial IS NULL AND requiere_revision FROM vigilante.signals WHERE categoria = 'financiamiento'),
         'el enlace inventado no se guarda y la señal pide revisión';
  ASSERT (SELECT s.codigo FROM vigilante.signals sg JOIN vigilante.sources s ON s.id = sg.source_id WHERE sg.categoria = 'financiamiento') = 'gnews_turismo',
         'la fuente sale de la noticia, no del modelo';
  ASSERT (SELECT nivel FROM vigilante.oportunidades) = 'explicita', 'la convocatoria es explícita (la marcó la regla)';
  ASSERT (SELECT count(*) FROM vigilante.tareas_agente WHERE tipo = 'corroborar') = 1, 'prioridad alta sin fuente oficial → tarea para Hermes';
  ASSERT (SELECT count(*) FROM vigilante.analisis) = 2, 'análisis guardado por versión';
END $$;

-- 7. Nada nuevo → nada que clasificar (no se repite el gasto)
DO $$ BEGIN
  ASSERT jsonb_array_length(vigilante.lote_para_clasificar('orbita-bolivia', 10)) = 0, 'sin versiones nuevas no hay lote';
END $$;

-- 8. La convocatoria cambia (amplían el plazo): nueva versión → vuelve al clasificador y actualiza LA MISMA señal
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', 'cambio', '[
  {"id": "g-1", "titulo": "Ministerio de Turismo abre convocatoria de fondos para emprendimientos en Uyuni", "url": "https://ej.bo/conv", "resumen": "Amplían las postulaciones hasta el 15 de diciembre."}
]'::jsonb) AS cambio;
SELECT x ->> 'es_actualizacion' AS actualizacion, x #>> '{senal_existente,codigo}' AS senal
  FROM jsonb_array_elements(vigilante.lote_para_clasificar('orbita-bolivia', 10)) x;
SELECT vigilante.guardar_clasificacion('orbita-bolivia', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM vigilante.raw_items WHERE id_externo = 'g-1'), 'relevante', true,
    'titulo', 'Uyuni: convocatoria de fondos (plazo ampliado)', 'resumen', 'Postulaciones hasta el 15 de diciembre.',
    'categoria', 'financiamiento', 'plazo_hasta', '2026-12-15',
    'oportunidad', jsonb_build_object('tipo', 'convocatoria', 'hecho', 'Plazo ampliado al 15/12.', 'accion', 'Preparar la postulación'))),
  'modelo-prueba', 'clasificador-1.0') AS reclasificacion;
DO $$ BEGIN
  ASSERT (SELECT version FROM vigilante.raw_items WHERE id_externo = 'g-1') = 2, 'versión 2';
  ASSERT (SELECT count(*) FROM vigilante.raw_item_versions WHERE raw_item_id = (SELECT id FROM vigilante.raw_items WHERE id_externo = 'g-1')) = 2, 'se guardan las dos versiones';
  ASSERT (SELECT count(*) FROM vigilante.signals) = 2, 'misma señal, no una nueva';
  ASSERT (SELECT to_char(plazo_hasta AT TIME ZONE 'America/La_Paz', 'YYYY-MM-DD') FROM vigilante.signals WHERE categoria = 'financiamiento') = '2026-12-15', 'plazo actualizado';
  ASSERT (SELECT count(*) FROM vigilante.oportunidades) = 1, 'la oportunidad se actualiza, no se duplica';
END $$;

-- 9. Sin evidencia no hay señal nueva
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.guardar_senal('orbita-bolivia', '{"titulo": "Algo inventado", "resumen": "Sin noticias"}');
    RAISE EXCEPTION 'debería exigir evidencia';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Una señal nueva necesita%' THEN RAISE; END IF;
  END;
END $$;

-- 10. Hermes: tareas, oportunidad inferida con evidencia, fuente candidata
SELECT vigilante.tomar_tareas('orbita-bolivia') -> 0 ->> 'tipo' AS tarea;
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.guardar_oportunidad('orbita-bolivia', '{"tipo": "demanda", "hecho": "x", "evidencias": [987654321]}');
    RAISE EXCEPTION 'debería exigir evidencias reales';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Una oportunidad necesita evidencias%' THEN RAISE; END IF;
  END;
END $$;
SELECT vigilante.guardar_oportunidad('orbita-bolivia', jsonb_build_object(
  'tipo', 'demanda', 'hecho', 'Bloqueo en la ruta La Paz - Oruro.',
  'interpretacion', 'Operadores con salidas a Uyuni por Oruro pueden ofrecer rutas alternativas por Potosí (escenario).',
  'beneficiarios', jsonb_build_array('operadores'), 'accion', 'Avisar a operadores con salidas esta semana',
  'evidencias', jsonb_build_array((SELECT id FROM vigilante.raw_items WHERE url_doc = 'ej.bo/bloqueo')))) AS inferida;
SELECT vigilante.terminar_tarea('orbita-bolivia', (SELECT id FROM vigilante.tareas_agente LIMIT 1), 'hecha', '{"corroborada": false}') AS terminada;
SELECT vigilante.proponer_fuente('orbita-bolivia', 'Diario inventado', 'https://inventado.bo', 'lo vi') AS sin_evidencia;
SELECT vigilante.proponer_fuente('orbita-bolivia', 'Gobernación de Potosí', 'https://potosi.gob.bo/noticias', 'Publica avisos de rutas',
                                 jsonb_build_array((SELECT id FROM vigilante.raw_items WHERE url_doc = 'ej.bo/bloqueo'))) AS candidata;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.oportunidades WHERE nivel = 'inferida') = 1, 'inferida guardada';
  ASSERT (SELECT count(*) FROM vigilante.source_candidates) = 1, 'solo la que trae evidencia';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.sources WHERE url LIKE '%potosi.gob.bo%'), 'la candidata NO entra en el catálogo';
END $$;

-- 11. vigilante.json antiguo con una fuente desconocida y otra con alias
INSERT INTO vigilante.source_aliases (cliente_id, alias, source_id)
SELECT cliente_id, 'gnews', id FROM vigilante.sources WHERE codigo = 'gnews_turismo';
SELECT vigilante.sincronizar_vigilante('orbita-bolivia', '{"version": 1, "fuentes": [
  {"id": "gnews", "nombre": "Google News", "url": "https://news.google.com/rss", "estado": "OK"},
  {"id": "eldeb", "nombre": "El Deber", "url": "https://eldeber.com.bo/economia/articulo-123", "estado": "OK"}
], "senales": []}'::jsonb) AS sincronizacion;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.sources WHERE codigo IN ('eldeb', 'gnews')), 'ni la desconocida ni el alias crean fuentes';
  ASSERT (SELECT count(*) FROM vigilante.source_candidates WHERE propuesta_por = 'sincronizacion') = 1, 'la desconocida queda como candidata';
END $$;

-- 12. Web: el administrador aprueba la candidata; el equipo ve oportunidades y datos desde la base
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT id, '30000000-0000-0000-0000-00000000000a', 'Ana Admin', 'administrador' FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT id, '30000000-0000-0000-0000-00000000000b', 'Luis Analista', 'analista' FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-00000000000b', true);
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.decidir_candidata((SELECT id FROM vigilante.candidatas_web() WHERE nombre LIKE 'Gobernación%'), true);
    RAISE EXCEPTION 'el analista no debería poder aprobar';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Solo un administrador%' THEN RAISE; END IF;
  END;
END $$;
SELECT jsonb_array_length(vigilante.oportunidades_web()) AS oportunidades_web,
       jsonb_array_length(vigilante.vigilante_bd() -> 'senales') AS senales_web,
       jsonb_array_length(vigilante.vigilante_bd() -> 'oportunidades') AS oportunidades_json;
SELECT vigilante.decidir_oportunidad((SELECT (o ->> 'id')::bigint FROM jsonb_array_elements(vigilante.oportunidades_web()) o
                                      WHERE o ->> 'nivel' = 'inferida'), 'validada');
SELECT set_config('request.jwt.claim.sub', '30000000-0000-0000-0000-00000000000a', true);
SELECT vigilante.decidir_candidata((SELECT id FROM vigilante.candidatas_web() WHERE nombre LIKE 'Gobernación%'), true, 'útil',
                                   'vial', 'oficial', 'http_html', 120) AS fuente_creada;
RESET ROLE;
DO $$ BEGIN
  ASSERT EXISTS (SELECT 1 FROM vigilante.sources WHERE url = 'https://potosi.gob.bo/noticias' AND activa), 'aprobada → entra en el catálogo';
  ASSERT (SELECT estado FROM vigilante.oportunidades WHERE nivel = 'inferida') = 'validada', 'el analista valida la oportunidad';
  ASSERT jsonb_array_length(vigilante.vigilante_json('orbita-bolivia') -> 'oportunidades') = 2, 'vigilante.json generado desde la base';
END $$;

-- 13. Limpieza de propuestas antiguas (solo mira)
SELECT * FROM vigilante.propuestas_a_candidatas(false);

\echo 'PRUEBA OK'
ROLLBACK;
