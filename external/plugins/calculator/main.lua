function eval_math(expr)
    local safe = expr:gsub("[^%d%+%-%*%/%%%^%_%s%.%(%)%%]", "")
    if safe == "" or #safe < 2 then
        return nil
    end
    local fn, err = load("return (" .. safe .. ")")
    if not fn then
        return nil
    end
    local ok, result = pcall(fn)
    if ok and type(result) == "number" and result == result then
        return result
    end
    return nil
end

function on_query(query)
    if query == "" or #query < 2 then
        return
    end
    local expr = query:gsub("%s+", "")
    local result = eval_math(expr)
    if result then
        local display = tostring(result)
        local rounded = tonumber(string.format("%.10g", result))
        if rounded then
            display = tostring(rounded)
        end
        api.add_result(display, expr .. " =", "accessories-calculator", "NoReturn")
    end
end

function on_open(id)
end
