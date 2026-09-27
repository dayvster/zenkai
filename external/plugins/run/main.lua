function on_query(query)
    if query:sub(1, 4):lower() ~= "run:" then
        return
    end

    local command = query:sub(5):match("^%s*(.-)%s*$")
    if command == "" then
        return
    end

    api.add_result("Run: " .. command, "Open with the Windows shell", "system-run", "ExecCmd", command)
end
