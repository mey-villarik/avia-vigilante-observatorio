-- Prueba de 52_uso_tokens.sql: suma hoy, mes y acumulado sin contar dos veces vigilante.analisis,
-- estima el coste cuando el registro no lo trae y calcula lo que queda solo si hay límite.
-- Requiere 01 a 52 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
UPDATE vigilante.clientes SET zona_horaria = 'America/La_Paz' WHERE id = (SELECT c FROM ids);
DELETE FROM vigilante.system_logs WHERE cliente_id = (SELECT c FROM ids);

-- hoy: un lote del clasificador con coste (1000+200) y un chat sin coste (500+100)
-- este mes (o hoy si es día 1): 2000+300 sin coste
-- hace 40 días: 10000+1000 con coste 0,5
-- un log sin tokens (no cuenta)
INSERT INTO vigilante.system_logs (cliente_id, proceso, mensaje, detalle, costo_usd, created_at)
SELECT c, x.p, 'prueba', x.d::jsonb, x.costo, x.t FROM ids, (VALUES
  ('clasificador', '{"tokens_entrada": 1000, "tokens_salida": 200, "costo_usd": 0.01, "modelo": "deepseek-chat"}', 0.01::numeric, now()),
  ('avia-chat',    '{"tokens_entrada": 500, "tokens_salida": 100, "modelo": "deepseek-chat"}', NULL, now()),
  ('clasificador', '{"tokens_entrada": 2000, "tokens_salida": 300}', 0::numeric,
     greatest(date_trunc('month', now() AT TIME ZONE 'America/La_Paz') AT TIME ZONE 'America/La_Paz' + interval '1 minute', now() - interval '1 minute')),
  ('clasificador', '{"tokens_entrada": 10000, "tokens_salida": 1000, "costo_usd": 0.5}', 0.5::numeric, now() - interval '40 days'),
  ('recolector',   '{"noticias": 12}', NULL, now())) x(p, d, costo, t);

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); r jsonb; v_mes_tokens bigint;
BEGIN
  r := vigilante.uso_tokens(v_c);
  RAISE NOTICE '%', jsonb_pretty(r - 'serie_14d');
  -- hoy: 1000+200 + 500+100 (+ 2000+300 si hoy es día 1)
  ASSERT (r -> 'hoy' ->> 'tokens')::bigint IN (1800, 4100), 'hoy: ' || (r -> 'hoy');
  ASSERT (r -> 'mes' ->> 'tokens')::bigint = 4100, 'mes: ' || (r -> 'mes');
  ASSERT (r -> 'acumulado' ->> 'tokens')::bigint = 15100, 'acumulado: ' || (r -> 'acumulado');
  ASSERT (r -> 'acumulado' ->> 'llamadas')::int = 4, 'el log sin tokens no cuenta';
  -- coste: 0,01 registrado + chat estimado (500*0,30 + 100*1,20)/1e6 + 2000/300 estimado (el 0 cuenta como sin coste)
  ASSERT abs((r -> 'mes' ->> 'costo_usd')::numeric - round(0.01 + 0.00027 + 0.00096, 4)) < 0.0001, 'coste mes: ' || (r -> 'mes');
  ASSERT (r ->> 'costo_estimado')::boolean, 'hay costes estimados';
  ASSERT r -> 'presupuesto_usd_mes' = 'null'::jsonb AND r -> 'restante_usd_mes' = 'null'::jsonb, 'sin presupuesto no hay restante';
  ASSERT jsonb_array_length(r -> 'serie_14d') = 14, 'serie de 14 días';
  ASSERT (r -> 'por_proceso' -> 0 ->> 'proceso') = 'clasificador', 'por proceso ordenado';

  -- con presupuesto y tope
  INSERT INTO vigilante.parametros (cliente_id, clave, valor) VALUES (v_c, 'ia_presupuesto_usd_mes', '1'), (v_c, 'ia_tope_tokens_mes', '5000');
  r := vigilante.uso_tokens(v_c);
  ASSERT (r ->> 'restante_usd_mes')::numeric BETWEEN 0.98 AND 0.99, 'restante usd: ' || (r ->> 'restante_usd_mes');
  ASSERT (r ->> 'restante_tokens_mes')::bigint = 900, 'restante tokens: ' || (r ->> 'restante_tokens_mes');
  RAISE NOTICE 'Prueba 52 superada';
END $$;

-- un visor con sesión no ve nada; un analista ve su cliente aunque pida otro
DO $$
DECLARE v_c uuid := (SELECT c FROM ids); v_auth uuid := gen_random_uuid(); r jsonb;
BEGIN
  INSERT INTO vigilante.users (cliente_id, nombre, rol, auth_user_id) VALUES (v_c, 'Visor prueba', 'visor', v_auth);
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  IF auth.uid() IS NULL THEN RAISE NOTICE 'auth.uid() de prueba no lee el JWT: se salta la parte de roles'; RETURN; END IF;
  ASSERT vigilante.uso_tokens(NULL) IS NULL, 'un visor no ve el uso';
  UPDATE vigilante.users SET rol = 'analista' WHERE auth_user_id = v_auth;
  r := vigilante.uso_tokens(gen_random_uuid());
  ASSERT (r -> 'acumulado' ->> 'tokens')::bigint = 15100, 'el analista ve su cliente';
  RAISE NOTICE 'Roles superados';
END $$;

ROLLBACK;
