-- =============================================================================
-- 59 · Ajuste del 58: quitar las palabras que dejaban pasar ruido
-- =============================================================================
-- Vista previa del 58 en Supabase (Meysel, 2026-11-26 17:05 UTC): 139 de 3.079 descartadas pasarían, pero
--   los 15 ejemplos eran noticias de aviación de fuera (LATAM en Brasil, KLM, Xiamen Airlines, Chicago…),
--   todas con «alerta: sin conexion» (texto fijo de la página de una fuente) y una palabra genérica de
--   aerolínea («aerolínea», «aeropuertos», «frecuencias», «viajeros», «LATAM», «JetSMART»…).
-- Por qué: una noticia de Bolivia ya pasa el filtro si nombra un departamento, una ciudad o un destino
--   (+25). Las palabras genéricas solo sumaban para noticias SIN lugar de Bolivia, es decir, sobre todo
--   noticias de otros países.
--
-- Qué hace (cliente orbita-bolivia):
--   · palabras_alerta: quita «sin conexión» y «varados» (queda «pasajeros varados»).
--   · palabras_oportunidad: quita aerolíneas extranjeras y palabras genéricas de aviación y de turismo
--     que valen para cualquier país. Se quedan las de Bolivia: BoA, Boliviana de Aviación, EcoJet,
--     Amaszonas, TAM, NAABOL, las fiestas y ferias bolivianas, Mi Teleférico, misiones jesuíticas,
--     ruta del singani, Viceministerio de Turismo…
--   · reglas_oportunidad «conectividad»: quita las frases que añadió el 58 (las del 15 se quedan).
--   · Vuelve a enseñar la vista previa y, aparte, cuántas pasarían por cada palabra. No cambia ninguna noticia.
-- El prompt 1.13 no cambia: la IA sigue sabiendo tratar aerolíneas, eventos y servicios.
-- Se puede ejecutar varias veces. Necesita el 58.
-- =============================================================================
BEGIN;

CREATE OR REPLACE FUNCTION vigilante._quitar_palabras(p_cliente uuid, p_clave text, p_quitar text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_actual jsonb := vigilante.param(p_cliente, p_clave); v_lista jsonb; n int;
BEGIN
  IF v_actual IS NULL OR jsonb_typeof(v_actual) <> 'array' THEN RETURN 0; END IF;
  SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') INTO v_lista
    FROM jsonb_array_elements_text(v_actual) WITH ORDINALITY AS e(x, o)
   WHERE vigilante.texto_norm(x) NOT IN (SELECT vigilante.texto_norm(q) FROM unnest(p_quitar) q);
  n := jsonb_array_length(v_actual) - jsonb_array_length(v_lista);
  IF n > 0 THEN
    UPDATE vigilante.parametros SET valor = v_lista, updated_at = now() WHERE cliente_id = p_cliente AND clave = p_clave;
  END IF;
  RETURN n;
END $$;

DO $$
DECLARE c uuid := (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'); n int; v_reglas jsonb;
BEGIN
  IF c IS NULL THEN RETURN; END IF;

  n := vigilante._quitar_palabras(c, 'palabras_alerta', ARRAY['sin conexión', 'varados']);
  RAISE NOTICE 'palabras_alerta: % quitadas', n;

  n := vigilante._quitar_palabras(c, 'palabras_oportunidad', ARRAY[
    -- aviación genérica y aerolíneas de fuera
    'aerolínea', 'aerolíneas', 'aeropuerto', 'aeropuertos', 'LATAM', 'Avianca', 'Aerolíneas Argentinas', 'Copa Airlines',
    'Air Europa', 'JetSMART', 'Sky Airline', 'Paranair', 'American Airlines', 'Gol Linhas Aéreas', 'Azul Linhas Aéreas',
    'pasajes aéreos', 'boletos aéreos', 'tarifas aéreas', 'precio de pasajes', 'frecuencias', 'vuelo directo',
    'vuelos directos', 'ruta aérea', 'rutas aéreas', 'conexión aérea', 'chárter', 'vuelos chárter', 'nuevos vuelos',
    'viajeros', 'pasajeros', 'turistas extranjeros', 'llegada de turistas', 'turismo receptivo', 'turismo interno',
    'paquete turístico', 'paquetes turísticos', 'agencia de viajes', 'visa', 'visas', 'requisitos de ingreso',
    -- eventos y actividades que valen para cualquier país
    'concierto', 'conciertos', 'bienal', 'convención', 'festividad', 'festividades', 'romería',
    'rally', 'maratón', 'triatlón', 'ultramaratón', 'campeonato sudamericano', 'campeonato mundial',
    'evento internacional', 'evento deportivo', 'Vendimia', 'Exaltación', 'San Roque',
    'resort', 'albergue', 'albergues', 'lodge', 'cabañas', 'camping', 'Airbnb', 'hostales', 'tour', 'tours',
    'excursión', 'excursiones', 'trekking', 'senderismo', 'montañismo', 'andinismo', 'escalada',
    'turismo de aventura', 'ecoturismo', 'agroturismo', 'enoturismo', 'turismo rural', 'turismo religioso',
    'turismo gastronómico', 'gastronomía', 'ruta del vino', 'bodegas', 'teleférico', 'mirador', 'miradores',
    'sitio arqueológico', 'sitios arqueológicos', 'patrimonio de la humanidad', 'UNESCO', 'reserva natural',
    'reserva de la biosfera', 'guardaparques', 'parques nacionales', 'atractivos', 'Feria Internacional de Turismo']);
  RAISE NOTICE 'palabras_oportunidad: % quitadas', n;

  v_reglas := vigilante.param(c, 'reglas_oportunidad');
  IF jsonb_typeof(v_reglas -> 'conectividad') = 'array' THEN
    UPDATE vigilante.parametros SET updated_at = now(), valor = v_reglas || jsonb_build_object('conectividad',
      (SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') FROM jsonb_array_elements_text(v_reglas -> 'conectividad') WITH ORDINALITY e(x, o)
        WHERE x NOT IN ('nuevos vuelos', 'vuelos directos', 'rutas aereas', 'conexion aerea', 'vuelos charter', 'nueva aerolinea',
                        'nueva frecuencia', 'mas frecuencias', 'reanuda vuelos', 'retoma vuelos', 'nueva terminal')))
     WHERE cliente_id = c AND clave = 'reglas_oportunidad';
  END IF;
  v_reglas := vigilante.param(c, 'reglas_oportunidad');
  IF jsonb_typeof(v_reglas -> 'evento') = 'array' THEN
    UPDATE vigilante.parametros SET updated_at = now(), valor = v_reglas || jsonb_build_object('evento',
      (SELECT coalesce(jsonb_agg(x ORDER BY o), '[]') FROM jsonb_array_elements_text(v_reglas -> 'evento') WITH ORDINALITY e(x, o)
        WHERE x NOT IN ('concierto', 'rally', 'maraton', 'campeonato sudamericano', 'evento internacional', 'feria internacional de turismo')))
     WHERE cliente_id = c AND clave = 'reglas_oportunidad';
  END IF;
END $$;

COMMIT;

-- Vista previa (no cambia nada) ---------------------------------------------------------------------------
SELECT vigilante.repuntuar_descartadas(slug, 7, false) AS vista_previa
  FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

-- Cuántas pasarían por cada motivo (para ver si queda ruido) ----------------------------------------------
WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'),
p AS (
  SELECT r.id, x.puntaje, x.motivos
    FROM vigilante.raw_items r JOIN c ON r.cliente_id = c.id,
         LATERAL vigilante.puntaje_previo(r.cliente_id, r.source_id, r.busqueda_id, coalesce(r.titulo, '') || ' ' || coalesce(r.contenido, '')) x
   WHERE r.estado = 'descartado' AND r.motivo_descarte LIKE 'puntaje previo%' AND r.recolectado_en > now() - interval '7 days')
SELECT m AS motivo, count(*) AS noticias
  FROM p, unnest(p.motivos) m
 WHERE p.puntaje >= coalesce((vigilante.param((SELECT id FROM c), 'umbral_previo') #>> '{}')::int, 30)
 GROUP BY m ORDER BY count(*) DESC LIMIT 30;
