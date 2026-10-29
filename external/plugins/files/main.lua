local targets = {}
local last_query = nil
local current_query = ""
local offset = 0
local search = nil
local last_error = nil
local config = plugin_config or {}
local excluded = {}
for _, name in ipairs(config.exclude or {".git", "node_modules", ".cache", ".zig-cache", "zig-pkg", "Library", "AppData"}) do
    excluded[name:lower()] = true
end

local function directory_query(path)
    if path:match("[/\\]$") then return path end
    local separator = (path:match("^%a:") or path:sub(1, 2) == "\\\\") and "\\" or "/"
    return path .. separator
end

local function notice(title, detail)
    api.add_result(title, detail or "", "dialog-information", "NoReturn")
end

local function add_entry(entry)
    local id = api.add_result(entry.name, entry.path, entry.icon, "NoReturn")
    if not id then return end
    api.set_preview(id, entry.path)
    targets[id] = {entry = entry}
    api.add_action(id, entry.is_dir and "Open in File Manager" or "Open with Default App", 1, "document-open")
    api.add_action(id, "Copy Path", 2, "edit-copy")
    api.add_action(id, entry.is_dir and "Browse Folder" or "Browse Containing Folder", 3, "folder-open")
    api.add_action(id, "Refresh", 4, "view-refresh")
    api.add_action(id, "Reveal in File Manager", 5, "folder-open")
    api.add_action(id, "New File…", 6, "document-new")
    api.add_action(id, "New Folder…", 7, "folder-new")
    if entry.parent ~= entry.path then
        api.add_action(id, "Rename…", 8, "edit-rename")
        api.add_action(id, "Move to Trash…", 9, "user-trash")
    end
end

local function navigation(title, subtitle, query, operation)
    local id = api.add_result(title, subtitle, "folder-open", "NoReturn")
    if id then targets[id] = {query = query, operation = operation} end
end

local function browse(path)
    local entry, message = api.path_info(path)
    if entry and not entry.is_dir then add_entry(entry); return end
    local filter = ""
    if not entry then
        local parent, partial = path:match("^(.*[/\\])([^/\\]+)$")
        if not parent then notice(message or "Path not found", path); return end
        local info = api.path_info(parent)
        if not info or not info.is_dir then notice(message or "Path not found", path); return end
        path, filter = parent, partial
    end
    local listing, err = api.read_dir(path, offset, filter)
    if not listing then notice(err or "Unable to read folder", path); return end
    if listing.parent ~= listing.path then
        navigation("..", "Browse " .. listing.parent, directory_query(listing.parent))
    end
    for _, item in ipairs(listing.entries) do add_entry(item) end
    if #listing.entries == 0 then
        local id = api.add_result(filter == "" and "Empty folder" or "No matching files", listing.path, "folder-open", "NoReturn")
        if id then
            targets[id] = {entry = {path = listing.path, parent = listing.parent, is_dir = true}}
            api.add_action(id, "New File…", 6, "document-new")
            api.add_action(id, "New Folder…", 7, "folder-new")
        end
    end
    if offset > 0 then navigation("Previous page", listing.path, current_query, "previous") end
    if listing.more then navigation("Next page", "Show more files and folders", current_query, "next") end
end

local function begin_search(term)
    search = {term = term:lower(), queue = {}, head = 1, seen = {}, skipped = 0}
    for _, root in ipairs(config.roots or {"~"}) do
        local info = api.path_info(root)
        if info and info.is_dir and not search.seen[info.path] then
            search.seen[info.path] = true
            search.queue[#search.queue + 1] = {path = info.path, offset = 0}
        else search.skipped = search.skipped + 1 end
    end
end

local function find_files(term)
    if not search then begin_search(term) end
    local count = 0
    -- Work in small pages; continuation never blocks the UI on a whole home tree.
    for _ = 1, 4 do
        local cursor = search.queue[search.head]
        if not cursor then break end
        local listing = api.read_dir(cursor.path, cursor.offset)
        if not listing then
            search.skipped = search.skipped + 1
            search.head = search.head + 1
        else
            local consumed = 0
            for _, entry in ipairs(listing.entries) do
                consumed = consumed + 1
                local name = entry.name:lower()
                local allowed = not excluded[name] and (config.include_hidden or name:sub(1, 1) ~= ".")
                if allowed then
                    if entry.is_dir and not entry.is_link and not search.seen[entry.path] then
                        search.seen[entry.path] = true
                        search.queue[#search.queue + 1] = {path = entry.path, offset = 0}
                    end
                    if name:find(search.term, 1, true) then add_entry(entry); count = count + 1 end
                end
                if count >= 100 then break end
            end
            cursor.offset = cursor.offset + consumed
            if consumed == #listing.entries and not listing.more then search.head = search.head + 1 end
        end
        if count >= 100 then break end
    end
    if search.head <= #search.queue then
        navigation("Continue searching", "Search the next folders for “" .. term .. "”", current_query, "continue")
    elseif count == 0 then notice("No more matching files", "Search complete") end
    if search.skipped > 0 then notice("Some folders could not be read", tostring(search.skipped) .. " unavailable folders") end
end

function on_query(query)
    targets = {}
    current_query = query
    if query ~= last_query then offset = 0; search = nil end
    last_query = query
    local text = query:match("^%s*(.-)%s*$")
    local prefixed = text:sub(1, 5):lower() == "file:"
    if prefixed then text = text:sub(6):match("^%s*(.-)%s*$") end
    if text:sub(1, 1) == '"' and text:sub(-1) == '"' then text = text:sub(2, -2) end
    local path = text:sub(1, 1) == "/" or text:sub(1, 1) == "\\" or text:sub(1, 1) == "~"
        or text:match("^%a:") or text:match("^%.%./") or text:match("^%./") or text:match("^%.%.?\\")
    if not prefixed and not path then return end
    if last_error then notice(last_error); last_error = nil end
    if text == "" then browse("~")
    elseif path then browse(text)
    else find_files(text) end
end

function on_open(id)
    local target = targets[id]
    if not target then return end
    if target.query then
        if target.operation == "next" then offset = offset + 128
        elseif target.operation == "previous" then offset = math.max(0, offset - 128) end
        api.set_query(target.query)
    elseif target.entry.is_dir then
        api.set_query(directory_query(target.entry.path))
    else on_action(id, 1) end
end

function on_action(id, action)
    local target = targets[id]
    if not target or not target.entry then return end
    local entry = target.entry
    if action == 1 then
        local ok, message = api.open_path(entry.path)
        if ok then api.close() else last_error = message or "Unable to open path"; api.set_query(current_query) end
    elseif action == 2 then api.copy_text(entry.path)
    elseif action == 3 then api.set_query(directory_query(entry.is_dir and entry.path or entry.parent))
    elseif action == 4 then offset = 0; search = nil; api.set_query(current_query)
    elseif action >= 5 and action <= 9 then
        local operations = {[5] = "reveal", [6] = "new_file", [7] = "new_folder", [8] = "rename", [9] = "trash"}
        local result, message = api.file_action(operations[action], entry.path)
        if not result then
            if message ~= "cancelled" then last_error = message or "File action failed"; api.set_query(current_query) end
            return
        end
        if action == 5 then return end
        offset = 0; search = nil
        local info = api.path_info(result)
        if action == 9 then api.set_query(directory_query(result))
        elseif action == 7 then api.set_query(directory_query(result))
        elseif info then api.set_query(info.is_dir and directory_query(info.path) or info.path)
        else api.set_query(current_query) end
    end
end
