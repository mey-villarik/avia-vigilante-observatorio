-- Prueba de 14_recolector_mcp.sql (recolector, búsquedas, noticias pendientes, señales de AVIA, propuestas).
-- Requiere 01, 02, 03, 04 y 06 a 14. Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 1. Lista para el recolector
SELECT jsonb_array_length(vigilante.fuentes_para_recolector('orbita-bolivia') -> 'fuentes') AS fuentes_activas,
       vigilante.fuentes_para_recolector('orbita-bolivia') -> 'apify_disponible_usd' AS apify;

-- 2. Una comprobación con 3 noticias: una oportunidad, una alerta y una que no interesa
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', '3 noticias', '[
  {"titulo": "Santa Cruz prepara un festival internacional de turismo en diciembre", "url": "https://ej.bo/1", "resumen": "La gobernación anuncia la feria.", "publicado_en": "2026-11-08T08:00:00-04:00"},
  {"titulo": "Bloqueo en la carretera a Oruro por conflicto", "url": "https://ej.bo/2"},
  {"titulo": "Resultados del fútbol europeo", "url": "https://ej.bo/3"}
]'::jsonb, 'huella-1') AS primera;

-- 3. La misma lectura otra vez: todo repetido
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', 'sin cambios', '[
  {"titulo": "Santa Cruz prepara un festival internacional de turismo en diciembre", "url": "https://ej.bo/1"}]'::jsonb) AS segunda;

-- 4. Misma noticia en otra fuente (cuenta como coincidencia)
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gdelt_bolivia', 'OK', '1', '[
  {"titulo": "Santa Cruz prepara un festival internacional de turismo en diciembre", "url": "https://otro.bo/x"}]'::jsonb) AS otra_fuente;

-- 5. Una fuente que falla
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'senamhi_alertas', 'CRIT', 'HTTP 503');
SELECT codigo, config ->> 'estado' AS estado, config -> 'hist' AS hist, errores_seguidos, ultimo_error
  FROM vigilante.sources WHERE codigo IN ('gnews_turismo', 'senamhi_alertas') ORDER BY codigo;
DO $$ BEGIN
  ASSERT (SELECT errores_seguidos FROM vigilante.sources WHERE codigo = 'senamhi_alertas') = 1, 'CRIT suma un fallo';
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE estado = 'descartado') = 1, 'el fútbol se descarta sin IA';
END $$;

-- 6. Búsqueda pedida por AVIA
SELECT vigilante.pedir_busqueda('orbita-bolivia', 'festival Uyuni 2026', 'script', '{}', 'tema en aumento') AS pedida;
SELECT vigilante.pedir_busqueda('orbita-bolivia', 'algo en redes', 'apify') AS apify_desactivado;
SELECT vigilante.tomar_busquedas('orbita-bolivia') AS tomadas;
SELECT vigilante.guardar_busqueda('orbita-bolivia', (SELECT max(id) FROM vigilante.busquedas), true, NULL,
  '[{"titulo": "Uyuni anuncia festival de la sal", "url": "https://ej.bo/4"}]'::jsonb) AS busqueda;

-- 7. Noticias pendientes para AVIA (agrupadas: la del festival sale una vez con 2 fuentes)
SELECT jsonb_pretty(vigilante.noticias_pendientes('orbita-bolivia', 10)) AS pendientes;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE estado = 'en_cola') = 4, 'quedan en cola';
  ASSERT jsonb_array_length(vigilante.noticias_pendientes('orbita-bolivia', 10)) = 0, 'no se repiten antes de 2 horas';
END $$;

-- 8. AVIA guarda una señal y luego la actualiza
SELECT vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Santa Cruz: festival internacional de turismo en diciembre',
  'resumen', 'La gobernación anuncia una feria internacional.',
  'naturaleza', 'oportunidad', 'categoria', 'eventos', 'prioridad', 'media',
  'departamentos', jsonb_build_array('Santa Cruz'), 'fuente_id', 'gnews_turismo',
  'fecha_evento_inicio', '2026-12-10', 'plazo_hasta', '2026-11-20', 'confianza', 0.6, 'relevancia', 8,
  'importancia', 'Atrae visitantes de la región.', 'soluciones', jsonb_build_array(jsonb_build_object('t', 'Avisar a operadores')),
  'noticias', (SELECT jsonb_agg(id) FROM vigilante.raw_items WHERE titulo LIKE 'Santa Cruz%'))) AS senal;
SELECT vigilante.guardar_senal('orbita-bolivia', '{"codigo": "SEN-0001", "titulo": "Santa Cruz: festival internacional (fechas confirmadas)", "resumen": "Confirmado por la gobernación.", "confianza": 0.9}') AS actualizada;
SELECT codigo, titulo, estado, naturaleza, categoria, plazo_hasta, confianza, puntaje, salida_modelo ? 'importancia' AS conserva FROM vigilante.signals;
DO $$ BEGIN
  ASSERT (SELECT categoria FROM vigilante.signals WHERE codigo = 'SEN-0001') = 'eventos', 'al actualizar no se pierde la categoría';
  ASSERT (SELECT salida_modelo ? 'importancia' FROM vigilante.signals WHERE codigo = 'SEN-0001'), 'ni lo que no se manda';
END $$;
SELECT vigilante.marcar_noticias('orbita-bolivia', ARRAY(SELECT id FROM vigilante.raw_items WHERE estado = 'en_cola'), 'descartado', 'sin interés turístico') AS descartadas;

-- 9. Consultas de AVIA
SELECT vigilante.buscar_senales('orbita-bolivia', 'festival') AS parecidas;
SELECT jsonb_pretty(vigilante.metricas_oportunidades('orbita-bolivia')) AS metricas;
SELECT vigilante.alertas_tempranas('orbita-bolivia') AS alertas;
SELECT vigilante.proponer_metodo('orbita-bolivia', 'senamhi_alertas', 'apify', 'La web bloquea al lector normal (HTTP 503 repetido)',
                                 '{"apify_actor": "apify/website-content-crawler"}') AS propuesta;
SELECT jsonb_path_query(vigilante.estado_fuentes('orbita-bolivia'), '$[*] ? (@.codigo == "senamhi_alertas")') AS senamhi;

-- 10. Web: el analista ve, no decide; el administrador aprueba
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT id, '20000000-0000-0000-0000-00000000000a', 'Ana Admin', 'administrador' FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT id, '20000000-0000-0000-0000-00000000000b', 'Luis Analista', 'analista' FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-00000000000b', true);
SELECT codigo, metodo_actual, metodo_propuesto, estado FROM vigilante.propuestas_web();
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.decidir_propuesta((SELECT id FROM vigilante.propuestas_web() LIMIT 1), true);
    RAISE EXCEPTION 'el analista no debería poder aprobar';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Solo un administrador%' THEN RAISE; END IF;
  END;
END $$;
SELECT jsonb_array_length(vigilante.vigilante_bd() -> 'senales') AS senales_web,
       jsonb_array_length(vigilante.vigilante_bd() -> 'fuentes') AS fuentes_web,
       vigilante.vigilante_bd() #> '{senales,0}' AS primera;
RESET ROLE;
UPDATE vigilante.sources SET ultima_consulta_en = now() - interval '1 hour' WHERE codigo = 'senamhi_alertas';  -- la comprobación fue antes
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '20000000-0000-0000-0000-00000000000a', true);
SELECT vigilante.decidir_propuesta((SELECT id FROM vigilante.propuestas_web() LIMIT 1), true, 'de acuerdo');
RESET ROLE;
SELECT codigo, metodo, config ->> 'apify_actor' AS actor, config ? 'revisar_desde' AS revisar
  FROM vigilante.sources WHERE codigo = 'senamhi_alertas';
SELECT accion, quien, detalle FROM vigilante.source_events ORDER BY id DESC LIMIT 1;
DO $$ BEGIN
  ASSERT (SELECT metodo FROM vigilante.sources WHERE codigo = 'senamhi_alertas') = 'apify', 'método cambiado';
  ASSERT (vigilante.fuentes_para_recolector('orbita-bolivia') #> '{fuentes}') @> '[{"codigo": "senamhi_alertas", "nueva": true}]', 'vuelve como nueva';
END $$;

\echo 'PRUEBA OK'
ROLLBACK;
