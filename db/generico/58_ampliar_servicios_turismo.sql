-- =============================================================================
-- 58 · Más servicios esenciales y más turismo en el filtro previo y en los ejes de Dirección
-- =============================================================================
-- Pedido (Meysel, 2026-11-26): «en servicios especiales tienes que poner más cosas que detecte:
--   corte de luz, de agua, de salud, todo eso; y en turismo más cosas de viajes, de aerolíneas,
--   de eventos, cosas de turismo».
--
-- Lo que ya había (14, 15 y 55) y NO se repite: corte/falta de agua y luz, apagón, combustible, diésel,
--   garrafas, internet, hospitales, falta de medicamentos, emergencia sanitaria, epidemia, brote;
--   hotel, alojamiento, ocupación, visitantes, parque nacional, área protegida, SERNAP, museos, guías;
--   festival, feria, congreso, evento, carnaval, nueva ruta, nuevo vuelo.
--
-- Qué añade (cliente orbita-bolivia; las listas se SUMAN, no se quita nada; se puede ejecutar varias veces):
--   1. palabras_alerta (+30, la noticia ya pasa el filtro):
--      · agua y luz: cortes programados, baja presión, agua turbia, y las empresas que los anuncian
--        (EPSAS, SEMAPA, SAGUAPAC, ELAPAS, DELAPAZ, CRE, ELFEC…). No se pone «ENDE» porque «por ende»
--        lo dispararía en cualquier noticia.
--      · salud: dengue, chikungunya, zika, fiebre amarilla, sarampión, influenza, covid, alerta
--        epidemiológica, terapia intensiva, paro médico, SEDES, intoxicación…
--      · otros servicios que usa el viajero: recojo de basura, cajeros, falta de dólares o de efectivo,
--        subida de pasajes, combustible de aviación.
--      · aerolíneas (riesgo): vuelos cancelados, suspendidos o retrasados, pasajeros varados, huelga de
--        pilotos, controladores aéreos, cierre de aeropuerto.
--   2. palabras_oportunidad (+20, la noticia pasa justo):
--      · aerolíneas de Bolivia: BoA, EcoJet, Amaszonas, TAM, NAABOL, terminales de buses. Las aerolíneas de
--        fuera y las palabras genéricas de aviación NO: traían noticias de otros países.
--      · eventos: Gran Poder, Urkupiña, Alasitas, Carnaval de Oruro, Todos Santos, Año Nuevo Andino,
--        Festival de Música Barroca, Expocruz, Feicobol, fiestas patronales, peregrinación, Dakar,
--        Juegos Bolivarianos.
--        Partidos de liga NO: el clasificador sigue descartando los deportes sin efecto en el turismo.
--      · alojamiento y actividades propias de Bolivia: ecoalbergue, turismo comunitario, ruta del singani,
--        Mi Teleférico, misiones jesuíticas, Viceministerio de Turismo, Cámara Hotelera. Una noticia de
--        tours, hoteles o trekking en Bolivia ya pasa por nombrar el lugar (+25).
--   3. reglas_oportunidad: más frases en el tipo «evento», para que el clasificador
--      reciba la oportunidad como candidata.
--   4. vigilante.eje_de() (vista Dirección, 49): mismas reglas, más palabras. Servicios suma salud
--      (dengue, brotes, medicamentos, vacunas), basura y cajeros o falta de dólares; atención turística
--      suma pasajes, rutas aéreas, frecuencias, museos, parques, atractivos, tours, trekking, teleférico,
--      conciertos y las fiestas grandes.
--   5. NO recupera noticias por sí solo. Al final enseña una VISTA PREVIA de cuántas descartadas de los
--      últimos 7 días pasarían ahora. Para recuperarlas (solo con el visto bueno de Meysel):
--        SELECT vigilante.repuntuar_descartadas('orbita-bolivia', 7, true);
--      y después, en el VPS, vaciar la cola sin esperar al cron:
--        python3 /root/avia/analizador.py --lotes 40
--
-- Coste: más noticias llegan a la IA. Al ver la vista previa se sabe cuántas por semana; si son
--   demasiadas, se puede quitar una palabra de la lista (Fuentes → parámetros, o un UPDATE).
--
-- Ajustado con el 59 tras la primera vista previa: sin «sin conexión» ni aviación o turismo genéricos
--   (dejaban pasar noticias de otros países). Si ya ejecutaste el 58 antiguo, ejecuta el 59.
-- Necesita el 55 (funciones _sumar_palabras y repuntuar_descartadas) y el 49 (eje_de).
-- Prueba: 99_prueba_ampliar_servicios_turismo.sql (termina en ROLLBACK).
-- =============================================================================
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('vigilante._sumar_palabras(uuid,text,text[],text)') IS NULL
     OR to_regprocedure('vigilante.repuntuar_descartadas(text,integer,boolean)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 55 (filtro de servicios y atención). Ejecuta el 55 antes que este archivo';
  END IF;
  IF to_regprocedure('vigilante.eje_de(text,text)') IS NULL THEN
    RAISE EXCEPTION 'Falta el 49 (vista Dirección). Ejecuta el 49 antes que este archivo';
  END IF;
END $$;

-- 3. Frases nuevas dentro de un tipo de reglas_oportunidad (se suman a las que haya) ----------------------
CREATE OR REPLACE FUNCTION vigilante._sumar_regla_oportunidad(p_cliente uuid, p_tipo text, p_nuevas text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_reglas jsonb := vigilante.param(p_cliente, 'reglas_oportunidad');
  v_actual jsonb; v_lista jsonb; n int;
BEGIN
  IF v_reglas IS NULL OR jsonb_typeof(v_reglas) <> 'object' THEN v_reglas := '{}'; END IF;
  v_actual := CASE WHEN jsonb_typeof(v_reglas -> p_tipo) = 'array' THEN v_reglas -> p_tipo ELSE '[]' END;
  SELECT v_actual || coalesce(jsonb_agg(w ORDER BY o), '[]'), count(*) INTO v_lista, n
    FROM unnest(p_nuevas) WITH ORDINALITY AS u(w, o)
   WHERE vigilante.texto_norm(w) NOT IN (SELECT vigilante.texto_norm(x) FROM jsonb_array_elements_text(v_actual) x);
  IF n = 0 THEN RETURN 0; END IF;
  INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
  VALUES (p_cliente, 'reglas_oportunidad', v_reglas || jsonb_build_object(p_tipo, v_lista),
          'Frases (sin tildes) que marcan una noticia como posible oportunidad EXPLÍCITA de cada tipo. Editable')
  ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor, updated_at = now();
  RETURN n;
END $$;

-- 4. Eje de una señal: mismas reglas que el 49, con más palabras ------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.eje_de(p_categoria text, p_texto text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH t AS (SELECT ' ' || vigilante.texto_norm(p_texto) || ' ' AS x, lower(coalesce(p_categoria, '')) AS c),
  r AS (
    SELECT c,
      x ~ '\m(bloqueo|bloqueos|bloquean|marcha|marchas|paro|paros|huelga|protesta|protestas|movilizacion|movilizaciones|conflicto social|cerco|enfrentamiento|toma de)\M' AS conflicto,
      x ~ ('\m(agua|potable|sequia|racionamiento|electricidad|energia electrica|suministro electrico|apagon\w*|corte de luz|cortes de luz|corte de energia|cortes de energia|combustible|gasolina|diesel|desabastec\w*|gnv|garrafa|internet|telefon\w*|telecomunicac\w*|conectividad movil|senal movil|hospital\w*|sanitari\w*'
           -- 58: salud, basura y dinero en efectivo
           || '|medicament\w*|farmacia\w*|dengue|chikungunya|zika|fiebre amarilla|sarampion|influenza|covid|brote\w*|epidemi\w*|vacuna\w*|terapia intensiva|basura|botadero|cajero\w*|falta de dolares|escasez de dolares|falta de efectivo'
           || ')\M') AS servicios,
      x ~ ('\m(aeropuerto|aeropuertos|vuelo|vuelos|aerolinea\w*|hotel\w*|alojamiento\w*|hosped\w*|reserva\w*|ocupacion|visitantes|turistas|demanda|feria|festival|fiesta|carnaval|entrada folklorica'
           -- 58: viajes, aerolíneas, eventos y actividades
           || '|pasaje\w*|ruta aerea|rutas aereas|frecuencias|charter|boa|ecojet|amaszonas|latam|avianca|viajeros|turismo|turistico\w*|turistica\w*|museo\w*|parque nacional|parques nacionales|area protegida|areas protegidas|atractivo\w*|tour|tours|excursion\w*|trekking|senderismo|teleferico|mirador\w*|concierto\w*|expocruz|feicobol|gran poder|urkupina|alasitas|todos santos|peregrinacion|festividad\w*|rally|dakar|maraton'
           || ')\M') AS atencion
    FROM t)
  SELECT CASE
    WHEN c = 'salud' THEN 'servicios'
    WHEN c IN ('vial', 'seguridad') THEN 'movilidad'
    WHEN c = 'clima' THEN CASE WHEN servicios THEN 'servicios' ELSE 'movilidad' END
    WHEN conflicto THEN 'movilidad'
    WHEN c IN ('eventos', 'conectividad', 'turismo', 'mercado', 'mercados') THEN 'atencion'
    WHEN servicios THEN 'servicios'
    WHEN atencion THEN 'atencion'
  END FROM r
$$;

-- 1, 2 y 3. Datos del cliente orbita-bolivia -----------------------------------------------------------
DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'); n int;
BEGIN
  IF c IS NULL THEN RAISE NOTICE 'No hay cliente orbita-bolivia: solo se crean las funciones'; RETURN; END IF;

  n := vigilante._sumar_palabras(c, 'palabras_alerta', ARRAY[
    -- agua
    'corte programado', 'cortes programados', 'sin suministro', 'suspensión del servicio', 'interrupción del servicio',
    'restricción del servicio', 'baja presión', 'agua turbia', 'agua contaminada', 'cisterna', 'represas', 'reservorios',
    'EPSAS', 'SEMAPA', 'SAGUAPAC', 'ELAPAS', 'COSAALT', 'AAPOS', 'SeLA',
    -- luz
    'racionamiento eléctrico', 'mantenimiento de redes', 'falla eléctrica', 'sin energía', 'corte de electricidad',
    'cortes de electricidad', 'DELAPAZ', 'CRE', 'ELFEC', 'SEPSA', 'SETAR',
    -- gas y telecom
    'gas domiciliario', 'sin gas', 'falta de gas', 'caída de la red',
    -- salud
    'dengue', 'chikungunya', 'zika', 'fiebre amarilla', 'sarampión', 'influenza', 'covid', 'tos ferina', 'malaria',
    'leishmaniasis', 'rabia canina', 'alerta epidemiológica', 'alerta sanitaria', 'casos sospechosos', 'contagios',
    'terapia intensiva', 'colapso de hospitales', 'hospital colapsado', 'sin camas', 'falta de camas', 'escasez de medicamentos',
    'desabastecimiento de medicamentos', 'farmacias', 'paro médico', 'paro de salud', 'huelga médica', 'Colegio Médico',
    'SEDES', 'intoxicación', 'intoxicación alimentaria', 'ambulancias', 'emergencia de salud',
    -- otros servicios que usa el viajero
    'recojo de basura', 'basura acumulada', 'botadero', 'cajeros', 'cajeros automáticos', 'falta de dólares',
    'escasez de dólares', 'falta de efectivo', 'alza de pasajes', 'subida de pasajes', 'incremento de pasajes',
    'combustible de aviación', 'jet fuel', 'turbocombustible',
    -- aerolíneas: riesgo
    'vuelos cancelados', 'cancelación de vuelos', 'vuelos suspendidos', 'suspensión de vuelos', 'vuelos retrasados',
    'retraso de vuelos', 'demoras en vuelos', 'pasajeros varados', 'huelga de pilotos', 'paro de pilotos',
    'controladores aéreos', 'cierre del aeropuerto', 'aeropuerto cerrado', 'pista cerrada', 'aterrizaje de emergencia',
    'overbooking'],
    'Palabras que suben el puntaje como posible riesgo o alerta temprana (55 y 58: + servicios esenciales, salud y aerolíneas)');
  RAISE NOTICE 'palabras_alerta: % nuevas', n;

  n := vigilante._sumar_palabras(c, 'palabras_oportunidad', ARRAY[
    -- aerolíneas y viajes
    'BoA', 'Boliviana de Aviación', 'EcoJet', 'Amaszonas',
    'Transporte Aéreo Militar', 'NAABOL',
    'terminal de buses', 'terminal de ómnibus', 'terminal bimodal',
    -- eventos
    'Gran Poder', 'Urkupiña', 'Alasitas', 'Carnaval de Oruro', 'Entrada Universitaria', 'entrada folklórica',
    'Todos Santos', 'Año Nuevo Andino', 'Año Nuevo Aymara', 'Willkakuti', 'Pujllay', 'Ch''utillos', 'Virgen de Guadalupe',
    'Virgen de Copacabana', 'Virgen de Cotoca', 'Festival de Música Barroca',
    'Festival de Música Renacentista y Barroca', 'Expocruz', 'Fexpocruz', 'Feicobol', 'fiestas patronales', 'peregrinación', 'aniversario departamental',
    'Dakar', 'Juegos Bolivarianos', 'Juegos Suramericanos',
    -- alojamiento y actividades
    'ecoalbergue', 'turismo comunitario', 'ruta del singani', 'Mi Teleférico', 'misiones jesuíticas', 'Viceministerio de Turismo', 'Cámara Hotelera'],
    'Palabras que suben el puntaje como posible oportunidad (55 y 58: + aerolíneas, eventos, alojamiento y actividades)');
  RAISE NOTICE 'palabras_oportunidad: % nuevas', n;

  n := vigilante._sumar_regla_oportunidad(c, 'evento', ARRAY[
    'festividad', 'entrada folklorica', 'gran poder', 'urkupina', 'alasitas', 'carnaval de oruro', 'todos santos',
    'ano nuevo andino', 'festival de musica barroca', 'expocruz', 'feicobol', 'peregrinacion', 'dakar',
    'juegos bolivarianos']);
  -- «conectividad» no se amplía: frases como «nuevos vuelos» o «vuelos directos» dejaban pasar noticias de
  -- aviación de otros países (vista previa del 2026-11-26). Las noticias de Bolivia pasan por el lugar.
  RAISE NOTICE 'reglas_oportunidad (evento): % frases nuevas', n;
END $$;

COMMIT;

-- 5. Vista previa (no cambia nada): cuántas descartadas de los últimos 7 días pasarían ahora ---------------
SELECT vigilante.repuntuar_descartadas(slug, 7, false) AS vista_previa
  FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
