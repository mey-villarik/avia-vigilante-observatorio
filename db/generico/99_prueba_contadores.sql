-- Prueba de 21_contadores_unicos.sql: panel y AVIA cuentan lo mismo.
-- Requiere 01 a 21 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
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
    ('C-1', 'oportunidad', 'eventos', 'media', 'detectada',       false, now() + interval '5 days',  interval '1 hour'),
    ('C-2', 'oportunidad', 'eventos', 'media', 'confirmada',      false, now() + interval '40 days', interval '1 hour'),
    ('C-3', 'riesgo',      'clima',   'alta',  'publicada',       false, NULL::timestamptz,          interval '1 hour'),
    ('C-4', 'mixta',       'eventos', 'baja',  'en_analisis',     true,  NULL::timestamptz,          interval '1 hour'),
    ('C-5', 'riesgo',      'salud',   'media', 'descartada',      false, NULL::timestamptz,          interval '1 hour'),
    ('C-6', 'riesgo',      'salud',   'media', 'cerrada',         false, NULL::timestamptz,          interval '1 hour'),
    ('C-7', 'oportunidad', 'eventos', 'media', 'detectada',       false, now() + interval '20 days', interval '1 hour'),
    ('C-8', 'oportunidad', 'eventos', 'media', 'detectada',       false, NULL::timestamptz,          interval '3 days')
  ) AS x(codigo, nat, cat, prio, est, rev, plazo, hace);
-- C-4 no viene de fuente oficial: la base le pone «requiere revisión»; las demás sí son oficiales.
-- (clima y salud piden revisión siempre, pero C-3 ya está publicada y C-5 descartada)

-- dos noticias para C-2 (y una ficha vencida ayer para C-7)
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
SELECT c, (SELECT min(id) FROM vigilante.sources WHERE cliente_id = c), 'https://ej.bo/' || n, 'h-contadores-' || n, 'Noticia ' || n
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
  IF (k ->> 'por_verificar')::int <> 2 OR (k ->> 'esperan_aprobacion')::int <> 1 THEN RAISE EXCEPTION 'por verificar mal: %', k; END IF;
  IF (k ->> 'alertas_publicadas')::int <> 1 OR (k ->> 'descartadas')::int <> 1 THEN RAISE EXCEPTION 'alertas/descartadas mal: %', k; END IF;
  -- lo que recibe el panel y el chat: la lista sin descartadas mide lo mismo que el contador
  SELECT count(*) INTO v_lista FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'estado' <> 'descartada';
  IF v_lista <> (k ->> 'senales_activas')::int THEN RAISE EXCEPTION 'lista (%) y contador (%) no coinciden', v_lista, k ->> 'senales_activas'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'id' IN ('C-6', 'C-7', 'C-8')) THEN
    RAISE EXCEPTION 'llegan señales que no deberían verse (cerrada, ficha vencida o caducada)';
  END IF;
  IF (j -> 'contadores') IS NULL THEN RAISE EXCEPTION 'vigilante.json no lleva contadores'; END IF;
  RAISE WARNING 'OK: panel y AVIA cuentan % señales activas', k ->> 'senales_activas';
END $$;

ROLLBACK;
