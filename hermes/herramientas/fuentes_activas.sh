#!/usr/bin/env bash
# Descarga de Supabase la lista de fuentes ACTIVAS que Hermes debe vigilar y la deja en
# un archivo fijo que lee la skill vigilancia-fuentes-bolivia. Así, cuando alguien añade,
# pausa o reactiva una fuente en la web, Hermes lo sabe en su siguiente ronda sin tocar el prompt.
#
# Uso:   fuentes_activas.sh [/ruta/de/salida.json]
# Cron:  */5 * * * * /opt/avia/fuentes_activas.sh >> /var/log/avia-fuentes.log 2>&1
#
# Variables en /etc/avia/supabase.env (las mismas que subir_vigilante_json.sh; NUNCA en Git):
#   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, VIGILANTE_CLIENTE=orbita-bolivia
set -euo pipefail

SALIDA="${1:-$HOME/.hermes/skills/vigilancia-fuentes-bolivia/fuentes_activas.json}"
ENV_FILE="${AVIA_SUPABASE_ENV:-/etc/avia/supabase.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${SUPABASE_URL:?Falta SUPABASE_URL}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Falta SUPABASE_SERVICE_ROLE_KEY}"
CLIENTE="${VIGILANTE_CLIENTE:-orbita-bolivia}"

TMP="$(mktemp)"
CODIGO="$(curl -sS -o "$TMP" -w '%{http_code}' -X POST \
  "$SUPABASE_URL/rest/v1/rpc/fuentes_para_hermes" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Content-Profile: vigilante' \
  --data "{\"p_cliente\": \"$CLIENTE\"}")"

if [ "$CODIGO" != 200 ] || ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("fuentes"), list)' "$TMP"; then
  # si Supabase no responde, Hermes sigue con la última lista buena
  echo "$(date -Is) error $CODIGO: $(head -c 300 "$TMP")" >&2
  rm -f "$TMP"; exit 1
fi
mkdir -p "$(dirname "$SALIDA")"
mv "$TMP" "$SALIDA"
echo "$(date -Is) $(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["fuentes"]))' "$SALIDA") fuentes activas en $SALIDA"
