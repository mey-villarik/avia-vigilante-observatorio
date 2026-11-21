-- Prueba de 21_contadores_unicos.sql: panel y AVIA cuentan lo mismo.
-- Requiere 01 a 21 (y 02 con el cliente orbita-bolivia); con el 39 comprueba también el desglose de
-- verificadas y las fuentes activas; con el 40, la regla única de «Verificada». Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- empezar sin señales del cliente para que los números sean exactos
DELETE FROM vigilante.signals WHERE cliente_id = (SELECT c FROM ids);

--  C-1 oportunidad detectada, plazo en 5 días           → activa, oportunidad, plazo corto, por verificar
--  C-2 oportunidad confirmada con 2 noticias, plazo 40 d → activa, verificada con 2 fuentes
--  C-3 riesgo alta publicada                             → activa, riesgo alto, verificada, alerta publicada
--  C-4 mixta en análisis que requiere revisión           → activa, mixta, por verificar, espera aprobación
--  C-5 riesgo descartado                                 → visible (columna Descartada) pero no activa
--  C-6 riesgo cerrado                                    → no visible (antes llegaba al panel como «detectada»)
--  C-7 oportunidad cuya ficha venció ayer               → no visible
--  C-8 oportunidad sin fechas, última noticia hace 3 días → no visible (caducada)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado,
                               fuente_oficial, plazo_hasta, created_at)
SELECT c, x.codigo, 'Señal ' || x.codigo, 'Resumen ' || x.codigo, x.nat::vigilante.naturaleza_senal, x.cat,
       x.prio::vigilante.prioridad, x.est::vigilante.estado_senal, NOT x.rev, x.plazo, now() - x.hace
  FROM ids, (VALUES
    ('C-1', 'oportunidad', 'eventos', 'media', 'detectada',       true,  now() + interval '5 days',  interval '1 hour'),
    ('C-2', 'oportunidad', 'eventos', 'media', 'confirmada',      false, now() + interval '40 days', interval '1 hour'),
    ('C-3', 'riesgo',      'clima',   'alta',  'publicada',       false, NULL::timestamptz,          interval '1 hour'),
    ('C-4', 'mixta',       'eventos', 'baja',  'en_analisis',     true,  NULL::timestamptz,          interval '1 hour'),
    ('C-5', 'riesgo',      'salud',   'media', 'descartada',      false, NULL::timestamptz,          interval '1 hour'),
    ('C-6', 'riesgo',      'salud',   'media', 'cerrada',         false, NULL::timestamptz,          interval '1 hour'),
    ('C-7', 'oportunidad', 'eventos', 'media', 'detectada',       false, now() + interval '20 days', interval '1 hour'),
    ('C-8', 'oportunidad', 'eventos', 'media', 'detectada',       false, NULL::timestamptz,          interval '3 days')
  ) AS x(codigo, nat, cat, prio, est, rev, plazo, hace);
-- C-1 y C-4 no vienen de fuente oficial: la base les pone «requiere revisión»; las demás sí son oficiales
-- (desde el 29 una oficial en Detectadas pasa sola a Confirmadas, por eso C-1 no es oficial).
-- Con el 29 (aprobacion_previa = false) ya no hay «esperan aprobación».
-- (clima y salud piden revisión siempre, pero C-3 ya está publicada y C-5 descartada)

-- dos noticias de dos fuentes distintas para C-2 (y una ficha vencida ayer para C-7)
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
SELECT c, (SELECT id FROM vigilante.sources WHERE cliente_id = c ORDER BY id OFFSET n - 1 LIMIT 1), 'https://ej.bo/' || n, 'h-contadores-' || n, 'Noticia ' || n
  FROM ids, generate_series(1, 2) n;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT s.id, r.id FROM vigilante.signals s, vigilante.raw_items r WHERE s.codigo = 'C-2' AND r.content_hash LIKE 'h-contadores-%';
INSERT INTO vigilante.oportunidades (cliente_id, signal_id, nivel, tipo, hecho, plazo_hasta, evidencias)
SELECT s.cliente_id, s.id, 'explicita', 'convocatoria', 'Cierra ayer', now() - interval '1 day',
       ARRAY[(SELECT min(id) FROM vigilante.raw_items WHERE content_hash LIKE 'h-contadores-%')]
  FROM vigilante.signals s WHERE s.codigo = 'C-7';

SELECT jsonb_pretty(vigilante.contadores(c) - 'actualizado') AS contadores FROM ids;

DO $$
DECLARE k jsonb; j jsonb; v_lista int;
BEGIN
  SELECT vigilante.contadores(c), vigilante._vigilante_json(c) INTO k, j FROM ids;
  IF (k ->> 'senales_activas')::int <> 4 THEN RAISE EXCEPTION 'activas: esperaba 4, salió %', k ->> 'senales_activas'; END IF;
  IF (k ->> 'oportunidades')::int <> 2 OR (k ->> 'riesgos')::int <> 1 OR (k ->> 'mixtas')::int <> 1 THEN RAISE EXCEPTION 'naturalezas mal: %', k; END IF;
  IF (k ->> 'plazo_corto')::int <> 1 THEN RAISE EXCEPTION 'plazo corto: esperaba 1 (C-1), salió %', k ->> 'plazo_corto'; END IF;
  IF (k ->> 'riesgos_altos')::int <> 1 THEN RAISE EXCEPTION 'riesgos altos mal'; END IF;
  IF (k ->> 'verificadas')::int <> 2 OR (k ->> 'verificadas_2_fuentes')::int <> 1 THEN RAISE EXCEPTION 'verificadas mal: %', k; END IF;
  -- 39: el desglose suma las verificadas (C-2 por 2 fuentes, C-3 oficial con una sola noticia)
  IF k ? 'verificadas_oficial' THEN
    IF (k ->> 'verificadas_oficial')::int <> 1 OR (k ->> 'verificadas_una_fuente')::int <> 0 THEN RAISE EXCEPTION 'desglose mal: %', k; END IF;
    IF (k ->> 'verificadas_2_fuentes')::int + (k ->> 'verificadas_oficial')::int + (k ->> 'verificadas_una_fuente')::int <> (k ->> 'verificadas')::int THEN
      RAISE EXCEPTION 'el desglose no suma las verificadas: %', k; END IF;
    IF (k ->> 'fuentes_activas')::int + (k ->> 'fuentes_en_pausa')::int
       <> (SELECT count(*) FROM vigilante.sources s, ids WHERE s.cliente_id = ids.c AND s.eliminada_en IS NULL) THEN
      RAISE EXCEPTION 'activas + en pausa no suman el catálogo: %', k; END IF;
  END IF;
  IF (k ->> 'por_verificar')::int <> 2 OR (k ->> 'esperan_aprobacion')::int NOT IN (0, 2) THEN RAISE EXCEPTION 'por verificar mal: %', k; END IF;
  IF (k ->> 'alertas_publicadas')::int <> 1 OR (k ->> 'descartadas')::int <> 1 THEN RAISE EXCEPTION 'alertas/descartadas mal: %', k; END IF;
  -- lo que recibe el panel y el chat: la lista sin descartadas mide lo mismo que el contador
  SELECT count(*) INTO v_lista FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'estado' <> 'descartada';
  IF v_lista <> (k ->> 'senales_activas')::int THEN RAISE EXCEPTION 'lista (%) y contador (%) no coinciden', v_lista, k ->> 'senales_activas'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'id' IN ('C-6', 'C-7', 'C-8')) THEN
    RAISE EXCEPTION 'llegan señales que no deberían verse (cerrada, ficha vencida o caducada)';
  END IF;
  IF (j -> 'contadores') IS NULL THEN RAISE EXCEPTION 'vigilante.json no lleva contadores'; END IF;
  -- 39: una fuente en pausa deja de contar como activa (Panorama, Pulso y panel Fuentes dicen lo mismo)
  IF k ? 'fuentes_activas' THEN
    UPDATE vigilante.sources SET activa = false WHERE id = (SELECT max(id) FROM vigilante.sources s, ids WHERE s.cliente_id = ids.c AND s.eliminada_en IS NULL);
    SELECT vigilante.contadores(c) INTO j FROM ids;
    IF (j ->> 'fuentes_activas')::int <> (k ->> 'fuentes_activas')::int - 1 OR (j ->> 'fuentes_en_pausa')::int <> (k ->> 'fuentes_en_pausa')::int + 1 THEN
      RAISE EXCEPTION 'fuente en pausa mal contada: antes %, después %', k, j; END IF;
  END IF;
  RAISE WARNING 'OK: panel y AVIA cuentan % señales activas', k ->> 'senales_activas';
END $$;

-- 40: «Verificada» = fuente oficial o 2 o más fuentes distintas (no basta con estar confirmada).
--  C-9 riesgo confirmado por una persona con UNA noticia de una fuente no oficial → confirmada sin verificar;
--  al publicarla la web pública la muestra «En verificación»; con una segunda fuente pasa a «Verificada».
DO $$
DECLARE k jsonb; v_c uuid := (SELECT c FROM ids); v_id bigint; v_et text;
BEGIN
  IF NOT (vigilante.contadores(v_c) ? 'confirmadas_sin_verificar') THEN RETURN; END IF;
  INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado, fuente_oficial, estado_manual)
  VALUES (v_c, 'C-9', 'Señal C-9', 'Resumen C-9', 'riesgo', 'eventos', 'media', 'confirmada', false, true) RETURNING id INTO v_id;
  INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
  SELECT v_c, (SELECT id FROM vigilante.sources WHERE cliente_id = v_c ORDER BY id LIMIT 1), 'https://ej.bo/c9-' || n, 'h-c9-' || n, 'Noticia C-9 ' || n
    FROM generate_series(1, 2) n;   -- dos notas del MISMO medio: siguen siendo una fuente
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id) SELECT v_id, id FROM vigilante.raw_items WHERE content_hash LIKE 'h-c9-%';
  k := vigilante.contadores(v_c);
  IF (k ->> 'verificadas')::int <> 2 OR (k ->> 'confirmadas_sin_verificar')::int <> 1 THEN
    RAISE EXCEPTION '40: C-9 (una sola fuente no oficial) no debe contar como verificada: %', k; END IF;
  IF (k ->> 'verificadas_2_fuentes')::int + (k ->> 'verificadas_oficial')::int <> (k ->> 'verificadas')::int THEN
    RAISE EXCEPTION '40: el desglose no suma las verificadas: %', k; END IF;

  UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE id = v_id;
  SELECT estado_verificacion INTO v_et FROM vigilante.alerts WHERE signal_id = v_id;
  IF v_et IS DISTINCT FROM 'en_verificacion' THEN RAISE EXCEPTION '40: la alerta de C-9 debería salir «En verificación», salió %', v_et; END IF;

  -- una segunda fuente distinta: ya es verificada y la web pública lo dice
  INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
  VALUES (v_c, (SELECT id FROM vigilante.sources WHERE cliente_id = v_c ORDER BY id OFFSET 1 LIMIT 1), 'https://otro.bo/c9', 'h-c9-otra', 'Otra fuente');
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id) SELECT v_id, id FROM vigilante.raw_items WHERE content_hash = 'h-c9-otra';
  SELECT estado_verificacion INTO v_et FROM vigilante.alerts WHERE signal_id = v_id;
  IF v_et IS DISTINCT FROM 'confirmada' THEN RAISE EXCEPTION '40: con 2 fuentes la alerta de C-9 debería ser «Verificada», salió %', v_et; END IF;
  k := vigilante.contadores(v_c);
  IF (k ->> 'verificadas')::int <> 3 OR (k ->> 'confirmadas_sin_verificar')::int <> 0 OR (k ->> 'alertas_verificadas')::int <> 2 THEN
    RAISE EXCEPTION '40: tras la segunda fuente: %', k; END IF;
  RAISE WARNING 'OK 40: «Verificada» = fuente oficial o 2+ fuentes en contadores y web pública';
END $$;

ROLLBACK;
