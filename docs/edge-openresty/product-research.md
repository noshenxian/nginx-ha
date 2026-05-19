# OpenResty Edge 产品调研

## 产品定位

OpenResty Edge 是 OpenResty Inc. 的商业化分布式网关/流量管理平台，面向多云和微服务架构。定位为负载均衡器、CDN 网络、API 网关的增强层，可直接安装在现有网关服务器上。

主要竞品对标：Nginx Plus、F5、Kong、APISIX。

## 产品形态

**纯软件，闭源商业产品。** 提供免费试用（试用 license），按节点/集群规模授权。

### 部署模式

| 模式 | 说明 |
|------|------|
| 主机部署 | Linux 直接安装（支持离线环境） |
| Kubernetes | K8s 内运行 Admin、Gateway Node、Log Server |
| Docker | 容器化部署 |

## 核心组件架构

```
┌──────────────────────────────────────────────────┐
│                  Edge Admin                        │
│         (Web 管理控制台 / REST API)                │
├──────────────────────────────────────────────────┤
│  PostgreSQL DB  │  Log Server  │  DNS Server       │
├──────────────────────────────────────────────────┤
│          Gateway Nodes (集群, 50-500+ 节点)        │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐           │
│  │ Node 1  │  │ Node 2  │  │ Node N  │  ...      │
│  │ (Nginx  │  │ (Nginx  │  │ (Nginx  │           │
│  │  + Lua) │  │  + Lua) │  │  + Lua) │           │
│  └─────────┘  └─────────┘  └─────────┘           │
└──────────────────────────────────────────────────┘
```

### 各部分职责

- **Edge Admin**：Web 控制台，管理所有配置；提供 Token-based REST API
- **Gateway Node**：承载真实流量的 OpenResty/Nginx 节点，运行 LuaJIT 增强引擎
- **Log Server**：集中日志收集与存储
- **DNS Server**：内置权威 DNS 服务器，支持 GeoDNS
- **PostgreSQL**：配置存储中心（支持 HA 集群）

## 功能矩阵

### 1. 流量管理

| 功能 | 说明 |
|------|------|
| **Page Rules 引擎** | 条件-动作规则引擎，支持变量、运算符、时间条件、文件上传检测等 |
| **负载均衡** | 动态 upstream 管理，主动健康检查 |
| **GSLB** | 全局服务器负载均衡，跨数据中心流量调度 |
| **HTTPDNS** | HTTP-based DNS 解析 |
| **代理缓存** | 集群级别分层响应缓存，支持自定义条件实时清除 |
| **速率限制** | 请求级和 SSL 握手级限流（rate/count/delay/block） |
| **熔断** | Circuit breaking |
| **请求镜像** | Request mirroring |
| **WebSocket 代理** | 双向 WebSocket 代理 |
| **HTTP/3, HTTP/2, HTTP/1.x** | 动态协议切换 |
| **TCP/SNI/SOCKS5 代理** | 多协议代理支持 |
| **SD-WAN** | 多层软件定义广域网路由 |

### 2. WAF（Web 应用防火墙）

- 高性能 WAF，支持动态规则配置
- 按应用和全局规则的层级管理
- IP 白名单/黑名单
- 验证码挑战（Captcha）
- 专用 WAF 日志
- 声称日拦截 1000+ 攻击（客户案例）

### 3. SSL/TLS 证书管理

- 全局和应用级证书管理
- 客户端证书验证
- Let's Encrypt / ACME/ACMEv2 自动签发和续期
- 自定义证书颁发者
- 源站证书管理
- 证书过期监控告警

### 4. 安全认证

- Basic Auth
- OpenID Connect
- OAuth2（JWT / Introspection）
- CSRF 保护
- JA4 指纹识别
- IP 地理定位数据库

### 5. 开发者能力

| 能力 | 说明 |
|------|------|
| **LuaJIT 增强** | 沙箱保护的 LuaJIT，支持高级 Lua 调试 |
| **WebAssembly** | 支持非阻塞 IO 的 WASM |
| **Fanlang / OpsLang** | 自研脚本语言 |
| **高性能客户端库** | Redis、MySQL、PostgreSQL、gRPC、HTTP/2、LDAP、Memcache、ZeroMQ 等 |
| **流式正则替换** | 响应体流式正则替换引擎 |
| **SchemaLang** | 数据模型生成器 |

### 6. 配置与管理

| 能力 | 说明 |
|------|------|
| **Web 控制台** | 集中管理大规模服务器集群 |
| **无重启生效** | 配置变更不需 reload/restart 服务 |
| **增量同步** | 配置增量同步到多节点 |
| **版本控制** | 配置/代码版本管理，支持回滚 |
| **YAML/Git 管理** | 通过 `edge2yaml` 实现 Infrastructure-as-Code |
| **CLI (`oredge`)** | 命令行工具覆盖 app/cache/gateway/dns/certs/waf/page-rules/k8s/upstreams/webhooks |
| **Python/PHP SDK** | 编程接口 |
| **A/B 测试发布** | 灰度发布能力 |
| **分区网络** | 多层网络分区支持 |

### 7. 可观测性

- 实时内存指标查询（类 SQL 语法）
- 网络范围响应状态码和错误日志统计
- 错误日志自动聚合分析
- 告警与会话管理
- OpenTelemetry 集成
- 自定义 Access Log 变量（Edge 扩展变量）

### 8. 高可用

- 数据库集群（PostgreSQL HA）
- Keepalived 实现网关 VIP
- 多层网络冗余
- 配置变更二次确认防误操作
- 环境克隆
- 备份与恢复工具

## 技术亮点

### 零停机配置
配置变更不需要 Nginx reload/restart，这是与开源 Nginx/OpenResty 的核心差异之一。通过 Lua 层面的动态配置实现。

### 性能
- 声称并发能力是 Nginx 和 Apache 的 5-6 倍
- 通过 JIT 编译优化实现高性能

### 集群规模
- 支持从 50 到 500+ 节点的集群部署
- 客户案例：每小时处理 2000 万+ 请求
- 每分钟数千次缓存清除

## 客户案例摘要

| 客户 | 效果 |
|------|------|
| **Qunar.com** | 运维成本降低 90%，亚秒级 reload |
| **Innovie GmbH** | 可扩展、可定制的网关，性能最大化的产品 |
| **某未具名客户** | 方案成本比 F5 降低 80%，运维人员从 7 人减至 1 人，平均响应时间改善 100+ms |

## 许可证与竞争定位

- **商业闭源**，不是开源 OpenResty 的一部分
- 开源 OpenResty 是其底层引擎，Edge 是上层管理平台
- 定位在 Nginx Plus / F5 的高性价比替代品
- 与 Kong / APISIX 同属 API 网关领域但更偏边缘流量管理层

## 管理接口总结

1. **Edge Admin Web 控制台** — 日常运维操作
2. **`oredge` CLI** — 自动化/脚本场景
3. **YAML 配置镜像** — GitOps/IaC 工作流
4. **Python/PHP SDK** — 编程集成
5. **REST API** — Token 认证的 API 访问

## 信息来源

- [OpenResty Edge 产品页](https://openresty.com/en/edge/)
- [OpenResty Edge 文档](https://doc.openresty.com/en/edge/)
- [OpenResty 主页](https://openresty.com/en/)
