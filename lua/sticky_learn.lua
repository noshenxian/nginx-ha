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

-- 学习：从上游 Set-Cookie 中提取目标 cookie 值，存入 L1(shm)+L2(Redis)
function _M.learn_from_response()
    if not bool_env("STICKY_LEARN_ENABLED", false) then
        return
    end

    local cookie_names = getenv("STICKY_LEARN_COOKIES", "JSESSIONID,PHPSESSID")
    if cookie_names == "" then
        return
    end

    local upstream_id = ngx.shared.upstream_health:get("last_upstream")
    if not upstream_id then
        return
    end

    -- 从 header_filter 阶段捕获的 Set-Cookie（存于 ngx.ctx）
    local cookies = ngx.ctx.sticky_cookies
    if not cookies then
        return
    end

    local dict = ngx.shared.upstream_sessions
    if not dict then
        return
    end

    local target_names = {}
    for name in cookie_names:gmatch("[^,%s]+") do
        name = name:gsub("%s+", "")
        if name ~= "" then
            target_names[name:lower()] = true
        end
    end

    local ttl = tonumber(getenv("STICKY_LEARN_TTL", "3600")) or 3600

    for _, cookie_str in ipairs(cookies) do
        local name, value = cookie_str:match("^%s*([^=;]+)%s*=%s*([^;]*)")
        if name and value and value ~= "" then
            local lower_name = name:lower()
            if target_names[lower_name] then
                local key = "learn:" .. lower_name .. ":" .. value

                -- L1: 本地 shm
                dict:set(key, upstream_id, ttl)

                -- L2: Redis 通过 ngx.timer 异步写入（避免 socket API 限制）


                local rkey = "sess:" .. key
                local rval = upstream_id
                local rttl = ttl
                ngx.log(ngx.ERR, "sticky_learn: scheduling redis timer for ", rkey)
                ngx.timer.at(0, function(premature)
                    ngx.log(ngx.ERR, "sticky_learn: redis timer fired, premature=", tostring(premature))
                    if premature then return end
                    local ok, err = pcall(function()
                        require("redis_sync").set(rkey, rval, rttl)
                    end)
                    if not ok then
                        ngx.log(ngx.ERR, "sticky_learn: redis timer failed: ", err)
                    else
                        ngx.log(ngx.ERR, "sticky_learn: redis timer success")
                    end
                end)
            end
        end
    end
end

-- 查找：L1 本地 shm → L2 Redis fallback，命中后回写 L1
-- 返回对应的 upstream_id，未命中则返回 nil
function _M.lookup_request()
    if not bool_env("STICKY_LEARN_ENABLED", false) then
        return nil
    end

    local cookie_names = getenv("STICKY_LEARN_COOKIES", "JSESSIONID,PHPSESSID")
    if cookie_names == "" then
        return nil
    end

    local target_names = {}
    for name in cookie_names:gmatch("[^,%s]+") do
        name = name:gsub("%s+", "")
        if name ~= "" then
            target_names[name:lower()] = true
        end
    end

    local dict = ngx.shared.upstream_sessions
    if not dict then
        return nil
    end

    local cookie_header = ngx.var.http_cookie
    if not cookie_header or cookie_header == "" then
        return nil
    end

    local redis_sync = require("redis_sync")

    for name, value in cookie_header:gmatch("([^=;]+)%s*=%s*([^;]*)") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if target_names[name:lower()] and value ~= "" then
            local key = "learn:" .. name:lower() .. ":" .. value

            -- L1: 本地 shm
            local upstream_id = dict:get(key)
            if upstream_id then
                return upstream_id
            end

            -- L2: Redis
            local redis_val = redis_sync.get("sess:" .. key)
            if redis_val then
                -- 回写 L1
                local ttl = tonumber(getenv("STICKY_LEARN_TTL", "3600")) or 3600
                dict:set(key, redis_val, ttl)
                return redis_val
            end
        end
    end

    return nil
end

return _M
