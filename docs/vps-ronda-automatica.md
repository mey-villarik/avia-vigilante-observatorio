# Ronda automática de AVIA en el VPS (vigilante.json cada 30 minutos)

Situación encontrada el 2026-11-08:

- `vigilante.json` lo construye `/root/.hermes/web/vigilante/build.py` a partir de los «partes» de `/root/.hermes/web/vigilante/partes/` (dentro del contenedor: `/opt/data/web/vigilante/`). Escribe `public/data/vigilante.json`.
- Nada lo ejecutaba solo: el último se construyó el 2026-11-07 a las 23:13 y se copió a mano a `/var/www/avia-vigilante-bolivia/web/data/`.
- La tarea de Hermes `b3c0d6cbc0ff` («Vigilancia fuentes oficiales cada 30 min») solo miraba SENAMHI, ABC, Salud y OPS y guardaba en `/opt/data/cache/scratch/*.jsonl`, que no lee nadie.
- `build.py` usaba el `id` que escribía AVIA o lo inventaba con el nombre: de ahí `eldeber`, `eldeb`, `el_deber`…

## Arreglo

1. **Supabase**: `db/generico/12_fuentes_repetidas.sql` junta las fuentes del mismo sitio web (las señales pasan a la que se queda) y hace que la sincronización no vuelva a duplicarlas.
2. **build.py**: `hermes/herramientas/parche_build_codigos.py` hace que cada fuente use el código de `fuentes_activas.json` (por código, dirección, sitio o nombre).
3. **Tarea de Hermes** `b3c0d6cbc0ff`: instrucciones nuevas con `hermes cron edit` (abajo). Vigila la lista viva, deja un parte con el código exacto de cada fuente y ejecuta `build.py`.
4. **Cron del host**: copia `vigilante.json` a la web cuando cambia. Supabase lo recoge cada 5 minutos (05).

## Comandos (VPS, como root)

```bash
# 2. Parche de build.py (guarda copia)
curl -fsSL https://raw.githubusercontent.com/mey-villarik/avia-vigilante-observatorio/web-acceso-login/hermes/herramientas/parche_build_codigos.py -o /root/avia/parche_build_codigos.py
python3 /root/avia/parche_build_codigos.py /root/.hermes/web/vigilante/build.py

# 3. Instrucciones nuevas de la tarea de 30 minutos
PROMPT=$(cat <<'EOF'
Ronda de vigilancia de AVIA (cada 30 minutos).
1. Lee /opt/data/skills/vigilancia-fuentes-bolivia/fuentes_activas.json. Vigila SOLO esas fuentes, siguiendo la skill: respeta frecuencia_minutos, haz siempre las que tengan "nueva": true, y usa que_buscar y palabras_clave.
2. Escribe un parte nuevo en /opt/data/web/vigilante/partes/AAAAMMDD-HHMM.json (hora UTC) con el MISMO formato que el parte más reciente de esa carpeta (míralo antes). En "fuentes" pon una entrada por cada fuente que consultaste: "id" = el "codigo" EXACTO de fuentes_activas.json (nunca inventes otro), "nombre" y "url" tal como vienen en la lista, "estado" (OK si la leíste bien, WARN si respondió con problemas, CRIT si no pudiste acceder, UNKNOWN solo si no te tocaba), "items" (novedades) e "info" (una frase; si falló, el error). En "senales" pon las señales nuevas o actualizadas según la skill.
3. Ejecuta: python3 /opt/data/web/vigilante/build.py /opt/data/web/vigilante y comprueba que termina con «OK:».
4. Devuelve un resumen corto: fuentes consultadas, fallos y señales nuevas. Si no hay señales nuevas, dilo.
EOF
)
docker exec hermes hermes cron edit b3c0d6cbc0ff --name "Ronda AVIA cada 30 min (lista viva + vigilante.json)" --prompt "$PROMPT"

# 4. Copiar a la web cuando cambie (cada 5 minutos)
(crontab -l 2>/dev/null; echo "*/5 * * * * cp -u /root/.hermes/web/vigilante/public/data/vigilante.json /var/www/avia-vigilante-bolivia/web/data/vigilante.json") | crontab -

# Probar ya: lanzar la ronda en el siguiente tick y mirar el resultado
docker exec hermes hermes cron run b3c0d6cbc0ff
```

Comprobar a los 10-15 minutos:

```bash
ls -lt /root/.hermes/web/vigilante/partes | head -3
ls -la /var/www/avia-vigilante-bolivia/web/data/vigilante.json
python3 -c "import json;d=json.load(open('/var/www/avia-vigilante-bolivia/web/data/vigilante.json'));print(d.get('construido'), len(d['fuentes']), 'fuentes');print(sorted(f['id'] for f in d['fuentes']))"
```
