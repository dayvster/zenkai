local trigger_prefixes = { "hypr", "wm" }

local function strip_prefix(q)
    if q == "hypr" or q == "wm" then
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

local function add_result(title, subtitle, cmd, icon)
    api.add_result(title, subtitle, icon, "ExecCmd", cmd)
end

local function custom_palette()
    local commands = plugin_config and plugin_config.commands
    if not commands then
        return
    end
    for _, c in ipairs(commands) do
        if type(c) == "table" and c.title and c.exec and c.exec ~= "" then
            add_result(c.title, c.subtitle or c.exec, c.exec, c.icon or "system-run")
        end
    end
end

local function palette()
    if plugin_config and plugin_config.replace == true then
        custom_palette()
        return
    end
    local items = {
        { "Workspace 1", "hyprctl dispatch workspace 1", "view-fullscreen" },
        { "Workspace 2", "hyprctl dispatch workspace 2", "view-fullscreen" },
        { "Workspace 3", "hyprctl dispatch workspace 3", "view-fullscreen" },
        { "Workspace 4", "hyprctl dispatch workspace 4", "view-fullscreen" },
        { "Workspace 5", "hyprctl dispatch workspace 5", "view-fullscreen" },
        { "Next workspace", "hyprctl dispatch workspace +1", "go-next" },
        { "Previous workspace", "hyprctl dispatch workspace -1", "go-previous" },
        { "Next empty workspace", "hyprctl dispatch workspace empty", "go-next" },
        { "Move window to next workspace", "hyprctl dispatch movetoworkspace +1", "go-jump" },
        { "Toggle floating", "hyprctl dispatch togglefloating", "preferences-system" },
        { "Toggle fullscreen", "hyprctl dispatch fullscreen", "view-restore" },
        { "Toggle pin", "hyprctl dispatch pin", "pin" },
        { "Focus next window", "hyprctl dispatch cyclenext", "go-down" },
        { "Focus previous window", "hyprctl dispatch cyclenext prev", "go-up" },
        { "Kill active window", "hyprctl dispatch killactive", "edit-delete" },
        { "Lock screen", "hyprctl dispatch exec hyprlock", "system-lock-screen" },
        { "Reload config", "hyprctl reload", "view-refresh" },
        { "Exit Hyprland", "hyprctl dispatch exit", "application-exit" },
        { "Screenshot (full)", "grim - | wl-copy", "camera-photo" },
        { "Screenshot (region)", "grim -g \"$(slurp)\" - | wl-copy", "camera-photo" },
    }
    for _, it in ipairs(items) do
        add_result(it[1], it[2], it[2], it[3])
    end
    custom_palette()
end

local function workspace_result(target, extra)
    if target == nil or target == "" then
        palette()
        return
    end
    local t = target:lower()
    if extra ~= nil and extra ~= "" and t == "name" then
        add_result("Workspace name:" .. extra, "hyprctl dispatch workspace name:" .. extra, "hyprctl dispatch workspace name:" .. extra, "view-fullscreen")
        return
    end
    if t == "empty" then
        add_result("Next empty workspace", "hyprctl dispatch workspace empty", "hyprctl dispatch workspace empty", "go-next")
    elseif t == "prev" or t == "previous" then
        add_result("Previous workspace", "hyprctl dispatch workspace previous", "hyprctl dispatch workspace previous", "go-previous")
    elseif t == "special" or t == "sp" then
        add_result("Toggle special workspace", "hyprctl dispatch togglespecialworkspace", "hyprctl dispatch togglespecialworkspace", "view-fullscreen")
    elseif t == "name" then
        add_result("Workspace by name", "hyprctl dispatch workspace name:", "hyprctl dispatch workspace name:", "view-fullscreen")
    elseif t:match("^[%+%-]?%d+$") then
        add_result("Workspace " .. target, "hyprctl dispatch workspace " .. target, "hyprctl dispatch workspace " .. target, "view-fullscreen")
    else
        add_result("Workspace name:" .. target, "hyprctl dispatch workspace name:" .. target, "hyprctl dispatch workspace name:" .. target, "view-fullscreen")
    end
end

local function move_result(target)
    if target == nil or target == "" then
        add_result("Move window to next workspace", "hyprctl dispatch movetoworkspace +1", "hyprctl dispatch movetoworkspace +1", "go-jump")
        return
    end
    local t = target:lower()
    if t == "empty" then
        add_result("Move window to empty workspace", "hyprctl dispatch movetoworkspace empty", "hyprctl dispatch movetoworkspace empty", "go-jump")
    elseif t == "special" or t == "sp" then
        add_result("Move window to special workspace", "hyprctl dispatch movetoworkspacesilent special:1", "hyprctl dispatch movetoworkspacesilent special:1", "go-jump")
    elseif t:match("^[%+%-]?%d+$") then
        add_result("Move window to workspace " .. target, "hyprctl dispatch movetoworkspace " .. target, "hyprctl dispatch movetoworkspace " .. target, "go-jump")
    else
        add_result("Move window to name:" .. target, "hyprctl dispatch movetoworkspace name:" .. target, "hyprctl dispatch movetoworkspace name:" .. target, "go-jump")
    end
end

local function monitor_result(target)
    if target == nil or target == "" or target == "next" or target == "+1" then
        add_result("Focus next monitor", "hyprctl dispatch focusmonitor +1", "hyprctl dispatch focusmonitor +1", "video-display")
        return
    end
    if target == "prev" or target == "previous" or target == "-1" then
        add_result("Focus previous monitor", "hyprctl dispatch focusmonitor -1", "hyprctl dispatch focusmonitor -1", "video-display")
        return
    end
    if target:match("^%d+$") then
        add_result("Focus monitor " .. target, "hyprctl dispatch focusmonitor " .. target, "hyprctl dispatch focusmonitor " .. target, "video-display")
        return
    end
    palette()
end

local function move_monitor_result(target)
    if target == nil or target == "" or target == "next" or target == "+1" then
        add_result("Move window to next monitor", "hyprctl dispatch movewindow mon:+1", "hyprctl dispatch movewindow mon:+1", "video-display")
        return
    end
    if target == "prev" or target == "previous" or target == "-1" then
        add_result("Move window to previous monitor", "hyprctl dispatch movewindow mon:-1", "hyprctl dispatch movewindow mon:-1", "video-display")
        return
    end
    if target:match("^%d+$") then
        add_result("Move window to monitor " .. target, "hyprctl dispatch movewindow mon:" .. target, "hyprctl dispatch movewindow mon:" .. target, "video-display")
        return
    end
    palette()
end

local function screenshot_result(target)
    if target == "full" or target == "all" then
        add_result("Screenshot (full)", "grim - | wl-copy", "grim - | wl-copy", "camera-photo")
    elseif target == "region" or target == "select" or target == "area" or target == "rect" then
        add_result("Screenshot (region)", "grim -g \"$(slurp)\" - | wl-copy", "grim -g \"$(slurp)\" - | wl-copy", "camera-photo")
    else
        add_result("Screenshot (full)", "grim - | wl-copy", "grim - | wl-copy", "camera-photo")
    end
end

local function notify_result(args)
    local msg = ""
    for i = 2, #args do
        if msg ~= "" then
            msg = msg .. " "
        end
        msg = msg .. args[i]
    end
    if msg == "" then
        palette()
        return
    end
    add_result("Notify: " .. msg, "hyprctl notify -1 5000 \"rgb(ff1ea3)\" \"" .. msg .. "\"", "hyprctl notify -1 5000 \"rgb(ff1ea3)\" \"" .. msg .. "\"", "preferences-desktop-notification")
end

local function handle_rest(cmd)
    if cmd == "" then
        palette()
        return
    end

    local args = {}
    for t in string.gmatch(cmd, "%S+") do
        args[#args + 1] = t
    end
    if #args == 0 then
        palette()
        return
    end

    local head = args[1]:lower()

    if head == "ws" or head == "workspace" or head == "work" then
        workspace_result(args[2], args[3])
        return
    end

    if head == "move" or head == "mvtows" then
        move_result(args[2])
        return
    end

    if head:match("^[%+%-]?%d+$") then
        workspace_result(head)
        return
    end

    if head == "float" or head == "floating" then
        add_result("Toggle floating", "hyprctl dispatch togglefloating", "hyprctl dispatch togglefloating", "preferences-system")
        return
    end

    if head == "full" or head == "fullscreen" then
        add_result("Toggle fullscreen", "hyprctl dispatch fullscreen", "hyprctl dispatch fullscreen", "view-restore")
        return
    end

    if head == "pin" then
        add_result("Toggle pin", "hyprctl dispatch pin", "hyprctl dispatch pin", "pin")
        return
    end

    if head == "kill" then
        add_result("Kill active window", "hyprctl dispatch killactive", "hyprctl dispatch killactive", "edit-delete")
        return
    end

    if head == "lock" or head == "sleep" then
        add_result("Lock screen", "hyprctl dispatch exec hyprlock", "hyprctl dispatch exec hyprlock", "system-lock-screen")
        return
    end

    if head == "next" then
        add_result("Focus next window", "hyprctl dispatch cyclenext", "hyprctl dispatch cyclenext", "go-down")
        return
    end

    if head == "prev" then
        add_result("Focus previous window", "hyprctl dispatch cyclenext prev", "hyprctl dispatch cyclenext prev", "go-up")
        return
    end

    if head == "mon" or head == "monitor" then
        monitor_result(args[2])
        return
    end

    if head == "mvtomon" or head == "movetomonitor" then
        move_monitor_result(args[2])
        return
    end

    if head == "reload" then
        add_result("Reload config", "hyprctl reload", "hyprctl reload", "view-refresh")
        return
    end

    if head == "exit" or head == "quit" then
        add_result("Exit Hyprland", "hyprctl dispatch exit", "hyprctl dispatch exit", "application-exit")
        return
    end

    if head == "shot" or head == "screenshot" or head == "screen" then
        screenshot_result(args[2])
        return
    end

    if head == "notify" then
        notify_result(args)
        return
    end

    palette()
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
end
