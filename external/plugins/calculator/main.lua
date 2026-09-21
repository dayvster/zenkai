function eval_math(expr)
    local safe = expr:gsub("[^%d%+%-%*%/%%%^%_%s%.%(%)%%]", "")
    if safe == "" or #safe < 2 then
        return nil
    end

    local pos = 1

    local function peek()
        while pos <= #safe do
            local c = safe:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\r' or c == '\n' then
                pos = pos + 1
            else
                break
            end
        end
        if pos > #safe then
            return nil
        end
        return safe:sub(pos, pos)
    end

    local function number_at(i)
        return safe:sub(i, i):match("%d") ~= nil
    end

    local function next_token()
        local c = peek()
        if c == nil then
            return nil
        end
        if c == '+' or c == '-' or c == '*' or c == '/' or c == '%' or c == '^' or c == '(' or c == ')' then
            pos = pos + 1
            return c
        end
        if number_at(pos) then
            local start = pos
            while pos <= #safe and number_at(pos) do
                pos = pos + 1
            end
            if pos <= #safe and safe:sub(pos, pos) == '.' then
                pos = pos + 1
                while pos <= #safe and number_at(pos) do
                    pos = pos + 1
                end
            end
            return tonumber(safe:sub(start, pos - 1))
        end
        if c == '.' then
            local after = pos + 1
            if after <= #safe and number_at(after) then
                pos = after + 1
                while pos <= #safe and number_at(pos) do
                    pos = pos + 1
                end
                return tonumber("0." .. safe:sub(after, pos - 1))
            end
        end
        return nil
    end

    local parse_additive
    local parse_multiplicative
    local parse_unary
    local parse_power
    local parse_primary

    parse_primary = function()
        local t = next_token()
        if t == '(' then
            local v = parse_additive()
            if v == nil then
                return nil
            end
            if next_token() ~= ')' then
                return nil
            end
            return v
        end
        if type(t) == "number" then
            return t
        end
        return nil
    end

    parse_power = function()
        local base = parse_primary()
        if base == nil then
            return nil
        end
        if peek() == '^' then
            pos = pos + 1
            local exp = parse_unary()
            if exp == nil then
                return nil
            end
            return base ^ exp
        end
        return base
    end

    parse_unary = function()
        if peek() == '-' then
            pos = pos + 1
            local v = parse_unary()
            if v == nil then
                return nil
            end
            return -v
        end
        return parse_power()
    end

    parse_multiplicative = function()
        local left = parse_unary()
        if left == nil then
            return nil
        end
        while true do
            local c = peek()
            if c == '*' or c == '/' or c == '%' then
                pos = pos + 1
                local right = parse_unary()
                if right == nil then
                    return nil
                end
                if c == '*' then
                    left = left * right
                elseif c == '/' then
                    if right == 0 then
                        return nil
                    end
                    left = left / right
                else
                    if right == 0 then
                        return nil
                    end
                    left = left % right
                end
            else
                break
            end
        end
        return left
    end

    parse_additive = function()
        local left = parse_multiplicative()
        if left == nil then
            return nil
        end
        while true do
            local c = peek()
            if c == '+' or c == '-' then
                pos = pos + 1
                local right = parse_multiplicative()
                if right == nil then
                    return nil
                end
                if c == '+' then
                    left = left + right
                else
                    left = left - right
                end
            else
                break
            end
        end
        return left
    end

    local result = parse_additive()
    if result == nil then
        return nil
    end
    if peek() ~= nil then
        return nil
    end
    return result
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