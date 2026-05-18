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

-- 学习：从上游 Set-Cookie 中提取目标 cookie 值，存入 upstream_sessions
function _M.learn_from_response()
    if not bool_env("STICKY_LEARN_ENABLED", false) then
        return
    end

    local cookie_names = getenv("STICKY_LEARN_COOKIES", "JSESSIONID,PHPSESSID")
    if cookie_names == "" then
        return
    end

    local upstream_id = ngx.ctx.selected_upstream
    if not upstream_id then
        return
    end

    -- 解析 Set-Cookie headers（可能有多个）
    local set_cookies = ngx.resp.get_headers()["Set-Cookie"]
    if not set_cookies then
        return
    end

    -- Set-Cookie 可以是字符串或表
    local cookies = set_cookies
    if type(cookies) == "string" then
        cookies = {cookies}
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
        -- 提取 cookie name=value
        local name, value = cookie_str:match("^%s*([^=;]+)%s*=%s*([^;]*)")
        if name and value and value ~= "" then
            local lower_name = name:lower()
            if target_names[lower_name] then
                local key = "learn:" .. lower_name .. ":" .. value
                dict:set(key, upstream_id, ttl)
            end
        end
    end
end

-- 查找：检查请求 cookie 是否匹配已学习的 session
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

    -- 检查请求中的所有 cookie
    local cookie_header = ngx.var.http_cookie
    if not cookie_header or cookie_header == "" then
        return nil
    end

    for name, value in cookie_header:gmatch("([^=;]+)%s*=%s*([^;]*)") do
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if target_names[name:lower()] and value ~= "" then
            local key = "learn:" .. name:lower() .. ":" .. value
            local upstream_id = dict:get(key)
            if upstream_id then
                return upstream_id
            end
        end
    end

    return nil
end

return _M
