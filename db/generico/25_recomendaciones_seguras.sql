-- =============================================================================
-- 25. Recomendaciones seguras (mejora 7 de la PoC, documento del revisor)
-- =============================================================================
-- Qué pasaba: AVIA podía recomendar «la ruta está habilitada, se puede viajar» sin que ninguna
-- fuente oficial lo hubiera dicho hace poco, y no decía qué faltaba saber antes de actuar.
--
-- Ahora cada señal lleva «recomendacion_segura»:
--   · texto: la recomendación de AVIA (o, si afirma algo sin verificar, el texto marcado «Sin confirmar»)
--   · para_quien: a quién va dirigida
--   · verificar_con: con quién comprobarlo según el tema (parámetro «verificar_con» del cliente)
--   · falta_saber[]: lo que propuso el modelo + lo que añade la base:
--       certeza posible/rumor → confirmar el hecho; convocado → si se mantiene la fecha;
--       vial/conectividad/clima sin dato oficial de las últimas 24 h → el estado actual;
--       oportunidad sin plazo → la fecha límite
--   · afirma_sin_verificar + aviso: el texto dice que algo está habilitado, operativo, transitable,
--       normal, abierto al tránsito o que «se puede viajar», y NO hay una fuente oficial recogida en las
--       últimas 24 h ni una persona que lo verificara en ese tiempo
--   · dato_oficial: hora del último dato oficial
-- La base no reescribe la recomendación: la marca, y el panel y AVIA muestran el aviso.
--
-- Necesita el 24. Cómo aplicarlo: pegar entero en el SQL Editor de Supabase y Run.
-- Comprobar: SELECT codigo, vigilante.recomendacion_segura(id) FROM vigilante.signals ORDER BY created_at DESC LIMIT 5;
-- Prueba: 99_prueba_recomendaciones.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

-- Con quién verificar cada tema. Valor por defecto de la plataforma y el de ORBITA (Bolivia).
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
  (NULL, 'verificar_con', '{"_": "la fuente oficial del tema"}', 'Con quién comprobar una recomendación según la categoría (mejora 7)')
ON CONFLICT (cliente_id, clave) DO NOTHING;
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
SELECT id, 'verificar_con', '{
  "vial": "la ABC (transitabilidad.abc.gob.bo) o la Policía caminera",
  "conectividad": "la DGAC, NAABOL (aeropuertos) o la aerolínea",
  "clima": "el SENAMHI (avisos vigentes)",
  "salud": "el Ministerio de Salud o el SEDES del departamento",
  "seguridad": "la Policía Boliviana o la gobernación",
  "eventos": "el organizador o la alcaldía",
  "financiamiento": "las bases oficiales de la entidad que convoca",
  "normativa": "la Gaceta Oficial de Bolivia",
  "mercados": "la fuente del dato (INE o Viceministerio de Turismo)",
  "_": "la fuente oficial del tema"}', 'Con quién comprobar una recomendación según la categoría (mejora 7)'
  FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
ON CONFLICT (cliente_id, clave) DO NOTHING;

-- Frases que dan algo por operativo o seguro. Se comparan sin distinguir mayúsculas. Antes se quitan
-- las negaciones («no está habilitada», «no se puede viajar», «ni transitable»), que son prudentes.
CREATE OR REPLACE FUNCTION vigilante.afirma_operativo(p_texto text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT regexp_replace(coalesce(p_texto, ''), '\m(no|ni|nunca) (est[aá]n? |es |son |se |hay |sigue[n]? |quedan? )?\w+', ' ', 'gi')
         ~* ('(habilitad[oa]s?|operativ[oa]s?|transitables?|expedit[oa]s?|normalidad|restablecid[oa]s?'
    || '|sin (problemas|riesgos?|restricci[oó]n(es)?|novedad(es)?|inconvenientes)'
    || '|(es|son|resulta|está|están) segur[oa]s?|pueden? viajar'
    || '|abiert[oa]s? al (tr[aá]nsito|tr[aá]fico|p[uú]blico|turismo)'
    || '|(ruta|carretera|camino|tramo|vuelo|aeropuerto|paso|frontera)s? (est[aá]n? |sigue[n]? )?(abiert|libre|disponible|funcionando))')
$$;

CREATE OR REPLACE FUNCTION vigilante.recomendacion_segura(p_signal bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  s vigilante.signals; m jsonb; c jsonb; t jsonb; v_cert text;
  v_texto text; v_para text; v_con text; v_falta text[] := '{}'; v_x text;
  v_oficial timestamptz; v_persona timestamptz; v_reciente boolean; v_afirma boolean; v_tema text;
BEGIN
  SELECT * INTO s FROM vigilante.signals WHERE id = p_signal;
  IF NOT FOUND THEN RETURN NULL; END IF;
  m := coalesce(s.salida_modelo, '{}');
  c := vigilante.certeza(s.id);
  t := vigilante.trazabilidad(s.id);
  v_cert := c ->> 'nivel';

  v_texto := coalesce(nullif(trim(s.recomendacion), ''), nullif(trim(m #>> '{soluciones,0,t}'), ''));
  v_para := coalesce(nullif(trim(m ->> 'para_quien'), ''),
                     (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(m -> 'actores') = 'array' THEN m -> 'actores' ELSE '[]' END) x));
  v_con := coalesce(vigilante.param(s.cliente_id, 'verificar_con') ->> s.categoria,
                    vigilante.param(s.cliente_id, 'verificar_con') ->> '_', 'la fuente oficial del tema');

  -- último dato oficial y última verificación de una persona
  SELECT max(coalesce((f ->> 'recogida')::timestamptz, (f ->> 'publicada')::timestamptz)) INTO v_oficial
    FROM jsonb_array_elements(coalesce(t -> 'fuentes', '[]')) f WHERE (f ->> 'oficial')::boolean;
  v_persona := CASE WHEN t #>> '{ultima_verificacion,estado}' IN ('confirmada', 'publicada')
                    THEN (t #>> '{ultima_verificacion,cuando}')::timestamptz END;
  v_reciente := greatest(v_oficial, v_persona) > now() - interval '24 hours';
  v_afirma := vigilante.afirma_operativo(v_texto) AND NOT coalesce(v_reciente, false);

  -- qué falta saber: lo del modelo + lo que añade la base
  IF jsonb_typeof(m -> 'falta_saber') = 'array' THEN
    FOR v_x IN SELECT trim(x) FROM jsonb_array_elements_text(m -> 'falta_saber') x WHERE trim(x) <> '' LIMIT 4 LOOP
      v_falta := array_append(v_falta, v_x);
    END LOOP;
  END IF;
  IF v_cert IN ('posible', 'rumor') THEN
    v_falta := array_append(v_falta, ('Confirmar que el hecho es cierto con ' || v_con || ' o una segunda fuente'));
  ELSIF v_cert = 'convocado' THEN
    v_falta := array_append(v_falta, 'Si se mantiene en la fecha anunciada (puede suspenderse o cambiar)');
  END IF;
  IF s.categoria IN ('vial', 'conectividad', 'clima') AND NOT coalesce(v_reciente, false) THEN
    v_tema := CASE s.categoria WHEN 'vial' THEN 'de la ruta' WHEN 'conectividad' THEN 'de vuelos y aeropuertos' ELSE 'del aviso' END;
    v_falta := array_append(v_falta, ('Estado actual ' || v_tema || ' según ' || v_con
                           || CASE WHEN v_oficial IS NULL THEN ': no hay dato oficial'
                                   ELSE ': el último dato oficial es del ' || to_char(v_oficial AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI') END));
  END IF;
  IF s.naturaleza IN ('oportunidad', 'mixta') AND s.plazo_hasta IS NULL AND s.categoria IN ('financiamiento', 'eventos') THEN
    v_falta := array_append(v_falta, 'Fecha límite: la fuente no la da');
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'texto', CASE WHEN v_texto IS NULL THEN NULL WHEN v_afirma THEN 'Sin confirmar: ' || v_texto ELSE v_texto END,
    'original', CASE WHEN v_afirma THEN v_texto END,
    'para_quien', v_para,
    'verificar_con', v_con,
    'falta_saber', to_jsonb(ARRAY(SELECT d.x FROM (SELECT DISTINCT ON (lower(u.x)) u.x, u.i FROM unnest(v_falta) WITH ORDINALITY u(x, i)
                                                         ORDER BY lower(u.x), u.i) d ORDER BY d.i)),   -- sin repetir, en orden
    'afirma_sin_verificar', v_afirma,
    'aviso', CASE WHEN v_afirma THEN 'La recomendación da algo por habilitado, operativo o seguro, pero ninguna fuente oficial ni persona lo comprobó en las últimas 24 h. Comprobar con '
                                     || v_con || ' antes de recomendarlo.' END,
    'dato_oficial', v_oficial,
    'certeza', v_cert));
END $$;
REVOKE ALL ON FUNCTION vigilante.recomendacion_segura(bigint) FROM public, anon;
GRANT EXECUTE ON FUNCTION vigilante.recomendacion_segura(bigint) TO authenticated, service_role;

-- El analizador pide qué falta saber y para quién (prompt clasificador-1.4): guardar_clasificacion
-- los pasa a la señal (igual que en el 24, con esas dos claves más)
CREATE OR REPLACE FUNCTION vigilante.guardar_clasificacion(p_cliente text, p_resultados jsonb, p_modelo text DEFAULT NULL,
                                                           p_prompt_version text DEFAULT NULL, p_uso jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente); x jsonb; v_doc vigilante.raw_items; v_ids bigint[];
  v_sig bigint; v_cod text; v_res jsonb; v_senal jsonb; v_op jsonb; v_nivel text; v_tarea jsonb; v_n int;
  n_desc int := 0; n_nuevas int := 0; n_act int := 0; n_opp int := 0; n_tareas int := 0; n_ignoradas int := 0;
BEGIN
  v_n := greatest(jsonb_array_length(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END), 1);
  PERFORM set_config('vigilante.actor', 'clasificador:' || coalesce(p_modelo, '?'), true);
  FOR x IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_resultados) = 'array' THEN p_resultados ELSE '[]' END) LOOP
    -- solo se acepta lo que se mandó a clasificar (clave = id de la noticia principal del grupo)
    SELECT * INTO v_doc FROM vigilante.raw_items WHERE cliente_id = v_cliente AND id = (x ->> 'clave')::bigint AND estado IN ('en_cola', 'nuevo');
    IF v_doc.id IS NULL OR (x ->> 'clave') !~ '^\d+$' THEN n_ignoradas := n_ignoradas + 1; CONTINUE; END IF;
    -- el grupo: misma noticia en otras fuentes, también pendiente
    v_ids := ARRAY(SELECT id FROM vigilante.raw_items WHERE cliente_id = v_cliente AND titulo_norm = v_doc.titulo_norm
                     AND estado IN ('en_cola', 'nuevo') ORDER BY id);

    INSERT INTO vigilante.analisis (cliente_id, raw_item_id, version, tipo, modelo, prompt_version, salida, relevante,
                                    tokens_entrada, tokens_salida, costo_usd)
    VALUES (v_cliente, v_doc.id, v_doc.version, 'clasificacion', p_modelo, p_prompt_version, x,
            coalesce((x ->> 'relevante')::boolean, false),
            ((p_uso ->> 'tokens_entrada')::numeric / v_n)::int, ((p_uso ->> 'tokens_salida')::numeric / v_n)::int,
            (p_uso ->> 'costo_usd')::numeric / v_n)
    ON CONFLICT (raw_item_id, version, tipo) DO NOTHING;

    IF NOT coalesce((x ->> 'relevante')::boolean, false) THEN
      UPDATE vigilante.raw_items SET estado = 'descartado', motivo_descarte = 'IA: ' || coalesce(nullif(x ->> 'motivo', ''), 'no relevante')
       WHERE id = ANY (v_ids);
      n_desc := n_desc + 1; CONTINUE;
    END IF;

    -- ¿ya hay señal para este hecho? (una noticia del grupo ya enlazada, o el mismo título en 72 h)
    SELECT s.codigo INTO v_cod FROM vigilante.signal_raw_items sr JOIN vigilante.signals s ON s.id = sr.signal_id
     WHERE sr.raw_item_id = ANY (v_ids) ORDER BY s.id DESC LIMIT 1;
    IF v_cod IS NULL THEN
      SELECT s.codigo INTO v_cod FROM vigilante.raw_items r JOIN vigilante.signal_raw_items sr ON sr.raw_item_id = r.id
        JOIN vigilante.signals s ON s.id = sr.signal_id
       WHERE r.cliente_id = v_cliente AND r.titulo_norm = v_doc.titulo_norm AND r.recolectado_en > now() - interval '72 hours'
         AND s.estado NOT IN ('descartada', 'cerrada')
       ORDER BY s.id DESC LIMIT 1;
    END IF;

    v_senal := jsonb_strip_nulls(jsonb_build_object(
      'codigo', v_cod,
      'titulo', coalesce(nullif(x ->> 'titulo', ''), v_doc.titulo),
      'resumen', coalesce(nullif(x ->> 'resumen', ''), left(v_doc.contenido, 300), v_doc.titulo),
      'recomendacion', x ->> 'recomendacion', 'naturaleza', x ->> 'naturaleza', 'categoria', x ->> 'categoria',
      'prioridad', x ->> 'prioridad', 'motivos_prioridad', x -> 'motivos_prioridad', 'departamentos', x -> 'departamentos',
      'fecha_evento_inicio', x ->> 'fecha_evento_inicio', 'fecha_evento_fin', x ->> 'fecha_evento_fin',
      'plazo_hasta', x ->> 'plazo_hasta', 'es_escenario', x -> 'es_escenario', 'confianza', x -> 'confianza',
      'impacto', x -> 'impacto', 'probabilidad', x -> 'probabilidad',   -- 22: se guardan en salida_modelo
      'certeza', x -> 'certeza',                                         -- 24: grado de certeza que propone el modelo
      'falta_saber', x -> 'falta_saber', 'para_quien', x -> 'para_quien', -- 25: recomendación segura
      'modelo', p_modelo, 'noticias', to_jsonb(v_ids),
      -- para la web (mismo formato que vigilante.json)
      'tipo_oportunidad', x #>> '{oportunidad,tipo}', 'actores', x #> '{oportunidad,beneficiarios}',
      'importancia', x #>> '{oportunidad,interpretacion}',
      'soluciones', CASE WHEN x #>> '{oportunidad,accion}' IS NOT NULL
                         THEN jsonb_build_array(jsonb_build_object('t', x #>> '{oportunidad,accion}')) END));
    v_res := vigilante.guardar_senal(p_cliente, v_senal);
    SELECT id INTO v_sig FROM vigilante.signals WHERE cliente_id = v_cliente AND codigo = v_res ->> 'codigo';
    UPDATE vigilante.analisis SET signal_id = v_sig WHERE raw_item_id = v_doc.id AND version = v_doc.version AND tipo = 'clasificacion';
    IF (v_res ->> 'nueva')::boolean THEN n_nuevas := n_nuevas + 1; ELSE n_act := n_act + 1; END IF;

    -- oportunidad
    v_op := x -> 'oportunidad';
    IF jsonb_typeof(v_op) = 'object' AND coalesce(trim(v_op ->> 'hecho'), '') <> '' AND coalesce(trim(v_op ->> 'tipo'), '') <> '' THEN
      v_nivel := CASE WHEN lower(v_op ->> 'tipo') = ANY (v_doc.tipos_oportunidad) THEN 'explicita' ELSE 'inferida' END;
      IF v_nivel = 'explicita' OR coalesce(trim(v_op ->> 'interpretacion'), '') <> '' THEN
        INSERT INTO vigilante.oportunidades (cliente_id, signal_id, nivel, tipo, hecho, interpretacion, beneficiarios, accion,
                                             plazo_hasta, importancia, evidencias, creada_por)
        VALUES (v_cliente, v_sig, v_nivel, lower(v_op ->> 'tipo'), v_op ->> 'hecho', nullif(trim(v_op ->> 'interpretacion'), ''),
                CASE WHEN jsonb_typeof(v_op -> 'beneficiarios') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(v_op -> 'beneficiarios')) ELSE '{}' END,
                v_op ->> 'accion', (SELECT plazo_hasta FROM vigilante.signals WHERE id = v_sig),
                CASE WHEN (v_op ->> 'importancia') ~ '^[1-5]$' THEN (v_op ->> 'importancia')::smallint END,
                v_ids, 'clasificador')
        ON CONFLICT (signal_id, nivel, tipo) DO UPDATE SET
          hecho = EXCLUDED.hecho, interpretacion = EXCLUDED.interpretacion, beneficiarios = EXCLUDED.beneficiarios,
          accion = EXCLUDED.accion, plazo_hasta = EXCLUDED.plazo_hasta, importancia = EXCLUDED.importancia,
          evidencias = ARRAY(SELECT DISTINCT unnest(vigilante.oportunidades.evidencias || EXCLUDED.evidencias)), updated_at = now();
        n_opp := n_opp + 1;
      END IF;
    END IF;

    -- tareas para Hermes
    v_tarea := x -> 'tarea';
    IF coalesce((x ->> 'necesita_agente')::boolean, false) AND jsonb_typeof(v_tarea) = 'object'
       AND v_tarea ->> 'tipo' IN ('corroborar', 'contradiccion', 'relacionar', 'oportunidad_inferida') THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, v_tarea ->> 'tipo', v_sig, v_ids,
                                                    coalesce(nullif(v_tarea ->> 'motivo', ''), 'Pedido por el clasificador'), 'clasificador') ->> 'nueva')::boolean::int;
    ELSIF x ->> 'prioridad' = 'alta' AND NOT (v_res ->> 'fuente_oficial')::boolean THEN
      n_tareas := n_tareas + (vigilante.crear_tarea(v_cliente, 'corroborar', v_sig, v_ids,
                                                    'Prioridad alta sin fuente oficial: buscar confirmación', 'regla') ->> 'nueva')::boolean::int;
    END IF;
  END LOOP;

  IF coalesce((p_uso ->> 'costo_usd')::numeric, 0) > 0 OR coalesce((p_uso ->> 'tokens_entrada')::int, 0) > 0 THEN
    PERFORM vigilante.registrar_log(p_cliente, 'clasificador', 'info', format('Lote de %s noticias', v_n), p_uso || jsonb_build_object('modelo', p_modelo),
                                    (p_uso ->> 'costo_usd')::numeric, NULL);
  END IF;
  RETURN jsonb_build_object('descartadas', n_desc, 'senales_nuevas', n_nuevas, 'senales_actualizadas', n_act,
                            'oportunidades', n_opp, 'tareas_agente', n_tareas, 'ignoradas', n_ignoradas);
END $$;

-- vigilante.json / vigilante_bd(): igual que en el 24, con «recomendacion_segura» en cada señal
CREATE OR REPLACE FUNCTION vigilante._vigilante_json(p_cliente uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
  WITH c AS (SELECT p_cliente AS id,
                    vigilante._entero(vigilante.param(p_cliente, 'retencion_meses'), 6) AS meses,
                    vigilante._entero(vigilante.param(p_cliente, 'web_dias_visibles'), 7) AS dias)
  SELECT jsonb_build_object(
    'version', 1,
    'generado', now(),
    'origen', 'base',
    'dias_visibles', (SELECT dias FROM c),
    'noticias_revisadas', (SELECT count(*) FROM vigilante.raw_items r, c WHERE r.cliente_id = c.id AND r.recolectado_en > now() - interval '24 hours'),
    'ventana_horas', 24,
    'fuentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', s.codigo, 'nombre', s.nombre, 'canal', s.categorias[1], 'tipo', s.tipo, 'url', s.url,
                  'metodo', s.metodo, 'estado', CASE WHEN NOT s.activa THEN 'MANT' ELSE coalesce(s.config ->> 'estado', 'UNKNOWN') END,
                  'ultima', s.ultima_consulta_en, 'proxima', s.proxima_revision_en,
                  'items', vigilante._entero(s.config -> 'items', 0), 'hist', coalesce(s.config -> 'hist', '[]'), 'info', s.notas)
                  ORDER BY s.nombre), '[]')
                  FROM vigilante.sources s, c
                 WHERE s.cliente_id = c.id AND s.eliminada_en IS NULL AND NOT coalesce((s.config ->> 'propuesta_avia')::boolean, false)),
    'senales', (SELECT coalesce(jsonb_agg(
                  (CASE WHEN s.salida_modelo ? 'id' AND s.salida_modelo ? 'titulo'
                       THEN s.salida_modelo || jsonb_build_object('id', s.codigo, 'estado', s.estado)
                       ELSE jsonb_strip_nulls(jsonb_build_object(
                         'id', s.codigo, 'titulo', s.titulo, 'resumen', s.resumen, 'naturaleza', s.naturaleza,
                         'categoria', s.categoria, 'estado', s.estado, 'prioridad', s.prioridad,
                         'conf', s.confianza,
                         'rel', (s.salida_modelo ->> 'relevancia')::numeric, 'nov', (s.salida_modelo ->> 'novedad')::numeric,
                         'deps', (SELECT jsonb_agg(t.nombre) FROM vigilante.signal_territorios st JOIN vigilante.territorios t ON t.id = st.territorio_id WHERE st.signal_id = s.id),
                         'destinos', s.salida_modelo -> 'destinos',
                         'fecha_limite', to_char(s.plazo_hasta AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                         'enlaces', (SELECT jsonb_agg(jsonb_build_object('nombre', coalesce(src.nombre, 'Fuente'), 'url', r.url,
                                                                         'fecha', to_char(coalesce(r.publicado_en, r.recolectado_en), 'YYYY-MM-DD')))
                                       FROM vigilante.signal_raw_items sr JOIN vigilante.raw_items r ON r.id = sr.raw_item_id
                                       LEFT JOIN vigilante.sources src ON src.id = r.source_id WHERE sr.signal_id = s.id),
                         'tipoOpp', s.salida_modelo ->> 'tipo_oportunidad', 'actores', s.salida_modelo -> 'actores',
                         'importancia', coalesce(s.salida_modelo ->> 'importancia', s.recomendacion),
                         'soluciones', s.salida_modelo -> 'soluciones',
                         'revision', CASE WHEN s.requiere_revision THEN coalesce(s.motivo_revision, 'Requiere revisión de una persona') END,
                         'detectada', s.created_at))
                  END)
                  || jsonb_strip_nulls(jsonb_build_object(
                       'escenario', s.es_escenario,
                       'revision_vence', vigilante.vence_revision(s.cliente_id, s.requiere_revision, s.estado, s.created_at),
                       'revision_vencida', s.revision_vencida_en,
                       'evento_inicio', to_char(s.fecha_evento_inicio AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'evento_fin', to_char(s.fecha_evento_fin AT TIME ZONE 'UTC', 'YYYY-MM-DD'),
                       'ultima_noticia', vigilante.ultima_noticia(s.id, s.created_at),
                       'puntuaciones', vigilante.puntuaciones(s.id),
                       'trazabilidad', vigilante.trazabilidad(s.id),
                       'certeza', vigilante.certeza(s.id),
                       'recomendacion_segura', vigilante.recomendacion_segura(s.id),
                       'detectada', s.created_at))
                  ORDER BY s.created_at DESC), '[]')
                  FROM vigilante.senales_visibles(p_cliente) s),
    'oportunidades', vigilante._oportunidades_json(p_cliente),
    'contadores', vigilante.contadores(p_cliente)
  )
$$;
REVOKE ALL ON FUNCTION vigilante._vigilante_json(uuid) FROM public, anon, authenticated;

COMMIT;
