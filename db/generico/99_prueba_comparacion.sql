-- Prueba de 27_comparacion_dia.sql: qué cambió desde ayer (nuevas, sube/baja certeza, resueltas).
-- Requiere 01 a 27 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
DELETE FROM vigilante.certeza_registro WHERE cliente_id = (SELECT c FROM ids);
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{vial}', 'rss' FROM ids,
  (VALUES ('c-ofi', 'Oficial de prueba', 'oficial', 'https://abc.gob.bo'), ('c-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);

--  C-1 creada hace 2 h                                  → nueva
--  C-2 ayer «posible», hoy fuente oficial (confirmado)  → subió
--  C-3 ayer «confirmado», hoy una sola fuente (posible) → bajó
--  C-4 ayer «posible», hoy «posible»                    → sin cambio
--  C-5 descartada hace 2 h                              → resuelta
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado, created_at)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', 'riesgo', 'vial', 'media', 'detectada', now() - x.edad
  FROM ids, (VALUES ('C-1', interval '2 hours'), ('C-2', interval '3 days'), ('C-3', interval '3 days'),
                    ('C-4', interval '3 days'), ('C-5', interval '3 days')) x(cod, edad);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/' || g, 'h-comp-' || g, 'Noticia ' || g, now() - interval '1 hour'
  FROM ids, (VALUES ('C-1', 'c-pre'), ('C-2', 'c-ofi'), ('C-3', 'c-pre'), ('C-4', 'c-pre'), ('C-5', 'c-pre')) x(g, f)
  JOIN vigilante.sources s ON s.codigo = x.f;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-comp-' || g.codigo;

-- lo que se registró ayer (hace 30 h)
INSERT INTO vigilante.certeza_registro (signal_id, cliente_id, nivel, desde)
SELECT g.id, g.cliente_id, x.nivel, now() - interval '30 hours'
  FROM vigilante.signals g JOIN (VALUES ('C-2', 'posible'), ('C-3', 'confirmado'), ('C-4', 'posible'), ('C-5', 'posible')) x(cod, nivel)
    ON x.cod = g.codigo;

UPDATE vigilante.signals SET estado = 'descartada' WHERE codigo = 'C-5';
UPDATE vigilante.signal_history SET created_at = now() - interval '2 hours'
 WHERE signal_id = (SELECT id FROM vigilante.signals WHERE codigo = 'C-5') AND estado_nuevo = 'descartada';

SELECT jsonb_pretty(vigilante.comparacion_dia(c)) FROM ids;

DO $$
DECLARE r jsonb; v_c uuid; n int;
BEGIN
  SELECT c INTO v_c FROM ids;
  r := vigilante.comparacion_dia(v_c);
  IF NOT (r ->> 'comparable')::boolean THEN RAISE EXCEPTION 'con registro de hace 30 h debe ser comparable: %', r; END IF;
  IF r -> 'conteos' <> '{"nuevas": 1, "subieron": 1, "bajaron": 1, "resueltas": 1}' THEN RAISE EXCEPTION 'conteos: %', r -> 'conteos'; END IF;
  IF r #>> '{senales_nuevas,0,codigo}' <> 'C-1' THEN RAISE EXCEPTION 'nueva: %', r -> 'senales_nuevas'; END IF;
  IF r #> '{subieron_certeza,0}' <> '{"codigo": "C-2", "titulo": "Señal C-2", "antes": "posible", "ahora": "confirmado"}' THEN
    RAISE EXCEPTION 'subió: %', r -> 'subieron_certeza'; END IF;
  IF r #>> '{bajaron_certeza,0,codigo}' <> 'C-3' OR r #>> '{bajaron_certeza,0,ahora}' <> 'posible' THEN RAISE EXCEPTION 'bajó: %', r -> 'bajaron_certeza'; END IF;
  IF r #>> '{resueltas,0,codigo}' <> 'C-5' OR r #>> '{resueltas,0,como}' <> 'descartada' THEN RAISE EXCEPTION 'resuelta: %', r -> 'resueltas'; END IF;
  IF vigilante._vigilante_json(v_c) #> '{comparacion_dia,conteos}' <> r -> 'conteos' THEN RAISE EXCEPTION 'vigilante.json no lleva comparacion_dia'; END IF;

  -- el registro: solo añade cuando cambia (C-1 nueva, C-2 y C-3 cambiaron; C-4 igual; C-5 descartada no)
  n := vigilante.registrar_certezas(v_c);
  IF n <> 3 THEN RAISE EXCEPTION 'registrar_certezas añadió % filas (esperaba 3)', n; END IF;
  IF vigilante.registrar_certezas(v_c) <> 0 THEN RAISE EXCEPTION 'la segunda vez no debe añadir nada'; END IF;

  -- sin historial de 24 h: no se compara la certeza y se dice
  DELETE FROM vigilante.certeza_registro WHERE cliente_id = v_c AND desde < now() - interval '1 hour';
  r := vigilante.comparacion_dia(v_c);
  IF (r ->> 'comparable')::boolean OR (r #>> '{conteos,subieron}')::int + (r #>> '{conteos,bajaron}')::int <> 0 THEN
    RAISE EXCEPTION 'sin 24 h de historial no se puede comparar: %', r; END IF;
  RAISE NOTICE 'Prueba de comparación con ayer: OK';
END $$;

ROLLBACK;
