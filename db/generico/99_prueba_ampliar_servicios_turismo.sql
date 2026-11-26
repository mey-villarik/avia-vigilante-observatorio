-- Prueba del 58 (más servicios esenciales y más turismo). Termina en ROLLBACK.
BEGIN;
DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');
        f int := (SELECT id FROM vigilante.sources WHERE cliente_id = c AND tipo = 'medio' ORDER BY id LIMIT 1);
        p int; t text[]; r jsonb; frase text;
BEGIN
  -- pasan el filtro previo (sin nombrar un lugar, para medir solo las palabras nuevas)
  FOREACH frase IN ARRAY ARRAY[
    'EPSAS anuncia corte programado en varias zonas',
    'La CRE informa mantenimiento de redes el domingo',
    'Suben los casos de dengue y piden fumigar',
    'Paro médico de 48 horas en los hospitales de tercer nivel',
    'Recojo de basura suspendido por tercer día',
    'Cajeros sin efectivo y falta de dólares para viajeros',
    'Cancelación de vuelos por mal tiempo deja pasajeros varados',
    'BoA abre vuelos directos a Buenos Aires',
    'Arranca la Fiesta del Gran Poder con 70 fraternidades',
    'Expocruz espera más de 500 mil personas',
    'El rally reúne pilotos de cinco países',
    'Crece el turismo comunitario y el trekking en los Yungas',
    'Nuevo teleférico y mirador para turistas extranjeros'] LOOP
    SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, frase);
    IF p < 30 THEN RAISE EXCEPTION '«%» debe pasar (puntaje %)', frase, p; END IF;
  END LOOP;

  -- siguen sin pasar
  FOREACH frase IN ARRAY ARRAY[
    'Gol de último minuto en la liga española',
    'Por ende, el directorio aprobó el balance anual',
    'El abogado Juan Montero presenta su libro'] LOOP
    SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, frase);
    IF p >= 30 THEN RAISE EXCEPTION '«%» no debe pasar (puntaje %)', frase, p; END IF;
  END LOOP;

  -- oportunidad candidata
  SELECT tipos INTO t FROM vigilante.puntaje_previo(c, f, NULL, 'Llega Urkupiña y las agencias preparan paquetes');
  IF NOT 'evento' = ANY(t) THEN RAISE EXCEPTION 'Urkupiña debe marcar evento: %', t; END IF;
  SELECT tipos INTO t FROM vigilante.puntaje_previo(c, f, NULL, 'Amaszonas retoma vuelos a Rurrenabaque');
  IF NOT 'conectividad' = ANY(t) THEN RAISE EXCEPTION 'retoma vuelos debe marcar conectividad: %', t; END IF;
  -- las del 15 siguen
  SELECT tipos INTO t FROM vigilante.puntaje_previo(c, f, NULL, 'Abren la convocatoria de fondos');
  IF NOT 'convocatoria' = ANY(t) THEN RAISE EXCEPTION 'reglas del 15 perdidas: %', t; END IF;

  -- ejes de Dirección
  IF vigilante.eje_de('economia', 'Escasez de dólares en cajeros de Santa Cruz') IS DISTINCT FROM 'servicios' THEN RAISE EXCEPTION 'cajeros → servicios'; END IF;
  IF vigilante.eje_de('normativa', 'Campaña de vacunación contra la fiebre amarilla') IS DISTINCT FROM 'servicios' THEN RAISE EXCEPTION 'vacunación → servicios'; END IF;
  IF vigilante.eje_de('economia', 'Suben los pasajes en la terminal de La Paz') IS DISTINCT FROM 'atencion' THEN RAISE EXCEPTION 'pasajes → atención'; END IF;
  IF vigilante.eje_de('normativa', 'Nuevo horario del museo y del teleférico') IS DISTINCT FROM 'atencion' THEN RAISE EXCEPTION 'museo → atención'; END IF;
  IF vigilante.eje_de('economia', 'Bloqueo de transportistas por los pasajes') IS DISTINCT FROM 'movilidad' THEN RAISE EXCEPTION 'conflicto sigue → movilidad'; END IF;
  IF vigilante.eje_de('economia', 'La inflación de octubre') IS NOT NULL THEN RAISE EXCEPTION 'inflación sin eje'; END IF;
  IF vigilante.eje_de('normativa', 'El congreso del partido elige directiva') IS NOT NULL THEN RAISE EXCEPTION 'congreso político sin eje'; END IF;

  -- la vista previa no cambia nada
  INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, contenido, estado, motivo_descarte, recolectado_en, titulo_norm, puntaje_previo)
  VALUES (c, f, 'https://x.bo/57', 'p57-1', 'Brote de dengue en el norte', NULL, 'descartado', 'puntaje previo 10 < 30', now() - interval '1 day', 'x', 10);
  r := vigilante.repuntuar_descartadas('orbita-bolivia', 7, false);
  IF (r ->> 'ahora_pasan')::int < 1 THEN RAISE EXCEPTION 'vista previa sin recuperadas: %', r; END IF;
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p57-1') <> 'descartado' THEN RAISE EXCEPTION 'la vista previa no debe cambiar nada'; END IF;
  RAISE NOTICE 'OK 58: %', r - 'ejemplos';
END $$;
ROLLBACK;
