# 嵌入已有 OpenResty / 自编译 nginx

## 结论

已有 OpenResty 可以直接集成 KP-HA 的核心能力。把 `lua/` 模块复制到目标机器，再把 `embedded/openresty/*.conf` 按说明 include 到现有 `nginx.conf` 即可。

自编译 nginx 也可以，但必须编入这些能力：

- `ngx_http_lua_module`
- `ngx_http_headers_more_filter_module`
- `lua-resty-dns`
- `ngx.balancer` 可用的 cosocket/balancer 支持

如果只是普通 nginx，没有 Lua 模块，则只能使用 `embedded/plain-nginx/kp_ha_basic.conf` 的降级版：有基础负载均衡、被动失败切换、`ip_hash/hash` 等原生能力，但没有主动健康检查、cookie/header 粘滞会话、动态上游、`/status` 指标。

## 完整功能版集成步骤

1. 复制 Lua 模块：

```bash
mkdir -p /opt/kp-ha/lua
cp lua/*.lua /opt/kp-ha/lua/
cp embedded/openresty/runtime_config.lua.example /opt/kp-ha/lua/runtime_config.lua
```

2. 编辑 `/opt/kp-ha/lua/runtime_config.lua`：

```lua
return {
  BACKEND_UPSTREAMS = "10.0.0.11:8080:1,10.0.0.12:8080:1",
  API_GATEWAY_SECRET = "replace-with-a-strong-secret",
  HEALTH_CHECK_PATH = "/healthz",
  SESSION_STICKY = "true",
  SESSION_STICKY_MODE = "cookie",
}
```

3. 在现有 `http { ... }` 中 include：

```nginx
include /path/to/embedded/openresty/kp_ha_http.conf;
include /path/to/embedded/openresty/kp_ha_server.conf;
```

如果你要嵌入现有 server，不要 include `kp_ha_server.conf`，只把其中的 `location` 复制进你的 server，并保留：

```nginx
set $kp_ha_request_id "";
more_set_headers "Server: KP-HA";
```

4. 测试并 reload：

```bash
openresty -t
openresty -s reload
```

或：

```bash
nginx -t
nginx -s reload
```

## 自编译 nginx 模块要求

建议用 OpenResty，维护成本最低。若坚持自编译 nginx，需要确认：

```bash
nginx -V 2>&1 | grep -E 'lua|headers-more'
```

需要看到类似：

```text
--add-module=.../lua-nginx-module
--add-module=.../headers-more-nginx-module
```

并且 Lua package path 能找到：

```text
resty/dns/resolver.lua
```

## 普通 nginx 降级版

普通 nginx 可用：

```nginx
include /path/to/embedded/plain-nginx/kp_ha_basic.conf;
```

但它不能完整替代当前 KP-HA 版本。尤其是主动健康检查和 cookie/header 会话保持，需要 OpenResty/Lua 或第三方模块。

## 安全注意事项

- `API_GATEWAY_SECRET` 不能为空，生产必须替换示例值。
- `/status` 不建议暴露到公网；建议放内网或额外加 IP allowlist。
- 如果使用 `more_set_headers "Server: KP-HA";`，需要 headers-more 模块。
- `runtime_config.lua` 权限建议 `600`，避免密钥被普通用户读取。
