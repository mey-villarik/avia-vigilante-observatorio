-- =============================================================================
-- 43. Un hecho, una señal (de verdad): el mismo evento contado con otras palabras
-- =============================================================================
-- Qué pasaba: el 30 solo unía dos señales si sus TÍTULOS se parecían (trigramas ≥ 0,6). Dos medios
-- que cuentan el mismo hecho casi nunca lo titulan igual:
--   «Canción Boliviana 2026: preselecciones del 6 y 7 de noviembre; final en Oruro el 20-21…»
--   «Festival Nacional de la Canción Boliviana 2026: Oruro, 20-21 de noviembre»      → parecido 0,53
--   «Derrumbes en la carretera Cochabamba–Santa Cruz»
--   «Deslizamientos bloquean la ruta Cochabamba - Santa Cruz en el km 120»            → parecido 0,33
-- Y aunque se detectaran, juntar_senales_repetidas() nunca tocaba dos señales PUBLICADAS, así que en la
-- web pública el mismo hecho salía dos veces, cada uno con «1 fuente».
--
-- Ahora, tres capas:
--
--   1. LA BASE COMPARA EL HECHO, NO SOLO EL TÍTULO. Cada señal guarda sus palabras clave (sin palabras
--      vacías ni nombres de lugar, en singular y con sinónimos: derrumbe = deslizamiento = mazamorra;
--      carretera = ruta = vía = tramo). Dos señales son el mismo hecho si no se contradicen (misma
--      categoría, naturaleza compatible, algún departamento en común, fechas que se solapan, cifras que no
--      chocan) y además:
--        · el título se parece como antes (≥ senal_parecido_min), o
--        · comparten al menos 2 palabras clave (hecho_clave_n) que son al menos el 60 %
--          (hecho_clave_min) de las del título más corto, y una de ellas no es «débil» (vía, bloqueo,
--          festival, feria… solas no bastan: «bloqueo» y «derrumbe» en la misma ruta son hechos distintos).
--      guardar_senal usa esta regla al crear una señal: si ya existe, la noticia se suma como evidencia
--      (la señal pasa a «2 fuentes») y no se crea otra.
--
--   2. EL CLASIFICADOR LO CONFIRMA (prompt clasificador-1.9). Con cada noticia ya recibe las señales
--      que pueden hablar de lo mismo (ahora hasta 3, buscadas también por palabras clave). Si la noticia
--      cuenta el MISMO hecho que una de ellas aunque con otras palabras, responde "misma_senal": "<código>"
--      y la base la une a esa señal. Solo vale un código de los que se le mandaron.
--
--   3. LAS QUE YA ESTÁN REPETIDAS SE JUNTAN SOLAS, publicadas incluidas. Tarea de pg_cron
--      «vigilante-mismo-hecho» cada 15 min: juntar_senales_repetidas(). Se queda la publicada (si las
--      dos lo están, la que tiene más fuentes; luego la más antigua). La otra pasa a «descartada» con
--      «Mismo hecho que SEN-…», su alerta sale de la web y sus noticias y departamentos pasan a la que
--      se queda. Todo queda en vigilante.senales_juntadas y se puede deshacer: separar_senal('SEN-…').
--      Para lo que la regla no ve: juntar_senales('SEN-que-se-queda', 'SEN-repetida') a mano.
--
-- Necesita del 01 al 42 (usa 30 y 31). Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Se puede ejecutar más de una vez. Al terminar muestra qué pares ve repetidos.
-- Comprobar:  SELECT * FROM vigilante.senales_repetidas();          -- solo mira
--             SELECT vigilante.juntar_senales_repetidas();          -- junta (lo hace también pg_cron)
--             SELECT * FROM vigilante.senales_juntadas ORDER BY id DESC;
-- Prueba: 99_prueba_mismo_hecho.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- 0. Parámetros (globales; cada cliente puede tener los suyos) -------------------------------
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'hecho_clave_n', '2',
   'Palabras clave que deben compartir dos títulos para ser el mismo hecho (además de no contradecirse)'),
  (NULL, 'hecho_clave_min', '0.6',
   'Proporción mínima (0 a 1) de palabras clave del título más corto que debe estar en el otro'),
  (NULL, 'hecho_vigente_dias', '60',
   'Una señal con fecha de evento o plazo aún por llegar se sigue comparando hasta esta antigüedad (días)'),
  (NULL, 'hecho_juntar_publicadas', 'true',
   'true: la tarea automática junta también dos señales publicadas del mismo hecho (la repetida sale de la web)'),
  (NULL, 'hecho_palabras_vacias', '[]',
   'Palabras que no cuentan como clave, además de las de serie (lista JSON, p. ej. ["observatorio"])'),
  (NULL, 'hecho_palabras_debiles', '["via","bloqueo","alerta","festival","feria","evento","convocatoria","fondo","programa","proyecto","servicio","transito","vuelo","aeropuerto","precio","lluvia","marcha","paro"]',
   'Palabras clave demasiado comunes: dos títulos que solo comparten estas no son el mismo hecho'),
  (NULL, 'hecho_sinonimos', '{
     "derrumbe":   ["derrumbe","deslizamiento","deslave","mazamorra","desprendimiento","hundimiento","huayco","huaico","alud","sifonamiento"],
     "via":        ["carretera","ruta","via","camino","tramo","autopista","troncal","calzada"],
     "bloqueo":    ["bloqueo","bloquea","bloquean","bloqueada","bloqueado","corte","cortan","cortada","cortado","interrumpido","interrumpida","interrupcion","restringido","restringida","restriccion","intransitable","cierre","cierra","cierran","cerrada","cerrado"],
     "inundacion": ["inundacion","desborde","riada","crecida","anegamiento","rebalse"],
     "lluvia":     ["lluvia","tormenta","precipitacion","temporal","aguacero","granizada","granizo","chubasco"],
     "incendio":   ["incendio","fuego","quema","chaqueo","foco"],
     "sismo":      ["sismo","terremoto","temblor"],
     "festival":   ["festival","certamen"],
     "feria":      ["feria","expo","expoferia","exposicion"],
     "paro":       ["paro","huelga"],
     "marcha":     ["marcha","movilizacion","protesta","manifestacion"],
     "convocatoria": ["convocatoria","postulacion","llamado","concurso"]
   }',
   'Grupos de sinónimos para comparar hechos: cada palabra de la lista cuenta como la clave del grupo')
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- 1. Palabras clave de un título ----------------------------------------------------------
-- Singular sencillo: festivales → festival, derrumbes → derrumbe, inundaciones → inundacion
CREATE OR REPLACE FUNCTION vigilante._raiz(w text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN length(w) > 5 AND w ~ '[lnrdz]es$' THEN left(w, -2)
              WHEN length(w) > 4 AND w ~ 's$' AND w !~ '(is|us|ss)$' THEN left(w, -1)
              ELSE w END
$$;

CREATE OR REPLACE FUNCTION vigilante.palabras_clave(p_cliente uuid, p text)
RETURNS text[] LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  WITH w AS (
    SELECT DISTINCT vigilante._raiz(x) AS w
      FROM regexp_split_to_table(vigilante.texto_norm(p), ' ') x
     WHERE length(x) >= 3 AND x !~ '\d'
  ),
  vacias AS (
    SELECT vigilante._raiz(x) AS w FROM unnest(ARRAY[
      'para','como','sobre','entre','desde','hasta','tras','ante','segun','contra','durante','mediante','hacia','cerca',
      'este','esta','estos','estas','esos','esas','aquel','todo','toda','todos','todas','otro','otra','otros','otras',
      'cada','mismo','misma','pero','porque','cuando','donde','tambien','mientras','luego','antes','despues','ahora',
      'sera','seran','estan','tiene','tienen','hace','hacen','puede','pueden','debe','deben','hubo','habra','sigue',
      'siguen','queda','quedan','nuevo','nueva','gran','grande','primer','primera','segunda','tercera','ultimo','ultima',
      'enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','setiembre','octubre','noviembre','diciembre',
      'lunes','martes','miercoles','jueves','viernes','sabado','domingo','manana','tarde','noche','semana','fecha','dias','horas',
      'bolivia','nacional','departamental','departamento','municipal','municipio','ciudad','gobierno','gobernacion','alcaldia',
      'ministerio','turismo','turistico','turistica','turista','sector','anuncia','anuncian','lanza','lanzan','reporta','reportan',
      'informa','informan','confirma','confirman','presenta','presentan','realiza','realizan','realizara','llega','llegan',
      'llegara','llegaran','llego','llegaron','tendra','tendran','habra','podra','podran','dice','dicen','segun',
      'edicion','version','partir','junto','zona','zonas','region','regional','desde','segun','afecta','afectan','podria','pide','piden'
    ]) x
    UNION SELECT vigilante._raiz(vigilante.texto_norm(x))
      FROM jsonb_array_elements_text(coalesce(vigilante.param(p_cliente, 'hecho_palabras_vacias'), '[]')) x
  ),
  lugares AS (   -- nombres de lugar: ya cuentan aparte (departamentos)
    SELECT DISTINCT vigilante._raiz(x) AS w
      FROM vigilante.territorios t,
           regexp_split_to_table(vigilante.texto_norm(concat_ws(' ', t.nombre, t.datos ->> 'capital',
             CASE WHEN jsonb_typeof(t.datos -> 'alias') = 'array'
                  THEN (SELECT string_agg(a, ' ') FROM jsonb_array_elements_text(t.datos -> 'alias') a) END)), ' ') x
     WHERE t.cliente_id = p_cliente AND length(x) >= 4
  ),
  sin AS (
    SELECT g.key AS grupo, vigilante._raiz(vigilante.texto_norm(s)) AS w
      FROM jsonb_each(CASE WHEN jsonb_typeof(vigilante.param(p_cliente, 'hecho_sinonimos')) = 'object'
                           THEN vigilante.param(p_cliente, 'hecho_sinonimos') ELSE '{}' END) g,
           jsonb_array_elements_text(g.value) s
  )
  SELECT coalesce(ARRAY(
    SELECT DISTINCT coalesce((SELECT min(sin.grupo) FROM sin WHERE sin.w = w.w), w.w) AS k
      FROM w
     WHERE w.w NOT IN (SELECT vacias.w FROM vacias) AND w.w NOT IN (SELECT lugares.w FROM lugares)
       -- palabras de 3 letras solo si son de un grupo de sinónimos («vía»)
       AND (length(w.w) >= 4 OR EXISTS (SELECT 1 FROM sin WHERE sin.w = w.w))
     ORDER BY 1), '{}')
$$;
COMMENT ON FUNCTION vigilante.palabras_clave(uuid, text) IS
  'Palabras que identifican un hecho en un título: sin palabras vacías, cifras ni lugares, en singular y con sinónimos (43)';

-- Cada señal guarda las de su título (se recalculan al cambiar el título)
ALTER TABLE vigilante.signals ADD COLUMN IF NOT EXISTS claves text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN vigilante.signals.claves IS 'Palabras clave del título (vigilante.palabras_clave), para encontrar el mismo hecho (43)';
CREATE INDEX IF NOT EXISTS signals_claves_idx ON vigilante.signals USING gin (claves);

CREATE OR REPLACE FUNCTION vigilante.tg_claves_senal() RETURNS trigger
LANGUAGE plpgsql SET search_path = vigilante, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.titulo IS DISTINCT FROM OLD.titulo OR NEW.claves = '{}' THEN
    NEW.claves := vigilante.palabras_clave(NEW.cliente_id, NEW.titulo);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_claves_senal ON vigilante.signals;
CREATE TRIGGER b_claves_senal BEFORE INSERT OR UPDATE OF titulo, claves ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_claves_senal();

-- Rellenar (y recalcular si cambiaron los sinónimos). Sin tocar updated_at ni el historial.
ALTER TABLE vigilante.signals DISABLE TRIGGER USER;
UPDATE vigilante.signals SET claves = vigilante.palabras_clave(cliente_id, titulo);
ALTER TABLE vigilante.signals ENABLE TRIGGER USER;

-- 2. ¿Mismo hecho? ------------------------------------------------------------------------
-- Fechas: si las dos tienen, deben solaparse (con un día de margen)
CREATE OR REPLACE FUNCTION vigilante._fechas_compatibles(a_ini timestamptz, a_fin timestamptz, b_ini timestamptz, b_fin timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN coalesce(a_ini, a_fin) IS NULL OR coalesce(b_ini, b_fin) IS NULL THEN true
              ELSE coalesce(a_ini, a_fin) <= coalesce(b_fin, b_ini) + interval '1 day'
               AND coalesce(b_ini, b_fin) <= coalesce(a_fin, a_ini) + interval '1 day' END
$$;

-- Lo que hace falta para comparar, igual para una señal guardada que para una que llega.
--   titulos: título de la señal (+ los de sus noticias); claves: las del título de la señal
CREATE OR REPLACE FUNCTION vigilante._hecho_senal(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', s.id, 'codigo', s.codigo, 'estado', s.estado,
    'titulos', to_jsonb(ARRAY[s.titulo] || ARRAY(
                 SELECT r.titulo FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                  WHERE sr.signal_id = s.id AND coalesce(r.titulo, '') <> '' ORDER BY r.id LIMIT 8)),
    'claves', to_jsonb(s.claves),
    'categoria', vigilante.categoria_canonica(s.categoria), 'naturaleza', s.naturaleza,
    'territorios', to_jsonb(ARRAY(SELECT st.territorio_id FROM vigilante.signal_territorios st WHERE st.signal_id = s.id)
                            || vigilante.territorios_en(s.cliente_id, s.titulo)),
    'ini', s.fecha_evento_inicio, 'fin', s.fecha_evento_fin, 'plazo', s.plazo_hasta)
    FROM vigilante.signals s WHERE s.id = p_id
$$;
REVOKE ALL ON FUNCTION vigilante._hecho_senal(bigint) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante._hecho_entrante(p_cliente uuid, p_senal jsonb, p_noticias bigint[])
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT jsonb_build_object(
    'titulos', to_jsonb(ARRAY[p_senal ->> 'titulo'] || ARRAY(
                 SELECT r.titulo FROM vigilante.raw_items r
                  WHERE r.cliente_id = p_cliente AND r.id = ANY (coalesce(p_noticias, '{}')) AND coalesce(r.titulo, '') <> ''
                  ORDER BY r.id LIMIT 8)),
    'claves', to_jsonb(vigilante.palabras_clave(p_cliente, p_senal ->> 'titulo')),
    'categoria', vigilante.categoria_canonica(nullif(p_senal ->> 'categoria', '')),
    'naturaleza', nullif(p_senal ->> 'naturaleza', ''),
    'territorios', to_jsonb(
       CASE WHEN jsonb_typeof(p_senal -> 'departamentos') = 'array' THEN ARRAY(
         SELECT t.id FROM vigilante.territorios t WHERE t.cliente_id = p_cliente
            AND vigilante.texto_norm(t.nombre) IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(p_senal -> 'departamentos') x))
       ELSE '{}'::int[] END || vigilante.territorios_en(p_cliente, p_senal ->> 'titulo')),
    'ini', CASE WHEN (p_senal ->> 'fecha_evento_inicio') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_inicio')::timestamptz END,
    'fin', CASE WHEN (p_senal ->> 'fecha_evento_fin') ~ '^\d{4}-\d{2}-\d{2}' THEN (p_senal ->> 'fecha_evento_fin')::timestamptz END,
    'plazo', CASE WHEN (p_senal ->> 'plazo_hasta') ~ '^\d{4}-\d{2}-\d{2}' THEN left(p_senal ->> 'plazo_hasta', 10)::timestamptz END)
$$;
REVOKE ALL ON FUNCTION vigilante._hecho_entrante(uuid, jsonb, bigint[]) FROM public, anon, authenticated;

-- Compara dos hechos (los jsonb de arriba). mismo = true si cuentan lo mismo; motivo dice por qué sí o no.
CREATE OR REPLACE FUNCTION vigilante.comparar_hechos(p_cliente uuid, a jsonb, b jsonb)
RETURNS TABLE (mismo boolean, motivo text, parecido real, comunes text[])
LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_min   real := coalesce((vigilante.param(p_cliente, 'senal_parecido_min') #>> '{}')::real, 0.6);
  v_n     int  := coalesce((vigilante.param(p_cliente, 'hecho_clave_n') #>> '{}')::int, 2);
  v_prop  real := coalesce((vigilante.param(p_cliente, 'hecho_clave_min') #>> '{}')::real, 0.5);
  v_deb   text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(vigilante.param(p_cliente, 'hecho_palabras_debiles'), '[]')));
  ka text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(a -> 'claves', '[]')));
  kb text[] := ARRAY(SELECT jsonb_array_elements_text(coalesce(b -> 'claves', '[]')));
  ta int[]; tb int[]; ca text[]; cb text[]; v_fechas boolean; v_prop_real real; v_pais boolean;
  ai timestamptz := (a ->> 'ini')::timestamptz; af timestamptz := (a ->> 'fin')::timestamptz;
  bi timestamptz := (b ->> 'ini')::timestamptz; bf timestamptz := (b ->> 'fin')::timestamptz;
  pa timestamptz := (a ->> 'plazo')::timestamptz; pb timestamptz := (b ->> 'plazo')::timestamptz;
BEGIN
  -- parecido de títulos (el mejor entre título y noticias de cada lado)
  SELECT coalesce(max(vigilante.parecido(vigilante.texto_norm(x), vigilante.texto_norm(y))), 0) INTO parecido
    FROM jsonb_array_elements_text(coalesce(a -> 'titulos', '[]')) x, jsonb_array_elements_text(coalesce(b -> 'titulos', '[]')) y;
  comunes := ARRAY(SELECT unnest(ka) INTERSECT SELECT unnest(kb) ORDER BY 1);
  mismo := false;

  -- lo que contradice: categoría, naturaleza, lugar, fechas, plazo, cifras
  IF a ->> 'categoria' IS NOT NULL AND b ->> 'categoria' IS NOT NULL AND a ->> 'categoria' <> b ->> 'categoria'
     AND NOT (ARRAY[a ->> 'categoria', b ->> 'categoria'] <@ ARRAY['clima', 'vial']) THEN
    motivo := 'otra categoría'; RETURN NEXT; RETURN;
  END IF;
  IF a ->> 'naturaleza' IS NOT NULL AND b ->> 'naturaleza' IS NOT NULL AND a ->> 'naturaleza' <> b ->> 'naturaleza'
     AND 'mixta' NOT IN (a ->> 'naturaleza', b ->> 'naturaleza') THEN
    motivo := 'una es riesgo y la otra oportunidad'; RETURN NEXT; RETURN;
  END IF;
  ta := ARRAY(SELECT DISTINCT x::int FROM jsonb_array_elements_text(coalesce(a -> 'territorios', '[]')) x);
  tb := ARRAY(SELECT DISTINCT x::int FROM jsonb_array_elements_text(coalesce(b -> 'territorios', '[]')) x);
  -- una señal de todo el país vale para cualquier departamento
  v_pais := EXISTS (SELECT 1 FROM vigilante.territorios WHERE id = ANY (ta || tb) AND nivel = 'pais');
  -- con los departamentos de los municipios (sin subir hasta el país)
  ta := ta || ARRAY(SELECT t.padre_id FROM vigilante.territorios t JOIN vigilante.territorios p ON p.id = t.padre_id
                     WHERE t.id = ANY (ta) AND p.nivel <> 'pais');
  tb := tb || ARRAY(SELECT t.padre_id FROM vigilante.territorios t JOIN vigilante.territorios p ON p.id = t.padre_id
                     WHERE t.id = ANY (tb) AND p.nivel <> 'pais');
  IF cardinality(ta) > 0 AND cardinality(tb) > 0 AND NOT (ta && tb) AND NOT v_pais THEN
    motivo := 'otros departamentos'; RETURN NEXT; RETURN;
  END IF;
  IF NOT vigilante._fechas_compatibles(ai, af, bi, bf) THEN
    motivo := 'fechas que no se solapan'; RETURN NEXT; RETURN;
  END IF;
  IF pa IS NOT NULL AND pb IS NOT NULL AND abs(extract(epoch FROM pa - pb)) > 2 * 86400 THEN
    motivo := 'otro plazo'; RETURN NEXT; RETURN;
  END IF;
  -- años: si los dos nombran años y ninguno coincide, son ediciones distintas (FIT 2026 ≠ FIT 2027)
  ca := ARRAY(SELECT x FROM unnest(vigilante.cifras(a #>> '{titulos,0}')) x WHERE x ~ '^(19|20)\d\d$');
  cb := ARRAY(SELECT x FROM unnest(vigilante.cifras(b #>> '{titulos,0}')) x WHERE x ~ '^(19|20)\d\d$');
  IF cardinality(ca) > 0 AND cardinality(cb) > 0 AND NOT (ca && cb) THEN
    motivo := 'otro año'; RETURN NEXT; RETURN;
  END IF;
  -- el resto de cifras: si las fechas de los dos coinciden, ya no deciden
  v_fechas := coalesce(ai, af) IS NOT NULL AND coalesce(bi, bf) IS NOT NULL;
  IF NOT v_fechas THEN
    ca := ARRAY(SELECT x FROM unnest(vigilante.cifras(a #>> '{titulos,0}')) x WHERE x !~ '^(19|20)\d\d$');
    cb := ARRAY(SELECT x FROM unnest(vigilante.cifras(b #>> '{titulos,0}')) x WHERE x !~ '^(19|20)\d\d$');
    IF cardinality(ca) > 0 AND cardinality(cb) > 0 AND NOT (ca <@ cb OR cb <@ ca) THEN
      motivo := 'cifras distintas'; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- lo que lo hace el mismo
  IF parecido >= v_min THEN
    mismo := true; motivo := format('título parecido (%s)', round(parecido::numeric, 2)); RETURN NEXT; RETURN;
  END IF;
  v_prop_real := cardinality(comunes)::real / greatest(least(cardinality(ka), cardinality(kb)), 1);
  IF cardinality(comunes) >= v_n AND v_prop_real >= v_prop AND EXISTS (SELECT 1 FROM unnest(comunes) c WHERE c <> ALL (v_deb)) THEN
    mismo := true; motivo := 'mismas palabras clave: ' || array_to_string(comunes, ', '); RETURN NEXT; RETURN;
  END IF;
  motivo := CASE WHEN cardinality(comunes) = 0 THEN 'nada en común'
                 ELSE 'solo comparte: ' || array_to_string(comunes, ', ') END;
  RETURN NEXT;
END $$;
REVOKE ALL ON FUNCTION vigilante.comparar_hechos(uuid, jsonb, jsonb) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.comparar_hechos(uuid, jsonb, jsonb) TO authenticated, service_role;

-- Atajo para probar dos títulos sueltos: SELECT * FROM vigilante.mismo_hecho_titulos('orbita-bolivia', 'A', 'B');
CREATE OR REPLACE FUNCTION vigilante.mismo_hecho_titulos(p_cliente text, a text, b text)
RETURNS TABLE (mismo boolean, motivo text, parecido real, comunes text[])
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT * FROM vigilante.comparar_hechos(vigilante.id_cliente(p_cliente),
           vigilante._hecho_entrante(vigilante.id_cliente(p_cliente), jsonb_build_object('titulo', a), '{}'),
           vigilante._hecho_entrante(vigilante.id_cliente(p_cliente), jsonb_build_object('titulo', b), '{}'))
$$;
REVOKE ALL ON FUNCTION vigilante.mismo_hecho_titulos(text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.mismo_hecho_titulos(text, text, text) TO authenticated, service_role;

-- Señales vivas con las que vale la pena comparar: recientes, o con evento/plazo aún por llegar
CREATE OR REPLACE FUNCTION vigilante._senal_comparable(s vigilante.signals)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT s.duplicado_de IS NULL AND s.estado NOT IN ('descartada', 'cerrada')
     AND (greatest(s.created_at, s.updated_at) > now() - make_interval(days => coalesce((vigilante.param(s.cliente_id, 'senal_repetida_dias') #>> '{}')::int, 7))
          OR (coalesce(s.fecha_evento_fin, s.fecha_evento_inicio, s.plazo_hasta) >= now() - interval '1 day'
              AND s.created_at > now() - make_interval(days => coalesce((vigilante.param(s.cliente_id, 'hecho_vigente_dias') #>> '{}')::int, 60))))
$$;

-- 3. La señal que ya cuenta este hecho ----------------------------------------------------
-- (a) una de sus noticias ya está en otra señal · (b) el clasificador dijo cuál es (misma_senal)
-- (c) la regla de arriba contra las señales vivas
CREATE OR REPLACE FUNCTION vigilante.senal_del_hecho(p_cliente uuid, p_senal jsonb, p_noticias bigint[] DEFAULT '{}')
RETURNS TABLE (signal_id bigint, codigo text, motivo text)
LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE v_mapa jsonb; v_cod text; v_id bigint; v_h jsonb; v_claves text[];
BEGIN
  RETURN QUERY
    SELECT s.id, s.codigo, 'misma noticia'::text
      FROM vigilante.raw_items r
      JOIN vigilante.raw_items r2 ON r2.cliente_id = r.cliente_id AND (r2.id = r.id OR (r.url_doc <> '' AND r2.url_doc = r.url_doc))
      JOIN vigilante.signal_raw_items sr ON sr.raw_item_id = r2.id
      JOIN vigilante.signals s ON s.id = sr.signal_id AND s.duplicado_de IS NULL
     WHERE r.cliente_id = p_cliente AND r.id = ANY (coalesce(p_noticias, '{}'))
     ORDER BY (s.estado NOT IN ('descartada', 'cerrada')) DESC, s.id
     LIMIT 1;
  IF FOUND THEN RETURN; END IF;

  -- lo que dijo el clasificador en este lote (lo pone guardar_clasificacion)
  BEGIN v_mapa := nullif(current_setting('vigilante.misma_senal', true), '')::jsonb;
  EXCEPTION WHEN others THEN v_mapa := NULL; END;
  IF jsonb_typeof(v_mapa) = 'object' THEN
    SELECT v_mapa ->> x::text INTO v_cod FROM unnest(coalesce(p_noticias, '{}')) x WHERE v_mapa ? x::text LIMIT 1;
    IF v_cod IS NOT NULL THEN
      SELECT s.id INTO v_id FROM vigilante.signals s WHERE s.cliente_id = p_cliente AND s.codigo = v_cod;
      -- si ya se había juntado con otra, vale la que se quedó
      SELECT coalesce(s.duplicado_de, s.id) INTO v_id FROM vigilante.signals s WHERE s.id = v_id;
      RETURN QUERY SELECT s.id, s.codigo, 'el clasificador vio el mismo hecho'::text FROM vigilante.signals s
                    WHERE s.id = v_id AND s.estado NOT IN ('descartada', 'cerrada');
      IF FOUND THEN RETURN; END IF;
    END IF;
  END IF;

  -- si el clasificador dijo que la noticia CAMBIA una señal (31: desvío, nueva fecha…), no se une por
  -- parecido: queda como señal propia con el texto nuevo y el cambio enlaza las dos
  BEGIN v_mapa := nullif(current_setting('vigilante.con_cambio', true), '')::jsonb;
  EXCEPTION WHEN others THEN v_mapa := NULL; END;
  IF jsonb_typeof(v_mapa) = 'array' AND EXISTS (SELECT 1 FROM unnest(coalesce(p_noticias, '{}')) x WHERE v_mapa ? x::text) THEN
    RETURN;
  END IF;

  v_h := vigilante._hecho_entrante(p_cliente, p_senal, p_noticias);
  v_claves := ARRAY(SELECT jsonb_array_elements_text(v_h -> 'claves'));
  RETURN QUERY
    SELECT s.id, s.codigo, c.motivo
      FROM vigilante.signals s
      CROSS JOIN LATERAL vigilante.comparar_hechos(p_cliente, v_h, vigilante._hecho_senal(s.id)) c
     WHERE s.cliente_id = p_cliente AND vigilante._senal_comparable(s)
       -- antes de comparar a fondo: alguna palabra clave en común o el título algo parecido
       AND (s.claves && v_claves OR vigilante.parecido(vigilante.texto_norm(p_senal ->> 'titulo'), vigilante.texto_norm(s.titulo)) >= 0.3)
       AND c.mismo
     ORDER BY (s.estado = 'publicada') DESC, c.parecido + cardinality(c.comunes) * 0.2 DESC, s.id
     LIMIT 1;
END $$;
REVOKE ALL ON FUNCTION vigilante.senal_del_hecho(uuid, jsonb, bigint[]) FROM public, anon, authenticated;

-- La del 30 queda como atajo con la regla nueva (por si algo la llama)
CREATE OR REPLACE FUNCTION vigilante.senal_existente(p_cliente uuid, p_titulo text, p_noticias bigint[] DEFAULT '{}',
                                                    p_departamentos jsonb DEFAULT NULL)
RETURNS TABLE (signal_id bigint, codigo text, motivo text)
LANGUAGE sql STABLE SET search_path = vigilante, pg_temp AS $$
  SELECT * FROM vigilante.senal_del_hecho(p_cliente,
           jsonb_strip_nulls(jsonb_build_object('titulo', p_titulo, 'departamentos', p_departamentos)), p_noticias)
$$;

-- 4. guardar_senal (envoltorio del 30, con la regla nueva) ------------------------------
CREATE OR REPLACE FUNCTION vigilante.guardar_senal(p_cliente text, p_senal jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); v_ids bigint[]; v_s jsonb := p_senal; v_res jsonb;
  v_ex_id bigint; v_ex_cod text; v_ex_motivo text;
BEGIN
  IF nullif(trim(p_senal ->> 'codigo'), '') IS NULL AND coalesce(trim(p_senal ->> 'titulo'), '') <> '' THEN
    -- el mismo candado que usa la creación de códigos: dos señales iguales a la vez no pasan las dos
    PERFORM pg_advisory_xact_lock(hashtext('vigilante.signals.codigo:' || v_cliente));
    v_ids := CASE WHEN jsonb_typeof(p_senal -> 'noticias') = 'array'
                  THEN ARRAY(SELECT x::bigint FROM jsonb_array_elements_text(p_senal -> 'noticias') x WHERE x ~ '^\d+$') ELSE '{}' END;
    SELECT e.signal_id, e.codigo, e.motivo INTO v_ex_id, v_ex_cod, v_ex_motivo
      FROM vigilante.senal_del_hecho(v_cliente, p_senal, v_ids) e;
    IF v_ex_id IS NOT NULL THEN
      -- se une a la existente: suma las noticias como evidencia y conserva su título, resumen, categoría
      -- y naturaleza (un derrumbe que un medio llama «clima» no cambia la señal «vial»); la prioridad no baja
      SELECT (p_senal - 'categoria' - 'naturaleza')
             || jsonb_build_object('codigo', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen,
                                   'prioridad', CASE WHEN array_position(ARRAY['baja', 'media', 'alta'], p_senal ->> 'prioridad')
                                                          > array_position(ARRAY['baja', 'media', 'alta'], s.prioridad::text)
                                                     THEN p_senal ->> 'prioridad' ELSE s.prioridad::text END)
        INTO v_s FROM vigilante.signals s WHERE s.id = v_ex_id;
    END IF;
  END IF;

  v_res := vigilante.guardar_senal_15(p_cliente, v_s);

  IF v_ex_id IS NOT NULL THEN
    UPDATE vigilante.signals SET repetidas_unidas = repetidas_unidas + 1 WHERE id = v_ex_id;
    v_res := v_res || jsonb_build_object('repetida', true, 'unida_por', v_ex_motivo,
               'nota', format('Ya existía la señal %s para este hecho (%s): las noticias se añadieron como evidencia, no se creó otra',
                              v_ex_cod, v_ex_motivo));
  END IF;
  RETURN v_res;
END $$;
REVOKE ALL ON FUNCTION vigilante.guardar_senal(text, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.guardar_senal(text, jsonb) TO service_role;

-- 5. El clasificador dice «misma_senal» ---------------------------------------------------
-- guardar_clasificacion del 25 queda dentro; esta le pasa a guardar_senal lo que dijo el clasificador.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'vigilante' AND p.proname = 'guardar_clasificacion_25') THEN
    ALTER FUNCTION vigilante.guardar_clasificacion(text, jsonb, text, text, jsonb) RENAME TO guardar_clasificacion_25;
  END IF;
END $$;
REVOKE ALL ON FUNCTION vigilante.guardar_clasificacion_25(text, jsonb, text, text, jsonb) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION vigilante.guardar_clasificacion(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL,
                                                           p_prompt_version text DEFAULT NULL, p_uso jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_mapa jsonb; v_res jsonb;
BEGIN
  -- {"<clave de la noticia>": "<código de la señal>"} solo para las relevantes que lo traen
  SELECT coalesce(jsonb_object_agg(x ->> 'clave', trim(x ->> 'misma_senal')), '{}') INTO v_mapa
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END) x
   WHERE (x ->> 'clave') ~ '^\d+$' AND coalesce(trim(x ->> 'misma_senal'), '') <> ''
     AND coalesce((x ->> 'relevante')::boolean, false);
  PERFORM set_config('vigilante.misma_senal', v_mapa::text, true);
  -- las que traen «cambio» (31) no se unen por parecido (ver senal_del_hecho)
  PERFORM set_config('vigilante.con_cambio', coalesce((
    SELECT jsonb_agg(x ->> 'clave')
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END) x
     WHERE (x ->> 'clave') ~ '^\d+$' AND jsonb_typeof(x -> 'cambio') = 'object' AND coalesce(trim(x ->> 'misma_senal'), '') = ''), '[]')::text, true);
  v_res := vigilante.guardar_clasificacion_25(p_cliente, p_resultados, p_modelo, p_prompt_version, p_uso);
  PERFORM set_config('vigilante.misma_senal', '', true);
  PERFORM set_config('vigilante.con_cambio', '', true);
  RETURN v_res || jsonb_build_object('mismo_hecho_segun_clasificador', (SELECT count(*) FROM jsonb_object_keys(v_mapa)));
END $$;
REVOKE ALL ON FUNCTION vigilante.guardar_clasificacion(text, jsonb, text, text, jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.guardar_clasificacion(text, jsonb, text, text, jsonb) TO service_role;

-- Señales relacionadas que se mandan al clasificador (31): ahora también por palabras clave, hasta 3
CREATE OR REPLACE FUNCTION vigilante.senales_relacionadas(p_cliente uuid, p_titulo text, p_territorios integer[] DEFAULT '{}',
                                                          p_excluir bigint[] DEFAULT '{}', p_limite int DEFAULT 3)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH p AS (
    SELECT coalesce((vigilante.param(p_cliente, 'cambios_parecido_min') #>> '{}')::real, 0.25) AS minimo,
           coalesce((vigilante.param(p_cliente, 'cambios_buscar_dias') #>> '{}')::int, 30) AS dias,
           vigilante.palabras_clave(p_cliente, p_titulo) AS claves,
           ARRAY(SELECT jsonb_array_elements_text(coalesce(vigilante.param(p_cliente, 'hecho_palabras_debiles'), '[]'))) AS debiles
  ), c AS (
    SELECT s.id, vigilante.parecido(vigilante.texto_norm(p_titulo), vigilante.texto_norm(s.titulo)) AS par,
           cardinality(ARRAY(SELECT unnest(s.claves) INTERSECT SELECT unnest(p.claves))) AS n_com,
           EXISTS (SELECT 1 FROM unnest(s.claves) k WHERE k = ANY (p.claves) AND k <> ALL (p.debiles)) AS fuerte
      FROM vigilante.signals s, p
     WHERE s.cliente_id = p_cliente AND s.duplicado_de IS NULL
       AND s.estado NOT IN ('descartada', 'cerrada')
       AND (greatest(s.created_at, s.updated_at) > now() - make_interval(days => p.dias) OR vigilante._senal_comparable(s))
       AND NOT (s.id = ANY (coalesce(p_excluir, '{}')))
       -- territorios distintos: hechos distintos (si los dos los tienen)
       AND (cardinality(coalesce(p_territorios, '{}')) = 0
            OR NOT EXISTS (SELECT 1 FROM vigilante.signal_territorios st WHERE st.signal_id = s.id)
            OR EXISTS (SELECT 1 FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id
                        WHERE st.signal_id = s.id AND (t.id = ANY (p_territorios) OR t.padre_id = ANY (p_territorios)
                                                       OR t.nivel = 'pais')))
  )
  SELECT coalesce(jsonb_agg(vigilante._senal_corta(c.id) ORDER BY c.par + c.n_com * 0.2 DESC), '[]')
    FROM (SELECT c.* FROM c, p WHERE c.par >= p.minimo OR c.fuerte
           ORDER BY c.par + c.n_com * 0.2 DESC, c.id DESC
           LIMIT greatest(least(coalesce(p_limite, 3), 4), 1)) c
$$;
REVOKE ALL ON FUNCTION vigilante.senales_relacionadas(uuid, text, integer[], bigint[], int) FROM public, anon, authenticated;

-- lote_para_clasificar del 31 con 3 relacionadas en vez de 2
CREATE OR REPLACE FUNCTION vigilante.lote_para_clasificar(p_cliente text, p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cliente uuid := vigilante.id_cliente(p_cliente); v_lote jsonb; x jsonb; v_out jsonb := '[]';
        r vigilante.raw_items; v_ex bigint;
BEGIN
  v_lote := vigilante.lote_para_clasificar_15(p_cliente, p_limite);
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(v_lote, '[]')) LOOP
    SELECT * INTO r FROM vigilante.raw_items WHERE id = (x ->> 'clave')::bigint;
    v_ex := NULL;
    IF x #>> '{senal_existente,codigo}' IS NOT NULL THEN
      SELECT id INTO v_ex FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = x #>> '{senal_existente,codigo}';
      x := x || jsonb_build_object('senal_existente', vigilante._senal_corta(v_ex));
    END IF;
    x := x || jsonb_build_object('senales_relacionadas',
           vigilante.senales_relacionadas(v_cliente, coalesce(r.titulo, x ->> 'titulo'), coalesce(r.territorios_detectados, '{}'),
                                          CASE WHEN v_ex IS NULL THEN '{}'::bigint[] ELSE ARRAY[v_ex] END, 3));
    v_out := v_out || jsonb_build_array(x);
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION vigilante.lote_para_clasificar(text, int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.lote_para_clasificar(text, int) TO service_role;

-- 6. Juntar las que ya están repetidas (publicadas incluidas) y poder deshacerlo -----------
CREATE TABLE IF NOT EXISTS vigilante.senales_juntadas (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  cliente_id    uuid NOT NULL REFERENCES vigilante.clientes(id) ON DELETE CASCADE,
  se_queda_id   bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  repetida_id   bigint NOT NULL REFERENCES vigilante.signals(id) ON DELETE CASCADE,
  motivo        text,
  quien         text,
  estado_antes  vigilante.estado_senal NOT NULL,
  noticias      bigint[] NOT NULL DEFAULT '{}',   -- las que pasaron a la que se queda (se quitan al separar)
  territorios   integer[] NOT NULL DEFAULT '{}',
  oportunidades bigint[] NOT NULL DEFAULT '{}',
  separada_en   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE vigilante.senales_juntadas IS 'Cada vez que dos señales del mismo hecho se juntaron en una (43). separar_senal() lo deshace';
CREATE INDEX IF NOT EXISTS senales_juntadas_repetida_idx ON vigilante.senales_juntadas (repetida_id) WHERE separada_en IS NULL;
ALTER TABLE vigilante.senales_juntadas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS staff_lee ON vigilante.senales_juntadas;
CREATE POLICY staff_lee ON vigilante.senales_juntadas FOR SELECT TO authenticated
  USING (vigilante.es_staff() AND cliente_id = vigilante.cliente_actual());
GRANT SELECT ON vigilante.senales_juntadas TO authenticated;

-- Una descartada puede volver a Detectadas (lo usa separar_senal; también sirve para recuperar una a mano)
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
    ('confirmada',      'cerrada'),
    ('descartada',      'en_analisis')    -- 43: recuperar una descartada (p. ej. separar una juntada por error)
  )
$$;

-- Núcleo: la repetida pasa a la que se queda. Devuelve el id del registro en senales_juntadas.
CREATE OR REPLACE FUNCTION vigilante._juntar(p_queda bigint, p_repetida bigint, p_motivo text, p_quien text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE k vigilante.signals; d vigilante.signals; v_not bigint[]; v_ter int[]; v_opp bigint[]; v_reg bigint;
BEGIN
  SELECT * INTO k FROM vigilante.signals WHERE id = p_queda FOR UPDATE;
  SELECT * INTO d FROM vigilante.signals WHERE id = p_repetida FOR UPDATE;
  IF k.id IS NULL OR d.id IS NULL OR k.id = d.id OR k.cliente_id <> d.cliente_id THEN RETURN NULL; END IF;
  IF k.duplicado_de IS NOT NULL OR d.duplicado_de IS NOT NULL OR d.estado = 'descartada' THEN RETURN NULL; END IF;

  v_not := ARRAY(SELECT x FROM (SELECT raw_item_id AS x FROM vigilante.signal_raw_items WHERE signal_id = d.id
                                UNION SELECT d.raw_item_id WHERE d.raw_item_id IS NOT NULL) n
                  WHERE x NOT IN (SELECT raw_item_id FROM vigilante.signal_raw_items WHERE signal_id = k.id)
                    AND x IS DISTINCT FROM k.raw_item_id);
  v_ter := ARRAY(SELECT territorio_id FROM vigilante.signal_territorios WHERE signal_id = d.id
                 EXCEPT SELECT territorio_id FROM vigilante.signal_territorios WHERE signal_id = k.id);
  INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
  SELECT k.id, x, k.cliente_id FROM unnest(v_not) x ON CONFLICT DO NOTHING;
  INSERT INTO vigilante.signal_territorios (signal_id, cliente_id, territorio_id)
  SELECT k.id, k.cliente_id, x FROM unnest(v_ter) x ON CONFLICT DO NOTHING;
  -- oportunidades de la repetida que la otra no tiene
  WITH m AS (
    UPDATE vigilante.oportunidades o SET signal_id = k.id
     WHERE o.signal_id = d.id
       AND NOT EXISTS (SELECT 1 FROM vigilante.oportunidades o2 WHERE o2.signal_id = k.id AND o2.nivel = o.nivel AND o2.tipo = o.tipo)
    RETURNING o.id)
  SELECT coalesce(array_agg(id), '{}') INTO v_opp FROM m;

  UPDATE vigilante.signals SET duplicado_de = k.id, estado = 'descartada',
         motivo_revision = format('Mismo hecho que %s (%s)', k.codigo, p_motivo)
   WHERE id = d.id;          -- si estaba publicada, su alerta sale de la web (13)
  UPDATE vigilante.signals SET repetidas_unidas = repetidas_unidas + 1 + d.repetidas_unidas WHERE id = k.id;

  INSERT INTO vigilante.senales_juntadas (cliente_id, se_queda_id, repetida_id, motivo, quien, estado_antes, noticias, territorios, oportunidades)
  VALUES (k.cliente_id, k.id, d.id, p_motivo, p_quien, d.estado, v_not, v_ter, v_opp)
  RETURNING id INTO v_reg;
  RETURN v_reg;
END $$;
REVOKE ALL ON FUNCTION vigilante._juntar(bigint, bigint, text, text) FROM public, anon, authenticated;

-- ¿Cuál se queda? La publicada; luego la que tiene más fuentes; luego la más antigua.
CREATE OR REPLACE FUNCTION vigilante._orden_queda(s vigilante.signals)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT (CASE WHEN s.estado = 'publicada' THEN '0' WHEN s.estado = 'confirmada' THEN '1' ELSE '2' END)
         || lpad((999 - least(coalesce((SELECT n_fuentes FROM vigilante.respaldo_senal(s.id)), 0), 999))::text, 3, '0')
         || lpad(s.id::text, 12, '0')
$$;

-- Un par que una persona separó no se vuelve a juntar solo
CREATE OR REPLACE FUNCTION vigilante._separadas(a bigint, b bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM vigilante.senales_juntadas j WHERE j.separada_en IS NOT NULL
                  AND ((j.se_queda_id = a AND j.repetida_id = b) OR (j.se_queda_id = b AND j.repetida_id = a)))
$$;

-- Pares repetidos que ve la regla (no cambia nada)
DROP FUNCTION IF EXISTS vigilante.senales_repetidas(int);
CREATE FUNCTION vigilante.senales_repetidas(p_dias int DEFAULT 30)
RETURNS TABLE (cliente text, se_queda text, repetida text, titulo_se_queda text, titulo_repetida text,
               motivo text, parecido numeric, publicadas int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH v AS (
    SELECT s.*, vigilante._orden_queda(s) AS orden FROM vigilante.signals s
     WHERE s.duplicado_de IS NULL AND s.estado NOT IN ('descartada', 'cerrada')
       AND (greatest(s.created_at, s.updated_at) > now() - make_interval(days => p_dias) OR vigilante._senal_comparable(s))
       AND (vigilante.cliente_actual() IS NULL OR s.cliente_id = vigilante.cliente_actual())
  )
  SELECT c.slug, k.codigo, d.codigo, k.titulo, d.titulo,
         CASE WHEN EXISTS (SELECT 1 FROM vigilante.signal_raw_items a JOIN vigilante.signal_raw_items b ON b.raw_item_id = a.raw_item_id
                            WHERE a.signal_id = k.id AND b.signal_id = d.id) THEN 'misma noticia' ELSE m.motivo END,
         round(m.parecido::numeric, 2),
         ((k.estado = 'publicada')::int + (d.estado = 'publicada')::int)
    FROM v k JOIN v d ON d.cliente_id = k.cliente_id AND k.orden < d.orden AND NOT vigilante._separadas(k.id, d.id)
    JOIN vigilante.clientes c ON c.id = k.cliente_id
    CROSS JOIN LATERAL vigilante.comparar_hechos(k.cliente_id, vigilante._hecho_senal(k.id), vigilante._hecho_senal(d.id)) m
   WHERE (k.claves && d.claves OR vigilante.parecido(vigilante.texto_norm(k.titulo), vigilante.texto_norm(d.titulo)) >= 0.3
          OR EXISTS (SELECT 1 FROM vigilante.signal_raw_items a JOIN vigilante.signal_raw_items b ON b.raw_item_id = a.raw_item_id
                      WHERE a.signal_id = k.id AND b.signal_id = d.id))
     AND (m.mismo OR EXISTS (SELECT 1 FROM vigilante.signal_raw_items a JOIN vigilante.signal_raw_items b ON b.raw_item_id = a.raw_item_id
                              WHERE a.signal_id = k.id AND b.signal_id = d.id))
   ORDER BY c.slug, k.orden, d.orden
$$;
REVOKE ALL ON FUNCTION vigilante.senales_repetidas(int) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.senales_repetidas(int) TO authenticated, service_role;

-- Junta los pares (A≈B≈C: B y C se juntan en A). La tarea de pg_cron lo llama cada 15 min.
DROP FUNCTION IF EXISTS vigilante.juntar_senales_repetidas(int);
DROP FUNCTION IF EXISTS vigilante.juntar_senales_repetidas(int, boolean);
CREATE FUNCTION vigilante.juntar_senales_repetidas(p_dias int DEFAULT 30, p_publicadas boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE r record; v_k bigint; v_d bigint; n int := 0; v_lista jsonb := '[]'; v_pub boolean;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_admin() THEN RAISE EXCEPTION 'Solo un administrador puede juntar señales'; END IF;
  PERFORM set_config('vigilante.actor', 'limpieza:mismo_hecho', true);
  FOR r IN SELECT x.*, c.id AS cid FROM vigilante.senales_repetidas(p_dias) x JOIN vigilante.clientes c ON c.slug = x.cliente LOOP
    v_pub := coalesce(p_publicadas, (vigilante.param(r.cid, 'hecho_juntar_publicadas') #>> '{}')::boolean, true);
    CONTINUE WHEN r.publicadas = 2 AND NOT v_pub;
    SELECT id INTO v_k FROM vigilante.signals WHERE cliente_id = r.cid AND codigo = r.se_queda;
    SELECT id INTO v_d FROM vigilante.signals WHERE cliente_id = r.cid AND codigo = r.repetida;
    -- en cadena: si la que se queda ya se juntó con otra en esta vuelta, va a esa
    SELECT coalesce(duplicado_de, id) INTO v_k FROM vigilante.signals WHERE id = v_k;
    CONTINUE WHEN vigilante._separadas(v_k, v_d);
    IF vigilante._juntar(v_k, v_d, r.motivo, 'automático') IS NOT NULL THEN
      n := n + 1;
      v_lista := v_lista || jsonb_build_object('se_queda', (SELECT codigo FROM vigilante.signals WHERE id = v_k),
                                               'repetida', r.repetida, 'motivo', r.motivo);
    END IF;
  END LOOP;
  IF n > 0 THEN
    PERFORM vigilante.registrar_log(c.slug, 'mismo_hecho', 'info', format('%s señales juntadas con otra del mismo hecho', n),
                                    jsonb_build_object('pares', v_lista), NULL, NULL)
       FROM vigilante.clientes c WHERE c.id = (SELECT cliente_id FROM vigilante.signals WHERE id = v_k);
  END IF;
  RETURN jsonb_build_object('senales_juntadas', n, 'pares', v_lista);
END $$;
REVOKE ALL ON FUNCTION vigilante.juntar_senales_repetidas(int, boolean) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.juntar_senales_repetidas(int, boolean) TO authenticated, service_role;

-- A mano: juntar dos que la regla no ve. Si la «repetida» es la publicada, se cambian los papeles.
CREATE OR REPLACE FUNCTION vigilante.juntar_senales(p_se_queda text, p_repetida text, p_motivo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE k vigilante.signals; d vigilante.signals; t vigilante.signals; v_cli uuid := vigilante.cliente_actual(); v_reg bigint;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede juntar señales'; END IF;
  SELECT * INTO k FROM vigilante.signals WHERE codigo = p_se_queda AND (v_cli IS NULL OR cliente_id = v_cli) ORDER BY id LIMIT 1;
  SELECT * INTO d FROM vigilante.signals WHERE codigo = p_repetida AND cliente_id = k.cliente_id;
  IF k.id IS NULL OR d.id IS NULL THEN RAISE EXCEPTION 'No encuentro las señales % y %', p_se_queda, p_repetida; END IF;
  IF d.estado = 'publicada' AND k.estado <> 'publicada' THEN t := k; k := d; d := t; END IF;
  PERFORM set_config('vigilante.actor', coalesce('persona:' || auth.uid()::text, 'sql:juntar_senales'), true);
  v_reg := vigilante._juntar(k.id, d.id, coalesce(nullif(trim(p_motivo), ''), 'juntadas a mano'),
                             coalesce(vigilante.usuario_actual()::text, 'sql'));
  IF v_reg IS NULL THEN
    RAISE EXCEPTION 'No se pudieron juntar % y % (¿alguna ya está descartada o juntada con otra?)', k.codigo, d.codigo;
  END IF;
  RETURN jsonb_build_object('se_queda', k.codigo, 'repetida', d.codigo, 'registro', v_reg,
                            'fuentes', (SELECT n_fuentes FROM vigilante.respaldo_senal(k.id)));
END $$;
REVOKE ALL ON FUNCTION vigilante.juntar_senales(text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.juntar_senales(text, text, text) TO authenticated, service_role;

-- Deshacer: la repetida vuelve a Detectadas con sus noticias; la otra pierde lo que recibió.
-- (Si estaba publicada, una persona la vuelve a publicar.) Queda marcada para que la tarea no la vuelva a juntar.
CREATE OR REPLACE FUNCTION vigilante.separar_senal(p_repetida text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE j vigilante.senales_juntadas; d vigilante.signals; v_cli uuid := vigilante.cliente_actual();
BEGIN
  IF auth.uid() IS NOT NULL AND NOT vigilante.es_staff() THEN RAISE EXCEPTION 'Solo un analista o un administrador puede separar señales'; END IF;
  SELECT * INTO d FROM vigilante.signals WHERE codigo = p_repetida AND (v_cli IS NULL OR cliente_id = v_cli) ORDER BY id LIMIT 1;
  SELECT * INTO j FROM vigilante.senales_juntadas WHERE repetida_id = d.id AND separada_en IS NULL ORDER BY id DESC LIMIT 1;
  IF j.id IS NULL THEN RAISE EXCEPTION 'La señal % no está juntada con otra', p_repetida; END IF;
  PERFORM set_config('vigilante.actor', coalesce('persona:' || auth.uid()::text, 'sql:separar_senal'), true);
  DELETE FROM vigilante.signal_raw_items WHERE signal_id = j.se_queda_id AND raw_item_id = ANY (j.noticias);
  DELETE FROM vigilante.signal_territorios WHERE signal_id = j.se_queda_id AND territorio_id = ANY (j.territorios);
  UPDATE vigilante.oportunidades SET signal_id = d.id WHERE id = ANY (j.oportunidades);
  UPDATE vigilante.signals SET duplicado_de = NULL, estado = 'en_analisis', estado_manual = true,
         motivo_revision = 'Separada a mano: no es el mismo hecho'
   WHERE id = d.id;
  UPDATE vigilante.signals SET repetidas_unidas = greatest(repetidas_unidas - 1, 0) WHERE id = j.se_queda_id;
  UPDATE vigilante.senales_juntadas SET separada_en = now() WHERE id = j.id;
  RETURN jsonb_build_object('separada', d.codigo, 'de', (SELECT codigo FROM vigilante.signals WHERE id = j.se_queda_id),
                            'estado', 'en_analisis', 'estaba', j.estado_antes);
END $$;
REVOKE ALL ON FUNCTION vigilante.separar_senal(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.separar_senal(text) TO authenticated, service_role;


COMMIT;

-- 7. pg_cron: juntar cada 15 min (fuera de la transacción; solo en Supabase) -------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('vigilante-mismo-hecho', '*/15 * * * *', 'SELECT vigilante.juntar_senales_repetidas()');
  ELSE
    RAISE NOTICE 'pg_cron no está activo: las repetidas se juntan al llamar a vigilante.juntar_senales_repetidas()';
  END IF;
END $$;

-- Lo que ve ahora (no cambia nada)
SELECT se_queda, repetida, motivo, publicadas, titulo_se_queda, titulo_repetida FROM vigilante.senales_repetidas();
