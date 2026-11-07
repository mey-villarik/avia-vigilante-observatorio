-- =============================================================================
-- AVIA Vigilante · Ejemplo de alta de cliente: ORBITA, turismo en Bolivia
-- Requiere 01_vigilante_schema.sql. Sirve de plantilla para el siguiente vigilante:
--   SELECT vigilante.alta_cliente('otro-slug', 'Nombre', 'sector', 'BO', 'America/La_Paz', 'orbita-bolivia');
-- =============================================================================
BEGIN;
SET search_path = vigilante, public;
SET LOCAL vigilante.actor = 'alta:orbita-bolivia';

DO $$
DECLARE
  c uuid := vigilante.alta_cliente('orbita-bolivia', 'ORBITA · Turismo Bolivia', 'turismo', 'BO', 'America/La_Paz');
  bo integer;
BEGIN
  UPDATE vigilante.clientes
     SET perfil = '{
       "palabras_clave": ["turismo Bolivia", "Salar de Uyuni", "Titicaca", "Rurrenabaque", "festival", "vuelos Bolivia"],
       "ejes": ["riesgos para el visitante", "conectividad", "eventos", "financiamiento", "mercados y normativa"],
       "umbral_alerta": 6
     }'::jsonb
   WHERE id = c;

  -- Parámetros que ORBITA sobrescribe (el resto toma los de la plataforma)
  INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion) VALUES
    (c, 'anticipacion_horas', '24', 'Anticipación objetivo de las alertas');

  -- Territorio: país y 9 departamentos
  INSERT INTO vigilante.territorios (cliente_id, codigo, nombre, nivel) VALUES (c, 'BO', 'Bolivia', 'pais')
  RETURNING id INTO bo;
  INSERT INTO vigilante.territorios (cliente_id, codigo, nombre, nivel, padre_id, datos) VALUES
    (c, 'BO-H', 'Chuquisaca', 'region', bo, '{"capital": "Sucre"}'),
    (c, 'BO-L', 'La Paz',     'region', bo, '{"capital": "La Paz"}'),
    (c, 'BO-C', 'Cochabamba', 'region', bo, '{"capital": "Cochabamba"}'),
    (c, 'BO-O', 'Oruro',      'region', bo, '{"capital": "Oruro"}'),
    (c, 'BO-P', 'Potosí',     'region', bo, '{"capital": "Potosí"}'),
    (c, 'BO-T', 'Tarija',     'region', bo, '{"capital": "Tarija"}'),
    (c, 'BO-S', 'Santa Cruz', 'region', bo, '{"capital": "Santa Cruz de la Sierra"}'),
    (c, 'BO-B', 'Beni',       'region', bo, '{"capital": "Trinidad"}'),
    (c, 'BO-N', 'Pando',      'region', bo, '{"capital": "Cobija"}');

  -- Categorías de turismo
  INSERT INTO vigilante.categorias (cliente_id, codigo, nombre, descripcion, revision_obligatoria, orden) VALUES
    (c, 'clima',          'Clima y desastres',             'Alertas SENAMHI, inundaciones, sequías, heladas, incendios', true,  1),
    (c, 'salud',          'Salud y epidemiología',         'Alertas epidemiológicas, brotes, requisitos sanitarios',     true,  2),
    (c, 'vial',           'Vías y transporte terrestre',   'Cortes de ruta, bloqueos, transitabilidad',                  true,  3),
    (c, 'seguridad',      'Seguridad del visitante',       'Conflictos, riesgos para la integridad del turista',         true,  4),
    (c, 'conectividad',   'Conectividad aérea',            'Nuevas rutas, cancelaciones, cierres de aeropuerto',         false, 5),
    (c, 'eventos',        'Eventos y festividades',        'Ferias, festivales, congresos, fechas culturales',           false, 6),
    (c, 'financiamiento', 'Financiamiento y convocatorias','Fondos, licitaciones, cooperación',                          false, 7),
    (c, 'mercados',       'Mercados y normativa',          'Demanda, tendencias, inversión, normas',                     false, 8);

  -- Fuentes: las rápidas (ciclo de 30 min, gratuitas) y el Vigilante n8n por MCP
  INSERT INTO vigilante.sources (cliente_id, codigo, nombre, institucion, url, tipo, metodo, categorias,
                                 frecuencia_minutos, rapida, activa, config, notas) VALUES
    (c, 'gnews_turismo', 'Google News · turismo Bolivia', 'Google News', 'https://news.google.com/rss/search',
       'medio', 'google_news_rss', '{eventos,mercados,conectividad,seguridad}', 30, true, true,
       '{"q": "turismo Bolivia", "hl": "es-419", "gl": "BO"}', 'Gratis. Una consulta por palabra clave del perfil'),
    (c, 'gdelt_bolivia', 'GDELT · noticias sobre Bolivia', 'GDELT', 'https://api.gdeltproject.org/api/v2/doc/doc',
       'medio', 'gdelt', '{seguridad,vial,clima,eventos}', 30, true, true,
       '{"query": "Bolivia (turismo OR turistas)", "sourcelang": "spanish"}', 'Gratis; se actualiza cada 15 minutos'),
    (c, 'ops_alertas', 'OPS/OMS · alertas epidemiológicas', 'OPS/OMS', 'https://www.paho.org/es/rss.xml',
       'organismo_internacional', 'rss', '{salud}', 60, true, true, '{}', 'RSS general: filtrar por Bolivia'),
    (c, 'senamhi_alertas', 'SENAMHI · alertas', 'SENAMHI', 'https://senamhi.gob.bo/alertas3.php',
       'oficial', 'http_html', '{clima}', 60, true, true, '{}', NULL),
    (c, 'vigilante_avia', 'Vigilante AVIA (cosecha diaria, vía MCP)', 'AVIA', 'https://studio.avia-global.com/mcp/avia',
       'medio', 'mcp_vigilante', '{eventos,mercados,financiamiento,conectividad}', 1440, false, true, '{}',
       'Solo lectura. La cosecha con Apify la hace el Vigilante de n8n');
END $$;

COMMIT;
