-- Prueba de 48_plazo_absoluto.sql: la fecha de cierre es fija, los días se cuentan al consultar
-- (igual en panel, web pública, síntesis y Hermes) y la certeza del plazo va aparte de la del evento.
-- Requiere 01 a 48 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{financiamiento}', 'rss' FROM ids,
  (VALUES ('p-ofi', 'Ministerio de prueba', 'oficial', 'https://min-prueba.gob.bo'),
          ('p-pre', 'Diario de prueba', 'medio', 'https://diario-prueba.bo')) x(cod, nom, tipo, url);
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT c, '48000000-0000-0000-0000-00000000000a', 'Ana Analista', 'analista' FROM ids;

--  P-1 «IWT»: la fecha la da el ministerio tal cual           → confirmado, 8 días
--  P-2 la fecha la da un diario                               → pendiente de verificar
--  P-3 el ministerio dice «quedan 5 días»: AVIA la calcula    → pendiente de verificar
--  P-4 antigua: «Quedan 12 días» en el resumen y sin fecha    → reparar_plazos_relativos la fija (calculada)
--  P-5 cierra hoy                                             → 0 días, «cierra hoy»
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, plazo_hasta, created_at)
SELECT c, x.cod, 'Convocatoria ' || x.cod, x.res, 'oportunidad', 'financiamiento', 'confirmada',
       CASE WHEN x.d IS NULL THEN NULL ELSE ((vigilante.hoy_bo() + x.d)::text || 'T23:59:59-04:00')::timestamptz END,
       now() - interval '3 days'
  FROM ids, (VALUES
  ('P-1', 'Fondos IWT para emprendimientos', 8),
  ('P-2', 'Feria con inscripción abierta', 8),
  ('P-3', 'Concurso de rutas', 5),
  ('P-4', 'Quedan 12 días para postular al fondo de turismo comunitario', NULL::int),
  ('P-5', 'Último día para inscribirse', 0)) x(cod, res, d);

-- noticias: la de P-4 se publicó hace 3 días
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, publicado_en)
SELECT c, s.id, s.url || '/' || x.g, 'h-plazo-' || x.g, 'Noticia ' || x.g, x.pub
  FROM ids, (VALUES ('P-1', 'p-ofi', now() - interval '1 day'), ('P-2', 'p-pre', now() - interval '1 day'),
                    ('P-3', 'p-ofi', now() - interval '1 day'), ('P-4', 'p-pre', now() - interval '3 days'),
                    ('P-5', 'p-ofi', now() - interval '1 day')) x(g, f, pub)
  JOIN vigilante.sources s ON s.codigo = x.f;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
SELECT g.id, r.id, g.cliente_id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-plazo-' || g.codigo;

-- lo que guardaría el clasificador (el disparador se activa al poner signal_id, como en guardar_clasificacion)
INSERT INTO vigilante.analisis (cliente_id, raw_item_id, version, tipo, salida, relevante)
SELECT g.cliente_id, r.id, r.version, 'clasificacion', jsonb_build_object(
         'clave', r.id, 'relevante', true,
         'plazo_hasta', to_char(vigilante.dia_bo(g.plazo_hasta), 'YYYY-MM-DD'),
         'plazo_origen', CASE g.codigo WHEN 'P-3' THEN 'calculado' ELSE 'texto' END,
         'plazo_cita', CASE g.codigo WHEN 'P-3' THEN 'quedan 5 días' ELSE 'hasta el ' || to_char(vigilante.dia_bo(g.plazo_hasta), 'DD/MM') END),
       true
  FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-plazo-' || g.codigo
 WHERE g.codigo IN ('P-1', 'P-2', 'P-3', 'P-5');
UPDATE vigilante.analisis a SET signal_id = sr.signal_id
  FROM vigilante.signal_raw_items sr JOIN vigilante.signals g ON g.id = sr.signal_id
 WHERE sr.raw_item_id = a.raw_item_id AND g.codigo LIKE 'P-_';

SELECT codigo, vigilante.cierre(id) FROM vigilante.signals WHERE codigo LIKE 'P-_' ORDER BY 1;

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); r jsonb; j jsonb; x jsonb; v_hoy date := vigilante.hoy_bo();
BEGIN
  -- CP1: días = fecha de cierre − hoy (Bolivia), y la fecha guardada es una fecha
  r := vigilante.cierre((SELECT id FROM vigilante.signals WHERE codigo = 'P-1'));
  IF (r ->> 'dias_restantes')::int <> 8 THEN RAISE EXCEPTION 'P-1 debía dar 8 días: %', r; END IF;
  IF r ->> 'fecha' <> to_char(v_hoy + 8, 'YYYY-MM-DD') THEN RAISE EXCEPTION 'P-1 fecha mal: %', r; END IF;
  IF r ->> 'texto' <> 'cierra el ' || to_char(v_hoy + 8, 'DD/MM/YYYY') || ', en 8 días' THEN RAISE EXCEPTION 'P-1 texto mal: %', r; END IF;
  IF vigilante.dias_para((SELECT plazo_hasta FROM vigilante.signals WHERE codigo = 'P-1')) <> 8 THEN
    RAISE EXCEPTION 'dias_para debe coincidir con cierre (antes sumaba un día)'; END IF;
  r := vigilante.cierre((SELECT id FROM vigilante.signals WHERE codigo = 'P-5'));
  IF (r ->> 'dias_restantes')::int <> 0 OR r ->> 'texto' NOT LIKE 'cierra hoy%' THEN RAISE EXCEPTION 'P-5 cierra hoy: %', r; END IF;

  -- vigilante.json: fecha_limite en Bolivia (antes UTC, un día de más) y el mismo cierre
  j := vigilante._vigilante_json(v_c);
  SELECT e INTO x FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'id' = 'P-1';
  IF x ->> 'fecha_limite' <> to_char(v_hoy + 8, 'YYYY-MM-DD') THEN RAISE EXCEPTION 'fecha_limite con desfase: %', x ->> 'fecha_limite'; END IF;
  IF (x #>> '{cierre,dias_restantes}')::int <> 8 THEN RAISE EXCEPTION 'vigilante.json sin cierre: %', x -> 'cierre'; END IF;

  -- CP2: certeza del plazo aparte de la del evento (las cinco están confirmadas como señal)
  IF vigilante.certeza_plazo((SELECT id FROM vigilante.signals WHERE codigo = 'P-1')) ->> 'nivel' <> 'confirmado' THEN
    RAISE EXCEPTION 'P-1 (fecha del ministerio) debía ser confirmado'; END IF;
  IF vigilante.certeza_plazo((SELECT id FROM vigilante.signals WHERE codigo = 'P-2')) ->> 'nivel' <> 'pendiente de verificar' THEN
    RAISE EXCEPTION 'P-2 (fecha de un diario) debía estar pendiente de verificar'; END IF;
  r := vigilante.certeza_plazo((SELECT id FROM vigilante.signals WHERE codigo = 'P-3'));
  IF r ->> 'nivel' <> 'pendiente de verificar' OR r ->> 'origen' <> 'calculado' OR r ->> 'motivo' NOT LIKE '%quedan 5 días%' THEN
    RAISE EXCEPTION 'P-3 (calculada) debía estar pendiente de verificar: %', r; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.signals s WHERE s.codigo IN ('P-2', 'P-3')
               AND vigilante.certeza(s.id) ->> 'nivel' <> 'confirmado') THEN
    RAISE EXCEPTION 'la certeza del EVENTO no debe cambiar con el 48'; END IF;

  -- un diario que repite la misma fecha no baja un plazo que dio el ministerio
  INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
  SELECT v_c, id, url || '/rep', 'h-plazo-rep', 'Repetición' FROM vigilante.sources WHERE codigo = 'p-pre';
  INSERT INTO vigilante.analisis (cliente_id, raw_item_id, version, tipo, salida, relevante)
  SELECT v_c, r2.id, r2.version, 'clasificacion',
         jsonb_build_object('clave', r2.id, 'plazo_hasta', to_char(v_hoy + 8, 'YYYY-MM-DD'), 'plazo_origen', 'texto'), true
    FROM vigilante.raw_items r2 WHERE r2.content_hash = 'h-plazo-rep';
  UPDATE vigilante.analisis SET signal_id = (SELECT id FROM vigilante.signals WHERE codigo = 'P-1')
   WHERE raw_item_id = (SELECT id FROM vigilante.raw_items WHERE content_hash = 'h-plazo-rep');
  IF vigilante.certeza_plazo((SELECT id FROM vigilante.signals WHERE codigo = 'P-1')) ->> 'nivel' <> 'confirmado' THEN
    RAISE EXCEPTION 'un diario que repite la fecha no debe bajar el plazo del ministerio'; END IF;

  -- una persona comprueba la fecha de P-2
  PERFORM set_config('request.jwt.claim.sub', '48000000-0000-0000-0000-00000000000a', true);
  r := vigilante.verificar_plazo('P-2', v_hoy + 8, 'llamada a la organizadora');
  IF r ->> 'certeza' <> 'confirmado' OR r ->> 'motivo' NOT LIKE '%Ana Analista%' THEN RAISE EXCEPTION 'verificar_plazo: %', r; END IF;
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- señales viejas con «quedan N días»: primero solo la lista, luego se guarda la fecha
  r := vigilante.reparar_plazos_relativos(false);
  IF (r ->> 'senales')::int <> 1 OR r #>> '{detalle,0,codigo}' <> 'P-4' THEN RAISE EXCEPTION 'reparar (sin aplicar): %', r; END IF;
  IF (SELECT plazo_hasta FROM vigilante.signals WHERE codigo = 'P-4') IS NOT NULL THEN RAISE EXCEPTION 'sin aplicar no debe cambiar nada'; END IF;
  PERFORM vigilante.reparar_plazos_relativos(true);
  r := vigilante.cierre((SELECT id FROM vigilante.signals WHERE codigo = 'P-4'));
  IF (r ->> 'dias_restantes')::int <> 9 OR r ->> 'certeza' <> 'pendiente de verificar' THEN
    RAISE EXCEPTION 'P-4: publicada hace 3 días + 12 = 9 días y pendiente de verificar: %', r; END IF;

  -- síntesis: la línea de plazo lleva fecha y, si toca, «pendiente de verificar»
  SELECT e INTO x FROM jsonb_array_elements(vigilante.sintesis_dia(v_c) -> 'que_vigilar') e WHERE e ->> 'codigo' = 'P-3';
  IF x IS NOT NULL AND (x ->> 'texto' NOT LIKE '%en 5 días%' OR x ->> 'texto' NOT LIKE '%pendiente de verificar%') THEN
    RAISE EXCEPTION 'síntesis P-3: %', x; END IF;

  -- Hermes: métricas con la misma cuenta
  SELECT e INTO x FROM jsonb_array_elements(vigilante.metricas_oportunidades('orbita-bolivia') -> 'oportunidades_vigentes') e
   WHERE e ->> 'codigo' = 'P-1';
  IF (x ->> 'dias_plazo')::int <> 8 OR x ->> 'certeza_plazo' <> 'confirmado' THEN RAISE EXCEPTION 'métricas P-1: %', x; END IF;

  RAISE WARNING 'OK: plazos con fecha fija, días al consultar y certeza del plazo aparte';
END $$;

ROLLBACK;
