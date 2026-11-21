-- Prueba de 38_eventos_cerrados_24h.sql: un evento cerrado por el compositor o descartado sigue en el panel
-- sus 24 h, sin alarma y con el motivo; después deja de verse. Requiere 01 a 34 y 38. Termina en ROLLBACK.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-cerrados', 'Prueba de eventos cerrados', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;

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
SELECT vigilante.componer_eventos('prueba-cerrados') AS ronda_1;
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

-- 2. Se descartan SC-1 y SC-2: Santa Cruz se queda sin señales propias y el compositor lo CIERRA
UPDATE vigilante.signals SET estado = 'descartada' WHERE cliente_id = (SELECT c FROM ids) AND codigo IN ('SC-1', 'SC-2');
SELECT vigilante.componer_eventos('prueba-cerrados') AS ronda_2;
DO $$
DECLARE v jsonb := vigilante.eventos_emergentes(); sc jsonb;
BEGIN
  IF jsonb_array_length(v) <> 2 THEN RAISE EXCEPTION 'El panel debía seguir viendo 2 (uno cerrado): %', v; END IF;
  SELECT x INTO sc FROM jsonb_array_elements(v) x WHERE x ->> 'territorio' = 'Santa Cruz';
  IF sc ->> 'estado' <> 'cerrado' THEN RAISE EXCEPTION 'Santa Cruz debía estar cerrado: %', sc ->> 'estado'; END IF;
  IF (sc ->> 'alerta')::boolean OR NOT (sc ->> 'visto')::boolean THEN RAISE EXCEPTION 'Un cerrado no suena ni cuenta como sin ver: %', sc; END IF;
  IF sc ->> 'motivo_cierre' IS NULL OR sc ->> 'oculta_en' IS NULL THEN RAISE EXCEPTION 'Faltan motivo_cierre u oculta_en: %', sc; END IF;
  -- los abiertos van primero
  IF v -> 0 ->> 'territorio' <> 'La Paz' THEN RAISE EXCEPTION 'Los abiertos debían ir primero'; END IF;
  -- «marcar todo como visto» solo cuenta los abiertos
  IF (vigilante.marcar_evento_visto(NULL) ->> 'marcados')::int <> 1 THEN RAISE EXCEPTION 'Debía marcar solo el abierto'; END IF;
END $$;

-- 3. Un analista descarta La Paz: sigue en el panel como descartado, con su motivo -------------
SELECT vigilante.descartar_evento((SELECT codigo FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz'),
                                  'La huelga ya se levantó');
DO $$
DECLARE lp jsonb;
BEGIN
  SELECT x INTO lp FROM jsonb_array_elements(vigilante.eventos_emergentes()) x WHERE x ->> 'territorio' = 'La Paz';
  IF lp IS NULL OR lp ->> 'estado' <> 'descartado' OR lp ->> 'motivo_cierre' <> 'La huelga ya se levantó' THEN
    RAISE EXCEPTION 'La Paz debía verse como descartado con su motivo: %', lp;
  END IF;
END $$;

-- 4. Pasadas las 24 h ya no se ve ninguno (siguen en la base) ----------------------------------
UPDATE vigilante.eventos_compuestos SET version_en = now() - interval '30 hours' WHERE cliente_id = (SELECT c FROM ids);
DO $$ BEGIN
  IF vigilante.eventos_emergentes() <> '[]'::jsonb THEN RAISE EXCEPTION 'Pasadas 24 h no debía verse nada'; END IF;
  IF (SELECT count(*) FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids)) <> 2 THEN RAISE EXCEPTION 'Debían seguir guardados'; END IF;
END $$;

-- 5. Un visor no ve nada ------------------------------------------------------------------------
UPDATE vigilante.eventos_compuestos SET version_en = now() WHERE cliente_id = (SELECT c FROM ids);
UPDATE vigilante.users SET rol = 'visor' WHERE auth_user_id = '00000000-0000-0000-0000-0000000000d1';
DO $$ BEGIN
  IF vigilante.eventos_emergentes() <> '[]'::jsonb THEN RAISE EXCEPTION 'Un visor no debía ver eventos'; END IF;
END $$;

SELECT 'OK: 38_eventos_cerrados_24h' AS resultado;
ROLLBACK;
