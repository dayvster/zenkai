local snippets = {}

function on_query(query)
    snippets = {}
    if query:sub(1, 5):lower() ~= "snip:" then return end
    local term = query:sub(6):match("^%s*(.-)%s*$"):lower()
    local commands = plugin_config and plugin_config.commands or {}
    for _, command in ipairs(commands) do
        if command.text and (term == "" or command.title:lower():find(term, 1, true)
            or (command.subtitle or ""):lower():find(term, 1, true)) then
            local id = api.add_result(command.title, command.subtitle or "Enter to copy",
                command.icon or "edit-paste", "NoReturn")
            if id then
                snippets[id] = command.text
                api.add_action(id, "Copy Snippet", 1, "edit-copy")
            end
        end
    end
    if #commands == 0 then
        api.add_result("Add your snippets", "Configure snippets.json · see README",
            "dialog-information", "NoReturn")
    end
end

function on_open(id)
    if snippets[id] then api.copy_text(snippets[id]) end
end

function on_action(id, action)
    if action == 1 then on_open(id) end
end
