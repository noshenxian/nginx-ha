# OpenResty Load Balancer

基于 OpenResty 的项目内负载均衡网关，支持多上游、会话保持、主动健康检查、失败切换、WebSocket、结构化日志和状态端点。

## 快速启动

先准备 `.env`：

```bash
cp .env.example .env
```

本机 OpenResty：

```bash
sh ./start.sh
```

Docker Compose 会通过 `.env` 注入网关变量：

```bash
docker compose up --build
```

访问：

```bash
curl http://127.0.0.1:8080/healthz
curl -H "X-API-Gateway-Secret: change-me" http://127.0.0.1:8080/status
```

## 配置

所有网关变量从项目根目录 `.env` 读取。需要使用其他配置文件时，设置 `ENV_FILE`：

```bash
ENV_FILE=/path/to/prod.env sh ./start.sh
```

主要变量：

- `GATEWAY_BIND`：监听地址，默认 `0.0.0.0:8080`。
- `BACKEND_UPSTREAMS`：上游列表，格式 `host:port:weight,host:port:weight`。
- `BACKEND_UPSTREAM`：单上游兼容配置。
- `LB_STRATEGY`：负载均衡策略，可选 `round_robin`（加权轮询）、`ip_hash`、`least_conn`（最少连接）、`consistent_hash`（一致性哈希），默认 `round_robin`。
- `CONSISTENT_HASH_KEY`：一致性哈希 key 来源，可选 `remote_addr`（默认）、`cookie`、`header`、`uri`。
- `SLOW_START_WINDOW`：慢启动窗口秒数，`0` 关闭（默认）。
- `HEALTH_CHECK_STATUS_CODES`：健康检查接受的状态码范围，格式 `200,201,300-399`。
- `HEALTH_CHECK_BODY_MATCH`：body 正则，匹配则判健康。
- `HEALTH_CHECK_HEADER_NAME` / `HEALTH_CHECK_HEADER_MATCH`：header 名称和 value 正则匹配。
- `HEALTH_CHECK_MANDATORY`：`true` 时新成员必须先通过健康检查才能接流量。
- `SESSION_STICKY`：是否启用会话保持，默认 `true`。
- `SESSION_STICKY_MODE`：`cookie`、`header`、`ip_hash`，默认 `cookie`。
- `SESSION_COOKIE_NAME`：默认 `OPENRESTY_LB_ROUTE`。
- `SESSION_HEADER_NAME`：默认 `X-Session-ID`。
- `SESSION_TTL`：cookie 有效期，默认 `3600s`。
- `HEALTH_CHECK_ENABLED`：是否启用主动健康检查，默认 `true`。
- `HEALTH_CHECK_INTERVAL`：健康检查间隔，默认 `5s`。
- `HEALTH_CHECK_PATH`：上游健康检查路径，默认 `/healthz`。
- `HEALTH_CHECK_TIMEOUT`：健康检查超时，默认 `2s`。
- `HEALTH_CHECK_FAILS`：连续失败阈值，默认 `3`。
- `HEALTH_CHECK_PASSES`：连续恢复阈值，默认 `2`。
- `HEALTH_CHECK_STATUS_CODES`：健康检查接受的状态码范围，默认 `200-399`。
- `HEALTH_CHECK_BODY_MATCH`：body 正则，匹配则判健康。
- `HEALTH_CHECK_HEADER_NAME` / `HEALTH_CHECK_HEADER_MATCH`：header 名称和 value 正则匹配。
- `HEALTH_CHECK_MANDATORY`：`true` 时新成员必须先通过健康检查才能接流量。
- `PROXY_CONNECT_TIMEOUT`：默认 `3s`。
- `PROXY_READ_TIMEOUT`：默认 `30s`。
- `PROXY_SEND_TIMEOUT`：默认 `30s`。
- `DNS_RESOLVER`：nginx/Lua 解析上游域名使用的 DNS，Docker 内默认可用 `127.0.0.11 ipv6=off valid=10s`。
- `TLS_CERT_FILE` / `TLS_KEY_FILE`：同时设置后启用 HTTPS 证书配置。
- `API_GATEWAY_SECRET`：保护 `/status` 的密钥。

`API_GATEWAY_SECRET` 不能为空；生产环境必须替换 `.env.example` 里的示例值。

## 会话保持

默认使用 cookie 粘滞会话。首次请求会设置 `OPENRESTY_LB_ROUTE=<host:port>`，后续请求会优先命中同一健康上游。若绑定上游被健康检查标记为不健康，网关会选择其他健康上游并刷新 cookie。

`header` 模式使用 `SESSION_HEADER_NAME` 指定的 Header 做哈希绑定。`ip_hash` 模式使用客户端地址绑定。

## 健康检查

worker 启动后会按 `HEALTH_CHECK_INTERVAL` 主动请求每个上游的 `HEALTH_CHECK_PATH`。连续失败达到 `HEALTH_CHECK_FAILS` 后，上游会被标记为 `unhealthy` 并从选路中剔除；连续成功达到 `HEALTH_CHECK_PASSES` 后恢复参与调度。

## 状态和日志

`/healthz` 返回网关自身状态。

`/status` 返回上游健康状态、权重、请求计数和错误计数，需要 `X-API-Gateway-Secret`。

访问日志是 JSON，包含请求 ID、客户端地址、方法、URI、状态码、上游地址和耗时。

## 测试

```bash
sh ./scripts/render_config.sh
sh ./scripts/validate_config.sh
sh ./tests/test_gateway.sh
```

`tests/test_gateway.sh` 会启动两个本地 Python 后端，并验证配置渲染、nginx 语法、状态鉴权、cookie 会话保持、健康检查失败切换和 WebSocket 升级。

## 嵌入已有 OpenResty 或自编译 nginx

完整能力需要 OpenResty 或带 `ngx_http_lua_module`、`headers-more`、`lua-resty-dns` 的自编译 nginx。集成说明见：

```text
docs/embedded-openresty-nginx.md
embedded/openresty/
```

普通 nginx 只能使用降级版：

```text
embedded/plain-nginx/kp_ha_basic.conf
```

## 故障排查

- `BACKEND_UPSTREAMS or BACKEND_UPSTREAM is required`：没有配置上游。
- `API_GATEWAY_SECRET is required`：没有配置状态端点密钥。
- `/status` 返回 401：缺少或错误的 `X-API-Gateway-Secret`。
- 请求返回 503：所有上游都被标记为不健康，检查上游 `/healthz`、端口和健康检查阈值。
- 配置验证失败：查看 `build/nginx.conf` 和 `logs/error.log`。
