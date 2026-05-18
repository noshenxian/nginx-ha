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

local function create_client()
    local redis = require("resty.redis")
    local red = redis:new()
    red:set_timeout(2000)

    local host = getenv("REDIS_HOST", "127.0.0.1")
    local port = tonumber(getenv("REDIS_PORT", "6379")) or 6379
    local password = getenv("REDIS_PASSWORD", "")
    local db = tonumber(getenv("REDIS_DB", "0")) or 0

    local ok, err = red:connect(host, port)
    if not ok then
        return nil, "connect failed: " .. (err or "unknown")
    end

    if password ~= "" then
        local auth_ok, auth_err = red:auth(password)
        if not auth_ok then
            red:close()
            return nil, "auth failed: " .. (auth_err or "unknown")
        end
    end

    if db ~= 0 then
        red:select(db)
    end

    return red, nil
end

local function close_client(red)
    if red then
        local ok, err = red:set_keepalive(10000, 20)
        if not ok then
            red:close()
        end
    end
end

-- 读 Redis key，自动管理连接
function _M.get(key)
    if not bool_env("REDIS_ENABLED", false) then
        return nil
    end

    local red, err = create_client()
    if not red then
        ngx.log(ngx.WARN, "redis_sync: get failed to connect: ", err)
        return nil
    end

    local value, get_err = red:get("nginx-ha:" .. key)
    close_client(red)
    return value
end

-- 写 Redis key（带 TTL）
function _M.set(key, value, ttl)
    if not bool_env("REDIS_ENABLED", false) then
        return false
    end

    local red, err = create_client()
    if not red then
        ngx.log(ngx.WARN, "redis_sync: set failed to connect: ", err)
        return false
    end

    local full_key = "nginx-ha:" .. key
    local ok, set_err = red:set(full_key, value)
    if not ok then
        ngx.log(ngx.ERR, "redis_sync: set '", full_key, "' failed: ", set_err or "unknown")
        close_client(red)
        return false
    end

    ngx.log(ngx.INFO, "redis_sync: set '", full_key, "' = '", value, "'")

    ttl = tonumber(ttl) or 0
    if ttl > 0 then
        red:expire(full_key, ttl)
    end

    close_client(red)
    return true
end

-- 删除 Redis key
function _M.delete(key)
    if not bool_env("REDIS_ENABLED", false) then
        return false
    end

    local red, err = create_client()
    if not red then
        return false
    end

    local _, del_err = red:del("nginx-ha:" .. key)
    close_client(red)
    return true
end

-- 发布消息到频道
function _M.publish(channel, message)
    if not bool_env("REDIS_ENABLED", false) then
        return false
    end

    local red, err = create_client()
    if not red then
        return false
    end

    red:publish("nginx-ha:" .. channel, message)
    close_client(red)
    return true
end

-- 启动定时同步（在 init_worker 中调用，定期从 Redis 拉取变更）
function _M.start_poll(interval_sec)
    if not bool_env("REDIS_ENABLED", false) then
        return
    end

    interval_sec = interval_sec or 10

    ngx.timer.every(interval_sec, function()
        local red, err = create_client()
        if not red then
            return
        end
        -- 检查 upstreams 变更标记
        local changed = red:get("nginx-ha:upstreams:version")
        close_client(red)
        if changed then
            -- 重新加载 state（含动态 upstream）
            local ok, load_err = pcall(function()
                require("state").load()
            end)
            if not ok then
                ngx.log(ngx.ERR, "redis_sync: poll reload failed: ", load_err)
            end
        end
    end)
end

return _M
