-- Prueba de 35_cambios_24h.sql: un cambio se ve 24 h en el panel y después sigue guardado en la base.
-- Requiere 01 a 35. Usa su propio cliente («prueba-cambios-24h»). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS
SELECT vigilante.alta_cliente('prueba-cambios-24h', 'Prueba de cambios 24 h', 'turismo', 'BO', 'America/La_Paz', 'orbita-bolivia') AS c;

INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad, estado)
SELECT c, 'S-24', 'Ciclón hacia Santa Cruz', 'Llega el jueves', 'riesgo', 'clima', 'alta', 'detectada' FROM ids;

-- Tres cambios de la misma señal: hace 2 h, hace 23 h y hace 25 h (este último ya no se ve)
INSERT INTO vigilante.cambios_senal (cliente_id, codigo, signal_id, tipo, antes, ahora, importancia, origen, txid, created_at)
SELECT i.c, x.cod, s.id, x.tipo, 'antes', 'ahora ' || x.cod, 'media', 'datos', 0, now() - make_interval(hours => x.h)
  FROM ids i JOIN vigilante.signals s ON s.cliente_id = i.c AND s.codigo = 'S-24',
       (VALUES ('CAM-0001', 'fecha', 25), ('CAM-0002', 'desviado', 23), ('CAM-0003', 'atenuado', 2)) x(cod, tipo, h);

INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, email, rol)
SELECT c, '00000000-0000-0000-0000-0000000000c4', 'Analista de prueba', 'cam24@prueba.bo', 'analista' FROM ids;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c4', true);

-- 1. El panel ve solo los de las últimas 24 h, con oculta_en
DO $$
DECLARE v jsonb := vigilante.cambios_recientes();
BEGIN
  IF jsonb_array_length(v) <> 2 THEN RAISE EXCEPTION 'El panel debía ver 2 cambios: %', (SELECT jsonb_agg(x ->> 'codigo') FROM jsonb_array_elements(v) x); END IF;
  IF v -> 0 ->> 'codigo' <> 'CAM-0003' THEN RAISE EXCEPTION 'El más reciente debía ir primero: %', v -> 0 ->> 'codigo'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE x ->> 'codigo' = 'CAM-0001') THEN RAISE EXCEPTION 'CAM-0001 (25 h) no debía verse'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) x WHERE x ->> 'oculta_en' IS NULL) THEN RAISE EXCEPTION 'Falta oculta_en'; END IF;
END $$;

-- 2. «Marcar todo como visto» marca solo los que se ven
DO $$
DECLARE r jsonb := vigilante.marcar_cambio_visto(NULL);
BEGIN
  IF (r ->> 'marcados')::int <> 2 THEN RAISE EXCEPTION 'Debía marcar 2: %', r; END IF;
END $$;

-- 3. El de hace 25 h sigue guardado y Hermes lo sigue viendo por el MCP
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vigilante.cambios_senal WHERE codigo = 'CAM-0001' AND estado <> 'descartado'
                    AND cliente_id = (SELECT c FROM ids)) THEN
    RAISE EXCEPTION 'CAM-0001 debía seguir guardado';
  END IF;
  IF jsonb_array_length(vigilante.cambios_abiertos('prueba-cambios-24h')) <> 3 THEN RAISE EXCEPTION 'cambios_abiertos (Hermes) debía seguir dando 3'; END IF;
END $$;

-- 4. El plazo es un parámetro por cliente
INSERT INTO vigilante.parametros (cliente_id, clave, valor) SELECT c, 'cambios_horas_panel', '48' FROM ids
  ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor;
DO $$
BEGIN
  IF jsonb_array_length(vigilante.cambios_recientes()) <> 3 THEN RAISE EXCEPTION 'Con 48 h debía ver 3'; END IF;
END $$;

SELECT 'OK: 35_cambios_24h' AS resultado;
ROLLBACK;
