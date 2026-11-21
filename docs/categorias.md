# Categorías correctas (migración 42)

**Qué pasaba (2026-11-21):** en la web pública una noticia de inflación salía como «Clima y desastres» y el filtro de categorías mostraba «financiacion», un código interno sin tilde.

**Por qué:**

1. El clasificador no tenía regla para la economía y eligió «clima» para la inflación («clima económico»).
2. La base de ORBITA usa los códigos `financiamiento` y `mercados`; el Vigilante n8n, el chat y la web del panel usan `financiacion` y `mercado`. Al sincronizar, la base daba de alta una categoría nueva con código y nombre `financiacion`, y la web pública mostraba ese nombre.

**Arreglo:**

| Dónde | Qué |
| --- | --- |
| `db/generico/42_categorias_correctas.sql` | Categoría nueva **«Economía y precios»** (código `economia`). `categoria_canonica()` une los códigos; `categoria_corregida()` pasa a «economia» una señal en «clima» (o en «mercados», solo con términos claros: inflación, dólar, tipo de cambio, combustibles…) que no habla de tiempo ni desastres. Triggers en `signals` y `categorias`; corrige los datos que ya están; «Financiación y convocatorias» con tilde. |
| `hermes/analizador/prompt_clasificador.md` (clasificador-1.8) y `analizador.py` | Regla explícita: clima es solo tiempo y naturaleza; economía → economia; mercados = demanda y negocio turístico. |
| Panel (`types.ts`, `demo.ts`, `datos.ts`, `recomendacion.ts`, `avia.ts`) | La categoría «Economía» existe también en el panel y en sus filtros. |
| `web/src/lib/categorias.ts` | La web pública nunca muestra un código: si la base no trae un nombre legible, usa la misma lista de nombres. |

**Instalar en el VPS** (el analizador lee el prompt nuevo solo, pero `analizador.py` cambió: copiar el del repo si el VPS no corre desde `/root/avia-repo`):

```bash
cd /root/avia-repo && git fetch origin && git checkout claude/project-thread-cq04g5
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/generico/42_categorias_correctas.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/generico/99_prueba_categorias.sql   # termina en ROLLBACK
bash web/desplegar.sh claude/project-thread-cq04g5
```

El analizador lee el prompt nuevo en su siguiente ronda (no hace falta reiniciar nada). Las alertas de Telegram ya enviadas no cambian; las siguientes salen con la categoría correcta.
