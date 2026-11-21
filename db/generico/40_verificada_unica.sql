-- =============================================================================
-- 40. «Verificada» significa una sola cosa (panel, web pública, Telegram y AVIA)
-- =============================================================================
-- Qué se veía (Meysel, 2026-11-21): «Verificadas 59» frente a «2 con 2 o más fuentes», y la
-- palabra «Verificada» quería decir cosas distintas según dónde se mirara:
--   · contador del panel (21/39): toda señal confirmada o publicada, la sostuviera lo que la sostuviera
--     (también las que una persona pasó en bloque con una sola noticia no oficial);
--   · web pública y Telegram (13): toda alerta publicada que no venía de «En verificación», aunque
--     solo la contara una fuente no oficial;
--   · AVIA (24): «confirmado» = fuente oficial, dos fuentes distintas o una persona.
--
-- Regla única desde el 40 (la misma en web/src/lib/verificada.ts y hermes/avia-api/avia_api.py):
--
--   VERIFICADA = señal confirmada o publicada, que no es escenario, y que respalda
--                una FUENTE OFICIAL (u organismo internacional)  o  2 O MÁS FUENTES DISTINTAS.
--
--   Una señal confirmada o publicada que no cumple (una sola fuente no oficial, o un escenario) es
--   «Confirmada sin verificar»: no cuenta como verificada y, si está publicada, la web pública y
--   Telegram la muestran «En verificación».
--   Fuentes distintas = fuentes del catálogo distintas (dos notas del mismo medio son UNA fuente),
--   contadas igual que la fiabilidad del 22, que es lo que ve la web en cada tarjeta.
--
-- Contadores (vigilante.contadores):
--   verificadas               = las que cumplen la regla
--     verificadas_2_fuentes   = de ellas, con 2 o más fuentes distintas
--     verificadas_oficial     = de ellas, con menos de 2 fuentes pero fuente oficial
--     (las dos suman «verificadas»)
--   confirmadas_sin_verificar = confirmadas o publicadas que NO cumplen la regla
--   verificadas_una_fuente    = siempre 0 (se deja para la web anterior al 40, que la suma)
--
-- Web pública: alerts.estado_verificacion lo pone la base con la misma regla al publicar y cada vez
-- que cambian las noticias o la fuente de la señal. Una aprobación del 18 (si aprobacion_previa
-- vuelve a true) ya no convierte en «Verificada» una alerta que no tiene el respaldo.
--
-- Necesita 21 y 39. Se puede ejecutar más de una vez.
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT vigilante.contadores(id) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_contadores.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 1. Respaldo de una señal: la regla, en un solo sitio -------------------------------
CREATE OR REPLACE FUNCTION vigilante.respaldo_senal(p_signal bigint)
RETURNS TABLE (n_fuentes int, oficial boolean, verificada boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  -- Fuentes distintas y oficial, contados igual que la fiabilidad del 22 (lo que ve la web en cada señal)
  WITH s AS (SELECT id, raw_item_id, fuente_oficial, es_escenario, salida_modelo FROM vigilante.signals WHERE id = p_signal),
  r AS (
    SELECT r.id, r.source_id, src.tipo FROM vigilante.raw_items r
      LEFT JOIN vigilante.sources src ON src.id = r.source_id
     WHERE r.id IN (SELECT sr.raw_item_id FROM vigilante.signal_raw_items sr WHERE sr.signal_id = p_signal
                    UNION SELECT s.raw_item_id FROM s WHERE s.raw_item_id IS NOT NULL)
  ),
  n AS (
    SELECT CASE WHEN count(r.id) > 0 THEN count(DISTINCT coalesce(r.source_id::text, 'n' || r.id::text))::int
                -- señales antiguas copiadas de vigilante.json: sus enlaces, por nombre de medio
                ELSE (SELECT count(DISTINCT coalesce(e ->> 'nombre', e ->> 'url'))::int FROM s,
                        jsonb_array_elements(CASE WHEN jsonb_typeof(s.salida_modelo -> 'enlaces') = 'array'
                                                  THEN s.salida_modelo -> 'enlaces' ELSE '[]' END) e) END AS n,
           coalesce(bool_or(r.tipo IN ('oficial', 'organismo_internacional')), false) AS oficial_noticia
      FROM r
  )
  SELECT n.n, s.fuente_oficial OR n.oficial_noticia,
         NOT s.es_escenario AND (s.fuente_oficial OR n.oficial_noticia OR n.n >= 2)
    FROM s, n
$$;
REVOKE ALL ON FUNCTION vigilante.respaldo_senal(bigint) FROM public, anon, authenticated;

-- 2. Contadores con la regla única ---------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.contadores(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH a AS (
    SELECT s.*, r.n_fuentes, r.verificada
      FROM vigilante.senales_visibles(p_cliente) s
      CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
     WHERE s.estado <> 'descartada'
  ),
  c AS (SELECT * FROM a WHERE estado IN ('confirmada', 'publicada')),
  v AS (SELECT * FROM c WHERE verificada),
  f AS (
    SELECT * FROM vigilante.sources
     WHERE cliente_id = p_cliente AND eliminada_en IS NULL
  )
  SELECT jsonb_build_object(
    'actualizado', now(),
    'senales_activas',     (SELECT count(*) FROM a),
    'oportunidades',       (SELECT count(*) FROM a WHERE naturaleza = 'oportunidad'),
    'riesgos',             (SELECT count(*) FROM a WHERE naturaleza = 'riesgo'),
    'mixtas',              (SELECT count(*) FROM a WHERE naturaleza = 'mixta'),
    'plazo_corto',         (SELECT count(*) FROM a WHERE naturaleza <> 'riesgo' AND vigilante.dias_para(plazo_hasta) < 15),
    'riesgos_altos',       (SELECT count(*) FROM a WHERE naturaleza = 'riesgo' AND prioridad = 'alta'),
    'verificadas',               (SELECT count(*) FROM v),
    'verificadas_2_fuentes',     (SELECT count(*) FROM v WHERE n_fuentes >= 2),
    'verificadas_oficial',       (SELECT count(*) FROM v WHERE n_fuentes < 2),
    'verificadas_una_fuente',    0,
    'confirmadas_sin_verificar', (SELECT count(*) FROM c WHERE NOT verificada),
    'por_verificar',       (SELECT count(*) FROM a WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'esperan_aprobacion',  (SELECT count(*) FROM a WHERE requiere_revision AND estado IN ('detectada', 'en_analisis', 'en_verificacion')),
    'alertas_publicadas',  (SELECT count(*) FROM a WHERE estado = 'publicada'),
    'alertas_verificadas', (SELECT count(*) FROM v WHERE estado = 'publicada'),
    'descartadas',         (SELECT count(*) FROM vigilante.senales_visibles(p_cliente) s WHERE s.estado = 'descartada'),
    'noticias_24h',        (SELECT count(*) FROM vigilante.raw_items r WHERE r.cliente_id = p_cliente AND r.recolectado_en > now() - interval '24 hours'),
    'fuentes_activas',     (SELECT count(*) FROM f WHERE activa AND NOT coalesce((config ->> 'propuesta_avia')::boolean, false)),
    'fuentes_en_pausa',    (SELECT count(*) FROM f WHERE NOT activa OR coalesce((config ->> 'propuesta_avia')::boolean, false))
  )
$$;
REVOKE ALL ON FUNCTION vigilante.contadores(uuid) FROM public, anon, authenticated;

-- 3. Web pública y Telegram: «Verificada» / «En verificación» con la misma regla ------
-- Antes una alerta sin enlace no podía estar «En verificación». Ahora la etiqueta la pone la regla;
-- si falta el enlace se toma el de la primera noticia de la señal.
ALTER TABLE vigilante.alerts DROP CONSTRAINT IF EXISTS alerts_en_verificacion_con_enlace;

CREATE OR REPLACE FUNCTION vigilante.tg_alerts_verificacion() RETURNS trigger
LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  NEW.estado_verificacion := CASE WHEN (SELECT r.verificada FROM vigilante.respaldo_senal(NEW.signal_id) r)
                                  THEN 'confirmada' ELSE 'en_verificacion' END::vigilante.estado_verificacion;
  IF NEW.enlace_fuente IS NULL THEN
    NEW.enlace_fuente := (SELECT r.url FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                           WHERE sr.signal_id = NEW.signal_id ORDER BY r.publicado_en NULLS LAST, r.id LIMIT 1);
  END IF;
  RETURN NEW;
END $$;
-- «a_v…» para ir después de a_heredar_cliente y antes de alerts_version y que el cambio de etiqueta suba la versión
DROP TRIGGER IF EXISTS a_verificacion_unica ON vigilante.alerts;
CREATE TRIGGER a_verificacion_unica BEFORE INSERT OR UPDATE ON vigilante.alerts
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_alerts_verificacion();

-- Si cambian las noticias o la fuente de la señal, la alerta abierta se vuelve a etiquetar
CREATE OR REPLACE FUNCTION vigilante.refrescar_verificacion_alerta(p_signal bigint) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  UPDATE vigilante.alerts a
     SET estado_verificacion = CASE WHEN r.verificada THEN 'confirmada' ELSE 'en_verificacion' END::vigilante.estado_verificacion
    FROM vigilante.respaldo_senal(p_signal) r
   WHERE a.signal_id = p_signal AND a.cerrada_en IS NULL
     AND a.estado_verificacion IS DISTINCT FROM CASE WHEN r.verificada THEN 'confirmada' ELSE 'en_verificacion' END::vigilante.estado_verificacion
$$;
REVOKE ALL ON FUNCTION vigilante.refrescar_verificacion_alerta(bigint) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.tg_refrescar_verificacion() RETURNS trigger
LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF TG_TABLE_NAME = 'signal_raw_items' THEN
    PERFORM vigilante.refrescar_verificacion_alerta(CASE WHEN TG_OP = 'DELETE' THEN OLD.signal_id ELSE NEW.signal_id END);
  ELSE
    PERFORM vigilante.refrescar_verificacion_alerta(NEW.id);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_refrescar_verificacion ON vigilante.signal_raw_items;
CREATE TRIGGER zz_refrescar_verificacion AFTER INSERT OR DELETE ON vigilante.signal_raw_items
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_refrescar_verificacion();
DROP TRIGGER IF EXISTS zz_refrescar_verificacion ON vigilante.signals;
CREATE TRIGGER zz_refrescar_verificacion AFTER UPDATE OF fuente_oficial, es_escenario, raw_item_id ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_refrescar_verificacion();

-- 4. Poner al día las alertas abiertas -------------------------------------------------
-- (solo cambia las que no cuadran: las demás no suben de versión)
DO $$ BEGIN PERFORM vigilante.refrescar_verificacion_alerta(signal_id) FROM vigilante.alerts WHERE cerrada_en IS NULL; END $$;

COMMIT;

-- Diagnóstico (opcional): cómo queda cada señal confirmada o publicada
-- SELECT s.codigo, s.estado, r.* FROM vigilante.signals s CROSS JOIN LATERAL vigilante.respaldo_senal(s.id) r
--  WHERE s.estado IN ('confirmada', 'publicada') ORDER BY r.verificada, s.codigo;
