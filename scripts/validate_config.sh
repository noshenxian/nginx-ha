#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NGINX_BIN="${NGINX_BIN:-}"
if [ -z "$NGINX_BIN" ]; then
  if [ -x /opt/openresty/nginx/sbin/nginx ]; then
    NGINX_BIN=/opt/openresty/nginx/sbin/nginx
  else
    NGINX_BIN=/usr/local/openresty/nginx/sbin/nginx
  fi
fi
CONFIG="$ROOT/build/nginx.conf"

[ -x "$NGINX_BIN" ] || {
  echo "missing OpenResty nginx binary: $NGINX_BIN" >&2
  exit 1
}

[ -f "$CONFIG" ] || {
  echo "missing rendered config: $CONFIG" >&2
  exit 1
}

"$NGINX_BIN" -p "$ROOT" -c "$CONFIG" -t
