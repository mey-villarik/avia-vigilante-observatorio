-- =============================================================================
-- ORBITA · Conexión Hermes (Vigía) → base de datos → web pública
-- Se instala DESPUÉS de 01_orbita_schema.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 03_conexion_hermes_web.sql
-- En Supabase: SQL Editor → pegar este archivo → Run.
--
-- Crea tres cosas:
--   1. orbita.registrar_senal_hermes(json)  → guarda lo que encuentra Hermes
--   2. orbita.decidir_y_publicar(...)       → el analista aprueba o descarta
--   3. orbita.v_alertas_web                 → lo que muestra la web (solo aprobado)
-- =============================================================================
SET search_path = orbita, public;

-- -----------------------------------------------------------------------------
-- 1. Recibir una señal de Hermes
--    Entrada: el JSON que devuelve la skill vigilancia-fuentes-bolivia.
--    Salida:  {"ok":true,"accion":"en_revision"|"publicada"|"descartada"|"duplicada", ...}
--    Regla: lo que exige revisión (clima, salud, vial, seguridad, fuente no oficial,
--    escenario) queda esperando al analista. Lo demás, si viene de fuente oficial,
--    se publica solo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION orbita.registrar_senal_hermes(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_source_id  smallint;
  v_codigo     text := nullif(trim(p->>'fuente_id'), '');
  v_enlace     text := nullif(trim(p->>'enlace_oficial'), '');
  v_signal     orbita.signals;
  v_review     orbita.reviews;
  v_alert_id   bigint;
  v_existente  bigint;
  v_dep        text;
  v_dep_id     smallint;
  v_sin_dep    text[] := '{}';
  v_vigencia   timestamptz;
BEGIN
  -- Hermes decidió que no es relevante
  IF coalesce((p->>'descartar')::boolean, false) THEN
    RETURN jsonb_build_object('ok', true, 'accion', 'descartada', 'motivo', p->>'motivo');
  END IF;

  -- Actualizaciones de una señal existente: en la PoC las revisa el analista a mano
  IF p->>'accion' = 'actualizar_senal_existente' THEN
    RETURN jsonb_build_object('ok', true, 'accion', 'actualizacion_para_revisar', 'detalle', p);
  END IF;

  -- Campos obligatorios
  IF coalesce(trim(p->>'titulo'), '') = '' OR coalesce(trim(p->>'resumen'), '') = ''
     OR coalesce(p->>'categoria', '') = '' OR coalesce(p->>'naturaleza', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Faltan campos obligatorios: titulo, resumen, categoria o naturaleza');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orbita.categorias WHERE codigo = p->>'categoria') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Categoría desconocida: ' || (p->>'categoria'));
  END IF;
  IF p->>'naturaleza' NOT IN ('riesgo', 'oportunidad', 'mixta') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Naturaleza desconocida: ' || (p->>'naturaleza'));
  END IF;
  IF v_enlace IS NOT NULL AND v_enlace !~* '^https?://' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'enlace_oficial debe empezar por http:// o https://');
  END IF;

  -- Fuente (la skill usa "minturismo"; la semilla de la BD aún dice "minculturas")
  IF v_codigo = 'minturismo' AND NOT EXISTS (SELECT 1 FROM orbita.sources WHERE codigo = 'minturismo') THEN
    v_codigo := 'minculturas';
  END IF;
  SELECT id INTO v_source_id FROM orbita.sources WHERE codigo = v_codigo;
  IF v_source_id IS NULL THEN
    -- Fuente desconocida: se guarda como no oficial (irá a revisión)
    SELECT id INTO v_source_id FROM orbita.sources WHERE codigo = 'tavily';
  END IF;

  -- Duplicado: mismo título y mismo enlace en los últimos 7 días
  SELECT id INTO v_existente FROM orbita.signals
   WHERE lower(titulo) = lower(trim(p->>'titulo'))
     AND enlace_oficial IS NOT DISTINCT FROM v_enlace
     AND created_at > now() - interval '7 days'
   LIMIT 1;
  IF v_existente IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'accion', 'duplicada', 'signal_id', v_existente);
  END IF;

  -- Guardar la señal (el trigger decide si requiere revisión)
  INSERT INTO orbita.signals (source_id, titulo, resumen, recomendacion, naturaleza, categoria, prioridad,
                              motivos_prioridad, confianza, alcance_nacional, es_escenario, fuente_oficial,
                              enlace_oficial, estado, requiere_revision,
                              fecha_evento_inicio, fecha_evento_fin, plazo_hasta, modelo, salida_modelo)
  VALUES (v_source_id,
          left(trim(p->>'titulo'), 200),
          trim(p->>'resumen'),
          nullif(trim(p->>'recomendacion'), ''),
          (p->>'naturaleza')::orbita.naturaleza_senal,
          p->>'categoria',
          coalesce(nullif(p->>'prioridad', ''), 'media')::orbita.prioridad,
          coalesce(ARRAY(SELECT jsonb_array_elements_text(p->'motivos_prioridad')), '{}'),
          least(greatest(coalesce((p->>'confianza')::numeric, 0.5), 0), 1),
          coalesce((p->>'alcance_nacional')::boolean, false),
          coalesce((p->>'es_escenario')::boolean, false),
          coalesce((p->>'fuente_oficial')::boolean, false),
          v_enlace,
          'en_analisis',
          coalesce((p->>'requiere_revision')::boolean, false),
          nullif(p->>'fecha_evento_inicio', '')::timestamptz,
          nullif(p->>'fecha_evento_fin', '')::timestamptz,
          nullif(p->>'plazo_hasta', '')::timestamptz,
          coalesce(nullif(p->>'modelo', ''), 'hermes'),
          p)
  RETURNING * INTO v_signal;

  -- Departamentos: acepta "La Paz", "la paz", "Potosi", "BO-L"...
  FOR v_dep IN SELECT jsonb_array_elements_text(coalesce(p->'departamentos', '[]')) LOOP
    SELECT id INTO v_dep_id FROM orbita.departamentos
     WHERE translate(lower(nombre), 'áéíóú', 'aeiou') = translate(lower(trim(v_dep)), 'áéíóú', 'aeiou')
        OR lower(codigo) = lower(trim(v_dep));
    IF v_dep_id IS NULL THEN
      v_sin_dep := v_sin_dep || v_dep;
    ELSE
      INSERT INTO orbita.signal_departamentos VALUES (v_signal.id, v_dep_id) ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;

  -- Vigencia en la web: fin del evento, cierre de convocatoria o, para riesgos sin fecha, 3 días
  v_vigencia := coalesce(v_signal.fecha_evento_fin, v_signal.plazo_hasta,
                         CASE WHEN v_signal.naturaleza = 'riesgo' THEN now() + interval '3 days' END);

  -- Borrador de alerta (todavía no publicada)
  INSERT INTO orbita.alerts (signal_id, titulo, texto, recomendacion, enlace_fuente, es_escenario,
                             visibilidad, vigente_hasta)
  VALUES (v_signal.id, v_signal.titulo, v_signal.resumen, v_signal.recomendacion, v_enlace,
          v_signal.es_escenario,
          CASE WHEN v_signal.es_escenario THEN 'privada' ELSE 'publica' END::orbita.visibilidad,
          v_vigencia)
  RETURNING id INTO v_alert_id;

  IF v_signal.requiere_revision THEN
    SELECT * INTO v_review FROM orbita.solicitar_revision(v_signal.id);
    RETURN jsonb_build_object('ok', true, 'accion', 'en_revision',
                              'signal_id', v_signal.id, 'alert_id', v_alert_id, 'review_id', v_review.id,
                              'vence_en', v_review.vence_en, 'motivo', v_signal.motivo_revision,
                              'titulo', v_signal.titulo, 'resumen', v_signal.resumen,
                              'categoria', v_signal.categoria, 'prioridad', v_signal.prioridad,
                              'enlace', v_enlace, 'departamentos_no_reconocidos', v_sin_dep);
  END IF;

  -- Oportunidad de fuente oficial sin revisión obligatoria: se publica directamente
  UPDATE orbita.signals SET estado = 'confirmada' WHERE id = v_signal.id;
  UPDATE orbita.signals SET estado = 'publicada'  WHERE id = v_signal.id;
  UPDATE orbita.alerts  SET publicada_en = now()  WHERE id = v_alert_id;
  RETURN jsonb_build_object('ok', true, 'accion', 'publicada',
                            'signal_id', v_signal.id, 'alert_id', v_alert_id,
                            'titulo', v_signal.titulo, 'departamentos_no_reconocidos', v_sin_dep);
END $$;

-- -----------------------------------------------------------------------------
-- 2. Decisión del analista (botones "Aprobar" / "Descartar" del mensaje de Telegram)
--    p_decision: 'aprobada' o 'rechazada'.
--    p_analista: uuid de orbita.users. Si se deja vacío se usa el analista activo
--    más antiguo (sirve mientras haya un solo analista en la beta).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION orbita.decidir_y_publicar(p_review_id bigint, p_decision text,
                                                     p_analista uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_analista uuid := p_analista;
  v_review   orbita.reviews;
  v_titulo   text;
BEGIN
  IF p_decision NOT IN ('aprobada', 'rechazada') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'La decisión debe ser aprobada o rechazada');
  END IF;
  IF v_analista IS NULL THEN
    SELECT id INTO v_analista FROM orbita.users
     WHERE rol IN ('analista', 'administrador') AND activo ORDER BY created_at LIMIT 1;
  END IF;
  IF v_analista IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No hay ningún analista activo en orbita.users');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM orbita.reviews WHERE id = p_review_id AND decision IN ('pendiente', 'vencida')) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Esta revisión no existe o ya fue decidida');
  END IF;

  v_review := orbita.decidir_revision(p_review_id, v_analista, p_decision::orbita.decision_revision);
  SELECT titulo INTO v_titulo FROM orbita.signals WHERE id = v_review.signal_id;

  IF p_decision = 'aprobada' THEN
    UPDATE orbita.signals SET estado = 'publicada'
     WHERE id = v_review.signal_id AND estado = 'confirmada';
    UPDATE orbita.alerts SET publicada_en = coalesce(publicada_en, now())
     WHERE signal_id = v_review.signal_id;
    RETURN jsonb_build_object('ok', true, 'accion', 'publicada', 'signal_id', v_review.signal_id, 'titulo', v_titulo);
  END IF;
  RETURN jsonb_build_object('ok', true, 'accion', 'descartada', 'signal_id', v_review.signal_id, 'titulo', v_titulo);
END $$;

-- Solo n8n (usuario postgres / service_role) puede llamar a estas funciones
REVOKE EXECUTE ON FUNCTION orbita.registrar_senal_hermes(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION orbita.decidir_y_publicar(bigint, text, uuid) FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Lo que ve la web: alertas públicas, publicadas, vigentes y aprobadas
--    (o "en verificación" con enlace oficial). Añade nombre de fuente y confianza.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW orbita.v_alertas_web WITH (security_barrier) AS
SELECT p.*,
       src.nombre      AS fuente_nombre,
       s.fuente_oficial,
       s.confianza,
       s.es_escenario,
       s.created_at    AS detectada_en,
       a.aprobada_en
  FROM orbita.v_alertas_publicas p
  JOIN orbita.alerts  a   ON a.id = p.id
  JOIN orbita.signals s   ON s.id = a.signal_id
  LEFT JOIN orbita.sources src ON src.id = s.source_id;

GRANT SELECT ON orbita.v_alertas_web TO anon, authenticated;
