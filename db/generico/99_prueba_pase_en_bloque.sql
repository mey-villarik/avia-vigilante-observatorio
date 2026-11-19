-- Prueba de 29_pase_en_bloque.sql: pasar varias señales de una vez sin saltarse la aprobación.
-- Requiere 01 a 18 y 29 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT c, x.a::uuid, x.n, x.r::vigilante.rol_usuario FROM ids, (VALUES
  ('40000000-0000-0000-0000-0000000000b1', 'Lía Analista', 'analista'),
  ('40000000-0000-0000-0000-0000000000b2', 'Vico Visor',   'visor')) AS x(a, n, r);

--  B-1 eventos, oficial, detectada          → pasa a Confirmada y luego a Publicada
--  B-2 eventos, oficial, ya en análisis     → pasa a Confirmada
--  B-3 salud (riesgo)                       → espera aprobación: NUNCA se mueve en bloque
--  B-4 eventos, fuente no oficial           → espera aprobación, pero no es riesgo: pasa (el botón es la aprobación)
--  B-5 escenario aprobado (confirmada)      → nunca se publica
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad,
                               fuente_oficial, enlace_oficial, es_escenario)
SELECT c, x.codigo, 'Señal ' || x.codigo, 'Resumen ' || x.codigo, x.nat::vigilante.naturaleza_senal, x.cat, 'media',
       x.oficial, 'https://ej.bo/' || x.codigo, x.esc
  FROM ids, (VALUES
    ('B-1', 'oportunidad', 'eventos', true,  false),
    ('B-2', 'oportunidad', 'eventos', true,  false),
    ('B-3', 'riesgo',      'salud',   true,  false),
    ('B-4', 'oportunidad', 'eventos', false, false),
    ('B-5', 'oportunidad', 'eventos', true,  true)
  ) AS x(codigo, nat, cat, oficial, esc);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-0000000000b1', true);
SELECT vigilante.mover_senal('B-2', 'en_analisis');
SELECT vigilante.aprobar_senal('B-5');   -- escenario aprobado: queda confirmada

-- 1. El visor no puede
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-0000000000b2', true);
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.pasar_senales(ARRAY['B-1'], 'confirmada');
    RAISE EXCEPTION 'el visor no debería poder';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Solo un analista%' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-0000000000b1', true);

-- 2. Detectadas → Confirmadas: B-1, B-2 y B-4 pasan; B-3 (riesgo de salud) y X-9 (no existe) se omiten
SELECT vigilante.pasar_senales(ARRAY['B-1', 'B-2', 'B-3', 'B-4', 'X-9'], 'confirmada') AS a_confirmadas;
DO $$ BEGIN
  IF (SELECT array_agg(estado::text ORDER BY codigo) FROM vigilante.signals WHERE codigo IN ('B-1','B-2','B-3','B-4'))
     <> ARRAY['confirmada', 'confirmada', 'detectada', 'confirmada'] THEN
    RAISE EXCEPTION 'estados inesperados tras el pase a confirmadas';
  END IF;
  IF (SELECT revision_decidida_en FROM vigilante.signals WHERE codigo = 'B-4') IS NULL THEN
    RAISE EXCEPTION 'B-4 debería quedar aprobada por quien pulsó el botón';
  END IF;
END $$;

-- 3. Destino no permitido
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.pasar_senales(ARRAY['B-1'], 'descartada');
    RAISE EXCEPTION 'no debería aceptar otro destino';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'El pase en bloque solo%' THEN RAISE; END IF;
  END;
END $$;

-- 4. Confirmadas → Publicadas: B-1, B-2 y B-4 se publican; B-5 (escenario) y B-3 (sin confirmar) no
SELECT vigilante.pasar_senales(ARRAY['B-1', 'B-2', 'B-4', 'B-5', 'B-3'], 'publicada') AS a_publicadas;
SELECT quien, codigo, a, nota FROM vigilante.movimientos_senales(20) WHERE codigo LIKE 'B-%' ORDER BY codigo, cuando;
RESET ROLE;

DO $$ BEGIN
  IF (SELECT array_agg(estado::text ORDER BY codigo) FROM vigilante.signals WHERE codigo LIKE 'B-%')
     <> ARRAY['publicada', 'publicada', 'detectada', 'publicada', 'confirmada'] THEN
    RAISE EXCEPTION 'estados inesperados tras el pase a publicadas';
  END IF;
  IF EXISTS (SELECT 1 FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id WHERE s.codigo IN ('B-3', 'B-5')) THEN
    RAISE EXCEPTION 'se publicó un riesgo sin aprobar o un escenario';
  END IF;
END $$;
SELECT s.codigo, s.estado, a.id IS NOT NULL AS alerta_en_web
  FROM vigilante.signals s LEFT JOIN vigilante.alerts a ON a.signal_id = s.id
 WHERE s.codigo LIKE 'B-%' ORDER BY 1;

ROLLBACK;
