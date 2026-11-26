-- =============================================================================
-- 55 · El filtro previo deja pasar las noticias de servicios esenciales y de atención turística
-- =============================================================================
-- Fallo (2026-11-26, diagnóstico de Meysel en Supabase, últimos 30 días):
--   · De 278 noticias que hablan de agua, luz, combustible o internet, 219 se descartaron, y 209 de
--     ellas por «puntaje previo 10 < 30», es decir, SIN llegar a la IA. La IA solo rechazó 4.
--   · De 75 noticias de hoteles, ocupación, visitantes o áreas protegidas, 71 se descartaron igual.
--   Por eso los ejes «Servicios esenciales» y «Atención turística» de la vista Dirección (49) salían
--   casi vacíos.
-- Causa: el filtro sin IA (insertar_noticias, 14 y 15) da 10 puntos de base y pide 30. Solo suman las
--   palabras de alerta (desastres y conflictos), las de oportunidad (convocatorias, ferias…) y nombrar un
--   departamento o su capital. «Corte de agua», «apagón», «diésel», «hotel» u «ocupación» no sumaban, y
--   El Alto, Uyuni, Copacabana o Rurrenabaque no contaban como lugar.
--
-- Qué hace (cliente orbita-bolivia; no cambia la función del filtro, solo sus listas):
--   1. palabras_alerta (+30): cortes y faltas de servicios esenciales (agua, luz, combustible, gas,
--      internet y telefonía, hospitales). Con una de ellas la noticia ya pasa (10 + 30).
--   2. palabras_oportunidad (+20): oferta y demanda turística (hoteles, alojamiento, ocupación,
--      reservas, visitantes, áreas protegidas, SERNAP, museos, guías). Con una pasa justo (10 + 20).
--   3. Alias de territorio (+25): ciudades grandes y destinos turísticos de cada departamento. Se dejan
--      fuera los nombres que también son apellidos o lugares de fuera (Montero, Warnes, Reyes, San Borja…).
--   4. vigilante.repuntuar_descartadas(): vuelve a puntuar con estas listas las noticias descartadas por
--      puntaje en los últimos N días; las que ahora pasan vuelven a «nuevo» y el analizador las clasifica
--      en su siguiente ronda. Se ejecuta aquí con 7 días (Meysel, 2026-11-26).
--   Las listas se SUMAN a las que ya tenga el cliente o la plataforma: no se quita ninguna palabra.
--   Se puede ejecutar varias veces (la segunda vez no añade nada ni recupera de nuevo).
--
-- Coste: unas 7 noticias de servicios y 2-3 de atención más al día (según los 30 días medidos),
--   más las de los alias nuevos. Las recuperadas de 7 días son unas 50-80 (5-8 lotes del analizador).
--
-- Comprobar:
--   SELECT vigilante.repuntuar_descartadas('orbita-bolivia', 7, false);   -- vista previa, no cambia nada
-- Prueba: 99_prueba_filtro_servicios.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante.insertar_noticias(uuid,integer,bigint,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 15 (filtro previo con versiones). Ejecuta 14 y 15 antes que este archivo';
  END IF;
END $$;

-- 1 y 2. Palabras nuevas, sumadas a la lista vigente del cliente ---------------------------------------
CREATE OR REPLACE FUNCTION vigilante._sumar_palabras(p_cliente uuid, p_clave text, p_nuevas text[], p_desc text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_actual jsonb := coalesce(vigilante.param(p_cliente, p_clave), '[]'); v_lista jsonb; n int;
BEGIN
  IF jsonb_typeof(v_actual) <> 'array' THEN v_actual := '[]'; END IF;
  -- añade solo las que no están ya (comparando sin tildes ni mayúsculas)
  SELECT v_actual || coalesce(jsonb_agg(w ORDER BY o), '[]'), count(*) INTO v_lista, n
    FROM unnest(p_nuevas) WITH ORDINALITY AS u(w, o)
   WHERE vigilante.texto_norm(w) NOT IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_actual) x);
  INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
  VALUES (p_cliente, p_clave, v_lista, p_desc)
  ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor, updated_at = now();
  RETURN n;
END $$;

-- 3. Alias de territorio, sumados a los que ya tenga cada departamento ---------------------------------
CREATE OR REPLACE FUNCTION vigilante._sumar_alias(p_cliente uuid, p_codigo text, p_alias text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_actual jsonb; n int;
BEGIN
  SELECT CASE WHEN jsonb_typeof(datos -> 'alias') = 'array' THEN datos -> 'alias' ELSE '[]' END INTO v_actual
    FROM vigilante.territorios WHERE cliente_id = p_cliente AND codigo = p_codigo;
  IF NOT FOUND THEN RETURN 0; END IF;
  SELECT count(*) INTO n FROM unnest(p_alias) a
   WHERE vigilante.texto_norm(a) NOT IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_actual) x);
  UPDATE vigilante.territorios
     SET datos = coalesce(datos, '{}') || jsonb_build_object('alias', v_actual || coalesce(
           (SELECT jsonb_agg(a ORDER BY o) FROM unnest(p_alias) WITH ORDINALITY AS u(a, o)
             WHERE vigilante.texto_norm(a) NOT IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_actual) x)), '[]'))
   WHERE cliente_id = p_cliente AND codigo = p_codigo;
  RETURN n;
END $$;

-- 4. Puntaje previo de un texto (mismas reglas que insertar_noticias del 15) -----------------------------
CREATE OR REPLACE FUNCTION vigilante.puntaje_previo(p_cliente uuid, p_source_id integer, p_busqueda_id bigint, p_texto text)
RETURNS TABLE (puntaje int, motivos text[], territorios int[], tipos text[])
LANGUAGE plpgsql STABLE SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_src vigilante.sources; v_texto text := vigilante.texto_norm(p_texto); v_kw text[]; v_frase text; v_ter record;
  v_reglas jsonb; v_tipo text;
BEGIN
  puntaje := 10; motivos := '{}'; territorios := '{}'; tipos := '{}';
  IF p_source_id IS NOT NULL THEN SELECT * INTO v_src FROM vigilante.sources WHERE id = p_source_id; END IF;
  IF v_src.tipo IN ('oficial', 'organismo_internacional') THEN
    puntaje := puntaje + 15; motivos := motivos || 'fuente oficial'::text;
  END IF;
  v_kw := CASE WHEN jsonb_typeof(v_src.config -> 'palabras_clave') = 'array'
               THEN ARRAY(SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_src.config -> 'palabras_clave') x
                          WHERE vigilante.texto_norm(x) <> '')
               ELSE '{}' END;
  FOREACH v_frase IN ARRAY v_kw LOOP
    IF vigilante.contiene(v_texto, v_frase) THEN puntaje := puntaje + 30; motivos := motivos || ('palabra clave: ' || v_frase)::text; EXIT; END IF;
  END LOOP;
  FOR v_ter IN SELECT id, nombre, datos FROM vigilante.territorios WHERE cliente_id = p_cliente AND nivel <> 'pais' LOOP
    IF vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.nombre))
       OR vigilante.contiene(v_texto, vigilante.texto_norm(v_ter.datos ->> 'capital'))
       OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_ter.datos -> 'alias') = 'array' THEN v_ter.datos -> 'alias' ELSE '[]' END) a
                   WHERE vigilante.contiene(v_texto, vigilante.texto_norm(a))) THEN
      territorios := territorios || v_ter.id;
    END IF;
  END LOOP;
  IF cardinality(territorios) > 0 THEN puntaje := puntaje + 25; motivos := motivos || 'menciona un territorio'::text; END IF;
  FOREACH v_frase IN ARRAY vigilante.lista_param(p_cliente, 'palabras_alerta') LOOP
    IF vigilante.contiene(v_texto, v_frase) THEN puntaje := puntaje + 30; motivos := motivos || ('alerta: ' || v_frase)::text; EXIT; END IF;
  END LOOP;
  FOREACH v_frase IN ARRAY vigilante.lista_param(p_cliente, 'palabras_oportunidad') LOOP
    IF vigilante.contiene(v_texto, v_frase) THEN puntaje := puntaje + 20; motivos := motivos || ('oportunidad: ' || v_frase)::text; EXIT; END IF;
  END LOOP;
  v_reglas := CASE WHEN jsonb_typeof(vigilante.param(p_cliente, 'reglas_oportunidad')) = 'object'
                   THEN vigilante.param(p_cliente, 'reglas_oportunidad') ELSE '{}' END;
  FOR v_tipo IN SELECT jsonb_object_keys(v_reglas) LOOP
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(v_reglas -> v_tipo) = 'array' THEN v_reglas -> v_tipo ELSE '[]' END) f
                WHERE vigilante.contiene(v_texto, vigilante.texto_norm(f))) THEN
      tipos := tipos || v_tipo;
    END IF;
  END LOOP;
  IF cardinality(tipos) > 0 AND NOT EXISTS (SELECT 1 FROM unnest(motivos) m WHERE m LIKE 'oportunidad:%') THEN
    puntaje := puntaje + 20; motivos := motivos || ('oportunidad explícita: ' || array_to_string(tipos, ', '))::text;
  END IF;
  IF p_busqueda_id IS NOT NULL THEN puntaje := puntaje + 20; motivos := motivos || 'búsqueda pedida por AVIA'::text; END IF;
  puntaje := least(puntaje, 100);
  RETURN NEXT;
END $$;

-- 5. Volver a puntuar las descartadas por puntaje -------------------------------------------------------
-- p_aplicar = false: solo cuenta y enseña ejemplos. true: las que ahora pasan vuelven a «nuevo».
-- Nunca toca las descartadas como ruido (portadas, login…) ni las que rechazó la IA.
CREATE OR REPLACE FUNCTION vigilante.repuntuar_descartadas(p_cliente text, p_dias int DEFAULT 7, p_aplicar boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE
  v_cliente uuid := vigilante.id_cliente(p_cliente);
  v_umbral int := coalesce((vigilante.param(v_cliente, 'umbral_previo') #>> '{}')::int, 30);
  v_revisadas int; v_pasan int; v_ejemplos jsonb;
BEGIN
  IF v_cliente IS NULL THEN RAISE EXCEPTION 'Cliente % no existe', p_cliente; END IF;
  CREATE TEMP TABLE IF NOT EXISTS _repuntuar (id bigint PRIMARY KEY, titulo text, puntaje int, motivos text[], territorios int[], tipos text[]) ON COMMIT DROP;
  TRUNCATE _repuntuar;
  INSERT INTO _repuntuar
  SELECT r.id, r.titulo, p.puntaje, p.motivos, p.territorios, p.tipos
    FROM vigilante.raw_items r,
         LATERAL vigilante.puntaje_previo(r.cliente_id, r.source_id, r.busqueda_id, coalesce(r.titulo, '') || ' ' || coalesce(r.contenido, '')) p
   WHERE r.cliente_id = v_cliente AND r.estado = 'descartado'
     AND r.motivo_descarte LIKE 'puntaje previo%'
     AND r.recolectado_en > now() - make_interval(days => p_dias);
  GET DIAGNOSTICS v_revisadas = ROW_COUNT;
  SELECT count(*) FILTER (WHERE puntaje >= v_umbral),
         coalesce(jsonb_agg(jsonb_build_object('titulo', left(titulo, 90), 'puntaje', puntaje, 'motivos', motivos) ORDER BY puntaje DESC, id DESC)
                    FILTER (WHERE puntaje >= v_umbral), '[]')
    INTO v_pasan, v_ejemplos FROM _repuntuar;

  IF p_aplicar AND v_pasan > 0 THEN
    UPDATE vigilante.raw_items r SET
      estado = 'nuevo', motivo_descarte = NULL, puntaje_previo = x.puntaje, motivos = x.motivos,
      territorios_detectados = x.territorios, menciona_territorio = cardinality(x.territorios) > 0, tipos_oportunidad = x.tipos,
      payload = r.payload || jsonb_build_object('recuperada_55', now())
      FROM _repuntuar x
     WHERE r.id = x.id AND x.puntaje >= v_umbral;
  END IF;
  RETURN jsonb_build_object('dias', p_dias, 'revisadas', v_revisadas, 'ahora_pasan', v_pasan, 'aplicado', p_aplicar AND v_pasan > 0,
                            'ejemplos', (SELECT coalesce(jsonb_agg(e), '[]') FROM (SELECT e FROM jsonb_array_elements(v_ejemplos) e LIMIT 15) q));
END $$;
REVOKE ALL ON FUNCTION vigilante.repuntuar_descartadas(text, int, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION vigilante.repuntuar_descartadas(text, int, boolean) TO service_role;

-- 6. Datos del cliente orbita-bolivia ----------------------------------------------------------------
DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'); n int; m int := 0;
BEGIN
  IF c IS NULL THEN RAISE NOTICE 'No hay cliente orbita-bolivia: solo se crean las funciones'; RETURN; END IF;

  n := vigilante._sumar_palabras(c, 'palabras_alerta', ARRAY[
    -- agua
    'corte de agua', 'cortes de agua', 'sin agua', 'falta de agua', 'escasez de agua', 'racionamiento', 'agua potable',
    'distribución de agua', 'cisternas',
    -- electricidad
    'apagón', 'apagones', 'corte de luz', 'cortes de luz', 'sin luz', 'corte de energía', 'cortes de energía',
    'corte eléctrico', 'cortes eléctricos', 'suministro eléctrico', 'interrupción eléctrica',
    -- combustible y gas
    'desabastecimiento', 'escasez de combustible', 'falta de combustible', 'combustible', 'diésel', 'diesel', 'gasolina',
    'surtidores', 'filas en surtidores', 'garrafa', 'garrafas', 'gas licuado',
    -- telecomunicaciones
    'sin internet', 'caída de internet', 'corte de internet', 'falla de internet', 'sin señal', 'telefonía móvil',
    -- salud como servicio
    'colapso hospitalario', 'hospitales', 'falta de medicamentos', 'emergencia sanitaria'],
    'Palabras que suben el puntaje como posible riesgo o alerta temprana (55: + servicios esenciales)');
  m := m + n; RAISE NOTICE 'palabras_alerta: % nuevas', n;

  n := vigilante._sumar_palabras(c, 'palabras_oportunidad', ARRAY[
    'turismo', 'turistas', 'turista', 'visitantes', 'hotel', 'hoteles', 'hotelero', 'hotelera', 'hotelería',
    'alojamiento', 'alojamientos', 'hospedaje', 'hostal', 'ocupación hotelera', 'reservas hoteleras', 'agencias de viaje',
    'operadores de turismo', 'operadoras de turismo', 'guías de turismo', 'atractivo turístico', 'atractivos turísticos',
    'destino turístico', 'parque nacional', 'área protegida', 'áreas protegidas', 'sernap', 'museo', 'museos',
    'circuito turístico', 'temporada alta', 'feriado largo', 'fin de semana largo'],
    'Palabras que suben el puntaje como posible oportunidad (55: + oferta y demanda turística)');
  m := m + n; RAISE NOTICE 'palabras_oportunidad: % nuevas', n;

  n := 0;
  n := n + vigilante._sumar_alias(c, 'BO-L', ARRAY['El Alto', 'Copacabana', 'Titicaca', 'Coroico', 'Yungas', 'Sorata',
         'Tiwanaku', 'Tiahuanaco', 'Madidi', 'Chacaltaya', 'Isla del Sol', 'Caranavi', 'Desaguadero']);
  n := n + vigilante._sumar_alias(c, 'BO-P', ARRAY['Uyuni', 'Salar de Uyuni', 'Tupiza', 'Villazón', 'Llallagua',
         'Reserva Eduardo Avaroa', 'Laguna Colorada']);
  n := n + vigilante._sumar_alias(c, 'BO-O', ARRAY['Sajama', 'Huanuni', 'Challapata', 'Caracollo', 'Pisiga']);
  n := n + vigilante._sumar_alias(c, 'BO-C', ARRAY['Quillacollo', 'Sacaba', 'Chapare', 'Villa Tunari', 'Torotoro',
         'Tarata', 'Incallajta', 'Tunari']);
  n := n + vigilante._sumar_alias(c, 'BO-S', ARRAY['Samaipata', 'Chiquitania', 'Chiquitanía',
         'San José de Chiquitos', 'Roboré', 'Puerto Suárez', 'Puerto Quijarro', 'Amboró', 'Noel Kempff', 'Viru Viru',
         'Camiri', 'Vallegrande', 'San Ignacio de Velasco']);
  n := n + vigilante._sumar_alias(c, 'BO-H', ARRAY['Tarabuco', 'Monteagudo', 'Cal Orck''o', 'Muyupampa']);
  n := n + vigilante._sumar_alias(c, 'BO-T', ARRAY['Yacuiba', 'Bermejo', 'Villamontes', 'Valle de Concepción']);
  n := n + vigilante._sumar_alias(c, 'BO-B', ARRAY['Rurrenabaque', 'Riberalta', 'Guayaramerín', 'San Ignacio de Moxos',
         'Santa Ana del Yacuma']);
  m := m + n; RAISE NOTICE 'alias de territorio: % nuevos', n;
END $$;

-- 7. Recuperar las descartadas de los últimos 7 días (Meysel, 2026-11-26) --------------------------------
SELECT vigilante.repuntuar_descartadas(slug, 7, true) AS recuperadas
  FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

COMMIT;
