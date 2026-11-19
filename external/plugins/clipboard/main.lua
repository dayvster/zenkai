-- Clipboard history: type "clip:" to search what you copied, newest first, with pinned
-- copies on top. The background service (zenkai --service) records the copies; without it
-- there's nothing to show.

local shown = {}
local last_query = ""

local COPY, PIN, DELETE, CLEAR = 1, 2, 3, 4

local function one_line(text)
    local line = text:match("^%s*(.-)%s*$"):gsub("%s+", " ")
    if #line > 120 then line = line:sub(1, 117) .. "..." end
    return line
end

local function ago(seconds)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. " min ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. " h ago" end
    return math.floor(seconds / 86400) .. " days ago"
end

local function describe(entry, now)
    local lines = select(2, entry.text:gsub("\n", "\n")) + 1
    local size = lines > 1 and (lines .. " lines") or (#entry.text .. " characters")
    local parts = { ago(now - entry.time), size }
    if entry.pinned then table.insert(parts, 1, "Pinned") end
    return table.concat(parts, " · ")
end

local function show(entry, now)
    local id = api.add_result(one_line(entry.text), describe(entry, now),
        entry.pinned and "emblem-favorite" or "edit-paste", "NoReturn")
    if not id then return end
    shown[id] = entry
    api.add_action(id, "Copy", COPY, "edit-copy")
    api.add_action(id, entry.pinned and "Unpin" or "Pin", PIN, "emblem-favorite")
    api.add_action(id, "Delete", DELETE, "edit-delete")
    api.add_action(id, "Clear History (keeps pinned)", CLEAR, "edit-clear-history")
end

function on_query(query)
    shown = {}
    if query:sub(1, 5):lower() ~= "clip:" then return end
    last_query = query
    local term = query:sub(6):match("^%s*(.-)%s*$"):lower()

    local history, problem = api.clipboard_history()
    if not history then
        api.add_result("Clipboard history is off", problem, "dialog-information", "NoReturn")
        return
    end

    local now = math.floor(api.now() / 1000)
    local any = false
    -- Pinned copies first, then the rest, both newest first as the history keeps them.
    for _, pinned in ipairs({ true, false }) do
        for _, entry in ipairs(history) do
            if entry.pinned == pinned and (term == "" or entry.text:lower():find(term, 1, true)) then
                show(entry, now)
                any = true
            end
        end
    end
    if not any then
        api.add_result(term == "" and "Nothing copied yet" or "No copies match",
            "Copied text shows up here", "dialog-information", "NoReturn")
    end
end

function on_open(id)
    local entry = shown[id]
    if not entry then return end
    api.copy_text(entry.text)
    api.close()
end

function on_action(id, action)
    local entry = shown[id]
    if not entry then return end
    if action == COPY then
        on_open(id)
        return
    elseif action == PIN then
        api.clipboard_edit(entry.pinned and "unpin" or "pin", entry.id)
    elseif action == DELETE then
        api.clipboard_edit("delete", entry.id)
    elseif action == CLEAR then
        api.clipboard_edit("clear")
    end
    -- Show the change straight away.
    api.set_query(last_query)
end
