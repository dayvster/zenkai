local targets = {}
local browser_icons = {}

local function valid_host(host, explicit_scheme)
    if host == "localhost" then return true end
    if #host > 253 or host:find("[^%w%.%-]") or host:find("..", 1, true)
        or host:sub(1, 1) == "." or host:sub(-1) == "." then return false end
    if host:match("^[%d%.]+$") then
        local count = 0
        for part in host:gmatch("[^.]+") do
            if #part > 3 or tonumber(part) > 255 then return false end
            count = count + 1
        end
        return count == 4
    end
    for label in host:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return false end
    end
    if explicit_scheme then return host ~= "" end
    local tld = host:match("%.([%a]+)$")
    return tld ~= nil and #tld >= 2
end

function normalize_url(query)
    local text = query:match("^%s*(.-)%s*$")
    if text == "" or text:find("[%s%c<>\"\\]") then return nil end
    local scheme, rest = text:match("^([%a][%w+.-]*)://(.*)$")
    local explicit_scheme = scheme ~= nil
    if scheme then
        scheme = scheme:lower()
        if scheme ~= "http" and scheme ~= "https" then return nil end
    else
        rest = text
        scheme = "https"
    end
    local authority, suffix = rest:match("^([^/?#]+)(.*)$")
    if not authority or authority:find("@", 1, true) then return nil end
    local host, port = authority:match("^(.-):(%d+)$")
    host = (host or authority):lower()
    if port and (tonumber(port) < 1 or tonumber(port) > 65535) then return nil end
    if not valid_host(host, explicit_scheme) then return nil end
    if not explicit_scheme and host == "localhost" then
        if not port then return nil end
        scheme = "http"
    end
    return scheme .. "://" .. host .. (port and ":" .. port or "") .. suffix
end

function on_query(query)
    targets = {}
    local url = normalize_url(query)
    if not url then return end
    local scheme = url:match("^(%a+)://")
    if not browser_icons[scheme] then browser_icons[scheme] = api.browser_icon(scheme) end
    local id = api.add_result("Open " .. url, "Open in your default browser", browser_icons[scheme])
    if id then
        targets[id] = url
        api.add_action(id, "Copy URL", 1, "edit-copy")
    end
end

function on_open(id)
    if targets[id] then api.open_browser(targets[id]) end
end

function on_action(id, action)
    if action == 1 and targets[id] then api.copy_text(targets[id]) end
end
