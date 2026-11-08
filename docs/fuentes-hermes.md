# Fuentes: web → Supabase → Hermes → web

```
Web (Añadir / Pausar / Reactivar)  →  vigilante.sources (Supabase, lista oficial)
                                         │  fuentes_para_hermes()  cada 5 min
                                         ▼
                        VPS: hermes/herramientas/fuentes_activas.sh → fuentes_activas.json
                                         │  la skill vigila SOLO esa lista
                                         ▼
                        Hermes publica vigilante.json (estado de cada fuente por su código)
                                         │  sincronizar_vigilante()  (04 / 05)
                                         ▼
                        Supabase → la web muestra si cada fuente funciona
```

- La lista de fuentes **no va dentro del prompt**: la skill se cambió una vez para leer `fuentes_activas.json` en cada ronda. Añadir una fuente en la web no exige tocar a Hermes.
- `fuentes.yaml` queda como referencia histórica. Las fuentes que ya vigila Hermes entran en Supabase solas con la sincronización (04/05).
- Una fuente nueva aparece en la web como «pendiente de la primera comprobación» hasta que Hermes la mira.

## Instalar

1. Supabase, SQL Editor: `db/generico/06_fuentes_hermes.sql` (después de 04 y 05).
2. VPS (por SSH):
   - Copiar `hermes/herramientas/fuentes_activas.sh` a `/opt/avia/` y darle permiso de ejecución.
   - Crear `/etc/avia/supabase.env` (permisos 600) con `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (la clave secreta, nunca en Git ni en el chat) y `VIGILANTE_CLIENTE=orbita-bolivia`.
   - Probarlo una vez a mano y programarlo cada 5 minutos con `crontab -e`.
   - Sustituir la skill instalada en Hermes por `hermes/skills/vigilancia-fuentes-bolivia/SKILL.md` (versión 1.1.0) y comprobar que `fuentes_activas.json` queda en la carpeta de la skill.

## Eliminar fuentes (07_eliminar_fuentes.sql)

- Un administrador puede eliminar una fuente desde su ficha («Eliminar fuente»). Desaparece de la web y de `fuentes_activas.json`, así que Hermes deja de vigilarla en su siguiente ronda.
- En la base la fila no se borra: queda marcada con `sources.eliminada_en`, porque las noticias y señales que salieron de ella siguen apuntándole. Así la sincronización con `vigilante.json` tampoco la vuelve a crear.
- Si alguien da de alta otra vez la misma dirección, se recupera esa fuente con su historial.
- La pestaña Fuentes muestra un recuadro «Total» que sube al añadir y baja al eliminar. Una fuente nueva entra como «Desconocido» hasta que AVIA la compruebe por primera vez; entonces pasa a OK, Aviso o Crítico.

## Editar fuentes (08_editar_fuentes.sql)

- Desde la ficha de una fuente, «Editar» permite cambiar el nombre, la dirección, el canal, el tipo, cómo se lee, la frecuencia, qué buscar y las palabras clave. AVIA recibe los cambios en `fuentes_activas.json` en su siguiente ronda.
- La ficha muestra qué vigila AVIA en esa fuente, las palabras clave, quién la dio de alta y la última edición.
- `sources.gestionada_web`: una fuente dada de alta o editada en la web ya no cambia de nombre, dirección, tipo ni canal cuando llega `vigilante.json`. Hermes solo informa del resultado de su comprobación.
- «Cómo se lee» admite página web, RSS, Google News, API, Tavily, Apify, GDELT y manual. La frecuencia va de 15 minutos a 1 semana.

## Permisos (decisión de Meysel, 2026-11-08)

Solo el administrador puede añadir, editar, pausar, reactivar y eliminar fuentes. Analistas y visores ven la pestaña y las fichas, pero no los botones. La base lo comprueba con `es_admin()` en 06, 07 y 08.

## Seguridad y coherencia (09_fuentes_seguridad.sql, auditoría 2026-11-08)

- La tabla `vigilante.sources` ya no usa la regla general `staff_todo`. Todo el equipo del cliente la lee (también el visor) y solo el administrador escribe.
- Una fuente que AVIA publica en `vigilante.json` y la base no conoce entra **en pausa** como «Propuesta de AVIA» (`config.propuesta_avia`). El administrador la aprueba con «Aprobar» (decisión de Meysel).
- La sincronización guarda `ultimo_exito_en`, `errores_seguidos` y `ultimo_error` (solo cuenta cuando llega una comprobación con hora nueva) y no borra la hora anterior si AVIA no la manda. La ficha muestra «Lleva N comprobaciones fallidas seguidas».
- Al cambiar la dirección o el método, `config.revisar_desde` hace que la fuente vuelva a llegar a Hermes como `"nueva": true`.
- `vigilante.url_normal()`: http/https, `www.`, mayúsculas y barra final cuentan como la misma dirección para detectar duplicados.

## Reconocer problema y Bitácora (10_fuentes_bitacora.sql)

- «Reconocer problema» (analista o administrador) se guarda en la base con nombre, hora y nota opcional. Todo el equipo lo ve en la tabla y en la ficha. Se quita solo cuando la fuente vuelve a OK.
- `vigilante.source_events` guarda cada cambio que hace una persona en una fuente: alta, edición (con qué campos cambió), pausa, reactivación, aprobación de una propuesta de AVIA, eliminación, recuperación y reconocimiento. Lo rellena un disparador; los cambios de la sincronización con Hermes no se apuntan.
- La Bitácora de la web muestra esos eventos junto a los movimientos de señales.

## «AVIA no la está leyendo»

- Una fuente activa de la base que AVIA nunca ha comprobado se marca «⚠ AVIA no la lee» cuando pasa más de 3 veces su frecuencia (mínimo 2 horas) desde el alta o la última edición. La ficha dice cuánto tiempo lleva y con qué código debe publicarla AVIA.
- Mientras espera dentro de ese plazo aparece como «nueva · en espera» y no cuenta en «Con problemas».
- Causas habituales: el cron de `fuentes_activas.sh` no corre, la skill de la ronda no lee `fuentes_activas.json`, o AVIA publica la fuente con otro código.
