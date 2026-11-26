-- Prueba de 57_panel_en_cache.sql: la copia guarda lo mismo que vigilante_json() y el estado se corrige al día.
-- Requiere 01 a 57. Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;
CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, prioridad, fecha_evento_inicio, fecha_evento_fin, created_at)
SELECT c, x.cod, x.tit, 'Prueba.', 'riesgo', x.cat, x.est::vigilante.estado_senal, 'media', vigilante.hoy_bo()::timestamptz, (vigilante.hoy_bo() + 2)::timestamptz, now()
  FROM ids, (VALUES ('C-1', 'Cortes de agua en Potosí', 'economia', 'detectada'), ('C-2', 'Bloqueo en la ruta a Oruro', 'vial', 'confirmada')) x(cod, tit, cat, est);

SELECT vigilante.refrescar_panel((SELECT c FROM ids));
DO $$
DECLARE c uuid := (SELECT c FROM ids); j jsonb; n_vivo int; n_copia int;
BEGIN
  SELECT jsonb_array_length(vigilante.vigilante_json('orbita-bolivia') -> 'senales') INTO n_vivo;
  SELECT jsonb_array_length(datos -> 'senales') INTO n_copia FROM vigilante.panel_cache WHERE cliente_id = c;
  IF n_vivo <> n_copia OR n_copia < 2 THEN RAISE EXCEPTION 'copia % señales, vivo %', n_copia, n_vivo; END IF;

  UPDATE vigilante.signals SET estado = 'descartada' WHERE cliente_id = c AND codigo = 'C-1';
  UPDATE vigilante.signals SET estado = 'cerrada' WHERE cliente_id = c AND codigo = 'C-2';
  SELECT vigilante._estado_al_dia(datos, c) INTO j FROM vigilante.panel_cache WHERE cliente_id = c;
  IF (SELECT x ->> 'estado' FROM jsonb_array_elements(j -> 'senales') x WHERE x ->> 'id' = 'C-1') <> 'descartada' THEN
    RAISE EXCEPTION 'C-1 no lleva el estado al día'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'senales') x WHERE x ->> 'id' = 'C-2') THEN
    RAISE EXCEPTION 'C-2 cerrada sigue en el panel'; END IF;
  IF j -> 'direccion' IS NULL THEN RAISE EXCEPTION 'falta direccion en la copia'; END IF;
  RAISE NOTICE 'OK 57: copia = vivo (% señales), estado al día, cerradas fuera', n_copia;
END $$;
ROLLBACK;
