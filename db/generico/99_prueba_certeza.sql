-- Prueba de 24_grado_certeza.sql: confirmado / convocado / posible / rumor y quién lo decide.
-- Requiere 01 a 24 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, x.cod, x.nom, x.tipo::vigilante.tipo_fuente, x.url, '{eventos}', 'rss' FROM ids,
  (VALUES ('c-ofi', 'Ministerio de prueba', 'oficial', 'https://min.gob.bo'),
          ('c-pre', 'Prensa de prueba', 'medio', 'https://prensa.bo'),
          ('c-red', 'Página de Facebook', 'no_oficial', 'https://facebook.com/x')) x(cod, nom, tipo, url);
INSERT INTO vigilante.users (cliente_id, auth_user_id, nombre, rol, telegram_chat_id)
SELECT c, '50000000-0000-0000-0000-00000000000b', 'Ana Analista', 'analista', 778 FROM ids;

--  C-1 confirmada por una persona                       → confirmado (persona)
--  C-2 modelo «convocado», prensa, evento futuro        → convocado (modelo)
--  C-3 modelo «confirmado» con una sola prensa          → posible (modelo_ajustado)
--  C-4 modelo «posible» sin ninguna noticia             → rumor (modelo_ajustado)
--  C-5 escenario                                        → posible (reglas)
--  C-6 antigua, fuente oficial                          → confirmado (reglas)
--  C-7 antigua, solo Facebook                           → rumor (reglas)
--  C-8 antigua, una prensa                              → posible (reglas)
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, es_escenario,
                               fecha_evento_inicio, created_at, salida_modelo)
SELECT c, x.cod, 'Señal ' || x.cod, 'Resumen', 'riesgo', 'eventos', 'detectada', x.esc, x.ev, now() - interval '2 hours', x.m::jsonb
  FROM ids, (VALUES
  ('C-1', false, NULL::timestamptz, '{"certeza": {"nivel": "confirmado", "motivo": "El ministerio lo informa"}}'),
  ('C-2', false, now() + interval '3 days', '{"certeza": {"nivel": "convocado", "motivo": "La federación anuncia un paro el jueves"}}'),
  ('C-3', false, NULL, '{"certeza": {"nivel": "confirmado", "motivo": "Lo dice la prensa"}}'),
  ('C-4', false, NULL, '{"certeza": {"nivel": "posible", "motivo": "Se comenta"}}'),
  ('C-5', true,  NULL, '{"certeza": {"nivel": "confirmado", "motivo": "x"}}'),
  ('C-6', false, NULL, '{}'),
  ('C-7', false, NULL, '{}'),
  ('C-8', false, NULL, '{}')) x(cod, esc, ev, m);
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo)
SELECT c, s.id, s.url || '/' || g, 'h-cert-' || g, 'Noticia ' || g
  FROM ids, (VALUES ('C-1', 'c-ofi'), ('C-2', 'c-pre'), ('C-3', 'c-pre'), ('C-6', 'c-ofi'), ('C-7', 'c-red'), ('C-8', 'c-pre')) x(g, f)
  JOIN vigilante.sources s ON s.codigo = x.f;
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id)
SELECT g.id, r.id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-cert-' || g.codigo;
SELECT set_config('vigilante.actor', '50000000-0000-0000-0000-00000000000b', true);
UPDATE vigilante.signals SET estado = 'en_analisis' WHERE codigo = 'C-1';
UPDATE vigilante.signals SET estado = 'confirmada' WHERE codigo = 'C-1';
SELECT set_config('vigilante.actor', '', true);

SELECT codigo, vigilante.certeza(id) FROM vigilante.signals WHERE codigo LIKE 'C-_' ORDER BY 1;

DO $$
DECLARE r record; v_esperado jsonb := '{"C-1": ["confirmado", "persona"], "C-2": ["convocado", "modelo"],
  "C-3": ["posible", "modelo_ajustado"], "C-4": ["rumor", "modelo_ajustado"], "C-5": ["posible", "reglas"],
  "C-6": ["confirmado", "reglas"], "C-7": ["rumor", "reglas"], "C-8": ["posible", "reglas"]}';
BEGIN
  FOR r IN SELECT codigo, vigilante.certeza(id) AS c FROM vigilante.signals WHERE codigo LIKE 'C-_' LOOP
    IF r.c ->> 'nivel' <> v_esperado #>> ARRAY[r.codigo, '0'] OR r.c ->> 'origen' <> v_esperado #>> ARRAY[r.codigo, '1'] THEN
      RAISE EXCEPTION '% debía ser %, salió %', r.codigo, v_esperado -> r.codigo, r.c;
    END IF;
  END LOOP;
  IF (SELECT vigilante.certeza(id) ->> 'motivo' FROM vigilante.signals WHERE codigo = 'C-1') NOT LIKE '%Ana Analista%' THEN
    RAISE EXCEPTION 'C-1 debe decir quién lo comprobó';
  END IF;
  IF (SELECT vigilante.certeza(id) ->> 'propuesto' FROM vigilante.signals WHERE codigo = 'C-3') <> 'confirmado' THEN
    RAISE EXCEPTION 'C-3 debe decir qué propuso el modelo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ids, jsonb_array_elements(vigilante._vigilante_json(c) -> 'senales') e WHERE e ->> 'id' = 'C-2' AND e #>> '{certeza,nivel}' = 'convocado') THEN
    RAISE EXCEPTION 'vigilante.json no lleva certeza';
  END IF;
  IF (SELECT prosrc FROM pg_proc WHERE oid = coalesce(to_regprocedure('vigilante.guardar_clasificacion_25(text,jsonb,text,text,jsonb)'), 'vigilante.guardar_clasificacion(text,jsonb,text,text,jsonb)'::regprocedure)) NOT LIKE '%''certeza'', x -> ''certeza''%' THEN
    RAISE EXCEPTION 'guardar_clasificacion no guarda la certeza';
  END IF;
  RAISE WARNING 'OK: grado de certeza (8 casos: confirmado, convocado, posible y rumor; persona, modelo, ajuste y reglas)';
END $$;

ROLLBACK;
