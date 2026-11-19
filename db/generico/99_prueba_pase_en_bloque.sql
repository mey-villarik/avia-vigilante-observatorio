-- Prueba de 29_pase_en_bloque.sql: sin «Por aprobar», oficiales directas a Confirmadas,
-- pase en bloque en los dos sentidos. Requiere 01 a 18 y 29 (y 02 con el cliente orbita-bolivia).
-- Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol)
SELECT c, x.a::uuid, x.n, x.r::vigilante.rol_usuario FROM ids, (VALUES
  ('40000000-0000-0000-0000-0000000000b1', 'Lía Analista', 'analista'),
  ('40000000-0000-0000-0000-0000000000b2', 'Vico Visor',   'visor')) AS x(a, n, r);

--  B-1 eventos, fuente oficial      → entra directa en Confirmadas
--  B-2 eventos, no oficial          → Detectadas, sin «Por aprobar»
--  B-3 salud (riesgo), no oficial   → Detectadas, sin «Por aprobar»: pasa en bloque igual
--  B-4 escenario, oficial           → se queda en Detectadas; nunca se publica
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad,
                               fuente_oficial, enlace_oficial, es_escenario)
SELECT c, x.codigo, 'Señal ' || x.codigo, 'Resumen ' || x.codigo, x.nat::vigilante.naturaleza_senal, x.cat, 'media',
       x.oficial, 'https://ej.bo/' || x.codigo, x.esc
  FROM ids, (VALUES
    ('B-1', 'oportunidad', 'eventos', true,  false),
    ('B-2', 'oportunidad', 'eventos', false, false),
    ('B-3', 'riesgo',      'salud',   false, false),
    ('B-4', 'oportunidad', 'eventos', true,  true)
  ) AS x(codigo, nat, cat, oficial, esc);

SELECT codigo, estado, requiere_revision FROM vigilante.signals WHERE codigo LIKE 'B-%' ORDER BY 1;
DO $$ BEGIN
  IF (SELECT array_agg(estado::text ORDER BY codigo) FROM vigilante.signals WHERE codigo LIKE 'B-%')
     <> ARRAY['confirmada', 'detectada', 'detectada', 'detectada'] THEN
    RAISE EXCEPTION 'la oficial debería entrar en confirmada y el resto en detectada';
  END IF;
  IF EXISTS (SELECT 1 FROM vigilante.signals WHERE codigo LIKE 'B-%' AND requiere_revision) THEN
    RAISE EXCEPTION 'no debería quedar nada «Por aprobar»';
  END IF;
END $$;

-- 1. El visor no puede
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-0000000000b2', true);
DO $$ BEGIN
  BEGIN
    PERFORM vigilante.pasar_senales(ARRAY['B-2'], 'confirmada');
    RAISE EXCEPTION 'el visor no debería poder';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'Solo un analista%' THEN RAISE; END IF;
  END;
END $$;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-0000-0000-0000000000b1', true);

-- 2. → Confirmadas: B-2, B-3 y B-4 pasan; B-1 ya estaba; X-9 no existe
SELECT vigilante.pasar_senales(ARRAY['B-1', 'B-2', 'B-3', 'B-4', 'X-9'], 'confirmada') AS a_confirmadas;

-- 3. → Publicadas: todas menos el escenario B-4
SELECT vigilante.pasar_senales(ARRAY['B-1', 'B-2', 'B-3', 'B-4'], 'publicada') AS a_publicadas;
RESET ROLE;
DO $$ BEGIN
  IF (SELECT array_agg(estado::text ORDER BY codigo) FROM vigilante.signals WHERE codigo LIKE 'B-%')
     <> ARRAY['publicada', 'publicada', 'publicada', 'confirmada'] THEN
    RAISE EXCEPTION 'estados inesperados tras publicar';
  END IF;
  IF (SELECT count(*) FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id
       WHERE s.codigo LIKE 'B-%' AND a.cerrada_en IS NULL) <> 3 THEN
    RAISE EXCEPTION 'deberían quedar 3 alertas en la web';
  END IF;
END $$;

-- 4. ← Confirmadas: B-1 se retira de la web; ← Detectadas: B-1 vuelve y NO se re-confirma sola
SET LOCAL ROLE authenticated;
SELECT vigilante.pasar_senales(ARRAY['B-1'], 'confirmada') AS retirar_b1;
SELECT vigilante.pasar_senales(ARRAY['B-1', 'B-4'], 'en_analisis') AS a_detectadas;
SELECT quien, codigo, a, nota FROM vigilante.movimientos_senales(30) WHERE codigo LIKE 'B-%' ORDER BY codigo, cuando;
RESET ROLE;
DO $$ BEGIN
  IF (SELECT estado::text FROM vigilante.signals WHERE codigo = 'B-1') <> 'en_analisis' THEN
    RAISE EXCEPTION 'B-1 debería quedar en Detectadas (la movió una persona)';
  END IF;
  IF (SELECT a.cerrada_en FROM vigilante.alerts a JOIN vigilante.signals s ON s.id = a.signal_id WHERE s.codigo = 'B-1') IS NULL THEN
    RAISE EXCEPTION 'la alerta de B-1 debería estar retirada';
  END IF;
END $$;
SELECT s.codigo, s.estado, a.id IS NOT NULL AND a.cerrada_en IS NULL AS en_web
  FROM vigilante.signals s LEFT JOIN vigilante.alerts a ON a.signal_id = s.id
 WHERE s.codigo LIKE 'B-%' ORDER BY 1;

ROLLBACK;
