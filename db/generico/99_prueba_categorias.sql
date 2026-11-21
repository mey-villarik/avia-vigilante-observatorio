-- Prueba de 42_categorias_correctas.sql: inflación no es clima y no hay códigos internos en la web pública.
-- Requiere 01, 02 y 42. Termina en ROLLBACK: no deja nada.
-- Sirve en el editor SQL de Supabase y en psql. Si todo va bien, el resultado es una fila «OK: categorías correctas»;
-- si algo falla, sale un error que dice qué.
BEGIN;
SET client_min_messages = warning;

CREATE TEMP TABLE ids AS SELECT id AS c FROM vigilante.clientes WHERE slug = 'orbita-bolivia';

-- Como hacía la sincronización con el Vigilante n8n: primero da de alta la categoría, luego la señal
INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
SELECT c, 'financiacion', 'financiacion' FROM ids ON CONFLICT DO NOTHING;

INSERT INTO vigilante.signals (cliente_id, codigo, titulo, resumen, naturaleza, categoria, prioridad)
SELECT c, x.cod, x.tit, x.res, x.nat::vigilante.naturaleza_senal, x.cat, 'media'
  FROM ids, (VALUES
    ('K-1', 'La inflación sube al 2 % en octubre', 'El INE informa alza de precios en alimentos y transporte.', 'riesgo', 'clima'),
    ('K-2', 'Alerta naranja por lluvias en el Beni', 'SENAMHI anuncia lluvias intensas y posible inundación.', 'riesgo', 'clima'),
    ('K-3', 'Pérdidas económicas por la sequía en el Chaco', 'La sequía deja pérdidas económicas a productores.', 'riesgo', 'clima'),
    ('K-4', 'CAF abre fondo para turismo comunitario', 'Convocatoria con cierre en 12 días.', 'oportunidad', 'financiacion'),
    ('K-5', 'Crece la demanda de paquetes a Uyuni', 'Operadores reportan más reservas y suben los precios de los tours.', 'oportunidad', 'mercado'),
    ('K-6', 'El dólar paralelo sube a 12 bolivianos', 'Operadores temen menos turistas.', 'riesgo', 'mercados')
  ) AS x(cod, tit, res, nat, cat);

DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT codigo, categoria FROM vigilante.signals WHERE codigo LIKE 'K-%' ORDER BY codigo LOOP
    IF (r.codigo, r.categoria) NOT IN (('K-1','economia'), ('K-2','clima'), ('K-3','clima'),
                                        ('K-4','financiamiento'), ('K-5','mercados'), ('K-6','economia')) THEN
      RAISE EXCEPTION 'Categoría incorrecta: % → %', r.codigo, r.categoria;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM vigilante.categorias WHERE codigo IN ('financiacion', 'mercado')) THEN
    RAISE EXCEPTION 'Quedó un código duplicado en el catálogo';
  END IF;
  IF EXISTS (SELECT 1 FROM vigilante.categorias WHERE nombre ~ '^[a-z_]+$') THEN
    RAISE EXCEPTION 'Hay un nombre de categoría que es un código interno';
  END IF;
  IF (SELECT nombre FROM vigilante.categorias c JOIN ids ON ids.c = c.cliente_id WHERE codigo = 'financiamiento')
     <> 'Financiación y convocatorias' THEN
    RAISE EXCEPTION 'Financiación sin el nombre correcto';
  END IF;
  -- al editar el título, la regla se vuelve a aplicar
  UPDATE vigilante.signals SET categoria = 'clima', titulo = 'Sube el precio del dólar paralelo' WHERE codigo = 'K-2';
  IF (SELECT categoria FROM vigilante.signals WHERE codigo = 'K-2') = 'economia' THEN
    RAISE EXCEPTION 'K-2 menciona lluvias en el resumen: debía quedar en clima';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vigilante.categorias c JOIN ids ON ids.c = c.cliente_id
                  WHERE codigo = 'economia' AND nombre = 'Economía y precios') THEN
    RAISE EXCEPTION 'Falta la categoría Economía';
  END IF;
  RAISE WARNING 'OK: categorías correctas';
END $$;

SELECT 'OK: categorías correctas' AS resultado;

ROLLBACK;
