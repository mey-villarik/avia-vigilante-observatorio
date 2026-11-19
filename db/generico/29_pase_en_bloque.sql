-- =============================================================================
-- AVIA Vigilante · Pase en bloque de señales (pestaña Señales con tres columnas)
-- Requiere 01 a 18 (usa vigilante.espera_revision del 18). Se puede ejecutar más de una vez.
--
-- Pedido de Meysel (19-11-2026): menos trabajo manual y más protagonismo de AVIA.
-- La pestaña Señales muestra solo tres columnas:
--   Detectadas  = detectada + en_analisis + en_verificacion (lo que AVIA aún trabaja)
--   Confirmadas = confirmada
--   Publicadas  = publicada (+ cerrada)
-- y entre columna y columna un botón «Pasar todas →».
--
-- vigilante.pasar_senales(codigos, destino, nota) hace ese pase en una sola llamada y
-- respeta las mismas reglas que mover uno a uno, más dos protecciones:
--   * Las alertas de RIESGO (categorías con revision_obligatoria: clima, salud, vial,
--     seguridad) y los escenarios que esperan aprobación NUNCA se mueven en bloque: se
--     omiten y quedan para aprobarlas una por una («Aprobar y publicar» en su ficha o en
--     Telegram).
--   * Lo que solo espera aprobación por no tener aún fuente oficial SÍ pasa en bloque:
--     pulsar el botón es la aprobación de esa persona (decisión de Meysel, 19-11-2026),
--     y queda registrada como tal (revision_decidida_en / _por, trigger del 18).
--   * Un escenario nunca se publica: se omite al pasar a Publicadas.
-- Las etapas no se saltan: detectada → en_analisis → confirmada → publicada; cada paso
-- queda en el historial con el nombre de quien pulsó el botón.
--
-- Uso desde la web: rpc('pasar_senales', { p_codigos: [...], p_a: 'confirmada' | 'publicada' })
-- Respuesta: {"movidas": ["SEN-1", …], "omitidas": [{"codigo": "SEN-2", "motivo": "…"}, …]}
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION vigilante.pasar_senales(p_codigos text[], p_a text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_codigo   text;
  s          vigilante.signals;
  v_movidas  text[] := '{}';
  v_omitidas jsonb  := '[]'::jsonb;
  v_nota     text   := nullif(trim(coalesce(p_nota, '')), '');
  v_motivo   text;
BEGIN
  IF NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede mover señales'; END IF;
  IF p_a NOT IN ('confirmada', 'publicada') THEN
    RAISE EXCEPTION 'El pase en bloque solo lleva a confirmada o publicada (pedido: %)', p_a;
  END IF;
  IF coalesce(array_length(p_codigos, 1), 0) > 500 THEN
    RAISE EXCEPTION 'Demasiadas señales de una vez (máximo 500)';
  END IF;
  v_nota := coalesce(v_nota, 'Pase en bloque');

  FOREACH v_codigo IN ARRAY coalesce(p_codigos, '{}') LOOP
    SELECT * INTO s FROM vigilante.signals
     WHERE cliente_id = vigilante.cliente_actual() AND codigo = v_codigo FOR UPDATE;
    v_motivo := NULL;

    IF s.id IS NULL THEN
      v_motivo := 'aún no está en la base de datos';
    ELSIF vigilante.espera_revision(s) AND (s.es_escenario
          OR s.categoria IN ('clima', 'salud', 'vial', 'seguridad')
          OR EXISTS (SELECT 1 FROM vigilante.categorias c
                      WHERE c.cliente_id = s.cliente_id AND c.codigo = s.categoria AND c.revision_obligatoria)) THEN
      v_motivo := 'alerta de riesgo o escenario: se aprueba una por una desde su ficha';
    ELSIF p_a = 'confirmada' AND s.estado NOT IN ('detectada', 'en_analisis', 'en_verificacion') THEN
      v_motivo := 'ya no está en Detectadas';
    ELSIF p_a = 'publicada' AND s.estado <> 'confirmada' THEN
      v_motivo := 'no está en Confirmadas';
    ELSIF p_a = 'publicada' AND s.es_escenario THEN
      v_motivo := 'es un escenario: no se publica';
    END IF;

    IF v_motivo IS NOT NULL THEN
      v_omitidas := v_omitidas || jsonb_build_object('codigo', v_codigo, 'motivo', v_motivo);
      CONTINUE;
    END IF;

    -- mismas transiciones que mover_senal (el trigger de 01 las vuelve a comprobar)
    IF s.estado = 'detectada' THEN
      UPDATE vigilante.signals SET estado = 'en_analisis', estado_manual = true WHERE id = s.id;
      s.estado := 'en_analisis';
    END IF;
    IF s.estado IN ('en_analisis', 'en_verificacion') THEN
      UPDATE vigilante.signals SET estado = 'confirmada', estado_manual = true WHERE id = s.id;
      s.estado := 'confirmada';
    END IF;
    IF p_a = 'publicada' AND s.estado = 'confirmada' AND NOT s.es_escenario THEN
      UPDATE vigilante.signals SET estado = 'publicada', estado_manual = true WHERE id = s.id;
    END IF;

    UPDATE vigilante.signal_history SET nota = v_nota
     WHERE id = (SELECT max(id) FROM vigilante.signal_history
                  WHERE signal_id = s.id AND entidad = 'signal' AND estado_nuevo IS NOT NULL);
    v_movidas := v_movidas || v_codigo;
  END LOOP;

  RETURN jsonb_build_object('movidas', to_jsonb(v_movidas), 'omitidas', v_omitidas);
END $$;
REVOKE ALL ON FUNCTION vigilante.pasar_senales(text[], text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.pasar_senales(text[], text, text) TO authenticated;

COMMIT;
