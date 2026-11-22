-- Prueba de 46_pulso_evolucion.sql: el Pulso de hace 7 y 30 días se reconstruye con el estado que
-- tenían las señales ese día, el registro diario no se pisa y vigilante.json lo lleva.
-- Requiere 01 a 46 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
DELETE FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids);
DELETE FROM vigilante.pulso_registro WHERE cliente_id = (SELECT c FROM ids);

--  P-R1 riesgo alto, creado hace 10 días, detectado → confirmado hace 3 días, plazo dentro de 5 días
--  P-R2 riesgo medio, creado hace 20 días, el evento terminó hace 3 días (hoy ya no cuenta; hace 7, sí)
--  P-O1 oportunidad creada hace 2 días (relevancia 8, novedad 6): solo hoy
--  P-X1 riesgo descartado hace 1 día: hace 7 días contaba, hoy no
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado,
                               requiere_revision, plazo_hasta, fecha_evento_inicio, fecha_evento_fin, salida_modelo, created_at)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', x.nat::vigilante.naturaleza_senal, 'clima', x.prio::vigilante.prioridad,
       x.est::vigilante.estado_senal, false, x.plazo, x.ini, x.fin, x.sm, now() - x.edad
  FROM ids, (VALUES
  ('P-R1', 'riesgo', 'alta', 'confirmada', now() + interval '5 days', NULL::timestamptz, NULL::timestamptz, NULL::jsonb, interval '10 days'),
  ('P-R2', 'riesgo', 'media', 'detectada', NULL, now() - interval '20 days', now() - interval '3 days', NULL, interval '20 days'),
  ('P-O1', 'oportunidad', 'media', 'detectada', now() + interval '10 days', NULL, NULL, '{"relevancia": 8, "novedad": 6}', interval '2 days'),
  ('P-X1', 'riesgo', 'alta', 'descartada', now() + interval '9 days', NULL, NULL, NULL, interval '12 days')
  ) x(cod, nat, prio, est, plazo, ini, fin, sm, edad);

-- historial de estados con fechas pasadas
INSERT INTO vigilante.signal_history (signal_id, cliente_id, entidad, estado_anterior, estado_nuevo, created_at)
SELECT s.id, s.cliente_id, 'signal', x.antes::vigilante.estado_senal, x.despues::vigilante.estado_senal, now() - x.hace
  FROM vigilante.signals s JOIN (VALUES
    ('P-R1', 'detectada', 'confirmada', interval '3 days'),
    ('P-X1', 'detectada', 'descartada', interval '1 day')) x(cod, antes, despues, hace) ON x.cod = s.codigo
 WHERE s.cliente_id = (SELECT c FROM ids);

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); e jsonb; h7 jsonb; f1 numeric; f2 numeric; fx numeric; fo numeric; esp int;
  fia CONSTANT text := 'SELECT least(100, greatest(0, coalesce((vigilante.puntuaciones(id) -> ''fiabilidad'' ->> ''valor'')::numeric, 0))) FROM vigilante.signals WHERE codigo = $1';
BEGIN
  EXECUTE fia INTO f1 USING 'P-R1';
  EXECUTE fia INTO f2 USING 'P-R2';
  EXECUTE fia INTO fx USING 'P-X1';
  EXECUTE fia INTO fo USING 'P-O1';
  e := vigilante.pulso_evolucion(v_c);

  -- Hoy: solo P-R1 (alta × respaldo × confirmada 1) y P-O1
  esp := round(100 * (1 * (0.5 + 0.5 * f1 / 100) * 1) / (1 + 2));
  IF (e #>> '{hoy,riesgo}')::int <> esp THEN RAISE EXCEPTION 'riesgo de hoy: esperaba %, hay %', esp, e -> 'hoy'; END IF;
  IF (e #>> '{hoy,riesgos}')::int <> 1 OR (e #>> '{hoy,oportunidades}')::int <> 1 THEN RAISE EXCEPTION 'hoy cuenta mal: %', e -> 'hoy'; END IF;
  esp := round(100 * (least(1, (8 * 0.45 + 6 * 0.25 + fo / 100 * 10 * 0.3) / 10) * 0.7) / (1 + 2));
  IF (e #>> '{hoy,oportunidad}')::int <> esp THEN RAISE EXCEPTION 'oportunidad de hoy: esperaba %, hay %', esp, e -> 'hoy'; END IF;
  IF e #>> '{hoy,vigilancia}' NOT IN ('Vigilancia', 'Atención', 'Crítico') THEN
    RAISE EXCEPTION 'un riesgo alto confirmado da al menos Vigilancia: %', e -> 'hoy'; END IF;

  -- Hace 7 días: P-R1 aún detectada (0,7), P-R2 vigente (media 0,5 × 0,7), P-X1 aún no descartada (alta × 0,7); P-O1 no existía
  h7 := e -> 'hace_7';
  IF h7 IS NULL THEN RAISE EXCEPTION 'falta hace_7'; END IF;
  IF (h7 ->> 'riesgos')::int <> 3 OR (h7 ->> 'oportunidades')::int <> 0 THEN RAISE EXCEPTION 'hace 7 días cuenta mal: %', h7; END IF;
  esp := round(100 * ((0.5 + 0.5 * f1 / 100) * 0.7 + 0.5 * (0.5 + 0.5 * f2 / 100) * 0.7 + (0.5 + 0.5 * fx / 100) * 0.7) / (3 + 2));
  IF (h7 ->> 'riesgo')::int <> esp THEN RAISE EXCEPTION 'riesgo de hace 7 días: esperaba %, hay %', esp, h7; END IF;
  IF h7 ->> 'vigilancia' IS NULL OR (h7 ->> 'oportunidad')::int <> 0 THEN RAISE EXCEPTION 'hace 7 días: %', h7; END IF;
  IF NOT (h7 ->> 'reconstruido')::boolean THEN RAISE EXCEPTION 'hace 7 días debe ir marcado como reconstruido: %', h7; END IF;

  -- Hace 30 días: no había ninguna señal → sin datos (no un 0 inventado)
  IF e -> 'hace_30' <> 'null'::jsonb AND e -> 'hace_30' IS NOT NULL THEN RAISE EXCEPTION 'hace 30 días debería ir vacío: %', e -> 'hace_30'; END IF;
  IF (e ->> 'desde')::date <> ((now() - interval '20 days') AT TIME ZONE 'America/La_Paz')::date THEN RAISE EXCEPTION 'desde mal: %', e ->> 'desde'; END IF;

  -- Reconstrucción: 20 días anteriores (desde la primera señal hasta ayer), sin pisar lo registrado
  PERFORM vigilante.registrar_pulso(v_c);
  IF vigilante.reconstruir_pulso(v_c, 30) <> 20 THEN RAISE EXCEPTION 'esperaba 20 días reconstruidos, hay %',
       (SELECT count(*) FROM vigilante.pulso_registro WHERE cliente_id = v_c AND reconstruido); END IF;
  IF vigilante.reconstruir_pulso(v_c, 30) <> 0 THEN RAISE EXCEPTION 'la segunda vez no debe añadir nada'; END IF;
  e := vigilante.pulso_evolucion(v_c);
  IF (e -> 'hace_7') - 'activas' <> h7 - 'activas' THEN RAISE EXCEPTION 'la fila guardada no coincide con el cálculo: % vs %', e -> 'hace_7', h7; END IF;
  IF jsonb_array_length(e -> 'serie') <> 21 THEN RAISE EXCEPTION 'la serie debería tener 21 días: %', jsonb_array_length(e -> 'serie'); END IF;
  IF (e ->> 'registro_desde')::date <> (now() AT TIME ZONE 'America/La_Paz')::date THEN RAISE EXCEPTION 'registro_desde mal: %', e ->> 'registro_desde'; END IF;

  -- La fila de hoy se actualiza (no se duplica) y deja de ser reconstruida
  PERFORM vigilante.registrar_pulso(v_c);
  IF (SELECT count(*) FROM vigilante.pulso_registro WHERE cliente_id = v_c AND dia = (now() AT TIME ZONE 'America/La_Paz')::date AND NOT reconstruido) <> 1 THEN
    RAISE EXCEPTION 'la fila de hoy está mal'; END IF;

  -- vigilante.json lo lleva
  IF vigilante._vigilante_json(v_c) #> '{pulso_evolucion,hace_7,riesgo}' IS NULL THEN RAISE EXCEPTION 'vigilante.json no lleva pulso_evolucion'; END IF;
  RAISE WARNING 'OK: evolución del Pulso a 7 y 30 días';
END $$;

ROLLBACK;
