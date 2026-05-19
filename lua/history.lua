local _M = {}
local runtime_config = require("runtime_config")

local function bool_env(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        value = default and "true" or "false"
    end
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

-- 每 60s 快照当前 upstream_requests 计数写入 Redis
function _M.snapshot()
    if not bool_env("REDIS_ENABLED", false) then
        return
    end

    local now = ngx.now()
    local bucket = math.floor(now / 300) * 300  -- 5 分钟粒度

    local dict = ngx.shared.upstream_metrics
    local redis_sync = require("redis_sync")

    local all_keys = dict:get_keys(0)
    for _, key in ipairs(all_keys or {}) do
        local upstream_id = key:match("^upstream_requests:(.+)$")
        if upstream_id then
            local count = dict:get(key) or 0
            local redis_key = "ts:" .. upstream_id .. ":" .. bucket
            -- 用 Redis INCRBY 累加（同 bucket 内多次快照会叠加）
            local red = require("resty.redis"):new()
            red:set_timeout(1000)
            local ok, connerr = red:connect(
                runtime_config["REDIS_HOST"] or os.getenv("REDIS_HOST") or "127.0.0.1",
                tonumber(runtime_config["REDIS_PORT"] or os.getenv("REDIS_PORT") or "6379") or 6379
            )
            if ok then
                local pass = runtime_config["REDIS_PASSWORD"] or os.getenv("REDIS_PASSWORD") or ""
                if pass ~= "" then red:auth(pass) end
                red:incrby("nginx-ha:" .. redis_key, count)
                red:expire("nginx-ha:" .. redis_key, 691200)
                red:set_keepalive(1000, 5)
            end
        end
    end
end

-- 查询某上游的历史数据
-- 返回 {{time=unix, value=count}, ...}
function _M.query(upstream_id, range_sec)
    if not bool_env("REDIS_ENABLED", false) then
        return {}
    end

    range_sec = tonumber(range_sec) or 3600
    local now = ngx.now()
    local from = now - range_sec
    local bucket = math.floor(now / 300) * 300
    local from_bucket = math.floor(from / 300) * 300

    local redis_sync = require("redis_sync")
    local red = require("resty.redis"):new()
    red:set_timeout(2000)
    local ok = red:connect(
        runtime_config["REDIS_HOST"] or os.getenv("REDIS_HOST") or "127.0.0.1",
        tonumber(runtime_config["REDIS_PORT"] or os.getenv("REDIS_PORT") or "6379") or 6379
    )
    if not ok then
        return {}
    end
    local pass = runtime_config["REDIS_PASSWORD"] or os.getenv("REDIS_PASSWORD") or ""
    if pass ~= "" then red:auth(pass) end

    -- 收集该 upstream 的所有 bucket key
    local points = {}
    for b = from_bucket, bucket, 300 do
        local key = "nginx-ha:ts:" .. upstream_id .. ":" .. b
        local val = red:get(key)
        if val then
            points[#points + 1] = {time = b, value = tonumber(val)}
        end
    end

    -- 补充当前实时值作为最后一个点
    local dict = ngx.shared.upstream_metrics
    local current = dict:get("upstream_requests:" .. upstream_id) or 0
    points[#points + 1] = {time = bucket + 300, value = current}

    red:set_keepalive(1000, 5)
    return points
end

-- 启动定时快照（init_worker 中调用）
function _M.start()
    if not bool_env("REDIS_ENABLED", false) then
        ngx.log(ngx.ERR, "history: REDIS_ENABLED=false, skipping")
        return
    end
    ngx.timer.every(60, function()
        pcall(_M.snapshot)
    end)
end

return _M
