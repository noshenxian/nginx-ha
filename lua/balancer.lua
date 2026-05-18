local ngx_balancer = require("ngx.balancer")
local _M = {}

local rr_index = 0
local upstream_cache = nil
local upstream_cache_key = nil
local runtime_config = require("runtime_config")

-- 每 upstream 的排队信号量（key = upstream.id）
local queue_semaphores = {}

local function getenv(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function bool_env(name, default)
    local value = getenv(name, default and "true" or "false")
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function split_host_port_weight(item)
    local host, port, weight = item:match("^%s*([^:,%s]+):(%d+):?(%d*)%s*$")
    if not host then
        return nil
    end
    return {
        id = host .. ":" .. port,
        host = host,
        port = tonumber(port),
        weight = tonumber(weight) or 1,
    }
end

-- 一致性哈希：ketama 风格，每 upstream 160 个虚拟节点
local function ketama_ring(candidates)
    local continuum = {}
    for _, upstream in ipairs(candidates) do
        for rep = 1, 160 do
            local bin = ngx.md5_bin(upstream.id .. "-" .. rep)
            local b1, b2, b3, b4 = string.byte(bin, 1, 4)
            local point = bit.bor(
                bit.lshift(b1, 24),
                bit.lshift(b2, 16),
                bit.lshift(b3, 8),
                b4
            )
            table.insert(continuum, {point = point, upstream = upstream})
        end
    end
    table.sort(continuum, function(a, b)
        return a.point < b.point
    end)
    return continuum
end

local function ketama_pick(continuum, key)
    if #continuum == 0 then
        return nil
    end
    local hash
    if key and key ~= "" then
        local bin = ngx.md5_bin(key)
        local b1, b2, b3, b4 = string.byte(bin, 1, 4)
        hash = bit.bor(bit.lshift(b1, 24), bit.lshift(b2, 16), bit.lshift(b3, 8), b4)
    else
        hash = math.random(0, 0xffffffff)
    end
    local lo, hi = 1, #continuum
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if continuum[mid].point < hash then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return continuum[lo].upstream
end

local function parse_upstreams()
    local raw = getenv("BACKEND_UPSTREAMS", "")
    if raw == "" then
        raw = getenv("BACKEND_UPSTREAM", "")
    end
    local cache_key = raw

    local upstreams = {}
    for item in raw:gmatch("[^,]+") do
        local parsed = split_host_port_weight(item)
        if parsed then
            upstreams[#upstreams + 1] = parsed
        end
    end

    -- 合并动态成员和 SRV 发现成员（存储于 upstream_health 通过 dyn:/srvdyn: 前缀）
    local health_dict = ngx.shared.upstream_health
    if health_dict then
        local all_keys = health_dict:get_keys(0)
        for _, key in ipairs(all_keys or {}) do
            if key:sub(1, 4) == "dyn:" or key:sub(1, 6) == "srvdyn" then
                local value = health_dict:get(key)
                if value then
                    local parts = {}
                    for part in value:gmatch("[^|]+") do
                        parts[#parts + 1] = part
                    end
                    if #parts >= 2 then
                        local member = {
                            id = parts[1] .. ":" .. parts[2],
                            host = parts[1],
                            port = tonumber(parts[2]),
                            weight = tonumber(parts[3]) or 1,
                        }
                        upstreams[#upstreams + 1] = member
                        cache_key = cache_key .. "|" .. member.id
                    end
                end
            end
        end
    end

    if cache_key == upstream_cache_key and upstream_cache then
        return upstream_cache
    end

    upstream_cache_key = cache_key
    upstream_cache = upstreams
    return upstreams
end

local function health_key(upstream)
    return "health:" .. upstream.id
end

function _M.is_healthy(upstream)
    if not bool_env("HEALTH_CHECK_ENABLED", true) then
        return true
    end

    -- Circuit breaker 检查
    if bool_env("CIRCUIT_BREAKER_ENABLED", false) then
        local dict = ngx.shared.upstream_health
        local circuit_state = dict.get(dict, "circuit:" .. upstream.id)
        if circuit_state == "open" then
            local cb_timeout = tonumber(getenv("CIRCUIT_BREAKER_TIMEOUT", "30")) or 30
            local opened_at = dict.get(dict, "circuit_time:" .. upstream.id) or 0
            if ngx.now() - opened_at < cb_timeout then
                return false
            end
            -- 超时 → 半开，放行一个探测请求
            dict:set("circuit:" .. upstream.id, "half_open")
        elseif circuit_state == "half_open" then
            -- 半开状态：只放行一个请求探测
            dict:set("circuit:" .. upstream.id, "open") -- 默认假设探测失败
        end
    end

    local state = ngx.shared.upstream_health.get(ngx.shared.upstream_health, health_key(upstream))
    return state == nil or state == "healthy"
end

local function healthy_upstreams()
    local result = {}
    for _, upstream in ipairs(parse_upstreams()) do
        if _M.is_healthy(upstream) then
            result[#result + 1] = upstream
        end
    end
    return result
end

-- slow_start：恢复后按时间窗口比例放量，窗口内只选恢复最早的
local function slow_start_pick(candidates)
    local now = ngx.now()
    local window = tonumber(getenv("SLOW_START_WINDOW", "0")) or 0
    if window <= 0 then
        return nil
    end

    local best, best_ratio = nil, -1
    for _, upstream in ipairs(candidates) do
        local recovered_at = ngx.shared.upstream_health.get(ngx.shared.upstream_health, "recovered_at:" .. upstream.id) or 0
        if recovered_at > 0 then
            local elapsed = now - recovered_at
            if elapsed >= window then
                return upstream
            end
            local ratio = elapsed / window
            if ratio > best_ratio then
                best_ratio = ratio
                best = upstream
            end
        end
    end
    return best
end

local function weighted_round_robin(candidates)
    local expanded = {}
    for _, upstream in ipairs(candidates) do
        for _ = 1, upstream.weight do
            expanded[#expanded + 1] = upstream
        end
    end
    if #expanded == 0 then
        return nil
    end
    rr_index = (rr_index % #expanded) + 1
    return expanded[rr_index]
end

-- least_conn：选 (inflight / weight) 最低的上游
local function least_conn_pick(candidates)
    local best, best_load = nil, 1 / 0
    for _, upstream in ipairs(candidates) do
        local inflight = ngx.shared.upstream_inflight.get(ngx.shared.upstream_inflight, "inflight:" .. upstream.id) or 0
        local load = inflight / upstream.weight
        if load < best_load then
            best_load = load
            best = upstream
        end
    end
    return best
end

local function hash_pick(candidates, key)
    if #candidates == 0 then
        return nil
    end
    local hash = 2166136261
    for i = 1, #key do
        hash = bit.bxor(hash, key:byte(i))
        hash = (hash * 16777619) % 4294967296
    end
    local index = (hash % #candidates) + 1
    return candidates[index]
end

local function is_ip_address(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function resolve_host(host)
    if is_ip_address(host) then
        return host
    end
    local address = ngx.shared.upstream_health.get(ngx.shared.upstream_health, "address:" .. host)
    if not address then
        ngx.log(ngx.ERR, "no resolved address cached for upstream host ", host)
    end
    return address
end

local function cookie_name()
    return getenv("SESSION_COOKIE_NAME", "OPENRESTY_LB_ROUTE")
end

local function header_name()
    return getenv("SESSION_HEADER_NAME", "X-Session-ID")
end

local function find_by_id(candidates, id)
    for _, upstream in ipairs(candidates) do
        if upstream.id == id then
            return upstream
        end
    end
    return nil
end

local function sticky_key()
    local mode = getenv("SESSION_STICKY_MODE", "cookie")
    if mode == "header" then
        return ngx.req.get_headers()[header_name()]
    end
    if mode == "ip_hash" then
        return ngx.var.binary_remote_addr or ngx.var.remote_addr
    end
    return ngx.var["cookie_" .. cookie_name()]
end

local function set_cookie(upstream)
    local ttl_raw = getenv("SESSION_TTL", "3600s")
    local max_age = tonumber(ttl_raw:match("^(%d+)")) or 3600
    ngx.header["Set-Cookie"] = cookie_name() .. "=" .. upstream.id .. "; Path=/; Max-Age=" .. max_age .. "; HttpOnly; SameSite=Lax"
end

-- 一致性哈希 key 来源
local function consistent_hash_key()
    local key_source = getenv("CONSISTENT_HASH_KEY", "remote_addr")
    if key_source == "remote_addr" then
        return ngx.var.binary_remote_addr or ngx.var.remote_addr
    elseif key_source == "cookie" then
        return ngx.var["cookie_" .. cookie_name()]
    elseif key_source == "header" then
        return ngx.req.get_headers()[getenv("CONSISTENT_HASH_HEADER", "X-Request-ID")]
    elseif key_source == "uri" then
        return ngx.var.request_uri
    else
        return ngx.var.binary_remote_addr or ngx.var.remote_addr
    end
end

local function choose_upstream(candidates)
    -- sticky learn 查找（最高优先级：从上游 Set-Cookie 学到的 session）


    local learn_target = require("sticky_learn").lookup_request()
    if learn_target then
        local bound = find_by_id(candidates, learn_target)
        if bound then
            return bound, false
        end
    end

    local sticky = bool_env("SESSION_STICKY", true)
    local mode = getenv("SESSION_STICKY_MODE", "cookie")

    -- sticky 命中直接返回
    if sticky then
        local key = sticky_key()
        if key and key ~= "" then
            local bound = find_by_id(candidates, key)
            if bound then
                return bound, false
            end
            if mode == "header" or mode == "ip_hash" then
                return hash_pick(candidates, key), false
            end
        end
    end

    local strategy = getenv("LB_STRATEGY", "round_robin")

    if strategy == "ip_hash" then
        local key = ngx.var.binary_remote_addr or ngx.var.remote_addr or ""
        return hash_pick(candidates, key), sticky and mode == "cookie"
    end

    if strategy == "consistent_hash" then
        local key = consistent_hash_key()
        local ring = ngx.ctx.consistent_hash_ring
        if not ring then
            ring = ketama_ring(candidates)
            ngx.ctx.consistent_hash_ring = ring
        end
        return ketama_pick(ring, key), sticky and mode == "cookie"
    end

    if strategy == "least_conn" then
        return least_conn_pick(candidates), sticky and mode == "cookie"
    end

    return weighted_round_robin(candidates), sticky and mode == "cookie"
end

function _M.balance()
    local candidates = healthy_upstreams()
    if #candidates == 0 then
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say("no healthy upstreams")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    -- slow_start：恢复后先只选恢复了最久的
    local ss_upstream = slow_start_pick(candidates)
    if ss_upstream then
        candidates = {ss_upstream}
    end

    local upstream, refresh_cookie = choose_upstream(candidates)
    if not upstream then
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
        ngx.say("no upstream selected")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    -- max_conns + queue 检查
    local max_conns = tonumber(getenv("UPSTREAM_MAX_CONNS", "0")) or 0
    if max_conns > 0 then
        local inflight = ngx.shared.upstream_inflight.get(ngx.shared.upstream_inflight, "inflight:" .. upstream.id) or 0
        if inflight >= max_conns then
            local queue_size = tonumber(getenv("UPSTREAM_QUEUE_SIZE", "0")) or 0
            if queue_size <= 0 then
                ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
                ngx.say("upstream saturated")
                return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
            end

            -- 排队：获取或创建信号量
            local sem = queue_semaphores[upstream.id]
            if not sem then
                sem = ngx.semaphore.new(queue_size)
                queue_semaphores[upstream.id] = sem
            end

            local queue_timeout = tonumber(getenv("UPSTREAM_QUEUE_TIMEOUT", "30")) or 30
            local acquired, sem_err = sem:wait(queue_timeout)
            if not acquired then
                ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
                ngx.say("upstream saturated (queue timeout)")
                return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
            end

            -- 标记需要释放信号量
            ngx.ctx.queue_sem = sem
        end
    end

    ngx.ctx.selected_upstream = upstream.id
    -- 同时存到 shared dict（balancer ctx 和 log ctx 不共享 ngx.ctx）
    ngx.shared.upstream_health:set("last_upstream", upstream.id, 5)
    if refresh_cookie then
        set_cookie(upstream)
    end

    ngx.shared.upstream_inflight.incr(ngx.shared.upstream_inflight, "inflight:" .. upstream.id, 1, 0)

    local peer_host = resolve_host(upstream.host)
    if not peer_host then
        ngx.shared.upstream_inflight.incr(ngx.shared.upstream_inflight, "inflight:" .. upstream.id, -1)
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end

    local ok, err = ngx_balancer.set_current_peer(peer_host, upstream.port)
    if not ok then
        ngx.log(ngx.ERR, "failed to set current peer: ", err)
        ngx.shared.upstream_inflight.incr(ngx.shared.upstream_inflight, "inflight:" .. upstream.id, -1)
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
end

function _M.on_request_done()
    -- 释放排队信号量
    local sem = ngx.ctx.queue_sem
    if sem then
        sem:post()
        ngx.ctx.queue_sem = nil
    end

    local upstream_id = ngx.ctx.selected_upstream
    if upstream_id then
        ngx.ctx.selected_upstream = nil
        ngx.shared.upstream_inflight.incr(ngx.shared.upstream_inflight, "inflight:" .. upstream_id, -1)
    end
end

return _M
