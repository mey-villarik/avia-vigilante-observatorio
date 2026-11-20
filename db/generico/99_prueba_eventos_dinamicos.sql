-- Prueba de 34_eventos_dinamicos.sql: todo evento nuevo avisa al momento, «nuevo» frente a «actualizado»,
-- marcar todo como visto, prioridad mínima de la alarma y 24 h en el panel (sigue guardado en la base).
-- Requiere 01 a 34. Usa el mismo escenario que 99_prueba_eventos.sql, con su propio cliente. Termina en ROLLBACK.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-dinamicos', 'Prueba de eventos dinámicos', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;

INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{vial}', 'rss' FROM ids,
  (VALUES ('e-ofi', 'Oficial de prueba', 'oficial', 'https://abc.gob.bo'),
          ('e-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo')) x(cod, nom, tipo, url);

-- Escenario (fechas relativas a hoy):
--  LP-1 huelga de transporte en La Paz, sin fechas (última noticia hace 1 h)     riesgo  seguridad alta  oficial
--  LP-2 lluvia fuerte prevista en La Paz mañana                                   riesgo  clima     media prensa
--  LP-3 feria de turismo en La Paz dentro de 20 días (no coincide en fechas)      oport.  eventos   media prensa
--  LP-X descartada (no cuenta)
--  SC-1 festival en Santa Cruz pasado mañana                                      oport.  eventos   media prensa
--  SC-2 vuelo nuevo a Santa Cruz desde pasado mañana                               oport.  conectiv. alta  oficial
--  CB-1 feria en Cochabamba dentro de 25 días (sola: no hay evento)               oport.  eventos   baja  prensa
--  SC-Y anuncio de un hotel nuevo en Santa Cruz, sin fechas (oportunidad sin fecha: no cuenta) oport.  eventos   media prensa
--  NAC  paro nacional de transporte, sin fechas, alcance_total                     riesgo  vial      alta  oficial
-- Esperado: La Paz = riesgo_acumulado (LP-1, LP-2, NAC); Santa Cruz = confluencia (SC-1, SC-2, NAC).
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado,
                               fecha_evento_inicio, alcance_total, created_at)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen ' || x.cod, x.nat::vigilante.naturaleza_senal, x.cat,
       x.pri::vigilante.prioridad, x.est::vigilante.estado_senal,
       CASE WHEN x.dias IS NOT NULL THEN ((now() AT TIME ZONE 'America/La_Paz')::date + x.dias)::timestamp AT TIME ZONE 'UTC' END,
       x.nac, now() - interval '2 hours'
  FROM ids, (VALUES
    ('LP-1', 'riesgo', 'seguridad', 'alta', 'detectada', NULL::int, false),
    ('LP-2', 'riesgo', 'clima', 'media', 'detectada', 1, false),
    ('LP-3', 'oportunidad', 'eventos', 'media', 'detectada', 20, false),
    ('LP-X', 'riesgo', 'vial', 'alta', 'descartada', NULL, false),
    ('SC-1', 'oportunidad', 'eventos', 'media', 'detectada', 2, false),
    ('SC-2', 'oportunidad', 'conectividad', 'alta', 'detectada', 2, false),
    ('SC-Y', 'oportunidad', 'eventos', 'media', 'detectada', NULL, false),
    ('CB-1', 'oportunidad', 'eventos', 'baja', 'detectada', 25, false),
    ('NAC', 'riesgo', 'vial', 'alta', 'detectada', NULL, true)) x(cod, nat, cat, pri, est, dias, nac);

INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/' || x.g, 'h-ev-' || x.g, 'Noticia ' || x.g, now() - interval '1 hour'
  FROM ids, (VALUES ('LP-1', 'e-ofi'), ('LP-2', 'e-pre'), ('LP-3', 'e-pre'), ('LP-X', 'e-pre'), ('SC-1', 'e-pre'),
                    ('SC-2', 'e-ofi'), ('SC-Y', 'e-pre'), ('CB-1', 'e-pre'), ('NAC', 'e-ofi')) x(g, f),
       vigilante.sources s WHERE s.codigo = x.f AND s.cliente_id = ids.c;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-ev-' || g.codigo
 WHERE g.cliente_id = (SELECT c FROM ids);
INSERT INTO vigilante.signal_territorios (signal_id, territorio_id)
SELECT g.id, t.id FROM vigilante.signals g
  JOIN vigilante.territorios t ON t.cliente_id = g.cliente_id
   AND t.codigo = CASE left(g.codigo, 2) WHEN 'LP' THEN 'BO-L' WHEN 'SC' THEN 'BO-S' WHEN 'CB' THEN 'BO-C' END
 WHERE g.cliente_id = (SELECT c FROM ids) AND g.codigo <> 'NAC';

INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, email, rol)
SELECT c, '00000000-0000-0000-0000-0000000000d1', 'Analista de prueba', 'dina@prueba.bo', 'analista' FROM ids;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d1', true);

-- 1. Se detectan 2 eventos: los dos salen ya como alarma (sin esperar a AVIA y sea cual sea su prioridad)
SELECT vigilante.componer_eventos('prueba-dinamicos') AS ronda_1;
SELECT x ->> 'codigo' AS codigo, x ->> 'prioridad' AS prioridad, x ->> 'alerta' AS alerta, x ->> 'nuevo' AS nuevo,
       x ->> 'visto' AS visto, x ->> 'oculta_en' AS oculta_en
  FROM jsonb_array_elements(vigilante.eventos_emergentes()) x;
DO $$
DECLARE v jsonb := vigilante.eventos_emergentes(); x jsonb;
BEGIN
  IF jsonb_array_length(v) <> 2 THEN RAISE EXCEPTION 'El panel debía ver 2 eventos: %', v; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(v) LOOP
    IF (x ->> 'alerta')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Recién detectado y sin interpretar debía ser alarma ya: %', x ->> 'codigo'; END IF;
    IF (x ->> 'nuevo')::boolean IS NOT TRUE OR (x ->> 'visto')::boolean THEN RAISE EXCEPTION 'Debía ser nuevo y sin ver: %', x ->> 'codigo'; END IF;
    IF x ->> 'oculta_en' IS NULL THEN RAISE EXCEPTION 'Falta oculta_en'; END IF;
  END LOOP;
END $$;

-- 2. Con prioridad mínima «alta» solo suena el de prioridad alta ----------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor) SELECT c, 'eventos_alerta_desde', '"alta"' FROM ids;
DO $$
DECLARE v jsonb := vigilante.eventos_emergentes(); x jsonb;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(v) LOOP
    IF (x ->> 'alerta')::boolean <> (x ->> 'prioridad' = 'alta') THEN RAISE EXCEPTION 'Con «alta» la alarma no cuadra: % %', x ->> 'codigo', x ->> 'prioridad'; END IF;
  END LOOP;
END $$;
DELETE FROM vigilante.parametros WHERE cliente_id = (SELECT c FROM ids) AND clave = 'eventos_alerta_desde';

-- 3. «Marcar todo como visto» -----------------------------------------------------------------
DO $$
DECLARE r jsonb := vigilante.marcar_evento_visto(NULL); v jsonb := vigilante.eventos_emergentes();
BEGIN
  IF (r ->> 'marcados')::int <> 2 THEN RAISE EXCEPTION 'Debía marcar 2: %', r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE NOT (x ->> 'visto')::boolean) THEN RAISE EXCEPTION 'Todos debían quedar vistos'; END IF;
END $$;

-- 4. Entra una señal nueva en La Paz: versión 2, vuelve a sonar como «actualizado» (no «nuevo»)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado, created_at)
SELECT c, 'LP-4', 'Señal LP-4', 'Bloqueo en la carretera a Copacabana', 'riesgo', 'vial', 'media', 'detectada', now() - interval '1 hour' FROM ids;
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/LP-4', 'h-ev-LP-4', 'Noticia LP-4', now() - interval '30 minutes'
  FROM ids JOIN vigilante.sources s ON s.codigo = 'e-pre' AND s.cliente_id = ids.c;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-ev-LP-4' WHERE g.codigo = 'LP-4' AND g.cliente_id = (SELECT c FROM ids);
INSERT INTO vigilante.signal_territorios (signal_id, territorio_id)
SELECT g.id, t.id FROM vigilante.signals g JOIN vigilante.territorios t ON t.cliente_id = g.cliente_id AND t.codigo = 'BO-L'
 WHERE g.codigo = 'LP-4' AND g.cliente_id = (SELECT c FROM ids);

-- la detección de antes fue hace 30 h: el evento de Santa Cruz ya no se ve; La Paz vuelve con la versión 2
UPDATE vigilante.eventos_compuestos SET version_en = now() - interval '30 hours', created_at = now() - interval '30 hours'
 WHERE cliente_id = (SELECT c FROM ids);
SELECT vigilante.componer_eventos('prueba-dinamicos') AS ronda_2;
DO $$
DECLARE v jsonb := vigilante.eventos_emergentes(); e vigilante.eventos_compuestos;
BEGIN
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  IF e.version <> 2 OR e.version_en < now() - interval '1 minute' THEN RAISE EXCEPTION 'La Paz debía pasar a v2 con version_en de ahora: v% %', e.version, e.version_en; END IF;
  IF jsonb_array_length(v) <> 1 OR v -> 0 ->> 'territorio' <> 'La Paz' THEN
    RAISE EXCEPTION 'El panel debía ver solo La Paz (Santa Cruz pasó de 24 h): %', (SELECT jsonb_agg(x ->> 'territorio') FROM jsonb_array_elements(v) x);
  END IF;
  IF (v -> 0 ->> 'alerta')::boolean IS NOT TRUE OR (v -> 0 ->> 'visto')::boolean OR (v -> 0 ->> 'nuevo')::boolean THEN
    RAISE EXCEPTION 'La versión 2 debía sonar como actualización: %', v -> 0;
  END IF;
  -- Santa Cruz sigue guardado y abierto: Hermes lo sigue viendo
  IF (SELECT estado FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Santa Cruz') NOT IN ('por_interpretar', 'interpretando', 'interpretado') THEN
    RAISE EXCEPTION 'Santa Cruz debía seguir abierto en la base';
  END IF;
  IF jsonb_array_length(vigilante.eventos_abiertos('prueba-dinamicos')) <> 2 THEN RAISE EXCEPTION 'eventos_abiertos (Hermes) debía seguir dando 2'; END IF;
END $$;

-- 5. Hermes interpreta: version_en no cambia (no alarga las 24 h) -------------------------------
DO $$
DECLARE antes timestamptz; despues timestamptz;
BEGIN
  SELECT version_en INTO antes FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  UPDATE vigilante.eventos_compuestos SET estado = 'interpretado', titular = 'x' WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  SELECT version_en INTO despues FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  IF antes <> despues THEN RAISE EXCEPTION 'Interpretar no debía mover version_en'; END IF;
END $$;

-- 6. Un visor no ve nada ------------------------------------------------------------------------
UPDATE vigilante.users SET rol = 'visor' WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d1';
DO $$ BEGIN
  IF vigilante.eventos_emergentes() <> '[]'::jsonb THEN RAISE EXCEPTION 'Un visor no debía ver eventos'; END IF;
END $$;

SELECT 'OK: 34_eventos_dinamicos' AS resultado;
ROLLBACK;
