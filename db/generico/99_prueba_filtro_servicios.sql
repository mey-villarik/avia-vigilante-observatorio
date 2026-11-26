-- Prueba del 55 (filtro previo para servicios esenciales y atención turística). Termina en ROLLBACK.
BEGIN;
DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia');
        f int := (SELECT id FROM vigilante.sources WHERE cliente_id = c AND tipo = 'medio' ORDER BY id LIMIT 1);
        r jsonb; p int;
BEGIN
  -- puntajes con las listas nuevas
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'Vecinos sin agua por tercer día consecutivo');
  IF p < 30 THEN RAISE EXCEPTION 'corte de agua debe pasar (puntaje %)', p; END IF;
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'Largas filas en surtidores por falta de diésel');
  IF p < 30 THEN RAISE EXCEPTION 'falta de diésel debe pasar (puntaje %)', p; END IF;
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'La ocupación hotelera sube en el feriado');
  IF p < 30 THEN RAISE EXCEPTION 'ocupación hotelera debe pasar (puntaje %)', p; END IF;
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'Concierto gratuito en El Alto este sábado');
  IF p < 30 THEN RAISE EXCEPTION 'El Alto debe contar como lugar (puntaje %)', p; END IF;
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'Gol de último minuto en la liga española');
  IF p >= 30 THEN RAISE EXCEPTION 'el ruido no debe pasar (puntaje %)', p; END IF;
  SELECT puntaje INTO p FROM vigilante.puntaje_previo(c, f, NULL, 'El abogado Juan Montero presenta su libro');
  IF p >= 30 THEN RAISE EXCEPTION 'Montero (apellido) no debe contar como lugar (puntaje %)', p; END IF;

  -- recuperar: una descartada por puntaje que ahora pasa, una de ruido y una vieja que no se tocan
  INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, contenido, estado, motivo_descarte, recolectado_en, titulo_norm, puntaje_previo)
  VALUES (c, f, 'https://x.bo/1', 'p55-1', 'Apagones en Riberalta afectan a comercios', NULL, 'descartado', 'puntaje previo 10 < 30', now() - interval '1 day', 'apagones en riberalta', 10),
         (c, f, 'https://x.bo/2', 'p55-2', 'Apagones en Riberalta (portada)', NULL, 'descartado', 'ruido: portada del sitio', now() - interval '1 day', 'x', 10),
         (c, f, 'https://x.bo/3', 'p55-3', 'Cortes de agua en Sucre', NULL, 'descartado', 'puntaje previo 10 < 30', now() - interval '20 days', 'x', 10),
         (c, f, 'https://x.bo/4', 'p55-4', 'Resultados de la liga de fútbol de Brasil', NULL, 'descartado', 'puntaje previo 10 < 30', now() - interval '1 day', 'x', 10);
  r := vigilante.repuntuar_descartadas('orbita-bolivia', 7, false);
  IF (r ->> 'ahora_pasan')::int < 1 THEN RAISE EXCEPTION 'vista previa sin recuperadas: %', r; END IF;
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p55-1') <> 'descartado' THEN RAISE EXCEPTION 'la vista previa no debe cambiar nada'; END IF;
  r := vigilante.repuntuar_descartadas('orbita-bolivia', 7, true);
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p55-1') <> 'nuevo' THEN RAISE EXCEPTION 'la de apagones debe volver a nuevo'; END IF;
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p55-2') <> 'descartado' THEN RAISE EXCEPTION 'el ruido no se recupera'; END IF;
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p55-3') <> 'descartado' THEN RAISE EXCEPTION 'la de 20 días no se recupera'; END IF;
  IF (SELECT estado FROM vigilante.raw_items WHERE content_hash = 'p55-4') <> 'descartado' THEN RAISE EXCEPTION 'el fútbol no se recupera'; END IF;
  RAISE NOTICE 'OK 55: %', r - 'ejemplos';
END $$;
ROLLBACK;
