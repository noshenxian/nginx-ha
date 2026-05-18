# AGENTS.md

## 基本要求

- 始终使用简体中文回复用户。
- 在开始任何任务前，先运行 `~/.codex/superpowers/.codex/superpowers-codex bootstrap`，并遵循其返回的技能使用要求。
- 优先读取本文件、现有 README、脚本、配置和测试，再做实现判断。
- 不要回滚用户已有改动；如果工作区出现无关改动，忽略它们。
- 修改文件前说明将要修改的范围；完成后说明实际修改、验证命令和剩余风险。

## 项目目标

本项目要基于 OpenResty 实现一个可在项目内直接使用的生产可用负载均衡网关。实现应以配置可生成、可测试、可观测、可运维为核心，而不是只写一份静态 nginx 配置。

## 目标能力

负载均衡应覆盖以下能力：

- HTTP/HTTPS 反向代理。
- 多上游服务池配置。
- 加权轮询作为默认策略。
- 会话保持：默认支持 cookie 粘滞会话，并支持按 Header、Cookie 或客户端 IP 哈希绑定到固定上游。
- 支持 least_conn 或一致性哈希等可选策略；若 OpenResty 原生能力不足，优先使用清晰的 Lua 实现并补充测试。
- 主动健康检查，并结合被动失败剔除；健康状态变化必须影响负载均衡选路。
- 上游失败重试、超时、熔断或降级策略。
- 请求头透传与标准代理头：`Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto`、请求 ID。
- WebSocket 升级支持。
- gzip、连接复用、keepalive、合理的 buffer 与 timeout。
- 静态健康检查端点，例如 `/healthz`。
- 网关状态或指标端点，例如 `/status` 或 `/metrics`，至少能观察上游健康状态、请求量、错误量。
- 结构化访问日志与错误日志，包含请求 ID、上游地址、上游响应时间、状态码。
- 通过 `.env` 和模板配置渲染生成最终 OpenResty 配置。
- 本地开发启动脚本、配置渲染脚本和验证脚本。
- Docker 或 docker compose 运行方式。
- 自动化测试覆盖配置渲染、nginx 配置语法、代理转发、健康检查、失败切换。

## 推荐项目结构

除非已有代码结构明确不同，否则按以下结构推进：

```text
.
├── AGENTS.md
├── README.md
├── conf/
│   ├── nginx.conf
│   ├── gateway.conf
│   └── upstreams.conf
├── lua/
│   ├── balancer.lua
│   ├── healthcheck.lua
│   ├── metrics.lua
│   └── request_id.lua
├── scripts/
│   ├── render_config.sh
│   ├── validate_config.sh
│   └── smoke_test.sh
├── tests/
│   ├── test_gateway.sh
│   └── fixtures/
├── docker-compose.yml
└── Dockerfile
```

可以合并过度拆分的文件，但不要把所有逻辑塞进单个 nginx 配置文件。

## 配置约定

实现时优先通过项目根目录 `.env` 配置这些变量；脚本也可用 `ENV_FILE=/path/to/.env` 指定其他配置文件：

- `GATEWAY_BIND`：网关监听地址，默认 `0.0.0.0:8080`。
- `BACKEND_UPSTREAMS`：上游列表，格式建议为 `host1:port:weight,host2:port:weight`。
- `BACKEND_UPSTREAM`：兼容单上游或简化场景。
- `LB_STRATEGY`：负载均衡策略，可选 `round_robin`（加权轮询）、`ip_hash`（IP 哈希）、`least_conn`（最少连接）、`consistent_hash`（一致性哈希 ketama），默认 `round_robin`。
- `CONSISTENT_HASH_KEY`：一致性哈希选路 key 来源，可选 `remote_addr`（默认）、`cookie`、`header`（需配合 `CONSISTENT_HASH_HEADER`）、`uri`。
- `CONSISTENT_HASH_HEADER`：当 `CONSISTENT_HASH_KEY=header` 时，读取的 Header 名称。
- `UPSTREAM_MAX_CONNS`：每上游最大并发连接数，超过则返回 503，设为 `0` 关闭（默认）。
- `SESSION_STICKY`：是否启用会话保持，默认 `true`。
- `SESSION_STICKY_MODE`：会话保持模式，默认 `cookie`，可选 `cookie`、`header`、`ip_hash`。
- `SESSION_COOKIE_NAME`：粘滞会话 cookie 名称，默认 `OPENRESTY_LB_ROUTE`。
- `SESSION_HEADER_NAME`：Header 粘滞会话字段名，默认 `X-Session-ID`。
- `SESSION_TTL`：会话保持有效期，默认 `3600s`。
- `PROXY_CONNECT_TIMEOUT`：连接超时，默认 `3s`。
- `PROXY_READ_TIMEOUT`：读取超时，默认 `30s`。
- `PROXY_SEND_TIMEOUT`：发送超时，默认 `30s`。
- `HEALTH_CHECK_ENABLED`：是否启用主动健康检查，默认 `true`。
- `HEALTH_CHECK_INTERVAL`：健康检查间隔，默认 `5s`。
- `HEALTH_CHECK_PATH`：上游健康检查路径，默认 `/healthz`。
- `HEALTH_CHECK_TIMEOUT`：健康检查请求超时，默认 `2s`。
- `HEALTH_CHECK_FAILS`：连续失败多少次后标记为不健康，默认 `3`。
- `HEALTH_CHECK_PASSES`：连续成功多少次后恢复健康，默认 `2`。
- `HEALTH_CHECK_STATUS_CODES`：健康检查接受的 HTTP 状态码范围，格式 `200,201,300-399`，默认 `200-399`。
- `HEALTH_CHECK_BODY_MATCH`：body 正则，匹配则判健康；可与 `HEALTH_CHECK_BODY_MATCH_NEGATE` 配合做排除。
- `HEALTH_CHECK_BODY_MATCH_NEGATE`：`true` 时 body 匹配正则则判不健康。
- `HEALTH_CHECK_HEADER_NAME` + `HEALTH_CHECK_HEADER_MATCH`：指定响应 header 名称和 value 正则，两者同时设置时匹配才判健康。
- `HEALTH_CHECK_MANDATORY`：`true` 时新加入的上游默认不健康，必须通过健康检查才能接收流量。
- `TLS_CERT_FILE`：HTTPS 证书路径；未设置时只启用 HTTP。
- `TLS_KEY_FILE`：HTTPS 私钥路径；未设置时只启用 HTTP。
- `API_GATEWAY_SECRET`：保护管理或状态端点的共享密钥；不要在日志中打印。

配置渲染必须先加载 `.env`，有默认值，并在缺少关键上游配置时失败退出。

## 实现原则

- 首选 OpenResty/nginx 原生能力；只有在原生能力无法满足项目目标时才引入 Lua。
- Lua 模块保持小而清晰，避免全局可变状态失控。
- 所有输入配置都要校验，错误信息要能定位具体变量或配置项。
- 代理转发必须保留原始请求方法、路径、查询参数和请求体。
- 会话保持不能把请求固定到已判定不健康的上游；原绑定上游故障时必须重新选择健康上游并刷新绑定。
- 健康检查状态必须有内存共享区或等价机制存储，避免 worker 之间状态不一致。
- 默认配置应适合内网服务网关，不默认暴露危险管理端点到公网。
- 所有状态端点默认只监听本地或需要密钥访问。
- 不引入不必要的第三方依赖；确需依赖时说明理由。
- 不把密钥、内网地址、真实生产域名写死进仓库。

## 测试与验证

实现或修改后至少运行：

```bash
scripts/render_config.sh
scripts/validate_config.sh
tests/test_gateway.sh
```

如果项目使用 Docker，还要验证：

```bash
docker compose up --build
```

测试至少覆盖：

- 配置渲染成功与缺少上游配置失败。
- OpenResty 配置语法检查通过。
- 正常代理请求能到达上游。
- 多上游请求能按策略分布。
- 开启会话保持后，同一 cookie、Header 或客户端标识连续请求应命中同一健康上游。
- 会话绑定的上游变为不健康后，请求应迁移到其他健康上游，并更新 cookie 或绑定状态。
- 一个上游失败后，请求能切换到健康上游。
- 主动健康检查能按失败阈值标记不健康，并按恢复阈值重新接纳上游。
- `/healthz` 返回 200。
- `/status` 或 `/metrics` 能返回有效状态，并且未授权访问被拒绝。
- WebSocket 升级请求不被破坏。

## 文档要求

README 至少包含：

- 项目用途与架构说明。
- 快速启动命令。
- 环境变量说明。
- 示例上游配置。
- 会话保持模式、cookie 行为、故障迁移行为说明。
- 健康检查、指标、日志说明。
- 本地测试命令。
- 常见故障排查。

## 审核标准

审核实现时优先检查：

- 是否真的基于 OpenResty 可运行，而不是只提交伪配置。
- 配置是否可渲染、可验证、可重复部署。
- 变量是否集中来自 `.env` 或 `ENV_FILE` 指定文件，而不是散落在脚本或 Compose 中。
- 负载均衡、会话保持、失败切换、健康检查是否有自动化验证。
- 会话保持是否会错误绑定到不健康上游，健康恢复后是否能重新参与调度。
- 是否存在默认暴露管理端点、泄露密钥、绕过访问控制等安全问题。
- 超时、重试、buffer、日志是否有合理默认值。
- Docker 和本地脚本是否与 README 一致。
- 测试是否能在干净环境中运行。

## 交付格式

每次完成任务时，用简短中文说明：

- 修改了哪些文件。
- 实现了哪些能力。
- 运行了哪些验证命令及结果。
- 未完成项或需要用户确认的风险。

## 待办事项

- [x] **queue 排队替代直接 503**：`UPSTREAM_QUEUE_SIZE` + `UPSTREAM_QUEUE_TIMEOUT`，用 `ngx.semaphore` + timer 实现等待队列，max_conns 满时排队而非立即拒绝
- [ ] **gRPC / TCP 主动健康检查**：`healthcheck.lua` 扩展 `check_one`，支持 gRPC `Health/Check` 协议和裸 TCP connect
- [ ] **Circuit breaker 熔断**：连续失败达到阈值后短路一段时间，指数退避恢复探测，保护上游防雪崩
- [ ] **多 upstream group**：扩展为 `BACKEND_UPSTREAMS_app`、`BACKEND_UPSTREAMS_api`，location 级别通过变量切换 upstream 组
- [ ] **限流集成**：`access_by_lua` 加 `lua-resty-limit-conn` / `lua-resty-limit-req`，配合 KeyVal 动态更新白名单/黑名单/限速额度
- [ ] **可观测性增强**：`$upstream_last_addr` 等效变量记入 access log；`/metrics` 加 p50/p90/p99 latency；健康状态变更事件结构化日志
- [ ] **CI + 压测**：GitHub Actions 跑 `render + validate + test_gateway.sh`；`wrk`/`vegeta` 压测脚本验证 least_conn / max_conns / slow_start
