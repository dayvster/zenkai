local trigger_prefixes = { "os", "mac", "sys" }
local pending = {}

local function add_result(title, subtitle, icon, bin, ...)
    local id = api.add_result(title, subtitle, icon, "ExecCmd")
    if bin then
        pending[id] = { bin, ... }
    end
end

local function info(title, subtitle, icon)
    api.add_result(title, subtitle, icon, "NoReturn")
end

local function split(s)
    local out = {}
    for t in s:gmatch("%S+") do
        out[#out + 1] = t
    end
    return out
end

local function lines(s)
    local out = {}
    for l in (s .. "\n"):gmatch("(.-)\n") do
        if l ~= "" then
            out[#out + 1] = l
        end
    end
    return out
end

local function power_palette()
    add_result("Lock Screen", "zenkai-osx-power lock", "system-lock-screen", "zenkai-osx-power", "lock")
    add_result("Sleep", "zenkai-osx-power sleep", "system-suspend", "zenkai-osx-power", "sleep")
    add_result("Display Sleep", "zenkai-osx-power displaysleep", "video-display", "zenkai-osx-power", "displaysleep")
    add_result("Restart", "zenkai-osx-power restart", "system-reboot", "zenkai-osx-power", "restart")
    add_result("Shut Down", "zenkai-osx-power shutdown", "system-shutdown", "zenkai-osx-power", "shutdown")
    add_result("Log Out", "zenkai-osx-power logout", "system-log-out", "zenkai-osx-power", "logout")
end

local function audio_status()
    local out = api.run("zenkai-osx-audio", "status")
    if out == nil then
        return
    end
    local v, m = out:match("(%d+)%s*(%a+)")
    if v then
        info("Volume: " .. v .. "% (" .. (m == "true" and "muted" or "unmuted") .. ")", "audio status", "audio-volume-high")
    end
end

local function audio_palette()
    audio_status()
    add_result("Volume Up", "zenkai-osx-audio up", "audio-volume-high", "zenkai-osx-audio", "up")
    add_result("Volume Down", "zenkai-osx-audio down", "audio-volume-low", "zenkai-osx-audio", "down")
    add_result("Mute", "zenkai-osx-audio mute", "audio-volume-muted", "zenkai-osx-audio", "mute")
    add_result("Unmute", "zenkai-osx-audio unmute", "audio-volume-high", "zenkai-osx-audio", "unmute")
end

local function system_status()
    local out = api.run("zenkai-osx-system", "status")
    if out == nil then
        info("System status unavailable", "zenkai-osx-system not found", "preferences-system")
        return
    end
    local map = {}
    for _, l in ipairs(lines(out)) do
        local k, rest = l:match("^([%w_]+)\t(.+)$")
        if k then
            map[k] = rest
        end
    end
    if map.battery then
        local p, st = map.battery:match("(%d+)%s*(%a+)")
        info("Battery: " .. (p or "?") .. "%", st or map.battery, "battery")
    end
    if map.memory then
        info("Memory", map.memory, "memory")
    end
    if map.disk then
        info("Disk", map.disk, "drive-harddisk")
    end
    if map.uptime then
        info("Uptime", map.uptime, "clock")
    end
end

local function strip_prefix(q)
    if q == "os" or q == "mac" or q == "sys" then
        return ""
    end
    for _, p in ipairs(trigger_prefixes) do
        if q:sub(1, #p) == p then
            local rest = q:sub(#p + 1)
            rest = rest:gsub("^%s*[:%-]?%s*", "")
            return rest
        end
    end
    return nil
end

local function handle_rest(rest)
    if rest == "" then
        power_palette()
        audio_palette()
        add_result("System Status", "battery, memory, disk, uptime", "utilities-system-monitor", "status")
        return
    end

    local args = split(rest)
    local head = args[1]:lower()

    if head == "status" or head == "sys" then
        system_status()
        audio_status()
        return
    end

    if head == "power" or head == "pwr" then
        power_palette()
        return
    end

    if head == "audio" or head == "vol" or head == "volume" then
        audio_palette()
        local target = args[2]
        if target and target:match("^%d+$") then
            add_result("Set Volume to " .. target .. "%", "zenkai-osx-audio set " .. target, "audio-volume-medium", "zenkai-osx-audio", "set", target)
        end
        return
    end

    if head == "lock" then
        add_result("Lock Screen", "", "system-lock-screen", "zenkai-osx-power", "lock")
    elseif head == "sleep" then
        add_result("Sleep", "", "system-suspend", "zenkai-osx-power", "sleep")
    elseif head == "displaysleep" or head == "display" then
        add_result("Display Sleep", "", "video-display", "zenkai-osx-power", "displaysleep")
    elseif head == "restart" then
        add_result("Restart", "", "system-reboot", "zenkai-osx-power", "restart")
    elseif head == "shutdown" or head == "off" then
        add_result("Shut Down", "", "system-shutdown", "zenkai-osx-power", "shutdown")
    elseif head == "logout" then
        add_result("Log Out", "", "system-log-out", "zenkai-osx-power", "logout")
    else
        power_palette()
    end
end

function on_query(query)
    if query == "" or #query < 2 then
        return
    end
    local rest = strip_prefix(query:lower())
    if rest == nil then
        return
    end
    handle_rest(rest)
end

function on_open(id)
    local act = pending[id]
    if act then
        if act[1] == "status" then
            system_status()
        else
            api.exec(table.unpack(act))
        end
        pending[id] = nil
    end
end