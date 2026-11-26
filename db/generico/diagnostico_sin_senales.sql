-- Diagnóstico: ¿por qué el panel no muestra señales, ni estados ni cambios? (2026-11-26)
-- Solo lee, no cambia nada. Pegar entero en el SQL Editor de Supabase y mandar la tabla que sale.
WITH c AS (SELECT id FROM vigilante.clientes WHERE slug = 'orbita-bolivia'),
json_ok AS (
  SELECT CASE WHEN x IS NULL THEN 'FALLA' ELSE 'OK' END AS r FROM (
    SELECT (SELECT vigilante._vigilante_json(c.id) FROM c)::text AS x) q
)
SELECT * FROM (VALUES
 ('1 noticias recogidas 24 h',
  (SELECT count(*)::text || ' · última ' || coalesce(to_char(max(recolectado_en) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'nunca')
     FROM vigilante.raw_items, c WHERE cliente_id = c.id AND recolectado_en > now() - interval '24 hours')),
 ('2 noticias sin clasificar (nuevo/en_cola)',
  (SELECT count(*) FILTER (WHERE estado='nuevo')::text || ' nuevo · ' || count(*) FILTER (WHERE estado='en_cola') || ' en cola · más antigua ' ||
          coalesce(to_char(min(recolectado_en) FILTER (WHERE estado IN ('nuevo','en_cola')) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'-')
     FROM vigilante.raw_items, c WHERE cliente_id = c.id)),
 ('3 clasificaciones del modelo 24 h',
  (SELECT count(*)::text || ' · relevantes ' || count(*) FILTER (WHERE relevante) || ' · última ' ||
          coalesce(to_char(max(created_at) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'nunca')
     FROM vigilante.analisis, c WHERE cliente_id = c.id AND tipo = 'clasificacion' AND created_at > now() - interval '24 hours')),
 ('4 señales nuevas 24 h / 7 días',
  (SELECT count(*) FILTER (WHERE created_at > now() - interval '24 hours')::text || ' / ' || count(*) FILTER (WHERE created_at > now() - interval '7 days')
     || ' · última ' || coalesce(to_char(max(created_at) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'nunca')
     FROM vigilante.signals, c WHERE cliente_id = c.id)),
 ('5 señales por estado',
  (SELECT string_agg(estado::text || ' ' || n, ' · ' ORDER BY estado) FROM
     (SELECT estado, count(*) n FROM vigilante.signals, c WHERE cliente_id = c.id AND duplicado_de IS NULL GROUP BY estado) e)),
 ('6 señales visibles en el panel',
  (SELECT count(*)::text FROM c, vigilante.senales_visibles(c.id))),
 ('7 cambios 7 días',
  (SELECT count(*)::text || ' · último ' || coalesce(to_char(max(created_at) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'nunca')
     FROM vigilante.cambios_senal, c WHERE cliente_id = c.id AND created_at > now() - interval '7 days')),
 ('8 eventos compuestos 7 días',
  (SELECT count(*)::text || ' · último ' || coalesce(to_char(max(created_at) AT TIME ZONE 'America/La_Paz','DD/MM HH24:MI'),'nunca')
     FROM vigilante.eventos_compuestos, c WHERE cliente_id = c.id AND created_at > now() - interval '7 days')),
 ('9 errores del clasificador 48 h',
  (SELECT count(*)::text || ' · último: ' || coalesce((array_agg(left(mensaje,160) ORDER BY created_at DESC))[1],'-')
     FROM vigilante.system_logs, c WHERE cliente_id = c.id AND nivel = 'error' AND created_at > now() - interval '48 hours')),
 ('10 vigilante_bd (lo que lee el panel)', (SELECT r FROM json_ok))
) t(paso, resultado);
