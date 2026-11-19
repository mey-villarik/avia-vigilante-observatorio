-- =============================================================================
-- AVIA Vigilante · Señales en tres columnas, pase en bloque y menos trabajo manual
-- Requiere 01 a 17 (el 18 no hace falta). Se puede ejecutar más de una vez.
--
-- Decisiones de Meysel (19-11-2026): menos gestión humana y AVIA como protagonista.
--   1. La pestaña Señales muestra solo tres columnas:
--        Detectadas  = detectada + en_analisis + en_verificacion (lo que AVIA aún trabaja)
--        Confirmadas = confirmada
--        Publicadas  = publicada (+ cerrada)
--   2. Entre columna y columna, dos botones pequeños: «→ todas» y «← todas».
--      Se puede mover igual una a una (arrastrar) que en grupo, en los dos sentidos.
--   3. Ya no hay aprobación previa («Por aprobar»): ninguna señal espera a un analista
--      para poder moverse. Sigue sin publicarse nada solo: a Publicadas la pasa siempre
--      una persona (botón o arrastre), y eso es su aprobación.
--      Parámetro aprobacion_previa (false). Ponerlo en true vuelve a la regla del 18.
--   4. Las señales de fuente oficial no se quedan en Detectadas: AVIA las pasa sola a
--      Confirmadas (salvo escenarios, y salvo que una persona la haya movido a mano).
--
-- Qué añade:
--   * vigilante.pasar_senales(codigos, destino, nota): mueve varias de una vez hacia
--     'en_analisis' (Detectadas), 'confirmada' o 'publicada', sin saltar etapas y con
--     historial. Un escenario nunca se publica.
--   * Transiciones hacia atrás: confirmada → en_analisis y publicada → confirmada
--     (la alerta se retira de la web pública; el mensaje ya enviado a Telegram no se borra).
--   * Trigger zz_sin_aprobacion_y_oficiales (se ejecuta después de las reglas del 01).
--
-- Guía: docs/pase-en-bloque.md · Prueba: 99_prueba_pase_en_bloque.sql
-- =============================================================================

BEGIN;

-- 0. Parámetros ---------------------------------------------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'aprobacion_previa',            'false', 'true = las señales de riesgo o sin fuente oficial esperan aprobación de un analista (regla del 18). false = no hay «Por aprobar»; publicar lo hace siempre una persona'),
  (NULL, 'oficiales_directo_confirmadas', 'true', 'Las señales de fuente oficial pasan solas a Confirmadas')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Transiciones: se añaden las dos hacia atrás --------------------------------------
CREATE OR REPLACE FUNCTION vigilante.transicion_valida(p_de vigilante.estado_senal, p_a vigilante.estado_senal)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_de = p_a OR p_a = 'descartada' OR (p_de, p_a) IN (
    ('detectada',       'en_analisis'),
    ('en_analisis',     'en_verificacion'),
    ('en_analisis',     'confirmada'),
    ('en_verificacion', 'confirmada'),
    ('en_verificacion', 'publicada'),
    ('confirmada',      'publicada'),
    ('confirmada',      'en_analisis'),   -- 29: devolver a Detectadas
    ('publicada',       'en_verificacion'),
    ('publicada',       'confirmada'),    -- 29: retirar de la web, sigue confirmada
    ('publicada',       'cerrada'),
    ('confirmada',      'cerrada')
  )
$$;

-- 2. Sin aprobación previa y oficiales directas a Confirmadas -------------------------
-- BEFORE: se ejecuta después de signals_reglas (orden alfabético), que marca requiere_revision.
CREATE OR REPLACE FUNCTION vigilante.tg_sin_aprobacion_y_oficiales() RETURNS trigger
LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF NOT coalesce((vigilante.param(NEW.cliente_id, 'aprobacion_previa') #>> '{}')::boolean, false) THEN
    NEW.requiere_revision := false;
    NEW.motivo_revision   := NULL;
  END IF;

  IF coalesce((vigilante.param(NEW.cliente_id, 'oficiales_directo_confirmadas') #>> '{}')::boolean, true)
     AND NEW.fuente_oficial AND NOT coalesce(NEW.es_escenario, false)
     AND NEW.estado IN ('detectada', 'en_analisis', 'en_verificacion')
     AND NOT coalesce(NEW.estado_manual, false)
     -- to_jsonb: funciona aunque no se haya ejecutado el 18 (columna revision_decidida_en)
     AND NOT (NEW.requiere_revision AND (to_jsonb(NEW) ->> 'revision_decidida_en') IS NULL) THEN
    NEW.estado := 'confirmada';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zz_sin_aprobacion_y_oficiales ON vigilante.signals;
CREATE TRIGGER zz_sin_aprobacion_y_oficiales BEFORE INSERT OR UPDATE ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_sin_aprobacion_y_oficiales();

-- 3. Pase en bloque (y de una en una) -----------------------------------------------
DROP FUNCTION IF EXISTS vigilante.pasar_senales(text[], text, text);
CREATE FUNCTION vigilante.pasar_senales(p_codigos text[], p_a text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_codigo   text;
  s          vigilante.signals;
  v_movidas  text[] := '{}';
  v_omitidas jsonb  := '[]'::jsonb;
  v_nota     text   := coalesce(nullif(trim(coalesce(p_nota, '')), ''), 'Pase en bloque');
  v_motivo   text;
  v_col_de   int;
  v_col_a    int;
  v_paso     vigilante.estado_senal;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede mover señales'; END IF;
  IF p_a NOT IN ('en_analisis', 'confirmada', 'publicada') THEN
    RAISE EXCEPTION 'El pase en bloque solo lleva a en_analisis (Detectadas), confirmada o publicada (pedido: %)', p_a;
  END IF;
  IF coalesce(array_length(p_codigos, 1), 0) > 500 THEN
    RAISE EXCEPTION 'Demasiadas señales de una vez (máximo 500)';
  END IF;
  v_col_a := CASE p_a WHEN 'en_analisis' THEN 1 WHEN 'confirmada' THEN 2 ELSE 3 END;

  FOREACH v_codigo IN ARRAY coalesce(p_codigos, '{}') LOOP
    SELECT * INTO s FROM vigilante.signals
     WHERE cliente_id = vigilante.cliente_actual() AND codigo = v_codigo FOR UPDATE;
    v_motivo := NULL;
    v_col_de := CASE WHEN s.estado IN ('detectada', 'en_analisis', 'en_verificacion') THEN 1
                     WHEN s.estado = 'confirmada' THEN 2 WHEN s.estado = 'publicada' THEN 3 END;

    IF s.id IS NULL THEN
      v_motivo := 'aún no está en la base de datos';
    ELSIF v_col_de IS NULL THEN
      v_motivo := 'está descartada o cerrada';
    ELSIF v_col_de = v_col_a THEN
      v_motivo := 'ya está en esa columna';
    ELSIF p_a = 'publicada' AND s.es_escenario THEN
      v_motivo := 'es un escenario: no se publica';
    END IF;
    IF v_motivo IS NOT NULL THEN
      v_omitidas := v_omitidas || jsonb_build_object('codigo', v_codigo, 'motivo', v_motivo);
      CONTINUE;
    END IF;

    -- paso a paso (el trigger del 01 vuelve a comprobar cada transición)
    WHILE v_col_de <> v_col_a LOOP
      v_paso := CASE
        WHEN v_col_de < v_col_a AND s.estado = 'detectada' THEN 'en_analisis'
        WHEN v_col_de < v_col_a AND v_col_de = 1          THEN 'confirmada'
        WHEN v_col_de < v_col_a                           THEN 'publicada'
        WHEN v_col_de = 3                                 THEN 'confirmada'
        ELSE 'en_analisis' END;
      UPDATE vigilante.signals SET estado = v_paso, estado_manual = true WHERE id = s.id;
      s.estado := v_paso;
      v_col_de := CASE WHEN v_paso = 'en_analisis' THEN 1 WHEN v_paso = 'confirmada' THEN 2 ELSE 3 END;
    END LOOP;

    UPDATE vigilante.signal_history SET nota = v_nota
     WHERE id = (SELECT max(id) FROM vigilante.signal_history
                  WHERE signal_id = s.id AND entidad = 'signal' AND estado_nuevo IS NOT NULL);
    v_movidas := v_movidas || v_codigo;
  END LOOP;

  RETURN jsonb_build_object('movidas', to_jsonb(v_movidas), 'omitidas', v_omitidas);
END $$;
REVOKE ALL ON FUNCTION vigilante.pasar_senales(text[], text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.pasar_senales(text[], text, text) TO authenticated;

-- 4. Aplicar ya a lo que hay: quitar «Por aprobar» y pasar las oficiales a Confirmadas --
UPDATE vigilante.signals SET requiere_revision = requiere_revision
 WHERE estado IN ('detectada', 'en_analisis', 'en_verificacion');

COMMIT;

-- Comprobar: cuántas quedan en cada columna y cuántas esperan aprobación (debería ser 0)
-- SELECT estado, count(*), count(*) FILTER (WHERE requiere_revision) AS por_aprobar
--   FROM vigilante.signals GROUP BY 1 ORDER BY 1;
