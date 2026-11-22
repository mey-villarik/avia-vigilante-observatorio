-- =============================================================================
-- 45. Aviso de revisiones vencidas al principio de la síntesis, con responsable
-- =============================================================================
-- Qué pasaba: «8 señales con la revisión vencida» salía como una línea más al final de «Qué vigilar»,
-- sin decir quién tenía que decidirlas.
--
-- Ahora sintesis_dia() devuelve aparte «revisiones_vencidas», que el panel pone encima de todo:
--   · total: señales a las que se les venció el plazo de revisión y siguen sin decidir (siguen en
--       Detectada, En análisis o En verificación). Las que ya se confirmaron, publicaron, cerraron o
--       descartaron no cuentan aunque se decidieran tarde. Antes el 26 las contaba todas, así que la
--       cifra puede bajar. No mira requiere_revision: desde el 29 (sin «Por aprobar») se pone en false,
--       pero las señales que vencieron antes siguen esperando a alguien.
--   · senales: las 5 más antiguas (código, título, desde cuándo está vencida)
--   · responsable: el nombre del parámetro «responsable_revision» del cliente, si el administrador lo
--       puso; si no, los analistas activos del cliente; si no hay ninguno, null (el panel dice
--       «Sin responsable asignado»)
--   · responsable_origen: 'asignado' | 'analistas' | null
-- La línea de revisiones vencidas sale de «Qué vigilar» para no decirlo dos veces.
--
-- Cómo asignar un responsable (opcional):
--   INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
--   SELECT id, 'responsable_revision', to_jsonb('Nombre Apellido'::text), 'Quien responde por las revisiones vencidas'
--     FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
--   ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor, updated_at = now();
--
-- Necesita el 18 (revision_decidida_en) y el 26 (sintesis_dia). Se puede ejecutar varias veces.
-- Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT jsonb_pretty(vigilante.sintesis_dia(id) -> 'revisiones_vencidas') FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
-- Prueba: 99_prueba_aviso_vencidas.sql (termina en ROLLBACK).
-- Si después se vuelve a ejecutar el 26, hay que volver a ejecutar este.
-- =============================================================================
BEGIN;

-- La síntesis del 26 pasa a llamarse _sintesis_dia_base; sintesis_dia() la envuelve.
-- Si se reejecutó el 26 después de este, la versión nueva del 26 sustituye a la base.
DO $$
BEGIN
  IF to_regprocedure('vigilante._sintesis_dia_base(uuid)') IS NULL THEN
    ALTER FUNCTION vigilante.sintesis_dia(uuid) RENAME TO _sintesis_dia_base;
  ELSIF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'vigilante.sintesis_dia(uuid)'::regprocedure
                     AND prosrc LIKE '%_sintesis_dia_base%') THEN
    DROP FUNCTION vigilante._sintesis_dia_base(uuid);
    ALTER FUNCTION vigilante.sintesis_dia(uuid) RENAME TO _sintesis_dia_base;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante._sintesis_dia_base(uuid) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.revisiones_vencidas(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_total int; v_senales jsonb; v_resp text; v_origen text;
BEGIN
  SELECT count(*),
         coalesce(jsonb_agg(jsonb_build_object('codigo', codigo, 'titulo', titulo, 'desde', revision_vencida_en)
                            ORDER BY revision_vencida_en, id) FILTER (WHERE n <= 5), '[]')
    INTO v_total, v_senales
    FROM (SELECT s.id, s.codigo, s.titulo, s.revision_vencida_en,
                 row_number() OVER (ORDER BY s.revision_vencida_en, s.id) AS n
            FROM vigilante.signals s
           WHERE s.cliente_id = p_cliente AND s.revision_vencida_en IS NOT NULL
             AND s.revision_decidida_en IS NULL
             AND s.estado IN ('detectada', 'en_analisis', 'en_verificacion')) q;

  v_resp := nullif(btrim(vigilante.param(p_cliente, 'responsable_revision') #>> '{}'), '');
  IF v_resp IS NOT NULL THEN
    v_origen := 'asignado';
  ELSE
    SELECT string_agg(nombre, ', ' ORDER BY nombre) INTO v_resp
      FROM vigilante.users WHERE cliente_id = p_cliente AND activo AND rol = 'analista';
    v_origen := CASE WHEN v_resp IS NULL THEN NULL ELSE 'analistas' END;
  END IF;

  RETURN jsonb_build_object('total', v_total, 'senales', v_senales,
                            'responsable', v_resp, 'responsable_origen', v_origen);
END $$;
REVOKE ALL ON FUNCTION vigilante.revisiones_vencidas(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.revisiones_vencidas(uuid) TO service_role;

CREATE OR REPLACE FUNCTION vigilante.sintesis_dia(p_cliente uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  b jsonb := vigilante._sintesis_dia_base(p_cliente);
BEGIN
  RETURN b
    || jsonb_build_object(
         'que_vigilar', coalesce((SELECT jsonb_agg(e ORDER BY i) FROM jsonb_array_elements(b -> 'que_vigilar') WITH ORDINALITY a(e, i)
                                   WHERE e ->> 'tipo' IS DISTINCT FROM 'revision_vencida'), '[]'),
         'revisiones_vencidas', vigilante.revisiones_vencidas(p_cliente));
END $$;
REVOKE ALL ON FUNCTION vigilante.sintesis_dia(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.sintesis_dia(uuid) TO service_role;

COMMIT;
