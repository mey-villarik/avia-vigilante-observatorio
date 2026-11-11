-- Prueba de 17_tareas_control.sql: borrado a los 6 meses y tareas que no se paran entre sí.
-- Requiere 01 a 17 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

-- R-A publicada hace 7 meses, sin plazo                → se borra
-- R-B publicada hace 7 meses, convocatoria en 10 días  → se queda (sigue viva)
-- R-C detectada hace 7 meses, en revisión              → se borra
-- R-D publicada hace 2 meses                           → se queda
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, plazo_hasta)
SELECT c, x.codigo, 'Prueba ' || x.codigo, 'Resumen', x.nat::vigilante.naturaleza_senal, 'salud', 'media', x.plazo
  FROM ids, (VALUES ('R-A', 'riesgo', NULL::timestamptz), ('R-B', 'oportunidad', now() + interval '10 days'),
                    ('R-C', 'riesgo', NULL), ('R-D', 'riesgo', NULL)) AS x(codigo, nat, plazo);

-- fechas antiguas (el disparador de updated_at se salta desactivándolo solo en la prueba)
ALTER TABLE vigilante.signals DISABLE TRIGGER USER;
UPDATE vigilante.signals SET created_at = now() - interval '7 months', updated_at = now() - interval '7 months',
       estado = CASE codigo WHEN 'R-C' THEN 'detectada' ELSE 'publicada' END::vigilante.estado_senal
 WHERE codigo IN ('R-A', 'R-B', 'R-C');
UPDATE vigilante.signals SET created_at = now() - interval '2 months', updated_at = now() - interval '2 months',
       estado = 'publicada' WHERE codigo = 'R-D';
ALTER TABLE vigilante.signals ENABLE TRIGGER USER;

-- una alerta con voto colgando de R-A (se va en cascada)
INSERT INTO vigilante.alerts (signal_id, titulo, texto, publicada_en)
SELECT id, titulo, 'Texto', now() - interval '7 months' FROM vigilante.signals WHERE codigo = 'R-A';

-- noticias: una suelta antigua (se borra) y una antigua usada por R-D (se queda)
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, titulo, content_hash, recolectado_en)
SELECT c, (SELECT min(id) FROM vigilante.sources WHERE cliente_id = c), 'https://ejemplo.bo/' || n, 'Noticia ' || n,
       md5('prueba-17-' || n), now() - interval '8 months'
  FROM ids, (VALUES ('suelta'), ('usada')) AS x(n);
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT s.id, r.id FROM vigilante.signals s, vigilante.raw_items r WHERE s.codigo = 'R-D' AND r.url = 'https://ejemplo.bo/usada';

SELECT vigilante.tarea_retencion() AS retencion;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM vigilante.signals WHERE codigo IN ('R-A', 'R-C')) THEN RAISE EXCEPTION 'R-A o R-C no se borraron'; END IF;
  IF (SELECT count(*) FROM vigilante.signals WHERE codigo IN ('R-B', 'R-D')) <> 2 THEN RAISE EXCEPTION 'Se borró R-B o R-D'; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.raw_items WHERE url = 'https://ejemplo.bo/suelta') THEN RAISE EXCEPTION 'La noticia suelta no se borró'; END IF;
  IF NOT EXISTS (SELECT 1 FROM vigilante.raw_items WHERE url = 'https://ejemplo.bo/usada') THEN RAISE EXCEPTION 'Se borró una noticia usada'; END IF;
  IF NOT EXISTS (SELECT 1 FROM vigilante.system_logs WHERE proceso = 'tareas' AND paso = 'retencion') THEN RAISE EXCEPTION 'Sin registro del borrado'; END IF;
END $$;

-- Un fallo en el resumen no para los recordatorios y queda registrado
SELECT vigilante._tarea_segura('prueba', 'SELECT 1/0') AS fallo_controlado;
SELECT vigilante.tareas_programadas() AS tareas;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vigilante.system_logs WHERE proceso = 'tareas' AND paso = 'prueba' AND nivel = 'error') THEN
    RAISE EXCEPTION 'El fallo no quedó en el registro';
  END IF;
  IF vigilante.tareas_programadas() ? 'error' THEN RAISE EXCEPTION 'tareas_programadas devolvió error'; END IF;
END $$;

SELECT * FROM vigilante.estado_tareas();

\echo PRUEBA OK
ROLLBACK;
