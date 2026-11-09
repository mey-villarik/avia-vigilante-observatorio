#!/usr/bin/env bash
# Sube vigilante.json (el que genera Hermes en el VPS) a Supabase:
#  1) al almacenamiento privado, para que la web solo muestre los datos a quien inició sesión;
#  2) a las tablas (fuentes y señales), con vigilante.sincronizar_vigilante(), para que las
#     decisiones de las personas sobre cada señal se guarden en la base de datos.
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
# las claves nuevas (sb_secret_…) van solo en «apikey»; las antiguas (JWT service_role) también en Authorization
AUTORIZACION=()
case "$SUPABASE_SERVICE_ROLE_KEY" in sb_*) ;; *) AUTORIZACION=(-H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY") ;; esac

# no subir un archivo a medio escribir o que no sea JSON válido
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("version")==1' "$ARCHIVO" \
  || { echo "$(date -Is) vigilante.json no válido, no se sube" >&2; exit 1; }

# solo si cambió desde la última subida
MARCA="/var/tmp/avia-vigilante-json.sha256"
SUMA="$(sha256sum "$ARCHIVO" | cut -d' ' -f1)"
if [ -f "$MARCA" ] && [ "$(cat "$MARCA")" = "$SUMA" ]; then exit 0; fi

CODIGO="$(curl -sS -o /tmp/avia-subida.out -w '%{http_code}' -X POST \
  "$SUPABASE_URL/storage/v1/object/vigilante/$CLIENTE/vigilante.json" \
  "${AUTORIZACION[@]}" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Cache-Control: no-cache' \
  -H 'x-upsert: true' \
  --data-binary @"$ARCHIVO")"

if [ "$CODIGO" != 200 ]; then
  echo "$(date -Is) error al subir $CODIGO: $(cat /tmp/avia-subida.out)" >&2
  exit 1
fi
echo "$(date -Is) subido $CLIENTE/vigilante.json"

# 2) pasar fuentes y señales a las tablas (respeta las etapas que cambiaron las personas)
python3 -c 'import json,sys; print(json.dumps({"p_cliente": sys.argv[2], "p_json": json.load(open(sys.argv[1]))}))' \
  "$ARCHIVO" "$CLIENTE" > /tmp/avia-sinc.json
CODIGO="$(curl -sS -o /tmp/avia-sinc.out -w '%{http_code}' -X POST \
  "$SUPABASE_URL/rest/v1/rpc/sincronizar_vigilante" \
  "${AUTORIZACION[@]}" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Content-Profile: vigilante' \
  --data-binary @/tmp/avia-sinc.json)"
if [ "$CODIGO" != 200 ]; then
  echo "$(date -Is) error al sincronizar $CODIGO: $(cat /tmp/avia-sinc.out)" >&2
  exit 1
fi
echo "$(date -Is) sincronizado: $(cat /tmp/avia-sinc.out)"
echo "$SUMA" > "$MARCA"
