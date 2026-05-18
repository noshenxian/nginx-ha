# OpenResty Load Balancer

基于 OpenResty 的负载均衡网关，对齐 NGINX Plus 能力。支持多上游、多种负载均衡策略、主动健康检查、会话保持、动态上游管理、Redis 跨节点同步、熔断和限流。

## 快速启动

```bash
cp .env.example .env
# 编辑 .env，至少填写 BACKEND_UPSTREAMS 和 API_GATEWAY_SECRET
sh ./start.sh
```

Docker Compose：

```bash
docker compose up --build
```

验证：

```bash
curl http://127.0.0.1:8080/healthz
curl -H "X-API-Gateway-Secret: change-me" http://127.0.0.1:8080/status
```

## 配置

所有变量从 `.env` 读取。也可指定其他文件：

```bash
ENV_FILE=/path/to/prod.env sh ./start.sh
```

### 必须

| 变量 | 说明 |
|---|---|
| `BACKEND_UPSTREAMS` | 上游列表，格式 `host:port:weight,...` |
| `API_GATEWAY_SECRET` | 保护 `/status` `/metrics` `/admin` 的密钥 |

### 负载均衡

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LB_STRATEGY` | `round_robin` | `round_robin` / `ip_hash` / `least_conn` / `consistent_hash` |
| `CONSISTENT_HASH_KEY` | `remote_addr` | 一致性哈希 key 来源：`remote_addr` / `cookie` / `header` / `uri` |
| `SLOW_START_WINDOW` | `0` | 慢启动窗口秒数，`0` 关闭 |

### 会话保持

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SESSION_STICKY` | `true` | 是否启用 |
| `SESSION_STICKY_MODE` | `cookie` | `cookie` / `header` / `ip_hash` |
| `SESSION_COOKIE_NAME` | `OPENRESTY_LB_ROUTE` | cookie 名称 |
| `SESSION_TTL` | `3600s` | cookie 有效期 |

首次请求设置 `OPENRESTY_LB_ROUTE=<host:port>` cookie，后续命中同一健康上游。若绑定上游故障，自动切换并刷新 cookie。

### 健康检查

| 变量 | 默认值 | 说明 |
|---|---|---|
| `HEALTH_CHECK_ENABLED` | `true` | 是否启用 |
| `HEALTH_CHECK_TYPE` | `http` | `http` / `tcp` / `grpc` |
| `HEALTH_CHECK_INTERVAL` | `5s` | 检查间隔 |
| `HEALTH_CHECK_PATH` | `/healthz` | 检查路径 |
| `HEALTH_CHECK_TIMEOUT` | `2s` | 检查超时 |
| `HEALTH_CHECK_FAILS` | `3` | 标记 unhealthy 的连续失败数 |
| `HEALTH_CHECK_PASSES` | `2` | 恢复 healthy 的连续成功数 |
| `HEALTH_CHECK_STATUS_CODES` | `200-399` | 接受的状态码范围 |
| `HEALTH_CHECK_BODY_MATCH` | — | body 正则匹配 |
| `HEALTH_CHECK_HEADER_NAME` | — | header 名称匹配 |
| `HEALTH_CHECK_HEADER_MATCH` | — | header value 正则匹配 |
| `HEALTH_CHECK_MANDATORY` | `false` | 新成员默认 unhealthy，先过检再接流量 |

### 容量控制

| 变量 | 默认值 | 说明 |
|---|---|---|
| `UPSTREAM_MAX_CONNS` | `0` | 每上游最大并发连接数，`0` 不限 |
| `UPSTREAM_QUEUE_SIZE` | `0` | 排队容量，`0` 不排队 |
| `UPSTREAM_QUEUE_TIMEOUT` | `30` | 排队超时秒数 |

### 熔断

| 变量 | 默认值 | 说明 |
|---|---|---|
| `CIRCUIT_BREAKER_ENABLED` | `false` | 是否启用 |
| `CIRCUIT_BREAKER_FAILS` | `5` | 连续失败 N 次后断路 |
| `CIRCUIT_BREAKER_TIMEOUT` | `30` | 断路超时后半开探测的秒数 |

### 限流

| 变量 | 默认值 | 说明 |
|---|---|---|
| `RATE_LIMIT_ENABLED` | `false` | 是否启用 |
| `RATE_LIMIT_RATE` | `10` | 速率，如 `100r/s` |
| `RATE_LIMIT_BURST` | `20` | 突发容量 |
| `RATE_LIMIT_KEY` | `remote_addr` | 限流 key：`remote_addr` / `header` |

通过 KeyVal `/admin/keyval/ratelimit/whitelist/<ip>` 设置白名单。

### Sticky Learn

| 变量 | 默认值 | 说明 |
|---|---|---|
| `STICKY_LEARN_ENABLED` | `false` | 是否从上游 Set-Cookie 自动学习会话标识 |
| `STICKY_LEARN_COOKIES` | `JSESSIONID,PHPSESSID` | 要学习的 cookie 名称 |
| `STICKY_LEARN_TTL` | `3600` | 会话绑定有效期秒数 |

### Redis 跨节点同步

| 变量 | 默认值 | 说明 |
|---|---|---|
| `REDIS_ENABLED` | `false` | 是否启用 |
| `REDIS_HOST` | `127.0.0.1` | Redis 地址 |
| `REDIS_PORT` | `6379` | Redis 端口 |
| `REDIS_PASSWORD` | — | Redis 密码 |
| `REDIS_DB` | `0` | Redis 数据库 |

启用后：sticky learn 会话表 L2 写 Redis，其他节点可读取；动态上游变更同步 Redis 版本号，各节点 10s 轮询。

### 代理与网络

| 变量 | 默认值 | 说明 |
|---|---|---|
| `GATEWAY_BIND` | `0.0.0.0:8080` | 监听地址 |
| `PROXY_CONNECT_TIMEOUT` | `3s` | 连接超时 |
| `PROXY_READ_TIMEOUT` | `30s` | 读取超时 |
| `PROXY_SEND_TIMEOUT` | `30s` | 发送超时 |
| `DNS_RESOLVER` | `127.0.0.11 ipv6=off valid=10s` | DNS 解析器 |
| `TLS_CERT_FILE` | — | HTTPS 证书路径 |
| `TLS_KEY_FILE` | — | HTTPS 私钥路径 |

## 多上游组

定义多组上游，在 location 级别切换：

```bash
# .env
BACKEND_UPSTREAMS_app=10.0.0.1:8080:2,10.0.0.2:8080:1
BACKEND_UPSTREAMS_api=10.0.0.10:8080:1,10.0.0.11:8080:1
```

```nginx
# conf/nginx.conf.template
location /app/ {
    set $upstream_group app;
    # ...
}
location /api/ {
    set $upstream_group api;
    # ...
}
```

不设 `$upstream_group` 时使用默认 `BACKEND_UPSTREAMS`。

## 端点

| 路径 | 鉴权 | 说明 |
|---|---|---|
| `/` | — | 代理到上游 |
| `/healthz` | — | 网关自身健康检查 |
| `/status` | `X-API-Gateway-Secret` | 上游健康/权重/请求计数（JSON） |
| `/metrics` | `X-API-Gateway-Secret` | Prometheus 格式指标 |
| `/admin/upstreams` | `X-API-Gateway-Secret` | 动态上游 CRUD |
| `/admin/keyval/<zone>/<key>` | `X-API-Gateway-Secret` | 键值存储 CRUD |

### Admin API 示例

```bash
# 添加上游
curl -X POST -H "X-API-Gateway-Secret: change-me" \
  -H "Content-Type: application/json" \
  -d '{"host":"10.0.0.5","port":8080,"weight":2}' \
  http://127.0.0.1:8080/admin/upstreams

# 查看所有动态上游
curl -H "X-API-Gateway-Secret: change-me" http://127.0.0.1:8080/admin/upstreams

# 修改权重
curl -X PATCH -H "X-API-Gateway-Secret: change-me" \
  -H "Content-Type: application/json" \
  -d '{"weight":0}' \
  http://127.0.0.1:8080/admin/upstreams/10.0.0.5:8080

# 删除
curl -X DELETE -H "X-API-Gateway-Secret: change-me" \
  http://127.0.0.1:8080/admin/upstreams/10.0.0.5:8080
```

## 压测

```bash
# 本地 wrk
GATEWAY_URL=http://127.0.0.1:8080 bash scripts/benchmark.sh 30 1000

# Docker
docker run --rm --network host williamyeh/wrk \
  -t4 -c100 -d30s -R1000 --latency http://127.0.0.1:8080/app
```

## 测试

```bash
sh ./scripts/render_config.sh
sh ./scripts/validate_config.sh
sh ./tests/test_gateway.sh
```

集成测试覆盖：配置渲染、语法验证、加权轮询、least_conn、一致性哈希、cookie 粘滞会话、故障切换、WebSocket、Prometheus `/metrics`、admin CRUD、sticky learn、Redis 同步、KeyVal、TCP 健康检查。

## 嵌入已有 OpenResty

```text
docs/embedded-openresty-nginx.md
embedded/openresty/
```

普通 nginx 降级版：`embedded/plain-nginx/kp_ha_basic.conf`（无主动健康检查、无动态上游）。

## 故障排查

- `BACKEND_UPSTREAMS or BACKEND_UPSTREAM is required`：未配置上游。
- `API_GATEWAY_SECRET is required`：未配置管理密钥。
- `/status` 返回 401：缺少或错误的 `X-API-Gateway-Secret`。
- 请求返回 503：所有上游不健康，检查上游 `/healthz`、端口和健康检查阈值。
- 请求返回 429：触发限流。
- 配置验证失败：查看 `build/nginx.conf` 和 `logs/error.log`。
