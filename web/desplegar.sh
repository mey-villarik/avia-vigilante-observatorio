#!/usr/bin/env bash
# Compila la web (panel con login + web pública de alertas) y la publica en el VPS.
#
# Uso, en el VPS:
#   bash /root/avia-repo/web/desplegar.sh                 # rama actual del repo
#   bash /root/avia-repo/web/desplegar.sh nombre-de-rama  # cambia antes a esa rama
#
# Qué hace:
#   1. Actualiza el repo (git pull) en la rama indicada.
#   2. Si falta web/.env.production, lo crea a partir de la web que ya está publicada
#      (URL de Supabase, clave pública anon y URL de la API de AVIA). Solo valores públicos:
#      todo lo que empieza por VITE_ ya está dentro del navegador.
#   3. Compila con Node 20+ si está instalado; si no, con Docker (imagen node:20-alpine).
#   4. Guarda una copia de la web publicada (dist.bak-FECHA) y copia la nueva encima.
#      No borra nada de la carpeta publicada: los archivos viejos se quedan sin uso.
#
# Para volver atrás: cp -a /var/www/avia-vigilante-bolivia/web/dist.bak-FECHA/. /var/www/avia-vigilante-bolivia/web/dist/
set -euo pipefail

DEST="${DEST:-/var/www/avia-vigilante-bolivia/web/dist}"
WEB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$WEB")"
RAMA="${1:-}"

echo "== 1. Código"
cd "$REPO"
git fetch -q origin
if [ -n "$RAMA" ]; then git checkout -q "$RAMA"; fi
git pull -q --ff-only origin "$(git rev-parse --abbrev-ref HEAD)"
echo "Rama $(git rev-parse --abbrev-ref HEAD), commit $(git log -1 --format='%h %s')"

echo "== 2. Configuración (web/.env.production)"
cd "$WEB"
if [ ! -f .env.production ]; then
  [ -d "$DEST/assets" ] || { echo "Falta web/.env.production y no hay web publicada de la que sacarlo. Créalo a partir de web/.env.example."; exit 1; }
  js="$DEST/assets"
  sb_url=$(grep -ohE 'https://[a-z0-9]+\.supabase\.co' "$js"/*.js | sort -u | head -1 || true)
  sb_key=$(grep -ohE 'sb_publishable_[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' "$js"/*.js | sort -u | head -1 || true)
  api=$(grep -ohE '="[^"]*"\.replace\(/\\/\$/,""\)' "$js"/*.js | head -1 | sed -E 's/^="([^"]*)".*/\1/' || true)
  if [ -z "$sb_url" ] || [ -z "$sb_key" ]; then
    echo "No encontré la URL o la clave de Supabase en la web publicada. Crea web/.env.production a mano (ver web/.env.example)."; exit 1
  fi
  cat > .env.production <<EOF
# Creado por desplegar.sh a partir de la web publicada el $(date +%F). Solo valores públicos.
VITE_SUPABASE_URL=$sb_url
VITE_SUPABASE_ANON_KEY=$sb_key
VITE_AVIA_API_URL=$api
VITE_DATA_URL=/data/vigilante.json
VITE_CLIENTE_PUBLICO=orbita-bolivia
EOF
  echo "Creado web/.env.production:"
fi
sed -E 's/(ANON_KEY=.{12}).*/\1…/' .env.production | grep -v '^#'

echo "== 3. Compilar"
rm -rf dist
if command -v node >/dev/null && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]; then
  npm ci --no-audit --no-fund && npm run build
elif command -v docker >/dev/null; then
  echo "Node 20+ no está instalado: compilo con Docker."
  docker run --rm -v "$WEB":/app -w /app node:20-alpine sh -c "npm ci --no-audit --no-fund && npm run build"
else
  echo "Hace falta Node 20+ o Docker para compilar."; exit 1
fi
[ -f dist/index.html ] && [ -f dist/publico.html ] || { echo "La compilación no generó index.html y publico.html. No toco la web publicada."; exit 1; }

echo "== 4. Publicar en $DEST"
if [ -d "$DEST" ]; then
  copia="${DEST}.bak-$(date +%F-%H%M)"
  cp -a "$DEST" "$copia"
  echo "Copia de la web anterior: $copia"
fi
mkdir -p "$DEST"
cp -a dist/. "$DEST/"
chmod -R a+rX "$DEST"

echo "== Listo"
echo "Panel:        https://vigilante-bolivia.duckdns.org/"
echo "Web pública:  https://vigilante-bolivia.duckdns.org/publico.html"
