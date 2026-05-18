#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMPOSE_FILE="$ROOT/docker-compose.tomcat.yml"
BASE_URL="${BASE_URL:-http://127.0.0.1:18090}"
SECRET="${API_GATEWAY_SECRET:-change-me}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wait_for_gateway() {
  i=0
  while [ "$i" -lt 120 ]; do
    if curl -fsS "$BASE_URL/healthz" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  fail "timed out waiting for gateway"
}

docker compose -f "$COMPOSE_FILE" up -d --build
wait_for_gateway

server_header=$(curl -sS -D - -o /dev/null "$BASE_URL/" | awk 'BEGIN{IGNORECASE=1} /^Server:/{print $2}' | tr -d '\r')
[ "$server_header" = "KP-HA" ] || fail "expected Server header KP-HA, got $server_header"

status=$(curl -fsS -H "X-API-Gateway-Secret: $SECRET" "$BASE_URL/status")
echo "$status" | grep '"tomcat-a"' >/dev/null || fail "status missing tomcat-a"
echo "$status" | grep '"tomcat-b"' >/dev/null || fail "status missing tomcat-b"

first=$(curl -fsS -c /tmp/nginx-ha-tomcat-cookies.txt "$BASE_URL/")
second=$(curl -fsS -b /tmp/nginx-ha-tomcat-cookies.txt "$BASE_URL/")

first_host=$(printf '%s\n' "$first" | sed -n 's/^hostname=//p')
second_host=$(printf '%s\n' "$second" | sed -n 's/^hostname=//p')
first_session=$(printf '%s\n' "$first" | sed -n 's/^session=//p')
second_session=$(printf '%s\n' "$second" | sed -n 's/^session=//p')

[ -n "$first_host" ] || fail "first response missing hostname"
[ -n "$first_session" ] || fail "first response missing session"
[ "$first_host" = "$second_host" ] || fail "sticky hostname changed from $first_host to $second_host"
[ "$first_session" = "$second_session" ] || fail "session changed from $first_session to $second_session"

printf '%s\n' "$first"
echo "--- second request with cookie ---"
printf '%s\n' "$second"
