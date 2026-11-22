-- =============================================================================
-- 42. Categorías correctas, categoría «Economía» y sin etiquetas internas en la web pública
-- =============================================================================
-- Qué se veía (Meysel, 2026-11-21, auditoría de usabilidad):
--   1. Una noticia de inflación salía en la web pública como «Clima y desastres».
--   2. El filtro de categorías de la web pública mostraba «financiacion» (sin tilde, en minúscula).
--
-- Causas:
--   1. El clasificador (hermes/analizador/prompt_clasificador.md) no tenía ninguna regla para la
--      economía: inflación, precios o dólar no encajaban en ninguna categoría y el modelo eligió
--      «clima» (de «clima económico»). Desde ahora hay categoría «economia» (Meysel, 2026-11-21):
--      el prompt la usa (clasificador-1.8) y esta base corrige aunque el modelo se equivoque.
--   2. El catálogo de ORBITA usa los códigos «financiamiento» y «mercados», pero el Vigilante n8n,
--      el chat de AVIA y la web del panel usan «financiacion» y «mercado». Al sincronizar, la base
--      creaba en el catálogo una categoría nueva con código y nombre «financiacion», y ese código
--      era lo que la web pública ponía en el filtro.
--
-- Qué hace este script (se puede ejecutar más de una vez):
--   · vigilante.categoria_canonica(): «financiacion» → «financiamiento» y «mercado» → «mercados».
--   · Categoría nueva «economia» (Economía y precios) en el catálogo de cada cliente.
--   · vigilante.categoria_corregida(): una señal en «clima» o «mercados» que habla de economía
--     (inflación, precios, dólar, tipo de cambio, combustible…) y no de tiempo, lluvias,
--     incendios ni desastres pasa a «economia».
--   · Trigger b_categoria_canonica en signals (antes de signals_reglas, que lee el catálogo) y
--     trigger a_categoria_canonica en categorias: ya no se crean códigos duplicados.
--   · Arregla los datos que ya están: señales, preferencias de usuarios y catálogo.
--   · Nombre del catálogo de ORBITA: «Financiación y convocatorias» (con tilde).
-- La web pública (web/src/lib/categorias.ts) además nunca muestra un código interno.
-- Prueba: 99_prueba_categorias.sql (termina en ROLLBACK).
-- =============================================================================

BEGIN;

-- 1. Códigos únicos ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION vigilante.categoria_canonica(p_codigo text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(trim(p_codigo))
           WHEN 'financiacion'  THEN 'financiamiento'
           WHEN 'financiación'  THEN 'financiamiento'
           WHEN 'financiamento' THEN 'financiamiento'
           WHEN 'mercado'       THEN 'mercados'
           WHEN 'economía'      THEN 'economia'
           WHEN 'economico'     THEN 'economia'
           ELSE p_codigo END
$$;

-- Nombre para mostrar de los códigos conocidos (cuando el catálogo no trae uno bueno)
CREATE OR REPLACE FUNCTION vigilante.categoria_nombre_defecto(p_codigo text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE vigilante.categoria_canonica(p_codigo)
           WHEN 'clima'          THEN 'Clima y desastres'
           WHEN 'salud'          THEN 'Salud y epidemiología'
           WHEN 'vial'           THEN 'Vías y transporte terrestre'
           WHEN 'seguridad'      THEN 'Seguridad del visitante'
           WHEN 'conectividad'   THEN 'Conectividad aérea'
           WHEN 'eventos'        THEN 'Eventos y festividades'
           WHEN 'financiamiento' THEN 'Financiación y convocatorias'
           WHEN 'mercados'       THEN 'Mercados y normativa'
           WHEN 'economia'       THEN 'Economía y precios'
           WHEN 'normativa'      THEN 'Normativa'
           WHEN 'turismo'        THEN 'Turismo'
           ELSE initcap(replace(p_codigo, '_', ' ')) END
$$;

-- 2. Economía no es clima ni mercado turístico -------------------------------------
CREATE OR REPLACE FUNCTION vigilante.categoria_corregida(p_codigo text, p_texto text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    -- tiempo, naturaleza o desastre: se queda donde está
    WHEN coalesce(p_texto, '') ~* '(lluvia|granizo|helada|nevada|nieve|sequ[ií]a|inundaci|desborde|riada|mazamorra|deslizamiento|derrumbe|incendio|humo|tormenta|vendaval|viento|ola de (calor|fr[ií]o)|friaje|temperatura|senamhi|fen[oó]meno|el ni[nñ]o|la ni[nñ]a|cicl[oó]n|sismo|terremoto|desastre natural|alerta (roja|naranja|amarilla))'
      THEN vigilante.categoria_canonica(p_codigo)
    -- términos claros de economía: desde clima o mercados
    WHEN vigilante.categoria_canonica(p_codigo) IN ('clima', 'mercados')
     AND coalesce(p_texto, '') ~* '(inflaci[oó]n|deflaci[oó]n|\mipc\M|[ií]ndice de precios|alza de precios|suba de precios|aumento de precios|subida de precios|canasta (b[aá]sica|familiar)|costo de (la )?vida|tipo de cambio|d[oó]lar|divisas|devaluaci[oó]n|\mpib\M|recesi[oó]n|combustibles?|gasolina|di[eé]sel|arancel|tasas? de inter[eé]s)'
      THEN 'economia'
    -- términos generales («económico», «precios de»): solo desde clima
    WHEN vigilante.categoria_canonica(p_codigo) = 'clima'
     AND coalesce(p_texto, '') ~* '(econom[ií]a|econ[oó]mic|precios? de)'
      THEN 'economia'
    ELSE vigilante.categoria_canonica(p_codigo) END
$$;

-- 3. Triggers ---------------------------------------------------------------------
-- En signals: corre después de a_heredar_cliente y antes de signals_reglas (orden alfabético),
-- así la regla de revisión obligatoria lee la categoría ya corregida.
CREATE OR REPLACE FUNCTION vigilante.tg_categoria_canonica_senal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
DECLARE v_cat text;
BEGIN
  v_cat := vigilante.categoria_corregida(NEW.categoria, concat_ws(' ', NEW.titulo, NEW.resumen));
  IF v_cat IS DISTINCT FROM NEW.categoria THEN
    -- el código bueno tiene que existir en el catálogo del cliente (lo exige la clave foránea)
    INSERT INTO vigilante.categorias (cliente_id, codigo, nombre)
    VALUES (NEW.cliente_id, v_cat, vigilante.categoria_nombre_defecto(v_cat))
    ON CONFLICT DO NOTHING;
    NEW.categoria := v_cat;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS b_categoria_canonica ON vigilante.signals;
CREATE TRIGGER b_categoria_canonica BEFORE INSERT OR UPDATE OF categoria, titulo, resumen ON vigilante.signals
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_categoria_canonica_senal();

-- En categorias: un alias no se da de alta; si el código bueno ya está, no se inserta nada.
-- Un nombre que es el propio código («financiacion») se cambia por uno legible.
CREATE OR REPLACE FUNCTION vigilante.tg_categoria_canonica_catalogo()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = vigilante, pg_temp AS $$
BEGIN
  NEW.codigo := vigilante.categoria_canonica(NEW.codigo);
  IF NEW.nombre IS NULL OR NEW.nombre ~ '^[a-z_]+$' THEN
    NEW.nombre := vigilante.categoria_nombre_defecto(NEW.codigo);
  END IF;
  IF EXISTS (SELECT 1 FROM vigilante.categorias WHERE cliente_id = NEW.cliente_id AND codigo = NEW.codigo) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a_categoria_canonica ON vigilante.categorias;
CREATE TRIGGER a_categoria_canonica BEFORE INSERT ON vigilante.categorias
  FOR EACH ROW EXECUTE FUNCTION vigilante.tg_categoria_canonica_catalogo();

-- 4. Datos que ya están -----------------------------------------------------------
-- 4·0. la categoría nueva «economia» en cada cliente, después de Mercados
INSERT INTO vigilante.categorias (cliente_id, codigo, nombre, descripcion, revision_obligatoria, orden)
SELECT cl.id, 'economia', 'Economía y precios',
       'Inflación, precios, canasta básica, tipo de cambio y dólar, combustibles, aranceles',
       false, coalesce((SELECT max(orden) FROM vigilante.categorias c WHERE c.cliente_id = cl.id), 0) + 1
  FROM vigilante.clientes cl
ON CONFLICT DO NOTHING;

-- 4a. el código bueno existe en cada cliente que tenga un alias
INSERT INTO vigilante.categorias (cliente_id, codigo, nombre, descripcion, revision_obligatoria, orden, activa)
SELECT c.cliente_id, vigilante.categoria_canonica(c.codigo), vigilante.categoria_nombre_defecto(c.codigo),
       c.descripcion, c.revision_obligatoria, c.orden, c.activa
  FROM vigilante.categorias c
 WHERE vigilante.categoria_canonica(c.codigo) <> c.codigo
ON CONFLICT DO NOTHING;

-- 4b. señales (el trigger del punto 3 también corrige economía → economia)
UPDATE vigilante.signals SET categoria = vigilante.categoria_canonica(categoria)
 WHERE vigilante.categoria_canonica(categoria) <> categoria;
UPDATE vigilante.signals SET categoria = 'economia'
 WHERE categoria IN ('clima', 'mercados')
   AND vigilante.categoria_corregida(categoria, concat_ws(' ', titulo, resumen)) = 'economia';

-- 4c. preferencias de usuarios: pasan al código bueno sin duplicar
UPDATE vigilante.user_categorias u SET categoria = vigilante.categoria_canonica(u.categoria)
 WHERE vigilante.categoria_canonica(u.categoria) <> u.categoria
   AND NOT EXISTS (SELECT 1 FROM vigilante.user_categorias o
                    WHERE o.user_id = u.user_id AND o.categoria = vigilante.categoria_canonica(u.categoria));
DELETE FROM vigilante.user_categorias WHERE vigilante.categoria_canonica(categoria) <> categoria;

-- 4d. fuentes: las categorías de cada fuente, con el código bueno y sin repetir
UPDATE vigilante.sources s
   -- se mantiene el orden: la primera es el «canal» que ve el panel
   SET categorias = ARRAY(SELECT c FROM (SELECT vigilante.categoria_canonica(x) AS c, min(n) AS n
                                           FROM unnest(s.categorias) WITH ORDINALITY AS t(x, n) GROUP BY 1) k
                           ORDER BY n)
 WHERE EXISTS (SELECT 1 FROM unnest(s.categorias) x WHERE vigilante.categoria_canonica(x) <> x);

-- 4e. los alias salen del catálogo (ya nada los usa)
DELETE FROM vigilante.categorias WHERE vigilante.categoria_canonica(codigo) <> codigo;

-- 4f. ningún nombre del catálogo es un código interno
UPDATE vigilante.categorias SET nombre = vigilante.categoria_nombre_defecto(codigo)
 WHERE nombre ~ '^[a-z_]+$';

-- 5. Catálogo de ORBITA: «Financiación» con tilde --------------------------------------
UPDATE vigilante.categorias c SET nombre = 'Financiación y convocatorias'
  FROM vigilante.clientes cl
 WHERE cl.id = c.cliente_id AND cl.slug = 'orbita-bolivia' AND c.codigo = 'financiamiento';

COMMIT;
