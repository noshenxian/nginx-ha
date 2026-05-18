local _M = {}

local function random_hex()
    local parts = {}
    for i = 1, 4 do
        parts[i] = string.format("%08x", math.random(0, 0xffffffff))
    end
    return table.concat(parts, "")
end

function _M.ensure()
    local request_id = ngx.var.http_x_request_id
    if not request_id or request_id == "" then
        request_id = random_hex()
    end
    ngx.var.gateway_request_id = request_id
end

return _M
