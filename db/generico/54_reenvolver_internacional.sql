-- =============================================================================
-- 54 · Las noticias internacionales vuelven a llevar su marca al clasificador
-- =============================================================================
-- Fallo (2026-11-26): el 43 (mismo hecho) reemplazó vigilante.lote_para_clasificar con la versión del 31
-- y quitó la envoltura del 37. Desde entonces el clasificador ya no recibe «internacional» ni
-- «senales_nacionales» con las noticias de OPS/OMS, CEPAL, BBC, Reuters o AP: no puede decir su impacto
-- en Bolivia, el analizador las descarta como «sin impacto en Bolivia» y no salen señales internacionales.
-- La prueba 99_prueba_internacional.sql fallaba con «lleva la marca internacional».
--
-- Este archivo hace lo mismo que el final del 37: la versión vigente (la del 43, con 3 señales
-- relacionadas, que sirven para los cambios y el mismo hecho) pasa a llamarse lote_para_clasificar_31
-- y la del 37 la envuelve. No toca nada más. Se puede ejecutar más de una vez.
--
-- Comprobar: SELECT position('senales_nacionales' IN prosrc) > 0 AS ok
--              FROM pg_proc WHERE proname = 'lote_para_clasificar' AND pronamespace = 'vigilante'::regnamespace;
-- =============================================================================
BEGIN;

-- La versión vigente de lote_para_clasificar (la del 31, o la del 43 si se ejecutó después) pasa a
-- llamarse lote_para_clasificar_31 y esta la envuelve. Si otro archivo (p. ej. el 43) la reemplazó
-- después del 37, volver a ejecutar el 37 la envuelve de nuevo sin perder ese cambio.
DO $$
DECLARE v_src text := (SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'vigilante' AND p.proname = 'lote_para_clasificar');
BEGIN
  IF v_src IS NOT NULL AND position('senales_nacionales' IN v_src) = 0 THEN
    -- no es la del 37: es la vigente de antes → queda dentro
    DROP FUNCTION IF EXISTS vigilante.lote_para_clasificar_31(text, int);
    ALTER FUNCTION vigilante.lote_para_clasificar(text, int) RENAME TO lote_para_clasificar_31;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar_31(text, int) FROM public, anon, authenticated;

-- lote_para_clasificar del 31 queda dentro; esta añade a cada noticia de fuente internacional:
--   internacional: true y senales_nacionales (máx. 4) para que el clasificador diga a cuáles refuerza
CREATE OR REPLACE FUNCTION vigilante.lote_para_clasificar(p_cliente text, p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; v_out jsonb := '[]'; r record;
BEGIN
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(vigilante.lote_para_clasificar_31(p_cliente, p_limite), '[]')) LOOP
    SELECT ri.titulo, ri.contenido, coalesce(s.internacional, false) AS internacional, s.nombre
      INTO r FROM vigilante.raw_items ri LEFT JOIN vigilante.sources s ON s.id = ri.source_id
     WHERE ri.id = (x ->> 'clave')::bigint;
    IF r.internacional THEN
      x := x || jsonb_build_object('internacional', true,
                                   'senales_nacionales', vigilante.senales_nacionales_para(v_cliente, r.titulo, r.contenido, 4));
    END IF;
    v_out := v_out || jsonb_build_array(x);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar(text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.lote_para_clasificar(text, int) TO service_role;

COMMIT;
