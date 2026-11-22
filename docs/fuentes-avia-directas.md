# Fuentes que encuentra AVIA: sin duplicados y sin aprobación manual (SQL 47)

Pedido de Meysel (2026-11-22): las fuentes que AVIA encuentra se añaden solas, sin «Aprobar / Rechazar», pero nunca repetidas; el usuario puede eliminar cualquiera, y la tabla dice cuáles puso el usuario y cuáles sugirió AVIA.

## Por qué salían repetidas

SENAMHI ya estaba en el catálogo (`senamhi.gob.bo/alertas3.php`) y aun así aparecían como candidatas `senamhi.gob.bo/alertas.php` y `senamhi.gob.bo/api/alertas/active-alerts`. Desde el SQL 30, `fuente_canonica` solo reconoce la **misma dirección**, no el mismo sitio.

## Cómo funciona ahora

1. AVIA encuentra una fuente (Hermes con `proponer_fuente`, o una fuente nueva en `vigilante.json`).
2. La base calcula su **sitio** (`vigilante.sitio`): `www.senamhi.gob.bo/x`, `alertas.senamhi.gob.bo/y` → `senamhi.gob.bo`. En Google News, redes y GDELT cada dirección cuenta como fuente distinta.
3. **No se añade** si ya hay una fuente de ese sitio (activa o en pausa), si un usuario eliminó una fuente de ese sitio, o si se rechazó en los últimos 90 días. Queda registrada como «Repetida: no se añadió».
4. Si el sitio es nuevo, **se añade y se activa al momento** con `origen = 'avia'`: AVIA la lee desde su próxima ronda.
   - Tipo: el que dé Hermes; si no, `oficial` para .gob.bo / .gov / .mil, `organismo_internacional` para OPS/OMS, ONU, CEPAL, CAF, BID, OMT…; si no, `no_oficial`.
   - Canal: el más frecuente en las señales de sus noticias de respaldo; si no hay, Turismo.
   - Cómo se lee: RSS si la dirección parece un feed; si no, página web, cada 60 min.
5. En la web (pestaña **Fuentes**):
   - columna **Origen**: «Usuario» o «Sugerida por AVIA» (al pasar el ratón, el porqué);
   - filtro *Todo origen / Del usuario / Sugeridas por AVIA*;
   - botón de **papelera** en cada fila (administrador) para eliminar cualquier fuente. Si era de AVIA, AVIA no vuelve a añadir ese sitio;
   - el recuadro de candidatas con Aprobar/Rechazar se sustituye por un resumen: «AVIA añadió N fuentes y no repitió M que ya estaban» (últimos 30 días, con detalle).

Las propuestas para **cambiar cómo se lee** una fuente (por ejemplo, a Apify) siguen necesitando aprobación, porque pueden costar dinero.

## Instalar

1. Supabase → SQL Editor: pegar `db/generico/47_fuentes_avia_directas.sql` y Run. Al instalarse, activa las candidatas pendientes y las propuestas en pausa, y marca/quita las repetidas (los avisos NOTICE dicen qué hizo con cada una). Vista previa sin cambiar nada: `select * from vigilante.activar_fuentes_avia_pendientes(false);`
2. Comprobar: `select origen, count(*) from vigilante.sources where eliminada_en is null group by 1;`
3. Desplegar la web y copiar `hermes/mcp-vigilante/servidor.py` (solo cambia la descripción de `proponer_fuente`) y la skill `vigilancia-fuentes-bolivia`.

Prueba local: `99_prueba_fuentes_avia.sql` (termina en ROLLBACK).
