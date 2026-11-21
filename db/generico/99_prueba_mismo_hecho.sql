-- Prueba de 43_mismo_hecho.sql: el mismo hecho contado con otras palabras acaba en UNA señal con 2 fuentes.
-- Casos reales del 21/11/2026: los dos festivales de la Canción Boliviana (publicados los dos) y los
-- derrumbes Cochabamba–Santa Cruz. Requiere 01 a 43. Usa un cliente propio («prueba-hecho»): no toca
-- las señales reales. Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-hecho', 'Prueba mismo hecho', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{eventos}', 'rss' FROM ids,
  (VALUES ('h-abc', 'ABC de prueba', 'oficial', 'https://abc.prueba.bo'),
          ('h-pre', 'Prensa de prueba', 'medio', 'https://prensa.prueba.bo'),
          ('h-otr', 'Otro medio de prueba', 'medio', 'https://otro.prueba.bo')) x(cod, nom, tipo, url);

CREATE TEMP TABLE n (k text PRIMARY KEY, id bigint);
CREATE FUNCTION pg_temp.noticia(p_k text, p_fuente text, p_titulo text) RETURNS bigint LANGUAGE sql AS $$
  WITH r AS (
    INSERT INTO vigilante.raw_items (cliente_id, source_id, url, url_doc, content_hash, titulo, titulo_norm, contenido, recolectado_en)
    SELECT i.c, s.id, s.url || '/' || p_k, vigilante.url_doc(s.url || '/' || p_k), 'h-hecho-' || p_k, p_titulo,
           vigilante.texto_norm(p_titulo), p_titulo, now()
      FROM ids i JOIN vigilante.sources s ON s.cliente_id = i.c AND s.codigo = p_fuente
    RETURNING id)
  INSERT INTO n SELECT p_k, id FROM r RETURNING id
$$;
CREATE FUNCTION pg_temp.sid(p_cod text) RETURNS bigint LANGUAGE sql AS $$
  SELECT id FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids) AND codigo = p_cod
$$;
CREATE FUNCTION pg_temp.cod_de(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT s.codigo FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
   WHERE sr.raw_item_id = (SELECT id FROM n WHERE k = p_k) AND s.duplicado_de IS NULL
$$;
-- Publicar como lo hace una persona en el panel
CREATE FUNCTION pg_temp.publicar(p_cod text) RETURNS void LANGUAGE sql AS $$
  UPDATE vigilante.signals SET estado = 'en_analisis', estado_manual = true WHERE id = pg_temp.sid(p_cod) AND estado IN ('detectada', 'en_verificacion');
  UPDATE vigilante.signals SET estado = 'confirmada', estado_manual = true WHERE id = pg_temp.sid(p_cod) AND estado IN ('en_analisis', 'en_verificacion');
  UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE id = pg_temp.sid(p_cod);
$$;

-- 1. La regla, con los títulos tal como salieron -------------------------------------------
SELECT a, b, m.* FROM (VALUES
  ('Canción Boliviana 2026: preselecciones del 6 y 7 de noviembre; final en Oruro el 20-21 de noviembre',
   'Festival Nacional de la Canción Boliviana 2026: Oruro, 20-21 de noviembre', true),
  ('Derrumbes en la carretera Cochabamba–Santa Cruz', 'Deslizamientos bloquean la ruta antigua Cochabamba - Santa Cruz en el km 120', true),
  ('Cochabamba: derrumbe cierra la carretera nueva a Santa Cruz', 'ABC: tránsito restringido por derrumbes en la vía Cochabamba–Santa Cruz', true),
  ('Bloqueo de transportistas en la carretera Cochabamba–Santa Cruz', 'Derrumbe bloquea la carretera Cochabamba–Santa Cruz', false),
  ('Derrumbe en la carretera La Paz–Yungas', 'Derrumbe en la carretera Cochabamba–Santa Cruz', false),
  ('Festival de la Canción Boliviana en Oruro', 'Festival del Charango en Oruro', false),
  ('Festival Nacional de la Canción Boliviana 2025 en Oruro', 'Festival Nacional de la Canción Boliviana 2026 en Oruro', false),
  ('Sucre: National Night en Kultur Berlin', 'Sucre: Sweet Monday en Kultur Berlin', false)) x(a, b, esperado)
CROSS JOIN LATERAL vigilante.mismo_hecho_titulos('prueba-hecho', a, b) m;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT a, b, esperado, m.mismo, m.motivo FROM (VALUES
    ('Canción Boliviana 2026: preselecciones del 6 y 7 de noviembre; final en Oruro el 20-21 de noviembre',
     'Festival Nacional de la Canción Boliviana 2026: Oruro, 20-21 de noviembre', true),
    ('Derrumbes en la carretera Cochabamba–Santa Cruz', 'Deslizamientos bloquean la ruta antigua Cochabamba - Santa Cruz en el km 120', true),
    ('Cochabamba: derrumbe cierra la carretera nueva a Santa Cruz', 'ABC: tránsito restringido por derrumbes en la vía Cochabamba–Santa Cruz', true),
    ('Bloqueo de transportistas en la carretera Cochabamba–Santa Cruz', 'Derrumbe bloquea la carretera Cochabamba–Santa Cruz', false),
    ('Derrumbe en la carretera La Paz–Yungas', 'Derrumbe en la carretera Cochabamba–Santa Cruz', false),
    ('Festival de la Canción Boliviana en Oruro', 'Festival del Charango en Oruro', false),
    ('Festival Nacional de la Canción Boliviana 2025 en Oruro', 'Festival Nacional de la Canción Boliviana 2026 en Oruro', false),
    ('Sucre: National Night en Kultur Berlin', 'Sucre: Sweet Monday en Kultur Berlin', false)) x(a, b, esperado)
    CROSS JOIN LATERAL vigilante.mismo_hecho_titulos('prueba-hecho', a, b) m
  LOOP
    IF r.mismo <> r.esperado THEN
      RAISE EXCEPTION '«%» vs «%»: esperaba %, salió % (%)', r.a, r.b, r.esperado, r.mismo, r.motivo;
    END IF;
  END LOOP;
END $$;

-- 2. Canción Boliviana: las dos señales que ya existían, publicadas las dos ----------------
-- (creadas con guardar_senal_15, como antes del 43, para tener el duplicado de la web)
SELECT pg_temp.noticia('cancion-1', 'h-pre', 'Festival Nacional de la Canción Boliviana 2026 será en Oruro el 20 y 21 de noviembre');
SELECT pg_temp.noticia('cancion-2', 'h-otr', 'Canción Boliviana 2026: preselecciones el 6 y 7 de noviembre, final en Oruro');
SELECT vigilante.guardar_senal_15('prueba-hecho', jsonb_build_object(
  'titulo', 'Festival Nacional de la Canción Boliviana 2026: Oruro, 20-21 de noviembre', 'resumen', 'Final en Oruro.',
  'categoria', 'eventos', 'naturaleza', 'oportunidad', 'departamentos', '["Oruro"]'::jsonb,
  'fecha_evento_inicio', '2026-11-20', 'fecha_evento_fin', '2026-11-21', 'noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'cancion-1'))));
SELECT vigilante.guardar_senal_15('prueba-hecho', jsonb_build_object(
  'titulo', 'Canción Boliviana 2026: preselecciones del 6 y 7 de noviembre; final en Oruro el 20-21 de noviembre', 'resumen', 'Preselecciones y final.',
  'categoria', 'eventos', 'naturaleza', 'oportunidad', 'departamentos', '["Santa Cruz", "Potosí", "Oruro"]'::jsonb,
  'fecha_evento_inicio', '2026-11-06', 'fecha_evento_fin', '2026-11-21', 'noticias', jsonb_build_array((SELECT id FROM n WHERE k = 'cancion-2'))));
UPDATE vigilante.signals SET created_at = now() - interval '9 days' WHERE id = pg_temp.sid('SEN-0001');
SELECT pg_temp.publicar('SEN-0001');
SELECT pg_temp.publicar('SEN-0002');
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.alerts WHERE cliente_id = (SELECT c FROM ids) AND cerrada_en IS NULL) = 2,
         'antes: el mismo festival sale dos veces en la web';
END $$;

SELECT se_queda, repetida, motivo, publicadas FROM vigilante.senales_repetidas() WHERE cliente = 'prueba-hecho';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.senales_repetidas() WHERE cliente = 'prueba-hecho') = 1, 've el par repetido';
  ASSERT (SELECT se_queda FROM vigilante.senales_repetidas() WHERE cliente = 'prueba-hecho') = 'SEN-0001',
         'se queda la más antigua (las dos publicadas, una fuente cada una)';
END $$;
SELECT vigilante.juntar_senales_repetidas() AS juntadas;
SELECT s.codigo, s.estado, s.duplicado_de, r.n_fuentes, r.verificada, a.cerrada_en IS NULL AS en_web
  FROM vigilante.signals s CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
  LEFT JOIN vigilante.alerts a ON a.signal_id = s.id
 WHERE s.cliente_id = (SELECT c FROM ids) ORDER BY 1;
DO $$ BEGIN
  ASSERT (SELECT estado::text FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) = 'descartada', 'la repetida queda descartada';
  ASSERT (SELECT duplicado_de FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) = pg_temp.sid('SEN-0001'), 'y apunta a la otra';
  ASSERT (SELECT n_fuentes FROM vigilante.respaldo_senal(pg_temp.sid('SEN-0001'))) = 2, 'la que se queda tiene 2 fuentes';
  ASSERT (SELECT verificada FROM vigilante.respaldo_senal(pg_temp.sid('SEN-0001'))), 'y por eso pasa a verificada';
  ASSERT (SELECT count(*) FROM vigilante.alerts WHERE cliente_id = (SELECT c FROM ids) AND cerrada_en IS NULL) = 1,
         'en la web sale una sola vez';
  ASSERT (SELECT estado_verificacion::text FROM vigilante.alerts WHERE signal_id = pg_temp.sid('SEN-0001')) = 'confirmada',
         'la alerta que queda ya no dice «En verificación»';
  ASSERT (SELECT count(*) FROM vigilante.signal_territorios WHERE signal_id = pg_temp.sid('SEN-0001')) = 3,
         'con los departamentos de las dos';
  ASSERT (SELECT count(*) FROM vigilante.senales_juntadas WHERE repetida_id = pg_temp.sid('SEN-0002')) = 1, 'queda registrado';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.senales_repetidas() WHERE cliente = 'prueba-hecho'), 'ya no quedan repetidas';
END $$;

-- Deshacer: vuelve a Detectadas con su noticia, y la tarea no la vuelve a juntar
SELECT vigilante.separar_senal('SEN-0002') AS separar;
SELECT vigilante.juntar_senales_repetidas() AS otra_vuelta;
DO $$ BEGIN
  ASSERT (SELECT estado::text FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) = 'en_analisis', 'separada: vuelve a Detectadas';
  ASSERT (SELECT duplicado_de FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) IS NULL, 'ya no apunta a la otra';
  ASSERT (SELECT n_fuentes FROM vigilante.respaldo_senal(pg_temp.sid('SEN-0001'))) = 1, 'la otra vuelve a su única fuente';
  ASSERT (SELECT count(*) FROM vigilante.signal_territorios WHERE signal_id = pg_temp.sid('SEN-0001')) = 1, 'y a su departamento';
  ASSERT (SELECT estado::text FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) = 'en_analisis', 'la tarea no la vuelve a juntar';
END $$;
-- A mano sí se puede (y si se pasa al revés, se queda la publicada)
SELECT vigilante.juntar_senales('SEN-0002', 'SEN-0001', 'lo vio la analista') AS a_mano;
DO $$ BEGIN
  ASSERT (SELECT duplicado_de FROM vigilante.signals WHERE id = pg_temp.sid('SEN-0002')) = pg_temp.sid('SEN-0001'),
         'se queda la publicada aunque se pidiera al revés';
END $$;

-- 3. Derrumbes: llegan noticias nuevas por el clasificador ---------------------------------
SELECT pg_temp.noticia('derrumbe-1', 'h-pre', 'Derrumbes en la carretera Cochabamba–Santa Cruz');
SELECT pg_temp.noticia('derrumbe-2', 'h-abc', 'ABC: deslizamientos bloquean la ruta antigua Cochabamba - Santa Cruz en el km 120');
SELECT pg_temp.noticia('bloqueo-1', 'h-otr', 'Transportistas bloquean la carretera Cochabamba–Santa Cruz');
SELECT pg_temp.noticia('transito-1', 'h-otr', 'Tránsito restringido entre Colomi y Villa Tunari');
SELECT vigilante.guardar_clasificacion('prueba-hecho', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'derrumbe-1'), 'relevante', true,
    'titulo', 'Derrumbes en la carretera Cochabamba–Santa Cruz', 'resumen', 'Varios derrumbes en la vía.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'alta', 'departamentos', '["Cochabamba", "Santa Cruz"]'::jsonb)),
  'prueba', 'clasificador-1.9') AS ronda_1;
-- otro medio (oficial), otras palabras; y un bloqueo de transportistas en la misma ruta
SELECT vigilante.guardar_clasificacion('prueba-hecho', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'derrumbe-2'), 'relevante', true,
    'titulo', 'Deslizamientos bloquean la ruta antigua Cochabamba–Santa Cruz (km 120)', 'resumen', 'La ABC reporta deslizamientos.',
    'naturaleza', 'riesgo', 'categoria', 'clima', 'prioridad', 'alta', 'departamentos', '["Cochabamba", "Santa Cruz"]'::jsonb),
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'bloqueo-1'), 'relevante', true,
    'titulo', 'Bloqueo de transportistas en la carretera Cochabamba–Santa Cruz', 'resumen', 'Transportistas bloquean.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'alta', 'departamentos', '["Cochabamba", "Santa Cruz"]'::jsonb)),
  'prueba', 'clasificador-1.9') AS ronda_2;
DO $$
DECLARE l jsonb;
BEGIN
  ASSERT pg_temp.cod_de('derrumbe-1') = pg_temp.cod_de('derrumbe-2'), 'los dos derrumbes en una señal';
  ASSERT pg_temp.cod_de('bloqueo-1') <> pg_temp.cod_de('derrumbe-1'), 'el bloqueo de transportistas es otro hecho';
  ASSERT (SELECT n_fuentes FROM vigilante.respaldo_senal(pg_temp.sid(pg_temp.cod_de('derrumbe-1')))) = 2, 'derrumbes: 2 fuentes';
  ASSERT (SELECT titulo FROM vigilante.signals WHERE id = pg_temp.sid(pg_temp.cod_de('derrumbe-1'))) = 'Derrumbes en la carretera Cochabamba–Santa Cruz',
         'conserva su título';
  ASSERT (SELECT categoria FROM vigilante.signals WHERE id = pg_temp.sid(pg_temp.cod_de('derrumbe-1'))) = 'vial',
         'y su categoría aunque el otro medio lo clasificara como clima';
  -- el clasificador recibe la señal del derrumbe con una noticia que la cuenta con otras palabras
  l := vigilante.senales_relacionadas((SELECT c FROM ids), 'Deslave en la vía Cochabamba–Santa Cruz', '{}', '{}', 3);
  ASSERT l @> jsonb_build_array(jsonb_build_object('codigo', pg_temp.cod_de('derrumbe-1'))), 'relacionada por palabras clave';
END $$;

-- 4. «misma_senal»: el clasificador ve el mismo hecho aunque no compartan palabras --------------
SELECT vigilante.guardar_clasificacion('prueba-hecho', jsonb_build_array(
  jsonb_build_object('clave', (SELECT id FROM n WHERE k = 'transito-1'), 'relevante', true,
    'titulo', 'Tránsito restringido entre Colomi y Villa Tunari', 'resumen', 'Paso restringido.',
    'naturaleza', 'riesgo', 'categoria', 'vial', 'prioridad', 'alta', 'departamentos', '["Cochabamba"]'::jsonb,
    'misma_senal', pg_temp.cod_de('derrumbe-1'))), 'prueba', 'clasificador-1.9') AS ronda_3;
DO $$ BEGIN
  ASSERT pg_temp.cod_de('transito-1') = pg_temp.cod_de('derrumbe-1'), 'unida a la señal que dijo el clasificador';
  ASSERT (SELECT n_fuentes FROM vigilante.respaldo_senal(pg_temp.sid(pg_temp.cod_de('derrumbe-1')))) = 3, 'derrumbes: 3 fuentes';
END $$;

SELECT s.codigo, s.titulo, s.estado, r.n_fuentes, s.repetidas_unidas, s.claves
  FROM vigilante.signals s CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
 WHERE s.cliente_id = (SELECT c FROM ids) ORDER BY 1;
SELECT 'Prueba del 43 superada' AS resultado;
ROLLBACK;
