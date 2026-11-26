-- Diagnóstico: ¿qué ha pasado con las noticias que recuperó el SQL 55? (2026-11-26)
-- Solo lee, no cambia nada. Pegar entero en el SQL Editor de Supabase y mandar la tabla que sale.
--   1-3  ¿el analizador las ha clasificado ya o siguen en la cola?
--   4-5  ¿las que clasificó, en qué acabaron (señal o «no relevante» y por qué)?
--   6-7  ¿hay señales nuevas de servicios o atención desde el 55 y cuántas ve hoy el panel?
--   8    ¿qué dice la vista Dirección de cada eje ahora mismo?
WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'),
rec AS (   -- las recuperadas por el 55
  SELECT r.*, (r.payload ->> 'recuperada_55')::timestamptz AS cuando
    FROM vigilante.raw_items r, c
   WHERE r.cliente_id = c.id AND r.payload ? 'recuperada_55'),
t0 AS (SELECT coalesce(min(cuando), now() - interval '2 hours') AS t FROM rec),
cola AS (  -- lo que espera al analizador (mismo criterio que lote_para_clasificar)
  SELECT r.id, r.puntaje_previo, r.payload ? 'recuperada_55' AS es_rec
    FROM vigilante.raw_items r, c
   WHERE r.cliente_id = c.id AND r.estado IN ('nuevo', 'en_cola')
     AND NOT EXISTS (SELECT 1 FROM vigilante.analisis a WHERE a.raw_item_id = r.id AND a.version = r.version AND a.tipo = 'clasificacion')),
cla AS (   -- clasificación de cada recuperada (si ya la tiene)
  SELECT rec.id, a.relevante, a.signal_id, a.created_at, coalesce(a.salida ->> 'motivo', '') AS motivo
    FROM rec JOIN vigilante.analisis a ON a.raw_item_id = rec.id AND a.tipo = 'clasificacion' AND a.created_at >= rec.cuando),
nuevas AS (
  SELECT s.id, s.estado, vigilante.eje_de(s.categoria, s.titulo || ' ' || coalesce(s.resumen, '')) AS eje,
         vigilante.senal_vigente(s.id, s.created_at, s.plazo_hasta, s.fecha_evento_inicio, s.fecha_evento_fin) AS vigente
    FROM vigilante.signals s, c, t0
   WHERE s.cliente_id = c.id AND s.created_at >= t0.t),
panel AS (
  SELECT vigilante.eje_de(s.categoria, s.titulo || ' ' || coalesce(s.resumen, '')) AS eje, s.estado
    FROM c, vigilante.senales_visibles(c.id) s WHERE s.estado <> 'descartada')
SELECT * FROM (VALUES
 ('1 recuperadas por el 55 (por estado)',
  (SELECT coalesce(string_agg(estado::text || ' ' || k, ' · ' ORDER BY k DESC), 'NINGUNA: el 55 no se aplicó') FROM (SELECT estado, count(*) k FROM rec GROUP BY estado) x)
  || coalesce(' · desde ' || (SELECT to_char(min(cuando) AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI') || ' (Bolivia)' FROM rec), '')),
 ('2 cola del analizador',
  (SELECT count(*) || ' en cola, de ellas ' || count(*) FILTER (WHERE es_rec) || ' recuperadas · puntaje recuperadas '
          || coalesce(min(puntaje_previo) FILTER (WHERE es_rec) || '-' || max(puntaje_previo) FILTER (WHERE es_rec), '—')
          || ' · por delante de la primera recuperada: '
          || count(*) FILTER (WHERE NOT es_rec AND puntaje_previo > coalesce((SELECT max(puntaje_previo) FROM cola WHERE es_rec), 0))
     FROM cola)),
 ('3 ritmo del analizador',
  (SELECT count(*) FILTER (WHERE a.created_at > now() - interval '1 hour') || ' clasificadas en la última hora · '
          || count(*) FILTER (WHERE a.created_at > now() - interval '6 hours') || ' en 6 h · última '
          || coalesce(to_char(max(a.created_at) AT TIME ZONE 'America/La_Paz', 'DD/MM HH24:MI'), 'nunca')
     FROM vigilante.analisis a, c WHERE a.cliente_id = c.id AND a.tipo = 'clasificacion' AND a.created_at > now() - interval '6 hours')),
 ('4 recuperadas ya clasificadas',
  (SELECT count(*) || ' clasificadas: ' || count(*) FILTER (WHERE relevante) || ' relevantes (' || count(DISTINCT signal_id) || ' señales), '
          || count(*) FILTER (WHERE NOT relevante) || ' no relevantes' FROM cla)),
 ('5 por qué la IA las rechaza',
  (SELECT coalesce(string_agg(left(motivo, 60) || ' ×' || k, ' | '), '—')
     FROM (SELECT motivo, count(*) k FROM cla WHERE NOT relevante GROUP BY motivo ORDER BY count(*) DESC LIMIT 8) x)),
 ('6 señales nuevas desde el 55 (eje · vigentes)',
  (SELECT coalesce(string_agg(coalesce(eje, 'sin eje') || ' ' || k || ' (' || v || ' vigentes)', ' · ' ORDER BY k DESC), 'ninguna')
     FROM (SELECT eje, count(*) k, count(*) FILTER (WHERE vigente) v FROM nuevas GROUP BY eje) x)),
 ('7 lo que ve hoy el panel por eje (estado)',
  (SELECT coalesce(string_agg(coalesce(eje, 'sin eje') || ': ' || l, ' · '), 'nada')
     FROM (SELECT eje, string_agg(estado::text || ' ' || k, ', ' ORDER BY k DESC) l
             FROM (SELECT eje, estado, count(*) k FROM panel GROUP BY eje, estado) y GROUP BY eje) x)),
 ('8 vista Dirección ahora',
  (SELECT string_agg(e ->> 'eje' || ' = ' || (e ->> 'estado') || ' (' || CASE WHEN jsonb_typeof(e -> 'senales') = 'array' THEN jsonb_array_length(e -> 'senales') ELSE 0 END || ' con peso)', ' · ')
     FROM c, jsonb_array_elements(vigilante.direccion(c.id) -> 'ejes') e))
) v(paso, resultado);
