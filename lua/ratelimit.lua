local _M = {}
local runtime_config = require("runtime_config")

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

local function parse_rate(value, default)
    local raw = tostring(value or "")
    local numeric = raw:match("^%s*(%d+%.?%d*)%s*r/s%s*$") or raw:match("^%s*(%d+%.?%d*)%s*$")
    return tonumber(numeric) or default
end

-- 检查 KeyVal 白名单（直接查找 key，避免遍历 get_keys 的限制）
local function is_whitelisted(key)
    local dict = ngx.shared.upstream_health
    if not dict then
        return false
    end
    local store_key = "kv:ratelimit:whitelist/" .. key
    local stored_value = dict:get(store_key)
    return stored_value ~= nil and stored_value == key
end

function _M.check()
    if not bool_env("RATE_LIMIT_ENABLED", false) then
        return
    end

    local rate = parse_rate(getenv("RATE_LIMIT_RATE", "10"), 10)
    local burst = tonumber(getenv("RATE_LIMIT_BURST", "20")) or 20
    local key_source = getenv("RATE_LIMIT_KEY", "remote_addr")

    -- 提取限流 key（用 remote_addr 字符串而非 binary_remote_addr，确保与 KeyVal 白名单字符串匹配）
    local key
    if key_source == "remote_addr" then
        key = ngx.var.remote_addr
    elseif key_source == "header" then
        local hdr_name = getenv("RATE_LIMIT_HEADER", "X-API-Key")
        key = ngx.req.get_headers()[hdr_name] or ngx.var.remote_addr
    else
        key = ngx.var.remote_addr
    end

    if not key then
        return
    end

    -- 白名单检查
    if is_whitelisted(key) then
        return
    end

    -- 使用 lua-resty-limit-req 的 shared dict（需要独立的 dict）
    local limit_req = require("resty.limit.req")
    -- 默认使用 upstream_metrics dict 存计数器
    local lim, err = limit_req.new("upstream_metrics", rate, burst)
    if not lim then
        ngx.log(ngx.ERR, "ratelimit: failed to create limiter: ", err)
        return
    end

    local delay, lerr = lim:incoming(key, true)
    if not delay then
        if lerr == "rejected" then
            ngx.shared.upstream_metrics:incr("rate_limit_hits", 1, 0)
            ngx.status = 429
            ngx.header["Retry-After"] = "1"
            ngx.say("rate limit exceeded")
            return ngx.exit(429)
        end
        ngx.log(ngx.ERR, "ratelimit: incoming error: ", lerr)
        return
    end

    if delay > 0 then
        -- 需要延迟
        if delay >= 0.001 then
            ngx.sleep(delay)
        end
    end
end

return _M
