-- Prueba de 47_fuentes_avia_directas.sql: lo que encuentra AVIA entra solo, sin repetir sitios,
-- y respeta lo que el usuario eliminó. Requiere 01..47 con el cliente orbita-bolivia (02).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 1. El sitio de una dirección
DO $$ BEGIN
  ASSERT vigilante.sitio('https://senamhi.gob.bo/api/alertas/active-alerts') = 'senamhi.gob.bo', 'senamhi api';
  ASSERT vigilante.sitio('https://www.senamhi.gob.bo/alertas.php') = 'senamhi.gob.bo', 'www';
  ASSERT vigilante.sitio('https://alertas.senamhi.gob.bo/x') = 'senamhi.gob.bo', 'subdominio de gob.bo';
  ASSERT vigilante.sitio('https://noticias.eldeber.com.bo/a') = 'eldeber.com.bo', 'com.bo';
  ASSERT vigilante.sitio('https://www.bbc.com/mundo') = 'bbc.com', 'bbc';
  ASSERT vigilante.sitio('https://news.google.com/rss/search?q=a') <> vigilante.sitio('https://news.google.com/rss/search?q=b'),
         'en Google News cada dirección es una fuente';
  ASSERT vigilante.sitio('https://a.blogspot.com/x') <> vigilante.sitio('https://b.blogspot.com/x'), 'cada blog es de otro dueño';
END $$;

CREATE TEMP TABLE t_cli AS SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
CREATE TEMP TABLE t_antes AS SELECT count(*) AS n FROM vigilante.sources;

-- 2. SENAMHI ya está en el catálogo (senamhi.gob.bo/alertas3.php): las otras páginas NO entran
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'SENAMHI', 'https://senamhi.gob.bo/alertas.php',
                                     'Apareció en vigilante.json sin estar en el catálogo', 'senamhi', NULL, '[]', 'sincronizacion') AS senamhi_1;
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'SENAMHI', 'https://senamhi.gob.bo/api/alertas/active-alerts',
                                     'Apareció en vigilante.json sin estar en el catálogo', 'senamhi_api', NULL, '[]', 'sincronizacion') AS senamhi_2;
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'SENAMHI', 'https://senamhi.gob.bo/api/alertas/active-alerts',
                                     'otra vez', 'senamhi_api', NULL, '[]', 'sincronizacion') AS senamhi_3;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.sources) = (SELECT n FROM t_antes), 'SENAMHI no se repite';
  ASSERT (SELECT count(*) FROM vigilante.source_candidates WHERE estado = 'duplicada') = 2, 'queda registro de las dos direcciones repetidas';
  ASSERT (SELECT veces FROM vigilante.source_candidates WHERE url LIKE '%active-alerts') = 2, 'la misma dirección suma veces, no filas';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.source_candidates WHERE estado = 'pendiente'), 'nada queda pendiente de aprobación';
END $$;

-- 3. Una fuente oficial nueva entra sola, activa y marcada como de AVIA
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'ABC Transitabilidad', 'https://transitabilidad.abc.gob.bo/mapa_reporte',
                                     'Cortes de ruta citados en 3 noticias', NULL, NULL, '[]', 'avia') AS abc;
DO $$ BEGIN
  ASSERT (SELECT activa AND origen = 'avia' AND tipo = 'oficial' AND metodo = 'http_html' AND categorias = ARRAY['turismo']
            AND notas = 'Cortes de ruta citados en 3 noticias'
            FROM vigilante.sources WHERE url = 'https://transitabilidad.abc.gob.bo/mapa_reporte'), 'ABC activa, oficial, de AVIA';
  ASSERT (SELECT estado = 'aprobada' AND source_id IS NOT NULL FROM vigilante.source_candidates WHERE url LIKE '%abc.gob.bo%'),
         'queda registrada como añadida';
  ASSERT (SELECT origen FROM vigilante.sources WHERE codigo = 'senamhi_alertas') = 'usuario', 'el catálogo inicial es del usuario';
END $$;

-- 4. Otra página del mismo sitio (otro subdominio) ya no entra
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'ABC', 'https://www.abc.gob.bo/noticias', 'x') AS abc_2;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.sources WHERE vigilante.sitio(url) = 'abc.gob.bo') = 1, 'ABC no se repite';
END $$;

-- 5. Un feed internacional entra como organismo internacional y por RSS; Google News por dirección
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'OMT', 'https://www.untourism.int/es/rss.xml', 'turismo mundial') AS omt;
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'Google News Uyuni', 'https://news.google.com/rss/search?q=Uyuni', 'búsqueda') AS gn;
DO $$ BEGIN
  ASSERT (SELECT tipo = 'organismo_internacional' AND metodo = 'rss' FROM vigilante.sources WHERE codigo = 'omt'), 'OMT por RSS';
  ASSERT EXISTS (SELECT 1 FROM vigilante.sources WHERE url = 'https://news.google.com/rss/search?q=Uyuni' AND activa), 'Google News por dirección';
  ASSERT (SELECT tipo FROM vigilante.sources WHERE url = 'https://news.google.com/rss/search?q=Uyuni') = 'no_oficial', 'lo demás, no oficial';
END $$;

-- 6. El usuario elimina la de ABC: AVIA no la vuelve a meter (ni otra página del sitio)
UPDATE vigilante.sources SET activa = false, eliminada_en = now(), config = config || '{"eliminada_por": "Meysel"}'
 WHERE url = 'https://transitabilidad.abc.gob.bo/mapa_reporte';
SELECT vigilante.registrar_candidata((SELECT id FROM t_cli), 'ABC', 'https://transitabilidad.abc.gob.bo/mapa_reporte', 'otra vez') AS abc_3;
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.sources WHERE vigilante.sitio(url) = 'abc.gob.bo' AND eliminada_en IS NULL), 'no vuelve';
  ASSERT (vigilante.registrar_candidata((SELECT id FROM t_cli), 'ABC', 'https://abc.gob.bo/otra', 'x') ->> 'motivo') LIKE 'Un usuario eliminó%',
         'explica por qué';
END $$;

-- 7. Dirección inventada: no entra
DO $$ BEGIN
  ASSERT NOT (vigilante.registrar_candidata((SELECT id FROM t_cli), 'x', 'no es una url', 'x') ->> 'ok')::boolean, 'url inválida';
END $$;

-- 8. Limpieza: lo pendiente de antes se activa o se marca repetido
INSERT INTO vigilante.source_candidates (cliente_id, nombre, url, url_doc, motivo, propuesta_por, veces)
VALUES ((SELECT id FROM t_cli), 'SENAMHI', 'https://senamhi.gob.bo/pronostico.php', vigilante.url_doc('https://senamhi.gob.bo/pronostico.php'), 'vieja', 'sincronizacion', 1),
       ((SELECT id FROM t_cli), 'DGAC', 'https://www.dgac.gob.bo/avisos', vigilante.url_doc('https://www.dgac.gob.bo/avisos'), 'vieja', 'avia', 3),
       ((SELECT id FROM t_cli), 'DGAC 2', 'https://dgac.gob.bo/otra', vigilante.url_doc('https://dgac.gob.bo/otra'), 'vieja', 'avia', 1);
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, activa, config)
VALUES ((SELECT id FROM t_cli), 'migracion_vieja', 'Migración', 'https://www.migracion.gob.bo/', 'oficial', 'http_html', false, '{"propuesta_avia": true}'),
       ((SELECT id FROM t_cli), 'senamhi_vieja', 'SENAMHI vieja', 'https://senamhi.gob.bo/vieja', 'oficial', 'http_html', false, '{"propuesta_avia": true}');
SELECT * FROM vigilante.activar_fuentes_avia_pendientes(false);
SELECT * FROM vigilante.activar_fuentes_avia_pendientes(true);
DO $$ BEGIN
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.source_candidates WHERE estado = 'pendiente'), 'sin pendientes';
  ASSERT (SELECT activa AND origen = 'avia' AND NOT config ? 'propuesta_avia' FROM vigilante.sources WHERE codigo = 'migracion_vieja'),
         'la propuesta en pausa se activa';
  ASSERT (SELECT eliminada_en IS NOT NULL FROM vigilante.sources WHERE codigo = 'senamhi_vieja'), 'la de SENAMHI repetida se quita';
  ASSERT (SELECT estado FROM vigilante.source_candidates WHERE url LIKE '%pronostico%') = 'duplicada', 'SENAMHI pendiente → duplicada';
  ASSERT (SELECT count(*) FROM vigilante.sources WHERE vigilante.sitio(url) = 'dgac.gob.bo' AND eliminada_en IS NULL) = 1, 'una sola DGAC';
  ASSERT EXISTS (SELECT 1 FROM vigilante.sources WHERE url = 'https://www.dgac.gob.bo/avisos' AND activa), 'se queda la más vista';
  ASSERT (SELECT count(*) FROM vigilante.sources WHERE vigilante.sitio(url) = 'senamhi.gob.bo' AND eliminada_en IS NULL) = 1, 'un solo SENAMHI';
END $$;

-- 9. La sincronización con vigilante.json: lo de un sitio conocido no entra, lo nuevo sí
SELECT vigilante.sincronizar_vigilante('orbita-bolivia', '{"version": 1, "fuentes": [
  {"id": "senamhi_x", "nombre": "SENAMHI", "url": "https://senamhi.gob.bo/alertas.php", "estado": "OK"},
  {"id": "viceministerio_turismo", "nombre": "Viceministerio de Turismo", "url": "https://www.turismo.gob.bo/", "estado": "OK"}
], "senales": []}'::jsonb) AS sincronizacion;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.sources WHERE vigilante.sitio(url) = 'senamhi.gob.bo' AND eliminada_en IS NULL) = 1, 'SENAMHI sigue siendo uno';
  ASSERT (SELECT activa AND origen = 'avia' FROM vigilante.sources WHERE codigo = 'viceministerio_turismo'), 'la nueva entra con su código';
END $$;

SELECT codigo, nombre, url, tipo, metodo, activa, origen, eliminada_en IS NOT NULL AS eliminada FROM vigilante.sources ORDER BY origen, codigo;
SELECT nombre, url, estado, veces, nota FROM vigilante.source_candidates ORDER BY id;

ROLLBACK;
