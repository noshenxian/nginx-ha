local _M = {}
local runtime_config = require("runtime_config")
local dns_resolver = require("resty.dns.resolver")

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

local function parse_duration(value, default)
    value = value or default
    local number, unit = tostring(value):match("^(%d+)(%a*)$")
    number = tonumber(number)
    if not number then
        return default
    end
    if unit == "ms" then
        return number / 1000
    end
    return number
end

-- 健康检查匹配规则
-- status_codes: 逗号分隔的单个状态码或范围 "200,201,300-399"
-- body_pattern: body 正则，不为空字符串时生效
-- header_name / header_value: 匹配指定 header value，可含正则
local function build_match_config()
    local raw_codes = getenv("HEALTH_CHECK_STATUS_CODES", "")
    local body_pattern = getenv("HEALTH_CHECK_BODY_MATCH", "")
    local header_name = getenv("HEALTH_CHECK_HEADER_NAME", "")
    local header_value = getenv("HEALTH_CHECK_HEADER_MATCH", "")

    local status_ranges = {}
    if raw_codes and raw_codes ~= "" then
        for _, part in ipairs(ngx.re.match(raw_codes, [[(\d+-\d+|\d+)]], "jo")) do
            local token = part[0]
            if token:find("-") then
                local lo = tonumber(token:match("^(%d+)"))
                local hi = tonumber(token:match("(%d+)$"))
                table.insert(status_ranges, {lo = lo, hi = hi})
            else
                local code = tonumber(token)
                table.insert(status_ranges, {lo = code, hi = code})
            end
        end
    end

    local body_re = nil
    if body_pattern and body_pattern ~= "" then
        local opts = getenv("HEALTH_CHECK_BODY_MATCH_NEGATE", "") == "true" and "jo" or "o"
        body_re, err = ngx.re.compile(body_pattern, opts)
        if not body_re then
            ngx.log(ngx.WARN, "invalid HEALTH_CHECK_BODY_MATCH regex: ", err, ", ignoring")
            body_re = nil
        end
    end

    local header_re = nil
    if header_name and header_name ~= "" and header_value and header_value ~= "" then
        header_re, err = ngx.re.compile(header_value, "jo")
        if not header_re then
            ngx.log(ngx.WARN, "invalid HEALTH_CHECK_HEADER_MATCH regex: ", err, ", ignoring")
            header_re = nil
        end
    end

    return {
        status_ranges = status_ranges,
        body_re = body_re,
        body_negate = getenv("HEALTH_CHECK_BODY_MATCH_NEGATE", "") == "true",
        header_name = header_name ~= "" and header_name or nil,
        header_re = header_re,
    }
end

-- 判断单个状态码是否在范围内
local function status_match(code, ranges)
    if #ranges == 0 then
        return code >= 200 and code < 400
    end
    for _, r in ipairs(ranges) do
        if code >= r.lo and code <= r.hi then
            return true
        end
    end
    return false
end

local function parse_upstreams()
    local raw = getenv("BACKEND_UPSTREAMS", "")
    if raw == "" then
        raw = getenv("BACKEND_UPSTREAM", "")
    end

    local upstreams = {}
    for item in raw:gmatch("[^,]+") do
        local host, port = item:match("^%s*([^:,%s]+):(%d+):?%d*%s*$")
        if host then
            upstreams[#upstreams + 1] = {
                id = host .. ":" .. port,
                host = host,
                port = tonumber(port),
            }
        end
    end
    return upstreams
end

local function key(prefix, upstream)
    return prefix .. ":" .. upstream.id
end

local function is_ip_address(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

local function resolver_nameserver()
    local resolver = getenv("DNS_RESOLVER", "127.0.0.11 ipv6=off valid=10s")
    return resolver:match("^(%S+)")
end

local function resolve_host(host)
    if is_ip_address(host) then
        return host
    end

    local resolver, err = dns_resolver:new({
        nameservers = { resolver_nameserver() },
        retrans = 2,
        timeout = 1000,
    })
    if not resolver then
        ngx.log(ngx.ERR, "failed to create dns resolver: ", err)
        return nil
    end

    local answers, query_err = resolver:query(host, { qtype = resolver.TYPE_A })
    if not answers then
        ngx.log(ngx.ERR, "failed to resolve upstream host ", host, ": ", query_err)
        return nil
    end

    for _, answer in ipairs(answers) do
        if answer.address then
            ngx.shared.upstream_health:set("address:" .. host, answer.address, math.max(answer.ttl or 10, 1))
            return answer.address
        end
    end

    ngx.log(ngx.ERR, "no A record found for upstream host ", host)
    return nil
end

local function check_one(upstream, match_cfg)
    local address = resolve_host(upstream.host)
    if not address then
        return false
    end

    local timeout_ms = parse_duration(getenv("HEALTH_CHECK_TIMEOUT", "2s"), 2) * 1000
    local path = getenv("HEALTH_CHECK_PATH", "/healthz")
    local host_header = getenv("HEALTH_CHECK_HOST_HEADER", upstream.host)

    local sock = ngx.socket.tcp()
    sock:settimeout(timeout_ms)

    local ok, err = sock:connect(address, upstream.port)
    if not ok then
        return false
    end

    local req = {
        "GET " .. path .. " HTTP/1.1\r\n",
        "Host: " .. host_header .. "\r\n",
        "Connection: close\r\n",
        "Accept: */*\r\n",
        "\r\n",
    }
    local send_ok, send_err = sock:send(req)
    if not send_ok then
        sock:close()
        return false
    end

    -- 读取状态行
    local status_line, rl_err = sock:receive("*l")
    if not status_line then
        sock:close()
        return false
    end

    local http_version, status_code_str = status_line:match("^HTTP/(%d%.%d)%s+(%d+)")
    if not http_version or not status_code_str then
        sock:close()
        return false
    end
    local status_code = tonumber(status_code_str)

    -- 读取 headers
    local headers = {}
    while true do
        local line, r_err = sock:receive("*l")
        if not line or line == "\r" or line == "" then
            break
        end
        local k, v = line:match("^([^:]+):%s*(.+)")
        if k and v then
            headers[k:lower()] = v
        end
    end

    -- 读取 body（仅当有 body 匹配规则时）
    local body = ""
    if match_cfg.body_re or match_cfg.header_re then
        local content_length = nil
        if headers["content-length"] then
            content_length = tonumber(headers["content-length"])
        elseif headers["transfer-encoding"] == "chunked" then
            -- 简化处理：chunked 先读一小段
            local chunk, cr_err = sock:receive("*l")
            if chunk then
                local len = tonumber(chunk, 16)
                if len and len > 0 then
                    local chunk_body, cb_err = sock:receive(len)
                    if chunk_body then
                        body = chunk_body
                    end
                    sock:receive("*l") -- 读 trailing CRLF
                end
            end
        end
        if not body and content_length and content_length > 0 then
            body = sock:receive(content_length)
        end
    end

    sock:close()

    -- ---- 匹配判断 ----
    -- 1. 状态码匹配
    if not status_match(status_code, match_cfg.status_ranges) then
        return false
    end

    -- 2. body 正则匹配
    if match_cfg.body_re then
        local matched = match_cfg.body_re and ngx.re.find(body, match_cfg.body_re, match_cfg.body_re._opts or "o")
        if match_cfg.body_negate then
            if matched then
                return false
            end
        else
            if not matched then
                return false
            end
        end
    end

    -- 3. header 匹配
    if match_cfg.header_re and match_cfg.header_name then
        local header_val = headers[match_cfg.header_name:lower()]
        if not header_val then
            return false
        end
        if not ngx.re.find(header_val, match_cfg.header_re, match_cfg.header_re._opts or "o") then
            return false
        end
    end

    return true
end

local function mark(upstream, ok)
    local dict = ngx.shared.upstream_health
    local fails = tonumber(getenv("HEALTH_CHECK_FAILS", "3")) or 3
    local passes = tonumber(getenv("HEALTH_CHECK_PASSES", "2")) or 2

    -- mandatory: 新成员初始 unhealthy 直到首次通过
    local mandatory = bool_env("HEALTH_CHECK_MANDATORY", false)
    local health_key_name = key("health", upstream)
    if mandatory and dict:get(health_key_name) == nil then
        dict:set(health_key_name, "unhealthy")
    end

    if ok then
        dict:incr(key("pass", upstream), 1, 0)
        dict:set(key("fail", upstream), 0)
        if (dict:get(key("pass", upstream)) or 0) >= passes then
            -- 记录恢复时间戳（slow_start 用）
            dict:set(key("recovered_at", upstream), ngx.now())
            dict:set(health_key_name, "healthy")
        end
    else
        dict:incr(key("fail", upstream), 1, 0)
        dict:set(key("pass", upstream), 0)
        if (dict:get(key("fail", upstream)) or 0) >= fails then
            dict:set(health_key_name, "unhealthy")
            dict:set(key("recovered_at", upstream), 0)
        end
    end
end

-- 缓存 match 配置，避免每次检查都解析正则
local match_cfg_cache = nil
local match_cfg_cache_time = 0

local function get_match_config()
    local now = ngx.now()
    if not match_cfg_cache or (now - match_cfg_cache_time) > 10 then
        match_cfg_cache = build_match_config()
        match_cfg_cache_time = now
    end
    return match_cfg_cache
end

-- SRV 服务发现：周期性查询 DNS SRV 记录，将结果写入动态上游
local function srv_discovery(premature)
    if premature then
        return
    end

    local srv_service = getenv("SRV_SERVICE", "")
    if srv_service == "" then
        return
    end

    local srv_domain = getenv("SRV_DOMAIN", "")
    if srv_domain == "" then
        return
    end

    local srv_name = srv_service .. "._tcp." .. srv_domain

    local resolver, err = dns_resolver:new({
        nameservers = { resolver_nameserver() },
        retrans = 2,
        timeout = 2000,
    })
    if not resolver then
        ngx.log(ngx.ERR, "SRV: failed to create resolver: ", err)
        return
    end

    local answers, query_err = resolver:query(srv_name, { qtype = resolver.TYPE_SRV })
    if not answers then
        ngx.log(ngx.WARN, "SRV: query failed for ", srv_name, ": ", query_err)
        return
    end

    local dict = ngx.shared.upstream_health
    if not dict then
        return
    end

    -- 清除旧的 SRV 成员（前缀 srvdyn:）
    local old_keys = dict:get_keys(0)
    for _, key in ipairs(old_keys or {}) do
        if key:sub(1, 6) == "srvdyn" then
            dict:delete(key)
        end
    end

    -- 添加新成员
    for _, answer in ipairs(answers) do
        if answer.target and answer.port then
            local member = answer.target .. "|" .. answer.port .. "|" .. (answer.weight or 1)
            local key = "srvdyn:" .. answer.target .. ":" .. answer.port
            dict:set(key, member)
        end
    end

    local refresh_interval = parse_duration(getenv("SRV_REFRESH_INTERVAL", "30s"), 30)
    ngx.timer.at(refresh_interval, srv_discovery)
end

local function run(premature)
    if premature or not bool_env("HEALTH_CHECK_ENABLED", true) then
        return
    end

    local cfg = get_match_config()
    for _, upstream in ipairs(parse_upstreams()) do
        mark(upstream, check_one(upstream, cfg))
    end

    ngx.timer.at(parse_duration(getenv("HEALTH_CHECK_INTERVAL", "5s"), 5), run)
end

function _M.start()
    if bool_env("HEALTH_CHECK_ENABLED", true) then
        ngx.timer.at(0, run)
    end
    -- SRV 服务发现
    if getenv("SRV_SERVICE", "") ~= "" then
        ngx.timer.at(0, srv_discovery)
    end
end

return _M
