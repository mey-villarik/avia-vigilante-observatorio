-- Prueba de 49_vista_direccion.sql: ejes, Normal/Atención/Acción, ficha de acción, semáforo por
-- departamento y «Lo que viene» por fecha de ocurrencia.
-- Requiere 01 a 49 (y 02 con el cliente orbita-bolivia). Termina en ROLLBACK: no deja nada.
BEGIN;
\set ON_ERROR_STOP 1
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';
INSERT INTO vigilante.sources (cliente_id, codigo, nombre, tipo, url, categorias, metodo)
SELECT c, 'd-ofi', 'Fuente oficial de prueba', 'oficial'::vigilante.tipo_fuente, 'https://prueba.gob.bo', '{clima}', 'rss' FROM ids;

-- D-1 derrumbe confirmado en La Paz (vial)                      → movilidad, Acción, La Paz rojo
-- D-2 corte de agua anunciado en Sucre, empieza mañana          → servicios (por el texto), Atención; lo que viene mañana
-- D-3 marcha convocada en Cochabamba dentro de 2 días (sin fuente)→ movilidad, posible: no pasa de Atención
-- D-4 feria en Tarija, convocatoria que cierra en 5 días        → atención turística, decisión por plazo
-- D-5 fondo de financiación sin efecto directo                  → sin eje
-- D-6 lluvia fuerte en todo el país, aviso naranja              → movilidad, nacional: no tiñe departamentos
INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, estado, prioridad,
                               plazo_hasta, fecha_evento_inicio, fecha_evento_fin, created_at)
SELECT c, x.cod, x.tit, x.res, x.nat::vigilante.naturaleza_senal, x.cat, x.est::vigilante.estado_senal, x.pri::vigilante.prioridad,
       CASE WHEN x.cierre IS NULL THEN NULL ELSE ((vigilante.hoy_bo() + x.cierre)::text || 'T23:59:59-04:00')::timestamptz END,
       CASE WHEN x.ini IS NULL THEN NULL ELSE (vigilante.hoy_bo() + x.ini)::timestamptz END,
       CASE WHEN x.fin IS NULL THEN NULL ELSE (vigilante.hoy_bo() + x.fin)::timestamptz END,
       now() - interval '2 hours'
  FROM ids, (VALUES
  ('D-1', 'Derrumbe cierra la carretera a los Yungas', 'Derrumbe en el kilómetro 40.', 'riesgo', 'vial', 'confirmada', 'alta', NULL::int, NULL::int, NULL::int),
  ('D-2', 'Cortes de agua potable en el centro de Sucre', 'La empresa anuncia cortes por obras.', 'riesgo', 'economia', 'confirmada', 'media', NULL, 1, 3),
  ('D-3', 'Transportistas convocan marcha con bloqueo', 'Anuncian marcha.', 'riesgo', 'seguridad', 'detectada', 'alta', NULL, 2, 2),
  ('D-4', 'Feria de turismo en Tarija abre inscripción', 'Rueda de negocios.', 'oportunidad', 'eventos', 'confirmada', 'media', 5, 12, 13),
  ('D-5', 'Fondo para emprendimientos', 'Convocatoria general.', 'oportunidad', 'financiamiento', 'confirmada', 'media', 30, NULL, NULL),
  ('D-6', 'Aviso naranja por lluvias en todo el país', 'Lluvias fuertes.', 'riesgo', 'clima', 'confirmada', 'media', NULL, 0, 2)
  ) x(cod, tit, res, nat, cat, est, pri, cierre, ini, fin);

INSERT INTO vigilante.signal_territorios (signal_id, territorio_id, cliente_id)
SELECT s.id, t.id, s.cliente_id FROM vigilante.signals s
  JOIN (VALUES ('D-1', 'BO-L'), ('D-2', 'BO-H'), ('D-3', 'BO-C'), ('D-4', 'BO-T'), ('D-5', 'BO'), ('D-6', 'BO')) x(cod, ter) ON x.cod = s.codigo
  JOIN vigilante.territorios t ON t.cliente_id = s.cliente_id AND t.codigo = x.ter;

-- D-1, D-2 y D-6 tienen una noticia oficial: confirmadas. D-3 no tiene ninguna.
INSERT INTO vigilante.raw_items (cliente_id, source_id, url, content_hash, titulo, publicado_en)
SELECT c, s.id, s.url || '/' || x, 'h-dir-' || x, 'Noticia ' || x, now() - interval '1 hour'
  FROM ids, unnest(ARRAY['D-1', 'D-2', 'D-4', 'D-6']) x JOIN vigilante.sources s ON s.codigo = 'd-ofi';
INSERT INTO vigilante.signal_raw_items (signal_id, raw_item_id, cliente_id)
SELECT g.id, r.id, g.cliente_id FROM vigilante.signals g JOIN vigilante.raw_items r ON r.content_hash = 'h-dir-' || g.codigo;

SELECT codigo, vigilante.eje_de(categoria, titulo || ' ' || resumen) AS eje, vigilante.accion_direccion(id) AS accion,
       vigilante.estado_direccion(id) AS estado, vigilante.certeza(id) ->> 'nivel' AS certeza
  FROM vigilante.signals WHERE codigo LIKE 'D-_' ORDER BY 1;

DO $$
DECLARE v_c uuid := (SELECT c FROM ids); d jsonb; j jsonb; f jsonb; x jsonb; v_hoy date := vigilante.hoy_bo();
  id_ text;
BEGIN
  -- ejes
  IF vigilante.eje_de('vial', 'Derrumbe') <> 'movilidad' THEN RAISE EXCEPTION 'vial debe ser movilidad'; END IF;
  IF vigilante.eje_de('salud', 'Dengue') <> 'servicios' THEN RAISE EXCEPTION 'salud debe ser servicios'; END IF;
  IF vigilante.eje_de('clima', 'Lluvias con tormenta eléctrica en Yungas') <> 'movilidad' THEN RAISE EXCEPTION 'clima en rutas debe ser movilidad'; END IF;
  IF vigilante.eje_de('clima', 'Sequía deja sin agua a Potosí') <> 'servicios' THEN RAISE EXCEPTION 'sequía debe ser servicios'; END IF;
  IF vigilante.eje_de('eventos', 'Marcha de gremiales en el centro') <> 'movilidad' THEN RAISE EXCEPTION 'marcha debe ser movilidad'; END IF;
  IF vigilante.eje_de('conectividad', 'Nueva ruta aérea') <> 'atencion' THEN RAISE EXCEPTION 'conectividad aérea debe ser atención'; END IF;
  IF vigilante.eje_de('economia', 'Escasez de diésel en surtidores') <> 'servicios' THEN RAISE EXCEPTION 'combustible debe ser servicios'; END IF;
  IF vigilante.eje_de('financiamiento', 'Fondo para emprendimientos') IS NOT NULL THEN RAISE EXCEPTION 'financiación sin efecto no tiene eje'; END IF;

  -- estados
  IF vigilante.estado_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-1')) <> 'accion' THEN RAISE EXCEPTION 'D-1 debía ser Acción'; END IF;
  IF vigilante.estado_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-3')) <> 'atencion' THEN
    RAISE EXCEPTION 'D-3 (sin confirmar) no puede pasar de Atención'; END IF;
  IF vigilante.estado_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-4')) <> 'normal' THEN RAISE EXCEPTION 'una oportunidad no pinta el semáforo'; END IF;

  -- ficha
  f := vigilante.ficha_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-1'));
  IF f ->> 'plazo' <> 'Hoy' OR f ->> 'responsable' IS NULL OR f ->> 'verificar' NOT LIKE 'Con %' OR f ->> 'accion' IS NULL THEN
    RAISE EXCEPTION 'ficha D-1 incompleta: %', f; END IF;
  f := vigilante.ficha_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-4'));
  IF f ->> 'plazo' NOT LIKE 'Antes del cierre: cierra el %' OR f ->> 'plazo_fecha' <> to_char(v_hoy + 5, 'YYYY-MM-DD') THEN
    RAISE EXCEPTION 'ficha D-4 plazo mal: %', f; END IF;
  -- responsable configurable
  INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
  VALUES (v_c, 'responsable_movilidad', to_jsonb('Unidad de prueba'::text), 'prueba');
  IF vigilante.ficha_direccion((SELECT id FROM vigilante.signals WHERE codigo = 'D-1')) ->> 'responsable' <> 'Unidad de prueba' THEN
    RAISE EXCEPTION 'el responsable del parámetro no se usa'; END IF;

  -- vista completa
  d := vigilante.direccion(v_c);
  IF d ->> 'bolivia' <> 'accion' THEN RAISE EXCEPTION 'Bolivia debía estar en Acción: %', d ->> 'bolivia'; END IF;
  SELECT e INTO x FROM jsonb_array_elements(d -> 'ejes') e WHERE e ->> 'eje' = 'servicios';
  IF x ->> 'estado' <> 'atencion' THEN RAISE EXCEPTION 'servicios debía estar en Atención: %', x; END IF;
  IF d #>> '{departamentos,La Paz,estado}' <> 'accion' THEN RAISE EXCEPTION 'La Paz debía ir en rojo: %', d -> 'departamentos'; END IF;
  IF d #>> '{departamentos,La Paz,motivo}' NOT LIKE 'Movilidad: Derrumbe%' THEN RAISE EXCEPTION 'motivo de La Paz: %', d #> '{departamentos,La Paz}'; END IF;
  IF d #>> '{departamentos,Tarija,estado}' <> 'normal' THEN RAISE EXCEPTION 'Tarija (solo oportunidad) debía ir en verde'; END IF;
  IF d -> 'departamentos' ? 'nacional' THEN RAISE EXCEPTION 'lo nacional no es un departamento'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(d -> 'nacionales') e WHERE e ->> 'codigo' = 'D-6') THEN RAISE EXCEPTION 'D-6 debía salir en nacionales'; END IF;
  -- decisiones: primero la acción, luego la convocatoria que cierra en 5 días
  IF d #>> '{decisiones,0,codigo}' <> 'D-1' OR d #>> '{decisiones,1,codigo}' <> 'D-4' THEN RAISE EXCEPTION 'orden de decisiones: %', d -> 'decisiones'; END IF;
  IF jsonb_array_length(d -> 'decisiones') > 3 THEN RAISE EXCEPTION 'máximo 3 decisiones'; END IF;
  -- lo que viene: por fecha de ocurrencia
  SELECT string_agg(e ->> 'codigo' || ':' || (e ->> 'dias') || ':' || (e ->> 'tipo'), ' ' ORDER BY o) INTO id_
    FROM jsonb_array_elements(d -> 'lo_que_viene') WITH ORDINALITY q(e, o);
  IF id_ <> 'D-6:0:pronostico D-2:1:evento D-3:2:conflicto D-4:5:plazo' THEN RAISE EXCEPTION 'lo que viene: %', id_; END IF;

  -- vigilante.json lleva la dirección en cada señal y arriba
  j := vigilante.vigilante_json('orbita-bolivia');
  SELECT e INTO x FROM jsonb_array_elements(j -> 'senales') e WHERE e ->> 'id' = 'D-1';
  IF x #>> '{direccion,eje}' <> 'movilidad' OR x #>> '{direccion,ficha,plazo}' <> 'Hoy' THEN RAISE EXCEPTION 'vigilante.json sin direccion: %', x -> 'direccion'; END IF;
  IF j #>> '{responsables,movilidad}' <> 'Unidad de prueba' OR j -> 'direccion' IS NULL THEN RAISE EXCEPTION 'vigilante.json sin responsables/direccion'; END IF;
  RAISE NOTICE 'OK: vista Dirección';
END $$;

ROLLBACK;
