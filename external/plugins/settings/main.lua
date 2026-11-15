-- Offers "Zenkai Settings" while typing a word that leads to it, such as "set" or "pref".

local words = { "settings", "preferences", "zenkai settings" }

local function leads_to_settings(query)
    query = query:lower():match("^%s*(.-)%s*$")
    if #query < 3 then return false end
    for _, word in ipairs(words) do
        if word:sub(1, #query) == query then return true end
    end
    return false
end

function on_query(query)
    if leads_to_settings(query) then
        api.add_result("Zenkai Settings", "Theme, window, behaviour, animations and plugins", "preferences-system")
    end
end

function on_open()
    api.open_settings()
end
