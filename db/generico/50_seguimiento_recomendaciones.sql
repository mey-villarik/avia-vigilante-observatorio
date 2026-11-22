-- =============================================================================
-- 50. Seguimiento de recomendaciones: pendiente · en curso · resuelta · sin efecto
-- =============================================================================
-- Qué pide la Dirección (auditoría para la Dirección de Turismo, P2, 2026-11-22): cerrar el ciclo
-- «actuar». De cada recomendación que da AVIA (la ficha «Acción recomendada · Plazo · Cómo verificar»
-- del 49) tiene que quedar qué se recomendó, qué se hizo y qué pasó.
--
-- Reglas:
--   · Una recomendación por señal: la acción de su ficha (vigilante.ficha_direccion, 49).
--   · Cuatro estados: pendiente (nadie la ha tomado), en_curso (alguien está actuando),
--     resuelta (se actuó y salió bien), sin_efecto (no hizo falta, no se pudo o no sirvió).
--   · Sin fila guardada, la recomendación está «pendiente».
--   · Solo analistas y administradores cambian el estado; el visor lo ve.
--   · Para «resuelta» y «sin efecto» hace falta una nota: qué se hizo, quién actuó y qué pasó.
--     No hay campo de responsable (la Dirección no tiene responsables por eje, Meysel 22/11): quién
--     actuó va en la nota, y queda guardado quién registró el cambio.
--   · Se guarda el texto de la recomendación en el momento del cambio: si AVIA la cambia después,
--     se sigue sabiendo qué se recomendó entonces, y la web avisa de que cambió.
--   · Cuentan como «por atender» las recomendaciones de las señales que pesan para la Dirección:
--     riesgos en Acción o Atención y oportunidades que cierran o empiezan en 7 días.
--
-- Qué hace:
--   1. Tablas vigilante.seguimiento_recomendaciones (estado actual) y vigilante.seguimiento_historial.
--   2. vigilante.seguir_recomendacion(codigo, estado, nota): la web cambia el estado.
--   3. vigilante.seguimiento_senal(id) y vigilante.seguimiento_resumen(cliente).
--   4. vigilante_bd() y vigilante_json() añaden «seguimiento» a cada señal y, arriba, el resumen.
--      Envuelven a _con_direccion (49): si se vuelve a ejecutar el 49, ejecutar después este 50.
--
-- Necesita el 49 (y lo anterior). Se puede ejecutar varias veces.
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar:
--   SELECT jsonb_pretty(vigilante.seguimiento_resumen(id)) FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_seguimiento.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 1. Tablas -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vigilante.seguimiento_recomendaciones (
  signal_id       bigint PRIMARY KEY REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  estado          text NOT NULL DEFAULT 'pendiente'
                  CHECK (estado IN ('pendiente', 'en_curso', 'resuelta', 'sin_efecto')),
  recomendacion   text,                 -- lo que recomendaba AVIA cuando se cambió el estado
  nota            text,                 -- qué se hizo, quién actuó, qué pasó
  actualizado_por text,                 -- nombre de quien lo registró
  actualizado_en  timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS seguimiento_recomendaciones_cliente_idx
  ON vigilante.seguimiento_recomendaciones (cliente_id, estado);

CREATE TABLE IF NOT EXISTS vigilante.seguimiento_historial (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  signal_id       bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  cliente_id      uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  de              text,
  a               text NOT NULL,
  recomendacion   text,
  nota            text,
  quien           text,
  usuario_id      uuid,
  cuando          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS seguimiento_historial_signal_idx ON vigilante.seguimiento_historial (signal_id, cuando DESC);

ALTER TABLE vigilante.seguimiento_recomendaciones ENABLE ROW LEVEL SECURITY;   -- sin políticas: solo por las funciones
ALTER TABLE vigilante.seguimiento_historial ENABLE ROW LEVEL SECURITY;

-- 2. Cambiar el estado (la web; analista o administrador del mismo cliente) ----------------------
CREATE OR REPLACE FUNCTION vigilante.seguir_recomendacion(p_codigo text, p_estado text, p_nota text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.cliente_actual();
  v_id bigint; v_de text; v_reco text; v_quien text; v_nota text := nullif(trim(p_nota), '');
BEGIN
  IF NOT vigilante.es_staff() THEN
    RAISE EXCEPTION 'Solo un analista o un administrador puede cambiar el seguimiento';
  END IF;
  IF p_estado NOT IN ('pendiente', 'en_curso', 'resuelta', 'sin_efecto') THEN
    RAISE EXCEPTION 'Estado no válido: %', p_estado;
  END IF;
  IF p_estado IN ('resuelta', 'sin_efecto') AND v_nota IS NULL THEN
    RAISE EXCEPTION 'Para cerrar una recomendación escribe qué se hizo, quién actuó y qué pasó';
  END IF;
  SELECT id INTO v_id FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = p_codigo;
  IF v_id IS NULL THEN RAISE EXCEPTION 'La señal % aún no está en la base de datos', p_codigo; END IF;

  SELECT estado INTO v_de FROM vigilante.seguimiento_recomendaciones WHERE signal_id = v_id FOR UPDATE;
  v_reco := vigilante.ficha_direccion(v_id) ->> 'accion';
  SELECT nombre INTO v_quien FROM vigilante.users WHERE id = vigilante.usuario_actual();

  INSERT INTO vigilante.seguimiento_recomendaciones AS r
         (signal_id, cliente_id, estado, recomendacion, nota, actualizado_por, actualizado_en)
  VALUES (v_id, v_cliente, p_estado, v_reco, v_nota, v_quien, now())
  ON CONFLICT (signal_id) DO UPDATE
     SET estado = EXCLUDED.estado, recomendacion = EXCLUDED.recomendacion,
         nota = coalesce(EXCLUDED.nota, CASE WHEN r.estado = EXCLUDED.estado THEN r.nota END),
         actualizado_por = EXCLUDED.actualizado_por, actualizado_en = now();

  INSERT INTO vigilante.seguimiento_historial (signal_id, cliente_id, de, a, recomendacion, nota, quien, usuario_id)
  VALUES (v_id, v_cliente, coalesce(v_de, 'pendiente'), p_estado, v_reco, v_nota, v_quien, vigilante.usuario_actual());

  RETURN vigilante.seguimiento_senal(v_id);
END $$;

-- 3a. Seguimiento de una señal: estado, nota, quién, cuándo y los últimos cambios -----------------
CREATE OR REPLACE FUNCTION vigilante.seguimiento_senal(p_signal bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'estado', coalesce(r.estado, 'pendiente'),
    'recomendacion', r.recomendacion,
    'nota', r.nota,
    'quien', r.actualizado_por,
    'cuando', r.actualizado_en,
    'cambio_reco', CASE WHEN r.recomendacion IS NOT NULL
                         AND r.recomendacion IS DISTINCT FROM vigilante.ficha_direccion(p_signal) ->> 'accion' THEN true END,
    'historial', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('de', h.de, 'a', h.a, 'nota', h.nota, 'quien', h.quien,
                                                                        'cuando', h.cuando, 'recomendacion', h.recomendacion))
                                   ORDER BY h.cuando DESC, h.id DESC)
                    FROM (SELECT * FROM vigilante.seguimiento_historial WHERE signal_id = p_signal
                           ORDER BY cuando DESC, id DESC LIMIT 5) h)))
  FROM (SELECT 1) uno
  LEFT JOIN vigilante.seguimiento_recomendaciones r ON r.signal_id = p_signal
$$;

-- 3b. Resumen para la Dirección y el chat AVIA ----------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.seguimiento_resumen(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH s AS (
    SELECT s.id, s.codigo, s.titulo, s.naturaleza,
           vigilante.estado_direccion(s.id) AS est_dir,
           vigilante.dia_bo(s.plazo_hasta) AS cierre,
           (s.fecha_evento_inicio AT TIME ZONE 'UTC')::date AS ini,
           r.estado, r.nota, r.actualizado_por, r.actualizado_en
      FROM vigilante.senales_visibles(p_cliente) s
      LEFT JOIN vigilante.seguimiento_recomendaciones r ON r.signal_id = s.id
     WHERE s.estado <> 'descartada'),
  k AS (
    -- pesan: riesgos en Acción o Atención y oportunidades que cierran o empiezan en 7 días
    SELECT s.*, coalesce(s.estado, 'pendiente') AS seg,
           (s.est_dir IN ('accion', 'atencion')
            OR (s.naturaleza <> 'riesgo' AND (s.cierre BETWEEN vigilante.hoy_bo() AND vigilante.hoy_bo() + 7
                                              OR s.ini BETWEEN vigilante.hoy_bo() AND vigilante.hoy_bo() + 7))) AS pesa
      FROM s),
  c AS (   -- solo lo que importa ahora: lo que pesa, lo que está en curso y lo cerrado en 7 días
    SELECT * FROM k
     WHERE (seg = 'pendiente' AND pesa) OR seg = 'en_curso'
        OR (seg IN ('resuelta', 'sin_efecto') AND actualizado_en >= now() - interval '7 days'))
  SELECT jsonb_build_object(
    'pendiente', count(*) FILTER (WHERE seg = 'pendiente'),
    'en_curso', count(*) FILTER (WHERE seg = 'en_curso'),
    'resuelta', count(*) FILTER (WHERE seg = 'resuelta'),
    'sin_efecto', count(*) FILTER (WHERE seg = 'sin_efecto'),
    'items', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'codigo', codigo, 'titulo', titulo, 'estado', seg, 'estado_direccion', est_dir,
               'recomendacion', vigilante.ficha_direccion(id) ->> 'accion',
               'nota', nota, 'quien', actualizado_por, 'cuando', actualizado_en))
             ORDER BY array_position(ARRAY['en_curso','pendiente','resuelta','sin_efecto'], seg),
                      CASE est_dir WHEN 'accion' THEN 0 WHEN 'atencion' THEN 1 ELSE 2 END,
                      actualizado_en DESC NULLS LAST), '[]'))
  FROM c
$$;

-- 4. vigilante_bd() y vigilante_json() con el seguimiento ----------------------------------------
CREATE OR REPLACE FUNCTION vigilante._con_seguimiento(p_json jsonb, p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN p_json IS NULL THEN NULL ELSE
    p_json
    || jsonb_build_object(
         'senales', coalesce((
           SELECT jsonb_agg(CASE WHEN s.id IS NULL THEN x ELSE x || jsonb_build_object('seguimiento', vigilante.seguimiento_senal(s.id)) END
                            ORDER BY o)
             FROM jsonb_array_elements(p_json -> 'senales') WITH ORDINALITY e(x, o)
             LEFT JOIN vigilante.signals s ON s.cliente_id = p_cliente AND s.codigo = x ->> 'id'), '[]'),
         'seguimiento', vigilante.seguimiento_resumen(p_cliente))
  END
$$;

CREATE OR REPLACE FUNCTION vigilante.vigilante_bd()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT CASE WHEN vigilante.cliente_actual() IS NULL THEN NULL
              ELSE vigilante._con_seguimiento(
                     vigilante._con_direccion(vigilante._vigilante_json(vigilante.cliente_actual()), vigilante.cliente_actual()),
                     vigilante.cliente_actual()) END
$$;

CREATE OR REPLACE FUNCTION vigilante.vigilante_json(p_cliente text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT vigilante._con_seguimiento(
           vigilante._con_direccion(vigilante._vigilante_json(vigilante.id_cliente(p_cliente)), vigilante.id_cliente(p_cliente)),
           vigilante.id_cliente(p_cliente))
$$;

-- Permisos ------------------------------------------------------------------------------------------
REVOKE ALL ON TABLE vigilante.seguimiento_recomendaciones, vigilante.seguimiento_historial FROM public, anon, authenticated;
GRANT ALL ON TABLE vigilante.seguimiento_recomendaciones, vigilante.seguimiento_historial TO service_role;
REVOKE ALL ON FUNCTION vigilante.seguir_recomendacion(text, text, text) FROM public, anon;
REVOKE ALL ON FUNCTION vigilante.seguimiento_senal(bigint) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION vigilante.seguimiento_resumen(uuid) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION vigilante._con_seguimiento(jsonb, uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.seguir_recomendacion(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION vigilante.seguimiento_senal(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION vigilante.seguimiento_resumen(uuid), vigilante._con_seguimiento(jsonb, uuid) TO service_role;

COMMIT;
