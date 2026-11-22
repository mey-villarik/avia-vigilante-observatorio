-- Prueba de 50_seguimiento_recomendaciones.sql: estados pendiente / en curso / resuelta / sin efecto,
-- nota obligatoria al cerrar, solo analista o administrador, recomendación guardada y resumen.
-- Requiere 01 a 50 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT c, x.a::uuid, x.n, x.r::vigilante.rol_usuario FROM ids, (VALUES
  ('50000000-0000-0000-0000-0000000000a1', 'Lía Analista', 'analista'),
  ('50000000-0000-0000-0000-0000000000a2', 'Vico Visor',   'visor')) AS x(a, n, r);

-- R-1 derrumbe (riesgo alto)          → pesa: sale pendiente sin que nadie lo toque
-- R-2 corte de agua (riesgo medio)    → pesa; se pasa a en curso y luego a resuelta
-- R-3 fondo sin fecha cercana          → no pesa: no sale en el resumen mientras siga pendiente
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, prioridad, plazo_hasta)
SELECT c, x.cod, x.tit, x.res, x.nat::vigilante.naturaleza_senal, x.cat, 'confirmada', x.pri::vigilante.prioridad,
       CASE WHEN x.cierre IS NULL THEN NULL ELSE ((vigilante.hoy_bo() + x.cierre)::text || 'T23:59:59-04:00')::timestamptz END
  FROM ids, (VALUES
  ('R-1', 'Derrumbe cierra la carretera a los Yungas', 'Derrumbe en el kilómetro 40.', 'riesgo', 'vial', 'alta', NULL::int),
  ('R-2', 'Cortes de agua potable en el centro de Sucre', 'Cortes por obras.', 'riesgo', 'economia', 'media', NULL),
  ('R-3', 'Fondo para emprendimientos', 'Convocatoria general.', 'oportunidad', 'financiamiento', 'baja', 60)
  ) x(cod, tit, res, nat, cat, pri, cierre);

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); r jsonb; j jsonb; ok boolean;
BEGIN
  -- sin fila: pendiente
  IF vigilante.seguimiento_senal((SELECT id FROM vigilante.signals WHERE codigo = 'R-2')) ->> 'estado' <> 'pendiente' THEN
    RAISE EXCEPTION 'sin fila debe ser pendiente'; END IF;

  -- el visor no puede
  PERFORM set_config('request.jwt.claim.sub', '50000000-0000-0000-0000-0000000000a2', true);
  ok := false;
  BEGIN PERFORM vigilante.seguir_recomendacion('R-2', 'en_curso', NULL);
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE 'Solo un analista%'; END;
  IF NOT ok THEN RAISE EXCEPTION 'el visor no debe poder cambiar el seguimiento'; END IF;

  -- el analista sí
  PERFORM set_config('request.jwt.claim.sub', '50000000-0000-0000-0000-0000000000a1', true);
  r := vigilante.seguir_recomendacion('R-2', 'en_curso', 'Llamamos a ELAPAS');
  IF r ->> 'estado' <> 'en_curso' OR r ->> 'quien' <> 'Lía Analista' OR r ->> 'recomendacion' IS NULL THEN
    RAISE EXCEPTION 'en curso mal guardado: %', r; END IF;

  -- cerrar sin nota no
  ok := false;
  BEGIN PERFORM vigilante.seguir_recomendacion('R-2', 'resuelta', '  ');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE 'Para cerrar%'; END;
  IF NOT ok THEN RAISE EXCEPTION 'resuelta sin nota debe fallar'; END IF;

  ok := false;
  BEGIN PERFORM vigilante.seguir_recomendacion('R-2', 'archivada', 'x');
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE 'Estado no válido%'; END;
  IF NOT ok THEN RAISE EXCEPTION 'estado inventado debe fallar'; END IF;

  r := vigilante.seguir_recomendacion('R-2', 'resuelta', 'Se avisó a los hoteles del centro; el agua volvió el martes');
  IF r ->> 'estado' <> 'resuelta' OR jsonb_array_length(r -> 'historial') <> 2
     OR r -> 'historial' -> 0 ->> 'de' <> 'en_curso' THEN
    RAISE EXCEPTION 'resuelta mal guardada: %', r; END IF;

  -- si AVIA cambia la recomendación, se avisa
  UPDATE vigilante.seguimiento_recomendaciones SET recomendacion = 'Otra cosa'
   WHERE signal_id = (SELECT id FROM vigilante.signals WHERE codigo = 'R-2');
  IF NOT coalesce((vigilante.seguimiento_senal((SELECT id FROM vigilante.signals WHERE codigo = 'R-2')) ->> 'cambio_reco')::boolean, false) THEN
    RAISE EXCEPTION 'debe avisar de que la recomendación cambió'; END IF;

  -- otro cliente: la señal no existe para este usuario
  ok := false;
  BEGIN PERFORM vigilante.seguir_recomendacion('NO-EXISTE', 'en_curso', NULL);
  EXCEPTION WHEN OTHERS THEN ok := SQLERRM LIKE 'La señal%'; END;
  IF NOT ok THEN RAISE EXCEPTION 'señal desconocida debe fallar'; END IF;

  -- resumen: R-1 pendiente (pesa), R-2 resuelta, R-3 no sale
  j := vigilante.seguimiento_resumen(v_c);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'items') x WHERE x ->> 'codigo' = 'R-1' AND x ->> 'estado' = 'pendiente') THEN
    RAISE EXCEPTION 'R-1 debe salir pendiente: %', j; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'items') x WHERE x ->> 'codigo' = 'R-2' AND x ->> 'estado' = 'resuelta' AND x ->> 'nota' LIKE 'Se avisó%') THEN
    RAISE EXCEPTION 'R-2 debe salir resuelta con su nota: %', j; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'items') x WHERE x ->> 'codigo' = 'R-3') THEN
    RAISE EXCEPTION 'R-3 no pesa y no debe salir: %', j; END IF;
  IF (j ->> 'resuelta')::int < 1 THEN RAISE EXCEPTION 'falta contar la resuelta: %', j; END IF;

  -- vigilante_bd: cada señal con su seguimiento y el resumen arriba
  j := vigilante._con_seguimiento(jsonb_build_object('senales', jsonb_build_array(jsonb_build_object('id', 'R-2'), jsonb_build_object('id', 'X-9'))), v_c);
  IF j -> 'senales' -> 0 -> 'seguimiento' ->> 'estado' <> 'resuelta' OR j -> 'senales' -> 1 ? 'seguimiento' OR NOT j ? 'seguimiento' THEN
    RAISE EXCEPTION '_con_seguimiento mal: %', j; END IF;
END $$;

SELECT x ->> 'codigo' AS codigo, x ->> 'estado' AS estado, left(x ->> 'recomendacion', 60) AS recomendacion, x ->> 'nota' AS nota
  FROM ids, jsonb_array_elements(vigilante.seguimiento_resumen(ids.c) -> 'items') x;

ROLLBACK;
