local _M = {}
local runtime_config = require("runtime_config")

local function getenv(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function parse_upstreams(group)
    -- 支持指定 group：BACKEND_UPSTREAMS_<group> 或默认 BACKEND_UPSTREAMS
    local env_name = "BACKEND_UPSTREAMS"
    if group and group ~= "" then
        env_name = "BACKEND_UPSTREAMS_" .. group
    end
    local raw = getenv(env_name, "")
    if raw == "" and group and group ~= "" then
        -- 指定 group 但没配置，回退默认
        raw = getenv("BACKEND_UPSTREAMS", "")
    end
    if raw == "" then
        raw = getenv("BACKEND_UPSTREAM", "")
    end

    local upstreams = {}
    for item in raw:gmatch("[^,]+") do
        local host, port, weight = item:match("^%s*([^:,%s]+):(%d+):?(%d*)%s*$")
        if host then
            local id = host .. ":" .. port
            upstreams[#upstreams + 1] = {
                id = id,
                host = host,
                port = tonumber(port),
                weight = tonumber(weight) or 1,
                health = ngx.shared.upstream_health:get("health:" .. id) or "healthy",
                requests = ngx.shared.upstream_metrics:get("upstream_requests:" .. id) or 0,
            }
        end
    end

    -- 合并动态和 SRV 成员
    local health_dict = ngx.shared.upstream_health
    if health_dict then
        local all_keys = health_dict:get_keys(0)
        for _, key in ipairs(all_keys or {}) do
            local prefix = key:sub(1, 4)
            if prefix == "dyn:" or prefix == "srvd" then
                local value = health_dict:get(key)
                if value then
                    local parts = {}
                    for part in value:gmatch("[^|]+") do
                        parts[#parts + 1] = part
                    end
                    if #parts >= 2 then
                        local id = parts[1] .. ":" .. parts[2]
                        upstreams[#upstreams + 1] = {
                            id = id,
                            host = parts[1],
                            port = tonumber(parts[2]),
                            weight = tonumber(parts[3]) or 1,
                            health = health_dict:get("health:" .. id) or "healthy",
                            requests = ngx.shared.upstream_metrics:get("upstream_requests:" .. id) or 0,
                        }
                    end
                end
            end
        end
    end

    return upstreams
end

local function json_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return '"' .. value .. '"'
end

-- 从 histogram 桶估算 p50（简单线性插值）
local function approx_p50(ns, hist_key_prefix, req_count)
    if req_count <= 0 then return 0 end
    local buckets = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}
    local target = req_count * 0.5
    local cumulative = 0
    local prev = 0
    for _, b in ipairs(buckets) do
        local c = ns:get(hist_key_prefix .. b) or 0
        cumulative = cumulative + c
        if cumulative >= target then
            local frac = (target - (cumulative - c)) / math.max(c, 1)
            return prev + (b - prev) * frac
        end
        prev = b
    end
    return prev
end

-- 发现所有 upstream group（从 env 中匹配 BACKEND_UPSTREAMS_*）
local function discover_groups()
    local groups = {[""] = true}  -- 默认组
    -- 检查 runtime_config 中的 key
    local config = require("runtime_config")
    for k, v in pairs(config) do
        local g = k:match("^BACKEND_UPSTREAMS_(.+)$")
        if g and v ~= "" then
            groups[g] = true
        end
    end
    -- 也检查 os.getenv
    local i = 0
    while true do
        i = i + 1
        local k = os.getenv(i)
        if not k then break end
        local g = k:match("^BACKEND_UPSTREAMS_(.+)$")
        if g then
            local v = os.getenv(k)
            if v and v ~= "" then
                groups[g] = true
            end
        end
    end
    return groups
end

-- 构建一个 group 的上游数据
local function build_group_data(group_name)
    local upstreams = parse_upstreams(group_name)
    local ns_metrics = ngx.shared.upstream_metrics
    local ns_health = ngx.shared.upstream_health
    local ns_inflight = ngx.shared.upstream_inflight

    local result = {}
    for _, upstream in ipairs(upstreams) do
        local id = upstream.id
        local inflight = ns_inflight and ns_inflight.get(ns_inflight, "inflight:" .. id) or 0
        local circuit = ns_health and ns_health.get(ns_health, "circuit:" .. id) or "closed"
        local p50 = approx_p50(ns_metrics, "hist:" .. id .. ":", upstream.requests)
        local errors = ns_metrics.get(ns_metrics, "upstream_errors:" .. id) or 0
        result[#result + 1] = {
            id = id,
            host = upstream.host,
            port = upstream.port,
            weight = upstream.weight,
            health = upstream.health,
            circuit = circuit,
            inflight = tonumber(inflight),
            requests = upstream.requests,
            errors = errors,
            p50_ms = string.format("%.2f", p50 * 1000),
        }
    end
    return result
end

local function json_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return '"' .. value .. '"'
end

-- 将上游对象数组转为 JSON
local function upstreams_json(upstreams)
    local parts = {}
    for i, u in ipairs(upstreams) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = "{"
        parts[#parts + 1] = '"id":' .. json_string(u.id)
        parts[#parts + 1] = ',"host":' .. json_string(u.host)
        parts[#parts + 1] = ',"port":' .. u.port
        parts[#parts + 1] = ',"weight":' .. u.weight
        parts[#parts + 1] = ',"health":' .. json_string(u.health)
        parts[#parts + 1] = ',"circuit":' .. json_string(u.circuit)
        parts[#parts + 1] = ',"inflight":' .. u.inflight
        parts[#parts + 1] = ',"requests":' .. u.requests
        parts[#parts + 1] = ',"errors":' .. u.errors
        parts[#parts + 1] = ',"p50_ms":' .. json_string(u.p50_ms)
        parts[#parts + 1] = "}"
    end
    return table.concat(parts)
end

function _M.status()
    local ns_metrics = ngx.shared.upstream_metrics
    local req_group = ngx.req.get_uri_args()["group"] or ngx.var.arg_group

    -- 指定了具体 group，只返回该组
    if req_group and req_group ~= "" then
        local upstreams = build_group_data(req_group)
        local parts = {'{"group":' .. json_string(req_group) .. ',"upstreams":['}
        parts[#parts + 1] = upstreams_json(upstreams)
        parts[#parts + 1] = '],"requests":' .. (ns_metrics:get("requests") or 0)
            .. ',"errors":' .. (ns_metrics:get("errors") or 0) .. "}"
        ngx.say(table.concat(parts))
        return
    end

    -- 返回所有 group
    local groups = discover_groups()
    local group_list = {}
    for g, _ in pairs(groups) do
        group_list[#group_list + 1] = g
    end
    table.sort(group_list)

    local parts = {'{"groups":['}
    local total_req = 0
    local total_err = 0

    for i, g in ipairs(group_list) do
        if i > 1 then parts[#parts + 1] = "," end
        local upstreams = build_group_data(g)
        parts[#parts + 1] = '{"name":' .. json_string(g == "" and "default" or g)
        parts[#parts + 1] = ',"upstreams":[' .. upstreams_json(upstreams) .. "]"
        parts[#parts + 1] = "}"
    end

    parts[#parts + 1] = '],"requests":' .. (ns_metrics:get("requests") or 0)
        .. ',"errors":' .. (ns_metrics:get("errors") or 0)
        .. ',"circuit_trips":' .. (ns_metrics:get("circuit_trips") or 0)
        .. ',"rate_limit_hits":' .. (ns_metrics:get("rate_limit_hits") or 0)
        .. "}"
    ngx.say(table.concat(parts))
end

-- Prometheus 文本格式指标端点
-- 暴露: upstreams_requests_total, upstreams_health, upstreams_inflight,
--       gateway_requests_total, gateway_errors_total, gateway_request_duration_seconds
local function prometheus_metrics()
    local upstreams = parse_upstreams()
    local lines = {}

    -- 全局计数器
    local total_requests = ngx.shared.upstream_metrics:get("requests") or 0
    local total_errors = ngx.shared.upstream_metrics:get("errors") or 0

    lines[#lines + 1] = '# HELP gateway_requests_total Total number of gateway requests'
    lines[#lines + 1] = '# TYPE gateway_requests_total counter'
    lines[#lines + 1] = 'gateway_requests_total ' .. total_requests

    lines[#lines + 1] = '# HELP gateway_errors_total Total number of gateway error responses (5xx)'
    lines[#lines + 1] = '# TYPE gateway_errors_total counter'
    lines[#lines + 1] = 'gateway_errors_total ' .. total_errors

    lines[#lines + 1] = ''
    lines[#lines + 1] = '# HELP gateway_circuit_trips_total Total circuit breaker trip events'
    lines[#lines + 1] = '# TYPE gateway_circuit_trips_total counter'
    lines[#lines + 1] = 'gateway_circuit_trips_total ' .. (ngx.shared.upstream_metrics:get("circuit_trips") or 0)

    lines[#lines + 1] = ''
    lines[#lines + 1] = '# HELP gateway_rate_limit_hits_total Total rate limit rejections'
    lines[#lines + 1] = '# TYPE gateway_rate_limit_hits_total counter'
    lines[#lines + 1] = 'gateway_rate_limit_hits_total ' .. (ngx.shared.upstream_metrics:get("rate_limit_hits") or 0)

    -- 每个上游的详细指标
    for _, upstream in ipairs(upstreams) do
        local id = upstream.id
        local ns = ngx.shared.upstream_metrics

        -- requests counter
        local req_count = ns:get("upstream_requests:" .. id) or 0
        lines[#lines + 1] = ''
        lines[#lines + 1] = '# HELP upstream_requests_total Total requests routed to upstream'
        lines[#lines + 1] = '# TYPE upstream_requests_total counter'
        lines[#lines + 1] = 'upstream_requests_total{upstream="' .. id .. '"} ' .. req_count

        -- health gauge
        local health_val = (upstream.health == "healthy") and 1 or 0
        lines[#lines + 1] = ''
        lines[#lines + 1] = '# HELP upstream_health Health status of upstream (1=healthy, 0=unhealthy)'
        lines[#lines + 1] = '# TYPE upstream_health gauge'
        lines[#lines + 1] = 'upstream_health{upstream="' .. id .. '"} ' .. health_val

        -- inflight gauge
        local inflight = ngx.shared.upstream_inflight:get("inflight:" .. id) or 0
        lines[#lines + 1] = ''
        lines[#lines + 1] = '# HELP upstream_inflight Current number of in-flight requests to upstream'
        lines[#lines + 1] = '# TYPE upstream_inflight gauge'
        lines[#lines + 1] = 'upstream_inflight{upstream="' .. id .. '"} ' .. inflight

        -- response time histogram（Prometheus 累积桶：每个请求计入所有 duration <= bucket 的桶）
        local duration_buckets = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}
        local hist_key = "hist:" .. id .. ":"
        for _, bucket in ipairs(duration_buckets) do
            local count = ns:get(hist_key .. bucket) or 0
            lines[#lines + 1] = 'upstream_request_duration_seconds_bucket{upstream="' .. id
                .. '",le="' .. bucket .. '"} ' .. count
        end
        lines[#lines + 1] = 'upstream_request_duration_seconds_bucket{upstream="' .. id .. '",le="+Inf"} ' .. req_count

        lines[#lines + 1] = 'upstream_request_duration_seconds_sum{upstream="' .. id .. '"} '
            .. string.format("%.6f", ns:get("hist_sum:" .. id) or 0)
        lines[#lines + 1] = 'upstream_request_duration_seconds_count{upstream="' .. id .. '"} ' .. req_count

        -- 近似百分位（从 histogram 桶估算）
        if req_count > 0 then
            local function approx_percentile(pct)
                local target = req_count * pct
                local cumulative = 0
                local prev_bucket = 0
                for _, bucket in ipairs(duration_buckets) do
                    local count = ns:get(hist_key .. bucket) or 0
                    cumulative = cumulative + count
                    if cumulative >= target then
                        -- 线性插值
                        local frac = (target - (cumulative - count)) / math.max(count, 1)
                        return prev_bucket + (bucket - prev_bucket) * frac
                    end
                    prev_bucket = bucket
                end
                return prev_bucket
            end

            lines[#lines + 1] = 'upstream_request_duration_seconds{upstream="' .. id .. '",quantile="0.5"} '
                .. string.format("%.6f", approx_percentile(0.5))
            lines[#lines + 1] = 'upstream_request_duration_seconds{upstream="' .. id .. '",quantile="0.9"} '
                .. string.format("%.6f", approx_percentile(0.9))
            lines[#lines + 1] = 'upstream_request_duration_seconds{upstream="' .. id .. '",quantile="0.99"} '
                .. string.format("%.6f", approx_percentile(0.99))
        end
    end

    ngx.header["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"
    ngx.say(table.concat(lines, "\n"))
end

-- 从 log_by_lua 调用，记录响应时间和状态码分类
function _M.record_request(upstream_id, status, duration_sec)
    local ns = ngx.shared.upstream_metrics

    -- histogram 桶
    if upstream_id and duration_sec then
        local buckets = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}
        local hist_key = "hist:" .. upstream_id .. ":"
        local sum_key = "hist_sum:" .. upstream_id
        for _, bucket in ipairs(buckets) do
            if duration_sec <= bucket then
                ns:incr(hist_key .. bucket, 1, 0)
            end
        end
        local sum = ns:get(sum_key) or 0
        ns:set(sum_key, sum + duration_sec)
    end

    -- 状态码分类
    if status then
        if status >= 200 and status < 300 then
            ns:incr("status_2xx", 1, 0)
        elseif status >= 300 and status < 400 then
            ns:incr("status_3xx", 1, 0)
        elseif status >= 400 and status < 500 then
            ns:incr("status_4xx", 1, 0)
        elseif status >= 500 then
            ns:incr("status_5xx", 1, 0)
        end
    end
end

-- content_by_lua 分发
function _M.serve()
    local path = ngx.var.uri
    if path == "/status" then
        _M.status()
    elseif path == "/metrics" then
        prometheus_metrics()
    else
        ngx.exit(ngx.HTTP_NOT_FOUND)
    end
end

return _M
