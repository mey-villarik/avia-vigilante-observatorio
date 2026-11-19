-- Prueba de 30_sin_duplicados.sql: fuentes, noticias y señales sin repetir.
-- Requiere 01 a 30 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

-- 1. FUENTES ------------------------------------------------------------------
-- La misma dirección escrita de otra forma (mayúsculas, www, barra final, utm) no entra como fuente nueva
DO $$
DECLARE v_msg text;
BEGIN
  BEGIN
    INSERT INTO vigilante.sources (cliente_id, codigo, nombre, url, tipo, metodo, categorias)
    SELECT cliente_id, 'senamhi_bis', 'SENAMHI otra vez', 'HTTP://WWW.Senamhi.gob.bo/alertas3.php/?utm_source=x', tipo, metodo, categorias
      FROM vigilante.sources WHERE codigo = 'senamhi_alertas';
    RAISE EXCEPTION 'la fuente repetida no debió entrar';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    RAISE NOTICE 'Rechazada: %', v_msg;
    ASSERT v_msg LIKE '%senamhi_alertas%', 'el aviso dice qué fuente ya la vigila';
  END;
  ASSERT vigilante.fuente_canonica((SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'), 'otro',
                                   'https://senamhi.gob.bo/alertas3.php?utm_campaign=y') = 'senamhi_alertas',
         'el catálogo reconoce la dirección con parámetros de seguimiento';
END $$;

-- 2. NOTICIAS -----------------------------------------------------------------
-- La misma noticia cuatro veces (con www, barra, utm) en una lectura y otra vez desde otra fuente
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', '4', '[
  {"titulo": "Lanzan nueva ruta turística al Salar de Uyuni", "url": "https://ej.bo/turismo/ruta-uyuni"},
  {"titulo": "Lanzan nueva ruta turística al Salar de Uyuni", "url": "https://www.ej.bo/turismo/ruta-uyuni/"},
  {"titulo": "Lanzan nueva ruta turística al Salar de Uyuni", "url": "https://ej.bo/turismo/ruta-uyuni?utm_source=fb"},
  {"titulo": "Bolivia: lanzan nueva ruta turística al Salar de Uyuni", "url": "https://otro.bo/nota/uyuni-ruta"}
]'::jsonb) AS lectura;
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gdelt_bolivia', 'OK', '1', '[
  {"titulo": "Lanzan nueva ruta turística al Salar de Uyuni", "url": "http://ej.bo/turismo/ruta-uyuni"}]'::jsonb) AS otra_fuente;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE url_doc = 'ej.bo/turismo/ruta-uyuni') = 1,
         'una sola fila por documento, venga de donde venga';
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE url_doc = 'otro.bo/nota/uyuni-ruta') = 1,
         'el mismo hecho en otro medio sí se guarda (es corroboración)';
END $$;

-- Aunque alguien inserte directamente (sin insertar_noticias), la copia no entra
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
SELECT cliente_id, source_id, 'https://ej.bo/turismo/ruta-uyuni#comentarios', 'otro-hash', titulo
  FROM vigilante.raw_items WHERE url_doc = 'ej.bo/turismo/ruta-uyuni';
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.raw_items WHERE url_doc = 'ej.bo/turismo/ruta-uyuni') = 1, 'el disparador para la copia';
END $$;

-- Más noticias para las señales
SELECT vigilante.guardar_comprobacion('orbita-bolivia', 'gnews_turismo', 'OK', '4', '[
  {"titulo": "Alerta naranja por lluvias en La Paz", "url": "https://ej.bo/clima/lluvias-lp"},
  {"titulo": "Alerta naranja por lluvias en Cochabamba", "url": "https://ej.bo/clima/lluvias-cbba"},
  {"titulo": "Feria Internacional de Turismo 2026 en La Paz", "url": "https://ej.bo/eventos/fit-2026"},
  {"titulo": "Feria Internacional de Turismo 2027 en La Paz", "url": "https://ej.bo/eventos/fit-2027"}
]'::jsonb) AS mas;

-- 3. SEÑALES ------------------------------------------------------------------
CREATE TEMP TABLE n AS SELECT url_doc, id FROM vigilante.raw_items;
CREATE TEMP TABLE res (paso text, r jsonb);

INSERT INTO res SELECT 'uyuni-1', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Nueva ruta turística al Salar de Uyuni', 'resumen', 'Se lanza una ruta.', 'categoria', 'eventos',
  'naturaleza', 'oportunidad', 'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/turismo/ruta-uyuni')));
-- otro medio, el mismo hecho, título reescrito: se une
INSERT INTO res SELECT 'uyuni-2', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Bolivia lanza nueva ruta turística hacia el Salar de Uyuni', 'resumen', 'Otra versión.', 'categoria', 'eventos',
  'naturaleza', 'oportunidad', 'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'otro.bo/nota/uyuni-ruta')));
-- la misma noticia otra vez con un título muy distinto: se une por la noticia
INSERT INTO res SELECT 'uyuni-3', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Oportunidad para operadores del sudoeste', 'resumen', 'Lo mismo.', 'categoria', 'eventos',
  'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/turismo/ruta-uyuni')));
-- parecidas pero distintas: otro departamento, otra cifra
INSERT INTO res SELECT 'lluvia-lp', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Alerta naranja por lluvias en La Paz', 'resumen', 'SENAMHI.', 'categoria', 'clima', 'naturaleza', 'riesgo',
  'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/clima/lluvias-lp')));
INSERT INTO res SELECT 'lluvia-cb', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Alerta naranja por lluvias en Cochabamba', 'resumen', 'SENAMHI.', 'categoria', 'clima', 'naturaleza', 'riesgo',
  'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/clima/lluvias-cbba')));
INSERT INTO res SELECT 'fit-26', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Feria Internacional de Turismo 2026 en La Paz', 'resumen', 'FIT.', 'categoria', 'eventos',
  'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/eventos/fit-2026')));
INSERT INTO res SELECT 'fit-27', vigilante.guardar_senal('orbita-bolivia', jsonb_build_object(
  'titulo', 'Feria Internacional de Turismo 2027 en La Paz', 'resumen', 'FIT.', 'categoria', 'eventos',
  'noticias', (SELECT jsonb_agg(id) FROM n WHERE url_doc = 'ej.bo/eventos/fit-2027')));

SELECT paso, r ->> 'codigo' AS codigo, r ->> 'nueva' AS nueva, r ->> 'unida_por' AS unida_por FROM res;
DO $$ BEGIN
  ASSERT (SELECT array_agg(r ->> 'codigo' ORDER BY paso) FROM res WHERE paso LIKE 'uyuni-%') = ARRAY['SEN-0001', 'SEN-0001', 'SEN-0001'],
         'las tres de Uyuni acaban en la misma señal';
  ASSERT (SELECT r ->> 'unida_por' FROM res WHERE paso = 'uyuni-2') LIKE 'título parecido%', 'uyuni-2 se une por el título';
  ASSERT (SELECT r ->> 'unida_por' FROM res WHERE paso = 'uyuni-3') = 'misma noticia', 'uyuni-3 se une por la noticia';
  ASSERT (SELECT titulo FROM vigilante.signals WHERE codigo = 'SEN-0001') = 'Nueva ruta turística al Salar de Uyuni',
         'la señal conserva su título';
  ASSERT (SELECT repetidas_unidas FROM vigilante.signals WHERE codigo = 'SEN-0001') = 2, 'cuenta las repetidas unidas';
  ASSERT (SELECT count(*) FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id WHERE s.codigo = 'SEN-0001') = 2,
         'con las dos noticias como evidencia';
  ASSERT (SELECT count(DISTINCT r ->> 'codigo') FROM res WHERE paso LIKE 'lluvia-%') = 2, 'La Paz y Cochabamba son señales distintas';
  ASSERT (SELECT count(DISTINCT r ->> 'codigo') FROM res WHERE paso LIKE 'fit-%') = 2, '2026 y 2027 son señales distintas';
END $$;

-- 4. Señales repetidas que ya existían (creadas sin pasar por guardar_senal)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad)
SELECT id, x.c, x.t, 'r', 'oportunidad', 'eventos', 'media'
  FROM vigilante.clientes, (VALUES ('V-1', 'Abren el nuevo mirador del Illimani para turistas'),
                                   ('V-2', 'Abren nuevo mirador del Illimani para los turistas'),
                                   ('V-3', 'Cierran el museo nacional de etnografía por obras')) x(c, t)
 WHERE slug = 'orbita-bolivia';
SELECT * FROM vigilante.senales_repetidas();
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM vigilante.senales_repetidas() WHERE repetida = 'V-2' AND se_queda = 'V-1') = 1, 'V-2 repite V-1';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.senales_repetidas() WHERE 'V-3' IN (se_queda, repetida)), 'V-3 no es repetida';
END $$;
SELECT vigilante.juntar_senales_repetidas() AS juntadas;
DO $$ BEGIN
  ASSERT (SELECT estado::text FROM vigilante.signals WHERE codigo = 'V-2') = 'descartada', 'la repetida queda descartada';
  ASSERT (SELECT duplicado_de FROM vigilante.signals WHERE codigo = 'V-2') = (SELECT id FROM vigilante.signals WHERE codigo = 'V-1'),
         'y apunta a la que se queda';
  ASSERT NOT EXISTS (SELECT 1 FROM vigilante.senales_repetidas()), 'ya no quedan repetidas';
END $$;

SELECT 'Prueba del 30 superada' AS resultado;
ROLLBACK;
