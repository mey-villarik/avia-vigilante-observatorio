# Uso de tokens de IA en el panel

Pedido de Meysel (2026-11-23): ver en la web cuántos tokens se han usado y cuánto queda. Solo lo ve el equipo (analista y administrador), nunca la web pública.

## Dónde se ve

- **Encabezado**: botón «50,1 mil hoy · queda USD 4,43» (o «· saldo USD 8,42» si no hay presupuesto). Se pone ámbar al 75 % del presupuesto del mes y rojo al 90 %, o rojo si la cuenta del modelo se queda sin saldo.
- **Panel «Uso de IA»** (pulsando el botón, o «Uso de IA» en la cuenta, abajo a la izquierda; en el móvil solo por ahí): tokens y coste de hoy, del mes y acumulado; lo que queda del presupuesto; saldo de la cuenta de DeepSeek; barras de los últimos 14 días; y quién gasta (clasificador, chat, análisis, evaluar).

## De dónde salen los números

| Dato | Origen |
| --- | --- |
| Tokens del clasificador | `analizador.py` → `vigilante.system_logs` (proceso `clasificador`), desde el 15 |
| Tokens del chat, análisis y evaluar | `avia_api.py` → `vigilante.system_logs` (procesos `avia-chat`, `avia-analisis`, `avia-evaluar`), **desde esta versión** |
| Resumen | `vigilante.uso_tokens()` (`db/generico/52_uso_tokens.sql`) |
| Saldo de la cuenta | `POST /saldo` de `avia_api.py`, que pregunta a DeepSeek (`GET /user/balance`), cache 5 min |

`vigilante.analisis` también guarda tokens, pero son los mismos del lote repartidos por noticia: no se suman para no contarlos dos veces.

Lo que Hermes gasta en sus propias tareas (skills, interpretar eventos, cambios) **no pasa por la base**: solo se refleja en el saldo de DeepSeek.

## Coste y límite

- Si el registro trae `costo_usd` se usa tal cual. Si no (el `.env` no tiene `LLM_PRECIO_ENTRADA` / `LLM_PRECIO_SALIDA`), se estima con los parámetros `ia_precio_entrada_usd_millon` (0,30) y `ia_precio_salida_usd_millon` (1,20), y la web dice «aprox.». Son precios estimados: conviene ponerlos con la tarifa real.
- «Lo que queda» del mes solo aparece si hay un límite guardado:

```sql
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
SELECT id, 'ia_presupuesto_usd_mes', '20', 'Presupuesto mensual de IA en USD'
  FROM vigilante.clientes WHERE slug = 'orbita-bolivia'
ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = excluded.valor;
-- o por tokens: clave 'ia_tope_tokens_mes', valor '5000000'
```

- El acumulado cubre lo que queda en `system_logs`, que se borra a los 6 meses.

## Instalar en el VPS

1. Supabase → SQL Editor: `db/generico/52_uso_tokens.sql` (prueba: `99_prueba_uso_tokens.sql`, termina en ROLLBACK).
2. Copiar `hermes/avia-api/avia_api.py` a `/root/avia/avia_api.py` y `systemctl restart avia-api`. Comprobar que sigue apuntando al esquema `vigilante` (cabeceras `Content-Profile`). Si nginx solo deja pasar rutas concretas hacia la API, añadir `/saldo` como `/chat`.
3. Opcional: `LLM_PRECIO_ENTRADA` y `LLM_PRECIO_SALIDA` en `supabase.env` (USD por millón) para anotar el coste exacto.
4. Publicar la web (`web/desplegar.sh <rama>`).
