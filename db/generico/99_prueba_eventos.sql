-- Prueba de 28_eventos_compuestos.sql: compositor, interpretación de Hermes y avisos del panel.
-- Requiere 01 a 28 (y 02 con el cliente orbita-bolivia). Usa un cliente propio («prueba-eventos», copia de
-- territorios y categorías de orbita-bolivia) para no tocar las señales reales. Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-eventos', 'Prueba de eventos', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;

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
    ('CB-1', 'oportunidad', 'eventos', 'baja', 'detectada', 25, false),
    ('NAC', 'riesgo', 'vial', 'alta', 'detectada', NULL, true)) x(cod, nat, cat, pri, est, dias, nac);

INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, recolectado_en)
SELECT c, s.id, s.url || '/' || x.g, 'h-ev-' || x.g, 'Noticia ' || x.g, now() - interval '1 hour'
  FROM ids, (VALUES ('LP-1', 'e-ofi'), ('LP-2', 'e-pre'), ('LP-3', 'e-pre'), ('LP-X', 'e-pre'), ('SC-1', 'e-pre'),
                    ('SC-2', 'e-ofi'), ('CB-1', 'e-pre'), ('NAC', 'e-ofi')) x(g, f),
       vigilante.sources s WHERE s.codigo = x.f AND s.cliente_id = ids.c;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-ev-' || g.codigo
 WHERE g.cliente_id = (SELECT c FROM ids);
INSERT INTO vigilante.signal_territorios (signal_id, territorio_id)
SELECT g.id, t.id FROM vigilante.signals g
  JOIN vigilante.territorios t ON t.cliente_id = g.cliente_id
   AND t.codigo = CASE left(g.codigo, 2) WHEN 'LP' THEN 'BO-L' WHEN 'SC' THEN 'BO-S' WHEN 'CB' THEN 'BO-C' END
 WHERE g.cliente_id = (SELECT c FROM ids) AND g.codigo <> 'NAC';

-- 1. Primera composición ---------------------------------------------------------------
SELECT vigilante.componer_eventos('prueba-eventos') AS ronda_1;
SELECT codigo, tipo, territorio_nombre, prioridad_calculada, puntaje, estado,
       (SELECT string_agg(s.codigo, ',' ORDER BY s.codigo) FROM vigilante.signals s WHERE s.id = ANY (e.senal_ids)) AS senales
  FROM vigilante.eventos_compuestos e WHERE e.cliente_id = (SELECT c FROM ids) ORDER BY codigo;

DO $$
DECLARE n int; t text; s text;
BEGIN
  SELECT count(*) INTO n FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids);
  IF n <> 2 THEN RAISE EXCEPTION 'Esperaba 2 eventos, hay %', n; END IF;
  SELECT e.tipo, (SELECT string_agg(x.codigo, ',' ORDER BY x.codigo) FROM vigilante.signals x WHERE x.id = ANY (e.senal_ids))
    INTO t, s FROM vigilante.eventos_compuestos e WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  IF t <> 'riesgo_acumulado' OR s <> 'LP-1,LP-2,NAC' THEN RAISE EXCEPTION 'La Paz mal: % %', t, s; END IF;
  SELECT e.tipo, (SELECT string_agg(x.codigo, ',' ORDER BY x.codigo) FROM vigilante.signals x WHERE x.id = ANY (e.senal_ids))
    INTO t, s FROM vigilante.eventos_compuestos e WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Santa Cruz';
  IF t <> 'confluencia' OR s <> 'NAC,SC-1,SC-2' THEN RAISE EXCEPTION 'Santa Cruz mal: % %', t, s; END IF;
  IF EXISTS (SELECT 1 FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Cochabamba') THEN
    RAISE EXCEPTION 'Cochabamba no debía tener evento (su señal es de dentro de 25 días)';
  END IF;
END $$;

-- 2. Sin cambios: no crea ni actualiza nada --------------------------------------------
DO $$
DECLARE r jsonb := vigilante.componer_eventos('prueba-eventos');
BEGIN
  IF r <> '{"creados": 0, "cerrados": 0, "con_senales_nuevas": 0}'::jsonb THEN RAISE EXCEPTION 'Ronda 2 debía ser vacía: %', r; END IF;
END $$;

-- 3. Hermes interpreta ------------------------------------------------------------------
SELECT vigilante.eventos_pendientes_hermes('prueba-eventos') AS pendientes;   -- 2
SELECT jsonb_array_length(vigilante.eventos_por_interpretar('prueba-eventos', 1)) AS reservados;  -- 1 (el de más puntaje)
SELECT vigilante.eventos_pendientes_hermes('prueba-eventos') AS pendientes_tras_reservar;          -- 1

-- incompleta: debe fallar
DO $$
BEGIN
  PERFORM vigilante.guardar_interpretacion_evento('prueba-eventos',
    (SELECT codigo FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz'),
    '{"titular": "x", "significado": "y", "recomendacion": {"accion": "a", "para_quien": "b"}}');
  RAISE EXCEPTION 'Debía fallar sin a_quien_afecta';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM NOT LIKE 'Falta «a_quien_afecta»%' THEN RAISE; END IF;
END $$;

-- prioridad dos niveles por debajo: debe fallar (La Paz es alta)
DO $$
BEGIN
  PERFORM vigilante.guardar_interpretacion_evento('prueba-eventos',
    (SELECT codigo FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz'),
    '{"titular": "x", "significado": "y", "a_quien_afecta": ["operadores"],
      "recomendacion": {"accion": "a", "para_quien": "b"}, "prioridad": {"nivel": "baja", "motivo": "m"}}');
  RAISE EXCEPTION 'Debía fallar al bajar dos niveles';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM NOT LIKE 'La prioridad calculada es%' THEN RAISE; END IF;
END $$;

SELECT vigilante.guardar_interpretacion_evento('prueba-eventos',
  (SELECT codigo FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz'),
  '{"es_confluencia": true,
    "titular": "Riesgo acumulado en La Paz: huelga de transporte + lluvia fuerte prevista",
    "significado": "Hechos: hay huelga de transporte (fuente oficial) y SENAMHI prevé lluvia fuerte mañana. Interpretación: juntas podrían dejar a visitantes sin traslados.",
    "a_quien_afecta": ["operadores de turismo receptivo de La Paz", "alojamientos con llegadas mañana"],
    "impacto": {"nivel": "alto", "motivo": "Coinciden en las próximas 24 h en el mismo departamento"},
    "recomendacion": {"accion": "Avisar a los clientes con llegada mañana y prever traslados alternativos",
                      "para_quien": "operadores y alojamientos", "cuando": "hoy, con 24 h de antelación",
                      "verificar_con": "ABC y SENAMHI"},
    "escenarios": [{"si": "la huelga sigue mañana", "entonces": "traslados del aeropuerto afectados"}, {"si": "", "entonces": "vacío: se ignora"}],
    "falta_saber": ["Duración de la huelga", "Zonas exactas de la lluvia"],
    "campo_inventado": "no se guarda"}', 'deepseek-chat') AS guardado;

-- Hermes descarta Santa Cruz (no es una confluencia real)
SELECT vigilante.guardar_interpretacion_evento('prueba-eventos',
  (SELECT codigo FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Santa Cruz'),
  '{"es_confluencia": false, "motivo_descarte": "El paro nacional no toca el festival: es en otra fecha"}') AS descartado;

DO $$
DECLARE e vigilante.eventos_compuestos;
BEGIN
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  IF e.estado <> 'interpretado' OR e.interpretacion ? 'campo_inventado' OR jsonb_array_length(e.interpretacion -> 'escenarios') <> 1 THEN
    RAISE EXCEPTION 'Interpretación mal guardada: % %', e.estado, e.interpretacion;
  END IF;
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Santa Cruz';
  IF e.estado <> 'descartado' THEN RAISE EXCEPTION 'Santa Cruz debía quedar descartado'; END IF;
END $$;

DO $$ BEGIN
  IF jsonb_array_length(vigilante.eventos_abiertos('prueba-eventos')) <> 1 THEN RAISE EXCEPTION 'eventos_abiertos debía dar 1 (La Paz)'; END IF;
END $$;

-- 4. Panel: un administrador ve la alerta, pulsa «Entendido» y deja de verla ----------------
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, email, rol)
SELECT c, '00000000-0000-0000-0000-0000000000e1', 'Analista de prueba', 'ana@prueba.bo', 'analista' FROM ids;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000e1', true);

SELECT x ->> 'codigo' AS codigo, x ->> 'titular' AS titular, x ->> 'prioridad' AS prioridad,
       x ->> 'alerta' AS alerta, x ->> 'visto' AS visto, jsonb_array_length(x -> 'senales') AS senales
  FROM jsonb_array_elements(vigilante.eventos_emergentes()) x;

DO $$
DECLARE v jsonb := vigilante.eventos_emergentes(); cod text;
BEGIN
  IF jsonb_array_length(v) <> 1 THEN RAISE EXCEPTION 'El panel debía ver 1 evento (Santa Cruz está descartado): %', v; END IF;
  IF (v -> 0 ->> 'alerta')::boolean IS NOT TRUE OR (v -> 0 ->> 'visto')::boolean THEN RAISE EXCEPTION 'Debía ser alerta sin ver: %', v -> 0; END IF;
  cod := v -> 0 ->> 'codigo';
  PERFORM vigilante.marcar_evento_visto(cod);
  IF (vigilante.eventos_emergentes() -> 0 ->> 'visto')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'Debía quedar visto'; END IF;
END $$;

-- 5. Entra una señal nueva en La Paz: versión 2, vuelve a interpretación y el aviso sale otra vez
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

SELECT vigilante.componer_eventos('prueba-eventos') AS ronda_3;
DO $$
DECLARE e vigilante.eventos_compuestos; v jsonb;
BEGIN
  SELECT * INTO e FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz';
  IF e.version <> 2 OR e.estado <> 'por_interpretar' OR cardinality(e.senal_ids) <> 4 THEN
    RAISE EXCEPTION 'La Paz debía pasar a versión 2 con 4 señales y por interpretar: v% % %', e.version, e.estado, cardinality(e.senal_ids);
  END IF;
  v := vigilante.eventos_emergentes();
  IF (v -> 0 ->> 'visto')::boolean THEN RAISE EXCEPTION 'La versión 2 debía volver a avisar'; END IF;
  IF (v -> 0 ->> 'alerta')::boolean THEN RAISE EXCEPTION 'Sin interpretar y recién cambiado no debía ser alerta todavía'; END IF;
  -- Santa Cruz descartado con las mismas señales: no vuelve
  IF (SELECT estado FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'Santa Cruz') <> 'descartado' THEN
    RAISE EXCEPTION 'Santa Cruz descartado no debía reabrirse sin señales nuevas';
  END IF;
END $$;

-- 6. Las señales de La Paz dejan de coincidir: el evento se cierra -----------------------
UPDATE vigilante.signals SET estado = 'descartada' WHERE codigo IN ('LP-1', 'LP-2', 'LP-4') AND cliente_id = (SELECT c FROM ids);
SELECT vigilante.componer_eventos('prueba-eventos') AS ronda_4;
DO $$
BEGIN
  IF (SELECT estado FROM vigilante.eventos_compuestos WHERE cliente_id = (SELECT c FROM ids) AND territorio_nombre = 'La Paz') <> 'cerrado' THEN
    RAISE EXCEPTION 'La Paz debía cerrarse';
  END IF;
END $$;

-- 7. Un visor no ve nada; un analista puede descartar -----------------------------------
UPDATE vigilante.users SET rol = 'visor' WHERE auth_user_id = '00000000-0000-0000-0000-0000000000e1';
DO $$ BEGIN
  IF vigilante.eventos_emergentes() <> '[]'::jsonb THEN RAISE EXCEPTION 'Un visor no debía ver eventos'; END IF;
END $$;

SELECT 'OK: 28_eventos_compuestos' AS resultado;
ROLLBACK;
