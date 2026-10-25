local defaults = {
    { title = "Search Google", url = "https://www.google.com/search?q={query}" },
    { title = "Search GitHub", url = "https://github.com/search?q={query}" },
}
local targets = {}

local function encode(text)
    return (text:gsub("[^%w%-_%.~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function on_query(query)
    targets = {}
    if query:sub(1, 5):lower() ~= "link:" then return end
    local term = query:sub(6):match("^%s*(.-)%s*$")
    local commands = {}
    if not (plugin_config and plugin_config.replace) then
        for _, command in ipairs(defaults) do commands[#commands + 1] = command end
    end
    for _, command in ipairs(plugin_config and plugin_config.commands or {}) do
        commands[#commands + 1] = command
    end
    for _, command in ipairs(commands) do
        local url = command.url
        if url and (url:match("^https://") or url:match("^http://")) then
            local template = url:find("{query}", 1, true)
            if template or term == "" or command.title:lower():find(term:lower(), 1, true) then
                if not template or term ~= "" then
                    local target = url:gsub("{query}", function() return encode(term) end)
                    local id = api.add_result(command.title, command.subtitle or target,
                        command.icon or "internet-web-browser")
                    if id then
                        targets[id] = target
                        api.add_action(id, "Copy URL", 1, "edit-copy")
                    end
                else
                    api.add_result(command.title, "Type search text after link:",
                        command.icon or "internet-web-browser", "NoReturn")
                end
            end
        end
    end
end

function on_open(id)
    if targets[id] then api.open_url(targets[id]) end
end

function on_action(id, action)
    if action == 1 and targets[id] then api.copy_text(targets[id]) end
end
