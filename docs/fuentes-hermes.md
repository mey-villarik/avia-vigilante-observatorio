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
