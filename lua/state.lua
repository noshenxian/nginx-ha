local _M = {}
local runtime_config = require("runtime_config")

local STATE_FILE = "build/state.json"

local function getenv(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function get_prefix()
    local prefix = os.getenv("NGINX_PREFIX") or ""
    if prefix ~= "" and prefix:sub(-1) ~= "/" then
        prefix = prefix .. "/"
    end
    return prefix
end

-- 管道格式 encode/decode（无需 JSON 库）
local function encode_state(members)
    local lines = {}
    for _, m in ipairs(members) do
        table.insert(lines, m.id .. "|" .. m.host .. "|" .. m.port .. "|" .. m.weight)
    end
    return table.concat(lines, "\n")
end

local function decode_state(content)
    if not content or content == "" then
        return {}
    end
    local members = {}
    for line in content:gmatch("[^\n]+") do
        local parts = {}
        for part in line:gmatch("[^|]+") do
            parts[#parts + 1] = part
        end
        if #parts >= 3 then
            members[#members + 1] = {
                id = parts[1],
                host = parts[2],
                port = tonumber(parts[3]),
                weight = tonumber(parts[4]) or 1,
            }
        end
    end
    return members
end

-- 从文件加载动态成员到 upstream_health（dyn: 前缀）
function _M.load()
    local prefix = get_prefix()
    local f, err = io.open(prefix .. STATE_FILE, "r")
    if not f then
        return
    end
    local content = f:read("*a")
    f:close()
    if content == "" then
        return
    end

    local members = decode_state(content)
    local dict = ngx.shared.upstream_health
    if not dict then
        return
    end

    for _, m in ipairs(members) do
        local key = "dyn:" .. m.id
        local value = m.host .. "|" .. m.port .. "|" .. m.weight
        dict:set(key, value)
    end
end

-- 将当前动态成员写入文件
function _M.save()
    local prefix = get_prefix()
    local dict = ngx.shared.upstream_health
    if not dict then
        return
    end

    local members = {}
    local all_keys = dict:get_keys(0)
    for _, key in ipairs(all_keys or {}) do
        if key:sub(1, 4) == "dyn:" then
            local value = dict:get(key)
            if value then
                local id = key:sub(5)
                local parts = {}
                for part in value:gmatch("[^|]+") do
                    parts[#parts + 1] = part
                end
                if #parts >= 2 then
                    members[#members + 1] = {
                        id = id,
                        host = parts[1],
                        port = tonumber(parts[2]),
                        weight = tonumber(parts[3]) or 1,
                    }
                end
            end
        end
    end

    local f, open_err = io.open(prefix .. STATE_FILE, "w")
    if not f then
        ngx.log(ngx.ERR, "state: failed to open state file for write: ", open_err)
        return
    end
    local content = encode_state(members)
    f:write(content)
    f:close()
end

-- 启动时加载 + 启动定时 flush（每 60s）
function _M.start()
    local ok, err = pcall(_M.load)
    if not ok then
        ngx.log(ngx.ERR, "state: load failed: ", err)
    end

    local _, timer_err = ngx.timer.every(60, function()
        pcall(_M.save)
    end)
    if timer_err then
        ngx.log(ngx.ERR, "state: failed to start timer: ", timer_err)
    end
end

return _M
