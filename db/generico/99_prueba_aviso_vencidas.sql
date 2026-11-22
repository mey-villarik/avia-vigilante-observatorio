-- Prueba de 45_aviso_revisiones_vencidas.sql: el aviso va aparte, cuenta solo las que siguen sin
-- decidir y dice quién responde. Requiere 01 a 45 (y 02 con el cliente orbita-bolivia).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

--  V-1 y V-2 esperan revisión y ya vencieron         → cuentan
--  V-3 vencida pero ya confirmada (decidida tarde)   → no cuenta
--  V-4 sin vencer                                    → no cuenta
-- (el 29 pone requiere_revision en false: el aviso no depende de él)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado,
                               revision_vencida_en, created_at)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', 'riesgo', 'clima', 'alta', x.est::vigilante.estado_senal,
       x.venc, now() - interval '3 hours'
  FROM ids, (VALUES
  ('V-1', 'detectada', now() - interval '2 hours'),
  ('V-2', 'en_analisis', now() - interval '1 hour'),
  ('V-3', 'confirmada', now() - interval '2 hours'),
  ('V-4', 'detectada', NULL::timestamptz)) x(cod, est, venc);

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); s jsonb; r jsonb;
BEGIN
  -- Sin analistas ni responsable asignado
  DELETE FROM vigilante.parametros WHERE cliente_id = v_c AND clave = 'responsable_revision';
  UPDATE vigilante.users SET activo = false WHERE cliente_id = v_c AND rol = 'analista';
  s := vigilante.sintesis_dia(v_c);
  r := s -> 'revisiones_vencidas';
  IF (r ->> 'total')::int <> 2 THEN RAISE EXCEPTION 'esperaba 2 vencidas, hay %', r ->> 'total'; END IF;
  IF r -> 'senales' -> 0 ->> 'codigo' <> 'V-1' THEN RAISE EXCEPTION 'la más antigua va primero: %', r -> 'senales'; END IF;
  IF r ->> 'responsable' IS NOT NULL THEN RAISE EXCEPTION 'sin analistas no hay responsable: %', r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(s -> 'que_vigilar') e WHERE e ->> 'tipo' = 'revision_vencida') THEN
    RAISE EXCEPTION 'las vencidas no se repiten en «qué vigilar»'; END IF;
  IF s -> 'que_pasa' IS NULL OR s ->> 'totales' IS NULL THEN RAISE EXCEPTION 'faltan bloques de la síntesis'; END IF;

  -- Con analistas activos
  INSERT INTO vigilante.users (cliente_id, nombre, email, rol) VALUES
    (v_c, 'Ana Prueba', 'ana.prueba@ejemplo.bo', 'analista'), (v_c, 'Beto Prueba', 'beto.prueba@ejemplo.bo', 'analista');
  r := vigilante.sintesis_dia(v_c) -> 'revisiones_vencidas';
  IF r ->> 'responsable' <> 'Ana Prueba, Beto Prueba' OR r ->> 'responsable_origen' <> 'analistas' THEN
    RAISE EXCEPTION 'responsable por analistas mal: %', r; END IF;

  -- Con responsable asignado
  INSERT INTO vigilante.parametros (cliente_id, clave, valor) VALUES (v_c, 'responsable_revision', to_jsonb('Carla Jefa'::text));
  r := vigilante.sintesis_dia(v_c) -> 'revisiones_vencidas';
  IF r ->> 'responsable' <> 'Carla Jefa' OR r ->> 'responsable_origen' <> 'asignado' THEN
    RAISE EXCEPTION 'responsable asignado mal: %', r; END IF;

  -- vigilante.json lo lleva
  IF (vigilante._vigilante_json(v_c) #>> '{sintesis_dia,revisiones_vencidas,total}')::int <> 2 THEN
    RAISE EXCEPTION 'vigilante.json no lleva revisiones_vencidas'; END IF;
  RAISE WARNING 'OK: aviso de revisiones vencidas';
END $$;

ROLLBACK;
