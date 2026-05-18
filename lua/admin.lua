local _M = {}
local runtime_config = require("runtime_config")
local state = require("state")

-- 用 upstream_health 存动态成员（前缀 dyn:），避免 ngx.shared 访问问题
local DICT_NAME = "upstream_health"
local MEMBER_PREFIX = "dyn:"

-- 简单 JSON 解析（仅处理 admin API 的 flat JSON）
local function json_decode(s)
    local obj = {}
    s = s:gsub("%s+", "")
    if s:sub(1, 1) ~= "{" or s:sub(-1) ~= "}" then
        return nil, "not an object"
    end
    s = s:sub(2, -2)
    for key, val in s:gmatch('"([^"]+)"%s*:%s*([^\n,}]+)') do
        val = val:gsub("%s+", "")
        if val:sub(1, 1) == '"' and val:sub(-1) == '"' then
            obj[key] = val:sub(2, -2)
        elseif val:match("^%d+%.?%d*$") then
            obj[key] = tonumber(val)
        elseif val == "true" then
            obj[key] = true
        elseif val == "false" then
            obj[key] = false
        elseif val == "null" then
            obj[key] = nil
        end
    end
    return obj
end

local function json_encode(obj)
    local function encode(v)
        if type(v) == "string" then
            local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"')
            return '"' .. escaped .. '"'
        elseif type(v) == "number" then
            return tostring(v)
        elseif type(v) == "boolean" then
            return tostring(v)
        elseif type(v) == "table" then
            local items = {}
            for k2, v2 in pairs(v) do
                items[#items + 1] = '"' .. tostring(k2) .. '":' .. encode(v2)
            end
            return "{" .. table.concat(items, ",") .. "}"
        else
            return "null"
        end
    end
    return encode(obj)
end

local function getenv(name, default)
    local value = runtime_config[name] or os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function get_dict()
    return ngx.shared[DICT_NAME]
end

-- 用管道分隔格式存储，balancer.lua 可以直接解析
local function encode_member(member)
    return member.host .. "|" .. member.port .. "|" .. member.weight
end

local function decode_member(s)
    local parts = {}
    for part in s:gmatch("[^|]+") do
        parts[#parts + 1] = part
    end
    if #parts < 2 then return nil end
    return {
        id = parts[1] .. ":" .. parts[2],
        host = parts[1],
        port = tonumber(parts[2]),
        weight = tonumber(parts[3]) or 1,
    }
end

local function parse_upstream_id(body)
    -- body.id 格式为 host:port，body.host/body.port 用于构建
    local id = body.id
    local port = body.port
    if not id and not body.host then
        return nil, "missing id or host"
    end
    if not id then
        id = body.host
    end
    if not port then
        if body.id then
            local p = body.id:match(":(%d+)$")
            if p then
                port = tonumber(p)
            else
                return nil, "missing port"
            end
        else
            return nil, "missing port"
        end
    end
    return {
        id = id .. ":" .. port,
        host = id,
        port = port,
        weight = tonumber(body.weight) or 1,
    }
end

local function list_upstreams()
    local dict = get_dict()
    local members = {}
    local all_keys = dict:get_keys(0)
    for _, key in ipairs(all_keys or {}) do
        if key:sub(1, #MEMBER_PREFIX) == MEMBER_PREFIX then
            local value = dict:get(key)
            if value then
                local member = decode_member(value)
                if member then
                    members[#members + 1] = member
                end
            end
        end
    end
    return members
end

local function send_json(status, body)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(json_encode(body))
    return ngx.exit(status)
end

function _M.serve()
    local method = ngx.req.get_method()
    local path = ngx.var.uri

    if path == "/admin/upstreams" then
        if method == "GET" then
            return send_json(200, {dynamic = list_upstreams()})
        end

        if method == "POST" or method == "PUT" then
            ngx.req.read_body()
            local body_str = ngx.req.get_body_data() or "{}"
            local body, err = json_decode(body_str)
            if not body then
                return send_json(400, {error = "invalid JSON: " .. (err or "parse error")})
            end

            local member, merr = parse_upstream_id(body)
            if not member then
                return send_json(400, {error = merr})
            end

            local dict = get_dict()
            local key = MEMBER_PREFIX .. member.id
            local ok2, err2 = dict:set(key, encode_member(member))
            if not ok2 then
                return send_json(500, {error = "failed to store: " .. (err2 or "unknown")})
            end

            state.save()
            return send_json(201, {message = "member added", member = member})
        end

        return send_json(405, {error = "method not allowed"})
    end

    local member_id = path:match("^/admin/upstreams/(.+)$")
    if member_id then
        local key = MEMBER_PREFIX .. member_id
        local dict = get_dict()

        if method == "GET" then
            local value = dict:get(key)
            if not value then
                return send_json(404, {error = "member not found"})
            end
            local member = decode_member(value)
            if not member then
                return send_json(500, {error = "corrupted data"})
            end
            return send_json(200, member)

        elseif method == "DELETE" then
            local exists = dict:get(key)
            if not exists then
                return send_json(404, {error = "member not found"})
            end
            dict:delete(key)
            state.save()
            return send_json(200, {message = "member deleted", id = member_id})

        elseif method == "PATCH" then
            ngx.req.read_body()
            local body_str = ngx.req.get_body_data() or "{}"
            local patch, perr = json_decode(body_str)
            if not patch then
                return send_json(400, {error = "invalid JSON: " .. (perr or "parse error")})
            end

            local value = dict:get(key)
            if not value then
                return send_json(404, {error = "member not found"})
            end
            local member = decode_member(value)
            if not member then
                return send_json(500, {error = "corrupted data"})
            end

            if patch.weight then member.weight = tonumber(patch.weight) end
            if patch.port then member.port = tonumber(patch.port) end
            if patch.host then
                member.host = patch.host
                member.id = patch.host .. ":" .. member.port
            end

            local ok4, err4 = dict:set(key, encode_member(member))
            if not ok4 then
                return send_json(500, {error = "failed to update: " .. (err4 or "unknown")})
            end
            state.save()
            return send_json(200, {message = "member updated", member = member})
        end

        return send_json(405, {error = "method not allowed for this path"})
    end

    -- /admin/keyval/{zone}/{key} - 通用键值存储
    local zone, kv_key = path:match("^/admin/keyval/([^/]+)/(.+)$")
    if zone and kv_key then
        local dict = get_dict()
        local store_key = "kv:" .. zone .. ":" .. kv_key

        if method == "GET" then
            local value = dict:get(store_key)
            if not value then
                return send_json(404, {error = "key not found"})
            end
            return send_json(200, {key = kv_key, value = value, zone = zone})

        elseif method == "PUT" then
            ngx.req.read_body()
            local body_str = ngx.req.get_body_data() or "{}"
            local body, berr = json_decode(body_str)
            if not body then
                return send_json(400, {error = "invalid JSON"})
            end
            local ttl = tonumber(body.ttl) or 0
            dict:set(store_key, tostring(body.value or ""), ttl)
            return send_json(200, {message = "ok", key = kv_key, zone = zone})

        elseif method == "DELETE" then
            local exists = dict:get(store_key)
            if not exists then
                return send_json(404, {error = "key not found"})
            end
            dict:delete(store_key)
            return send_json(200, {message = "deleted", key = kv_key, zone = zone})
        end

        return send_json(405, {error = "method not allowed"})
    end

    -- /admin/keyval/{zone} - 列出 zone 下所有 key
    local list_zone = path:match("^/admin/keyval/([^/]+)$")
    if list_zone then
        if method == "GET" then
            local dict = get_dict()
            local prefix = "kv:" .. list_zone .. ":"
            local keys = {}
            local all_keys = dict:get_keys(0)
            for _, k in ipairs(all_keys or {}) do
                if k:sub(1, #prefix) == prefix then
                    keys[#keys + 1] = {
                        key = k:sub(#prefix + 1),
                        value = dict:get(k),
                    }
                end
            end
            return send_json(200, {zone = list_zone, keys = keys})
        end
        return send_json(405, {error = "method not allowed"})
    end

    return send_json(404, {error = "not found"})
end

return _M
