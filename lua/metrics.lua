local _M = {}
local runtime_config = require("runtime_config")

local function getenv(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function parse_upstreams()
    local raw = getenv("BACKEND_UPSTREAMS", "")
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
    return upstreams
end

local function json_string(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    return '"' .. value .. '"'
end

function _M.status()
    local parts = {'{"upstreams":['}
    local upstreams = parse_upstreams()
    for i, upstream in ipairs(upstreams) do
        if i > 1 then
            parts[#parts + 1] = ","
        end
        parts[#parts + 1] = "{"
        parts[#parts + 1] = '"id":' .. json_string(upstream.id)
        parts[#parts + 1] = ',"host":' .. json_string(upstream.host)
        parts[#parts + 1] = ',"port":' .. upstream.port
        parts[#parts + 1] = ',"weight":' .. upstream.weight
        parts[#parts + 1] = ',"health":' .. json_string(upstream.health)
        parts[#parts + 1] = ',"requests":' .. upstream.requests
        parts[#parts + 1] = "}"
    end
    parts[#parts + 1] = ']}'
    parts[#parts] = '],"requests":' .. (ngx.shared.upstream_metrics:get("requests") or 0)
        .. ',"errors":' .. (ngx.shared.upstream_metrics:get("errors") or 0) .. "}"
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

        -- response time histogram (从 log_by_lua 记录的桶)
        local duration_buckets = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}
        local hist_key = "hist:" .. id .. ":"
        local cumulative = 0
        for _, bucket in ipairs(duration_buckets) do
            local count = ns:get(hist_key .. bucket) or 0
            cumulative = cumulative + count
            lines[#lines + 1] = 'upstream_request_duration_seconds_bucket{upstream="' .. id
                .. '",le="' .. bucket .. '"} ' .. cumulative
        end
        lines[#lines + 1] = 'upstream_request_duration_seconds_bucket{upstream="' .. id .. '",le="+Inf"} ' .. req_count

        lines[#lines + 1] = 'upstream_request_duration_seconds_sum{upstream="' .. id .. '"} '
            .. string.format("%.6f", ns:get("hist_sum:" .. id) or 0)
        lines[#lines + 1] = 'upstream_request_duration_seconds_count{upstream="' .. id .. '"} ' .. req_count
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
