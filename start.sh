#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NGINX_BIN="${NGINX_BIN:-}"
if [ -z "$NGINX_BIN" ]; then
  if [ -x /opt/openresty/nginx/sbin/nginx ]; then
    NGINX_BIN=/opt/openresty/nginx/sbin/nginx
  else
    NGINX_BIN=/usr/local/openresty/nginx/sbin/nginx
  fi
fi

sh "$ROOT/scripts/render_config.sh"
sh "$ROOT/scripts/validate_config.sh"

exec "$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf" -g "daemon off;"
