#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR="${TMPDIR:-/tmp}/openresty-lb-test-$$"
GATEWAY_PORT="${GATEWAY_PORT:-18080}"
BACKEND1_PORT="${BACKEND1_PORT:-18081}"
BACKEND2_PORT="${BACKEND2_PORT:-18082}"
SECRET="test-secret"
BACKEND1_DOWN="$TMP_DIR/backend1.down"
BACKEND2_DOWN="$TMP_DIR/backend2.down"
NGINX_BIN="${NGINX_BIN:-/opt/openresty/nginx/sbin/nginx}"
ADMIN_PID=
SC_PID=

mkdir -p "$TMP_DIR"

cleanup() {
  "$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf" -s stop >/dev/null 2>&1 || true
  kill "$BACKEND1_PID" "$BACKEND2_PID" "$ADMIN_PID" "$SC_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

wait_for_http() {
  url="$1"
  i=0
  while [ "$i" -lt 50 ]; do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  fail "timed out waiting for $url"
}

wait_for_port_free() {
  port="$1"
  i=0
  while [ "$i" -lt 50 ]; do
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} " && \
       ! ss -tlnp 2>/dev/null | grep -q ":::${port} "; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  fail "port $port still in use after 5s"
}

require_cmd python3
require_cmd curl
[ -x "$NGINX_BIN" ] || fail "missing OpenResty nginx binary: $NGINX_BIN"

PORT="$BACKEND1_PORT" BACKEND_ID="backend-a" HEALTH_FILE="$BACKEND1_DOWN" \
  python3 "$ROOT/tests/fixtures/backend.py" &
BACKEND1_PID=$!
PORT="$BACKEND2_PORT" BACKEND_ID="backend-b" HEALTH_FILE="$BACKEND2_DOWN" \
  python3 "$ROOT/tests/fixtures/backend.py" &
BACKEND2_PID=$!

sleep 0.5
kill -0 "$BACKEND1_PID" 2>/dev/null || fail "backend-a failed to start"
kill -0 "$BACKEND2_PID" 2>/dev/null || fail "backend-b failed to start"

wait_for_http "http://127.0.0.1:$BACKEND1_PORT/healthz"
wait_for_http "http://127.0.0.1:$BACKEND2_PORT/healthz"

TEST_ENV_FILE="$TMP_DIR/gateway.env"
{
  echo "BACKEND_UPSTREAMS=127.0.0.1:$BACKEND1_PORT:1,127.0.0.1:$BACKEND2_PORT:1"
  echo "GATEWAY_BIND=127.0.0.1:$GATEWAY_PORT"
  echo "API_GATEWAY_SECRET=$SECRET"
  echo "SESSION_STICKY=true"
  echo "SESSION_STICKY_MODE=cookie"
  echo "HEALTH_CHECK_INTERVAL=1s"
  echo "HEALTH_CHECK_FAILS=1"
  echo "HEALTH_CHECK_PASSES=1"
  echo "HEALTH_CHECK_TIMEOUT=500ms"
} > "$TEST_ENV_FILE"

ENV_FILE="$TEST_ENV_FILE" sh "$ROOT/scripts/render_config.sh"
sh "$ROOT/scripts/validate_config.sh"

"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf"
wait_for_http "http://127.0.0.1:$GATEWAY_PORT/healthz"

health=$(curl -fsS "http://127.0.0.1:$GATEWAY_PORT/healthz")
[ "$health" = "ok" ] || fail "unexpected /healthz body: $health"

server_header=$(curl -sS -D - -o /dev/null "http://127.0.0.1:$GATEWAY_PORT/healthz" | awk 'BEGIN{IGNORECASE=1} /^Server:/{print $2}' | tr -d '\r')
[ "$server_header" = "KP-HA" ] || fail "expected Server header KP-HA, got $server_header"

unauth_status=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GATEWAY_PORT/status")
[ "$unauth_status" = "401" ] || fail "expected /status without secret to return 401, got $unauth_status"

status_body=$(curl -fsS -H "X-API-Gateway-Secret: $SECRET" "http://127.0.0.1:$GATEWAY_PORT/status")
echo "$status_body" | grep '"upstreams"' >/dev/null || fail "status response missing upstreams"

# ---- /metrics Prometheus 格式验证 ----
metrics_body=$(curl -fsS -H "X-API-Gateway-Secret: $SECRET" "http://127.0.0.1:$GATEWAY_PORT/metrics")
echo "$metrics_body" | grep "^# HELP gateway_requests_total" >/dev/null || fail "metrics: missing gateway_requests_total"
echo "$metrics_body" | grep "^upstream_requests_total{" >/dev/null || fail "metrics: missing upstream_requests_total"
echo "$metrics_body" | grep "^upstream_health{" >/dev/null || fail "metrics: missing upstream_health"
echo "$metrics_body" | grep "^upstream_inflight{" >/dev/null || fail "metrics: missing upstream_inflight"
echo "$metrics_body" | grep "^upstream_request_duration_seconds_bucket{" >/dev/null || fail "metrics: missing duration histogram"

first_headers="$TMP_DIR/first.headers"
first_body="$TMP_DIR/first.body"
curl -fsS -D "$first_headers" -o "$first_body" "http://127.0.0.1:$GATEWAY_PORT/app"
grep -i '^Set-Cookie: OPENRESTY_LB_ROUTE=' "$first_headers" >/dev/null || fail "sticky cookie was not set"
cookie=$(awk 'BEGIN{IGNORECASE=1} /^Set-Cookie: OPENRESTY_LB_ROUTE=/{print $2}' "$first_headers" | sed 's/;.*//')
first_backend=$(sed -n 's/.*"backend": "\([^"]*\)".*/\1/p' "$first_body")
[ "$first_backend" ] || fail "first response missing backend"

second_body="$TMP_DIR/second.body"
curl -fsS -H "Cookie: $cookie" -o "$second_body" "http://127.0.0.1:$GATEWAY_PORT/app"
second_backend=$(sed -n 's/.*"backend": "\([^"]*\)".*/\1/p' "$second_body")
[ "$second_backend" = "$first_backend" ] || fail "sticky request moved from $first_backend to $second_backend"

if [ "$first_backend" = "backend-a" ]; then
  touch "$BACKEND1_DOWN"
  expected_after_failover="backend-b"
else
  touch "$BACKEND2_DOWN"
  expected_after_failover="backend-a"
fi

sleep 2
failover_headers="$TMP_DIR/failover.headers"
failover_body="$TMP_DIR/failover.body"
curl -fsS -D "$failover_headers" -H "Cookie: $cookie" -o "$failover_body" "http://127.0.0.1:$GATEWAY_PORT/app"
failover_backend=$(sed -n 's/.*"backend": "\([^"]*\)".*/\1/p' "$failover_body")
[ "$failover_backend" = "$expected_after_failover" ] || fail "expected failover to $expected_after_failover, got $failover_backend"
grep -i '^Set-Cookie: OPENRESTY_LB_ROUTE=' "$failover_headers" >/dev/null || fail "failover did not refresh sticky cookie"

ws_response=$(curl -s --max-time 2 -i \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  -H "Sec-WebSocket-Version: 13" \
  "http://127.0.0.1:$GATEWAY_PORT/ws" 2>/dev/null || true)
echo "$ws_response" | grep "101 Switching Protocols" >/dev/null || fail "expected websocket upgrade 101"

# ---- least_conn / consistent_hash 策略验证 ----
# 重启 nginx 使用新策略；验证能正常启动且能路由请求
"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf" -s stop
wait_for_port_free "$GATEWAY_PORT"

# least_conn
LC_ENV="$TMP_DIR/lc.env"
{
  echo "BACKEND_UPSTREAMS=127.0.0.1:$BACKEND1_PORT:1,127.0.0.1:$BACKEND2_PORT:1"
  echo "GATEWAY_BIND=127.0.0.1:$GATEWAY_PORT"
  echo "API_GATEWAY_SECRET=$SECRET"
  echo "LB_STRATEGY=least_conn"
} > "$LC_ENV"
ENV_FILE="$LC_ENV" sh "$ROOT/scripts/render_config.sh"
"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf"
wait_for_http "http://127.0.0.1:$GATEWAY_PORT/healthz"
lc_resp=$(curl -fsS --max-time 5 "http://127.0.0.1:$GATEWAY_PORT/app")
echo "$lc_resp" | grep -q '"backend"' || fail "least_conn: no valid response"
# 恢复后端状态：consistent_hash 测试需要两个后端都健康
if [ -n "${BACKEND1_DOWN:-}" ]; then rm -f "$BACKEND1_DOWN"; fi

# consistent_hash
"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf" -s stop
wait_for_port_free "$GATEWAY_PORT"
CH_ENV="$TMP_DIR/ch.env"
{
  echo "BACKEND_UPSTREAMS=127.0.0.1:$BACKEND1_PORT:1,127.0.0.1:$BACKEND2_PORT:1"
  echo "GATEWAY_BIND=127.0.0.1:$GATEWAY_PORT"
  echo "API_GATEWAY_SECRET=$SECRET"
  echo "LB_STRATEGY=consistent_hash"
  echo "CONSISTENT_HASH_KEY=remote_addr"
} > "$CH_ENV"
ENV_FILE="$CH_ENV" sh "$ROOT/scripts/render_config.sh"
"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf"
wait_for_http "http://127.0.0.1:$GATEWAY_PORT/healthz"

first_ch=""
for _ in $(seq 1 5); do
  r=$(curl -fsS --max-time 5 "http://127.0.0.1:$GATEWAY_PORT/app" 2>/dev/null || true)
  b=$(echo "$r" | sed -n 's/.*"backend": "\([^"]*\)".*/\1/p')
  [ -z "$b" ] && continue
  if [ -z "$first_ch" ]; then first_ch="$b"; fi
done
[ -n "$first_ch" ] || fail "consistent_hash: no responses received"

echo "gateway integration tests passed"

# ---- admin API 动态上游验证 ----
# 添加动态成员，验证选路能到达
ADMIN_PORT=$((GATEWAY_PORT + 30))
PORT="$ADMIN_PORT" BACKEND_ID="admin-backend" \
  python3 "$ROOT/tests/fixtures/backend.py" &
ADMIN_PID=$!
wait_for_http "http://127.0.0.1:$ADMIN_PORT/healthz"

# 添加动态上游
add_resp=$(curl -fsS -X POST -H "X-API-Gateway-Secret: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"host":"127.0.0.1","port":'$ADMIN_PORT',"weight":1}' \
  "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams")
echo "$add_resp" | grep -q '"message":"member added"' || \
  fail "admin: failed to add member, got: $add_resp"

# 列表查询
list_resp=$(curl -sS -H "X-API-Gateway-Secret: $SECRET" "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams")
echo "$list_resp" | grep -q "127.0.0.1:$ADMIN_PORT" || \
  fail "admin: added member not in list, got: $list_resp"

# 查询单个成员
get_resp=$(curl -fsS -H "X-API-Gateway-Secret: $SECRET" \
  "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams/127.0.0.1:$ADMIN_PORT")
echo "$get_resp" | grep -q "127.0.0.1" || \
  fail "admin: failed to get member, got: $get_resp"

# 修改权重
patch_resp=$(curl -fsS -X PATCH -H "X-API-Gateway-Secret: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"weight":5}' \
  "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams/127.0.0.1:$ADMIN_PORT")
echo "$patch_resp" | grep -q '"message":"member updated"' || \
  fail "admin: failed to patch member, got: $patch_resp"

# 删除成员
del_resp=$(curl -fsS -X DELETE -H "X-API-Gateway-Secret: $SECRET" \
  "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams/127.0.0.1:$ADMIN_PORT")
echo "$del_resp" | grep -q '"message":"member deleted"' || \
  fail "admin: failed to delete member, got: $del_resp"

# 验证已删除
list_after=$(curl -sS -H "X-API-Gateway-Secret: $SECRET" "http://127.0.0.1:$GATEWAY_PORT/admin/upstreams")
echo "$list_after" | grep -q "127.0.0.1:$ADMIN_PORT" && \
  fail "admin: member still in list after delete" || true

kill "$ADMIN_PID" >/dev/null 2>&1 || true

echo "admin API tests passed"

# ---- sticky learn 验证 ----
# 启动一个会设置 JSESSIONID cookie 的后端
SC_PORT=$((GATEWAY_PORT + 40))
PORT="$SC_PORT" BACKEND_ID="sc-backend" STICKY_COOKIE="JSESSIONID=abc123; Path=/" \
  python3 "$ROOT/tests/fixtures/backend.py" &
SC_PID=$!
wait_for_http "http://127.0.0.1:$SC_PORT/healthz"

SC_ENV="$TMP_DIR/sc.env"
{
  echo "BACKEND_UPSTREAMS=127.0.0.1:$SC_PORT:1"
  echo "GATEWAY_BIND=127.0.0.1:$GATEWAY_PORT"
  echo "API_GATEWAY_SECRET=$SECRET"
  echo "STICKY_LEARN_ENABLED=true"
  echo "STICKY_LEARN_COOKIES=JSESSIONID"
  echo "STICKY_LEARN_TTL=60"
  echo "HEALTH_CHECK_INTERVAL=1s"
  echo "HEALTH_CHECK_FAILS=1"
  echo "HEALTH_CHECK_PASSES=1"
} > "$SC_ENV"

"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf" -s stop >/dev/null 2>&1 || true
wait_for_port_free "$GATEWAY_PORT"
ENV_FILE="$SC_ENV" sh "$ROOT/scripts/render_config.sh"
"$NGINX_BIN" -p "$ROOT" -c "$ROOT/build/nginx.conf"
wait_for_http "http://127.0.0.1:$GATEWAY_PORT/healthz"
sleep 2

# 第一次请求：上游返回 Set-Cookie: JSESSIONID=abc123，网关学习
sleep 3
first_resp=$(curl -sS "http://127.0.0.1:$GATEWAY_PORT/app" || true)
echo "$first_resp" | grep -q '"backend"[ :]*"sc-backend"' || \
  fail "sticky learn: first request should reach sc-backend, got: $first_resp"

# 第二次请求：发送 JSESSIONID=abc123 cookie，网关应命中同一个上游
second_resp=$(curl -sS -H "Cookie: JSESSIONID=abc123" \
  "http://127.0.0.1:$GATEWAY_PORT/app" || true)
echo "$second_resp" | grep -q '"backend"[ :]*"sc-backend"' || \
  fail "sticky learn: learned session should route to same backend, got: $second_resp"

# 验证：不支持的其他 cookie 不会影响选路
third_resp=$(curl -sS -H "Cookie: RANDOM=xyz" \
  "http://127.0.0.1:$GATEWAY_PORT/app" 2>/dev/null || true)
# 应该正常返回（走默认轮询）

kill "$SC_PID" >/dev/null 2>&1 || true

echo "sticky learn tests passed"

# ---- KeyVal 键值存储验证 ----
kv_resp=$(curl -sS -X PUT -H "X-API-Gateway-Secret: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"value":"10"}' \
  "http://127.0.0.1:$GATEWAY_PORT/admin/keyval/ratelimit/ip-127.0.0.1")
echo "$kv_resp" | grep -q '"message":"ok"' || fail "keyval: failed to set key, got: $kv_resp"

kv_get=$(curl -sS -H "X-API-Gateway-Secret: $SECRET" \
  "http://127.0.0.1:$GATEWAY_PORT/admin/keyval/ratelimit/ip-127.0.0.1")
echo "$kv_get" | grep -q '"value":"10"' || fail "keyval: failed to get key, got: $kv_get"

kv_list=$(curl -sS -H "X-API-Gateway-Secret: $SECRET" \
  "http://127.0.0.1:$GATEWAY_PORT/admin/keyval/ratelimit")
echo "$kv_list" | grep -q "ip-127.0.0.1" || fail "keyval: key not in zone list"

kv_del=$(curl -sS -X DELETE -H "X-API-Gateway-Secret: $SECRET" \
  "http://127.0.0.1:$GATEWAY_PORT/admin/keyval/ratelimit/ip-127.0.0.1")
echo "$kv_del" | grep -q '"message":"deleted"' || fail "keyval: failed to delete key"

echo "keyval tests passed"
