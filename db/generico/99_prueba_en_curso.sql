-- Prueba del 44 (en curso ≠ cierra en N días). Se puede pegar en el editor SQL de Supabase.
-- Debe salir: festival t, bicentenario t, hoy t, futuro f, pasado f, convocatoria f.
SELECT 'festival (empezó hace 2 días, termina mañana)' AS caso, vigilante.en_curso(current_date - 2, current_date + 1, current_date + 1) AS en_curso
UNION ALL SELECT 'bicentenario (solo inicio y plazo)', vigilante.en_curso(now() - interval '100 days', NULL, now() + interval '30 days')
UNION ALL SELECT 'ocurre hoy (sin fin)', vigilante.en_curso((now() AT TIME ZONE 'America/La_Paz')::date, NULL, NULL)
UNION ALL SELECT 'futuro (empieza en 3 días)', vigilante.en_curso(current_date + 3, current_date + 5, NULL)
UNION ALL SELECT 'pasado', vigilante.en_curso(current_date - 10, current_date - 8, NULL)
UNION ALL SELECT 'convocatoria sin evento', vigilante.en_curso(NULL, NULL, current_date + 5);

-- Diagnóstico con datos reales: oportunidades que hoy están en curso (deberían incluir el Festival
-- de la Canción Boliviana y el Bicentenario) y cómo quedan los contadores.
SELECT s.codigo, s.titulo, s.fecha_evento_inicio::date AS inicio, s.fecha_evento_fin::date AS fin, s.plazo_hasta::date AS plazo,
       vigilante.dias_para(s.plazo_hasta) AS dias_plazo
  FROM vigilante.signals s
 WHERE s.naturaleza <> 'riesgo' AND s.estado NOT IN ('cerrada', 'descartada')
   AND vigilante.en_curso(s.fecha_evento_inicio, s.fecha_evento_fin, s.plazo_hasta)
 ORDER BY s.fecha_evento_inicio;

SELECT c.id AS cliente, vigilante.contadores(c.id) -> 'plazo_corto' AS plazo_corto, vigilante.contadores(c.id) -> 'en_curso' AS en_curso
  FROM vigilante.clientes c;
