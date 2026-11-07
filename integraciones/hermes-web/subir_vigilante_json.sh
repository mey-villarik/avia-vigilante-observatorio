#!/usr/bin/env bash
# Sube vigilante.json (el que genera Hermes en el VPS) al almacenamiento privado de Supabase.
# Así la web solo muestra los datos a quien ha iniciado sesión con un perfil activo.
#
# Uso:   subir_vigilante_json.sh /ruta/a/vigilante.json
# Cron:  */5 * * * * /opt/avia/subir_vigilante_json.sh /ruta/a/vigilante.json >> /var/log/avia-subida.log 2>&1
#
# Variables (en /etc/avia/supabase.env, con permisos 600 y dueño root; NUNCA en Git):
#   SUPABASE_URL=https://<ref>.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY=<service_role>
#   VIGILANTE_CLIENTE=orbita-bolivia      (slug del cliente en vigilante.clientes)
set -euo pipefail

ARCHIVO="${1:?Indica la ruta de vigilante.json}"
ENV_FILE="${AVIA_SUPABASE_ENV:-/etc/avia/supabase.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${SUPABASE_URL:?Falta SUPABASE_URL}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Falta SUPABASE_SERVICE_ROLE_KEY}"
CLIENTE="${VIGILANTE_CLIENTE:-orbita-bolivia}"

# no subir un archivo a medio escribir o que no sea JSON válido
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("version")==1' "$ARCHIVO" \
  || { echo "$(date -Is) vigilante.json no válido, no se sube" >&2; exit 1; }

# solo si cambió desde la última subida
MARCA="/var/tmp/avia-vigilante-json.sha256"
SUMA="$(sha256sum "$ARCHIVO" | cut -d' ' -f1)"
if [ -f "$MARCA" ] && [ "$(cat "$MARCA")" = "$SUMA" ]; then exit 0; fi

CODIGO="$(curl -sS -o /tmp/avia-subida.out -w '%{http_code}' -X POST \
  "$SUPABASE_URL/storage/v1/object/vigilante/$CLIENTE/vigilante.json" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Cache-Control: no-cache' \
  -H 'x-upsert: true' \
  --data-binary @"$ARCHIVO")"

if [ "$CODIGO" = 200 ]; then
  echo "$SUMA" > "$MARCA"
  echo "$(date -Is) subido $CLIENTE/vigilante.json"
else
  echo "$(date -Is) error $CODIGO: $(cat /tmp/avia-subida.out)" >&2
  exit 1
fi
