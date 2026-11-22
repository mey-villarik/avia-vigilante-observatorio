# «En curso» no es «cierra en N días» (SQL 44)

**Qué se veía (2026-11-22):** el Festival de la Canción Boliviana y el Bicentenario, que ya están ocurriendo, salían como oportunidades con cuenta atrás («cierra en N días», «N días para actuar»). Un evento en curso no es una oportunidad con plazo.

## Regla única

| Situación | Se muestra |
|---|---|
| inicio ≤ hoy ≤ fin | **En curso** · hasta el DD mmm (o «termina hoy»), sin cuenta atrás |
| hoy < inicio | cuenta atrás normal («N días para actuar», «cierra en N días») |
| hoy > fin | cerrado: ya no se muestra (regla de vigencia de siempre) |

Si falta el fin del evento se usa el plazo y, si tampoco hay, el mismo día de inicio («ocurre hoy»). «Hoy» es el día en Bolivia.

Misma regla en dos sitios:
- Web: `web/src/lib/vigencia.ts` → `enCurso()` y `enCursoTexto()`.
- Base: `vigilante.en_curso(inicio, fin, plazo)` en `db/generico/44_en_curso.sql`.

## Dónde cambia

- Panel: lista de señales, ficha (cajón), Mapa y Oportunidades muestran «En curso» en lugar de los días. En Oportunidades lo en curso va primero.
- «Qué vigilar» (síntesis del día, web y SQL): ya no dice «Oportunidad que cierra en N días» de un evento en curso.
- Contadores: `plazo_corto` («con plazo < 15 días», «cierran en menos de 15 días») ya no cuenta lo en curso; hay un contador nuevo `en_curso`. AVIA lee esos contadores de la base.
- Chat AVIA: la señal va con `en_curso_hasta` y sin `plazo_dias`; las listas dicen «en curso».
- Web pública: en el detalle sale «Evento: En curso · hasta …» en lugar de «Plazo: N días».

## Instalar

1. Supabase → editor SQL → ejecutar `db/generico/44_en_curso.sql`.
2. Probar con `db/generico/99_prueba_en_curso.sql` (la segunda consulta lista lo que hoy está en curso).
3. VPS: `bash /root/avia-repo/web/desplegar.sh claude/project-thread-u6a3pg`.

Hermes, `avia_api.py` y el analizador no cambian.
