#!/usr/bin/env sh
set -eu

# 压测脚本：wrk2 恒定速率压测
# 用法: bash scripts/benchmark.sh [duration_sec] [rate]
# 默认 30 秒，1000 req/s

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DURATION="${1:-30}"
RATE="${2:-1000}"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8080}"

command -v wrk >/dev/null 2>&1 || {
  echo "wrk not found. Install: https://github.com/wg/wrk" >&2
  echo "Or use: docker run --rm --network host williamyeh/wrk -t4 -c100 -d${DURATION}s --latency ${GATEWAY_URL}/app" >&2
  exit 1
}

echo "=== Benchmark: ${GATEWAY_URL}/app ==="
echo "Duration: ${DURATION}s, Rate: ${RATE} req/s (constant)"

wrk -t4 -c100 -d"${DURATION}"s -R"${RATE}" --latency "${GATEWAY_URL}/app"

echo ""
echo "=== /status ==="
curl -s -H "X-API-Gateway-Secret: change-me" "${GATEWAY_URL}/status" 2>/dev/null | python3 -m json.tool 2>/dev/null || true

echo ""
echo "=== /metrics ==="
curl -s -H "X-API-Gateway-Secret: change-me" "${GATEWAY_URL}/metrics" 2>/dev/null | grep -E "^(upstream_requests_total|upstream_request_duration_seconds)" | head -10
