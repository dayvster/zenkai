-- Browser integration for Zenkai.
--
-- Talks to `zenkai-web-bridge`, the CLI half of ../zenkai-web-bridge. The CLI relays
-- each request through a per-browser native messaging host to the Zenkai Web
-- extension, which answers with the browser's tabs, history or bookmarks.

local CLI = "zenkai-web-bridge"
local MAX_RESULTS = 100

local targets = {}
local current_query = ""

local function trim(text)
    return text:match("^%s*(.-)%s*$")
end

local function notice(title, detail)
    api.add_result(title, detail or "", "dialog-information", "NoReturn")
end

-- The CLI writes tab-separated lines and escapes tabs/newlines inside fields.
local function split_fields(line, count)
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = field
        if #fields == count then break end
    end
    return fields
end

local function each_line(text, callback)
    for line in text:gmatch("[^\n]+") do callback(line) end
end

local function run_cli(...)
    local output = api.run(CLI, ...)
    if not output then
        notice("zenkai-web-bridge is not available",
            "Install the CLI in PATH and run `zenkai-web-bridge install`")
        return nil
    end
    return output
end

-- Turns the CLI's A/P/S/M/I flags into readable words.
local flag_names = { A = "active", P = "pinned", S = "playing audio", M = "muted", I = "private" }
local function describe_flags(flags)
    local words = {}
    for flag in flags:gmatch(".") do
        local name = flag_names[flag]
        if name then words[#words + 1] = name end
    end
    return table.concat(words, ", ")
end

local function add_tab(row)
    local title = row.title ~= "" and row.title or row.url
    local detail = row.url
    if row.browser ~= "" then detail = row.browser .. " — " .. detail end
    local flags = describe_flags(row.flags)
    if flags ~= "" then detail = detail .. "  (" .. flags .. ")" end

    local id = api.add_result(title, detail, "internet-web-browser")
    if not id then return end

    local pinned = row.flags:find("P", 1, true) ~= nil
    local muted = row.flags:find("M", 1, true) ~= nil
    targets[id] = { kind = "tab", target = row.target, url = row.url }

    api.add_action(id, "Close Tab", 1, "window-close")
    api.add_action(id, "Reload Tab", 2, "view-refresh")
    api.add_action(id, "Duplicate Tab", 3, "edit-copy")
    api.add_action(id, pinned and "Unpin Tab" or "Pin Tab", 4, pinned and "window-unpin" or "window-pin")
    api.add_action(id, muted and "Unmute Tab" or "Mute Tab", 5, muted and "audio-volume-high" or "audio-volume-muted")
    api.add_action(id, "Move to New Window", 6, "window-new")
    api.add_action(id, "Close Other Tabs", 7, "window-close")
    api.add_action(id, "Bookmark Tab", 8, "user-bookmarks")
    api.add_action(id, "Copy URL", 9, "edit-copy")
end

local function add_builtin(title, subtitle, icon, args)
    local id = api.add_result(title, subtitle, icon)
    if not id then return end
    targets[id] = { kind = "command", args = args }
end

-- Bare hosts, explicit schemes and localhost:port are worth offering as new tabs.
local function looks_like_address(text)
    if text == "" or text:find("[%s%c]") then return false end
    local scheme = text:match("^([%a][%w+.-]*)://")
    if scheme then
        scheme = scheme:lower()
        return scheme == "http" or scheme == "https"
    end
    if text:match("^localhost:%d+$") then return true end
    return text:match("^[%w%-%.]+%.[%a][%w%-%.]*$") ~= nil
end

local function tab_query(term)
    local output = run_cli("tabs")
    if not output then return end
    if output == "" then
        notice("No browser connected",
            "Load the Zenkai Web extension and run `zenkai-web-bridge install`")
        return
    end

    local needle = term:lower()
    local shown = 0
    each_line(output, function(line)
        if shown >= MAX_RESULTS then return end
        local fields = split_fields(line, 5)
        if #fields < 5 then return end
        local row = { target = fields[1], browser = fields[2], flags = fields[3], title = fields[4], url = fields[5] }
        if needle ~= "" and not row.title:lower():find(needle, 1, true)
            and not row.url:lower():find(needle, 1, true) then
            return
        end
        add_tab(row)
        shown = shown + 1
    end)

    if looks_like_address(term) then
        add_builtin("Open " .. term .. " in a New Tab", "zenkai-web-bridge open " .. term,
            "internet-web-browser", { "open", term })
    elseif shown == 0 then
        notice("No matching tabs", "No open tab matches \"" .. term .. "\"")
    end

    if term == "" then
        add_builtin("New Tab", "Open a new browser tab", "internet-web-browser", { "new-tab" })
        add_builtin("New Window", "Open a new browser window", "window-new", { "new-window" })
        add_builtin("New Private Window", "Open a private browsing window", "view-private", { "new-window", "--private" })
        add_builtin("Reopen Closed Tab", "Restore the most recently closed tab or window", "edit-undo", { "reopen" })
        add_builtin("Close Duplicate Tabs", "Close tabs whose URL is already open", "window-close", { "close-duplicates" })
    end
end

local function link_query(cmd, term)
    local output = run_cli(cmd, term)
    if not output then return end

    local count = 0
    each_line(output, function(line)
        if count >= MAX_RESULTS then return end
        local fields = split_fields(line, 4)
        if #fields < 4 then return end
        local title = fields[3] ~= "" and fields[3] or fields[4]
        local subtitle = fields[2] .. " — " .. fields[4]
        local id = api.add_result(title, subtitle,
            cmd == "history" and "document-open-recent" or "user-bookmarks")
        if not id then return end
        targets[id] = { kind = "link", url = fields[4] }
        api.add_action(id, "Copy URL", 1, "edit-copy")
        count = count + 1
    end)

    if count == 0 then
        local label = cmd == "history" and "history entries" or "bookmarks"
        notice("No matching " .. label, term == "" and "Nothing to show" or "Nothing matches \"" .. term .. "\"")
    end
end

function on_query(query)
    targets = {}
    current_query = query

    local lower = query:lower()
    if lower:sub(1, 4) == "tab:" then
        tab_query(trim(query:sub(5)))
    elseif lower:sub(1, 5) == "hist:" then
        link_query("history", trim(query:sub(6)))
    elseif lower:sub(1, 3) == "bm:" then
        link_query("bookmarks", trim(query:sub(4)))
    end
end

function on_open(id)
    local target = targets[id]
    if not target then return end
    if target.kind == "tab" then
        api.run(CLI, "activate", target.target)
    elseif target.kind == "link" then
        api.run(CLI, "open", target.url)
    elseif target.kind == "command" then
        api.run(CLI, table.unpack(target.args))
    end
end

local action_commands = {
    [1] = "close",
    [2] = "reload",
    [3] = "duplicate",
    [4] = "pin",
    [5] = "mute",
    [6] = "detach",
    [7] = "close-others",
    [8] = "bookmark",
}

function on_action(id, action)
    local target = targets[id]
    if not target then return end
    if target.kind == "link" then
        if action == 1 then api.copy_text(target.url) end
        return
    end
    if target.kind ~= "tab" then return end
    if action == 9 then
        api.copy_text(target.url)
        return
    end
    local command = action_commands[action]
    if not command then return end

    api.run(CLI, command, target.target)
    -- Re-run the query so the list reflects the new tab state.
    if current_query ~= "" then api.set_query(current_query) end
end
