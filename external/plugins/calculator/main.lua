local functions = {
    sqrt = {math.sqrt, 1}, abs = {math.abs, 1}, floor = {math.floor, 1}, ceil = {math.ceil, 1},
    sin = {math.sin, 1}, cos = {math.cos, 1}, tan = {math.tan, 1},
    asin = {math.asin, 1}, acos = {math.acos, 1}, atan = {math.atan, 1},
    ln = {math.log, 1}, log = {function(x) return math.log(x, 10) end, 1}, exp = {math.exp, 1},
    rad = {math.rad, 1}, deg = {math.deg, 1},
    round = {function(x) return x < 0 and math.ceil(x - 0.5) or math.floor(x + 0.5) end, 1},
    min = {math.min, 2}, max = {math.max, 2},
}
local constants = {pi = math.pi, tau = 2 * math.pi, e = math.exp(1)}
local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function eval_math(expression)
    if #expression == 0 or #expression > 512 or expression:find("[^%w%+%-%*%/%%%^%s%.%(%)%,]") then return nil end
    local text, pos, depth = expression:lower(), 1, 0
    local function peek()
        while text:sub(pos, pos):match("%s") do pos = pos + 1 end
        return text:sub(pos, pos)
    end
    local add, multiply, unary, power, primary
    primary = function()
        depth = depth + 1
        if depth > 32 then return nil end
        local value
        if peek() == "(" then
            pos = pos + 1
            value = add()
            if peek() ~= ")" then return nil end
            pos = pos + 1
        elseif peek():match("[%a]") then
            local name = text:sub(pos):match("^[%a]+")
            pos = pos + #name
            if constants[name] then value = constants[name]
            else
                local fn = functions[name]
                if not fn or peek() ~= "(" then return nil end
                pos = pos + 1
                local first, second = add(), nil
                if not finite(first) then return nil end
                if fn[2] == 2 then
                    if peek() ~= "," then return nil end
                    pos = pos + 1
                    second = add()
                    if not finite(second) then return nil end
                end
                if peek() ~= ")" then return nil end
                pos = pos + 1
                value = fn[1](first, second)
            end
        else
            local rest = text:sub(pos)
            local number = rest:match("^%d*%.?%d+[e][%+%-]?%d+") or rest:match("^%d+%.?%d*") or rest:match("^%.%d+")
            if not number then return nil end
            pos = pos + #number
            value = tonumber(number)
        end
        depth = depth - 1
        return finite(value) and value or nil
    end
    power = function()
        local left = primary()
        if left == nil then return nil end
        if peek() == "^" then
            pos = pos + 1
            local right = unary()
            if right == nil then return nil end
            left = left ^ right
        end
        return finite(left) and left or nil
    end
    unary = function()
        local sign = peek()
        if sign == "-" or sign == "+" then
            pos = pos + 1
            depth = depth + 1
            if depth > 32 then return nil end
            local value = unary()
            depth = depth - 1
            return value and (sign == "-" and -value or value) or nil
        end
        return power()
    end
    multiply = function()
        local left = unary()
        if left == nil then return nil end
        while true do
            local op = peek()
            if op ~= "*" and op ~= "/" and op ~= "%" then return left end
            pos = pos + 1
            local right = unary()
            if right == nil or ((op == "/" or op == "%") and right == 0) then return nil end
            if op == "*" then left = left * right elseif op == "/" then left = left / right else left = left % right end
            if not finite(left) then return nil end
        end
    end
    add = function()
        local left = multiply()
        if left == nil then return nil end
        while true do
            local op = peek()
            if op ~= "+" and op ~= "-" then return left end
            pos = pos + 1
            local right = multiply()
            if right == nil then return nil end
            left = op == "+" and left + right or left - right
            if not finite(left) then return nil end
        end
    end
    local result = add()
    if peek() ~= "" then return nil end
    return result
end

local units = {}
local function unit(dimension, scale, names, offset)
    for name in names:gmatch("%S+") do units[name] = {dimension, scale, offset or 0} end
end
unit("length", 1, "m meter meters metre metres")
unit("length", 1000, "km kilometer kilometers kilometre kilometres")
unit("length", .01, "cm centimeter centimeters")
unit("length", .001, "mm millimeter millimeters")
unit("length", .0254, "in inch inches")
unit("length", .3048, "ft foot feet")
unit("length", .9144, "yd yard yards")
unit("length", 1609.344, "mi mile miles")
unit("mass", 1, "kg kilogram kilograms")
unit("mass", .001, "g gram grams")
unit("mass", .000001, "mg milligram milligrams")
unit("mass", .45359237, "lb lbs pound pounds")
unit("mass", .028349523125, "oz ounce ounces")
unit("time", 1, "s sec second seconds")
unit("time", .001, "ms millisecond milliseconds")
unit("time", 60, "min minute minutes")
unit("time", 3600, "h hr hour hours")
unit("time", 86400, "d day days")
unit("time", 604800, "week weeks")
unit("volume", 1, "l liter liters litre litres")
unit("volume", .001, "ml milliliter milliliters")
unit("speed", 1, "m/s")
unit("speed", 1/3.6, "km/h kph kmh")
unit("speed", .44704, "mph")
unit("temperature", 1, "c celsius", 273.15)
unit("temperature", 5/9, "f fahrenheit", 459.67)
unit("temperature", 1, "k kelvin")
unit("angle", 1, "rad radians")
unit("angle", math.pi/180, "deg degrees")
unit("data", 1, "B byte bytes")
unit("data", 1000, "KB kilobyte kilobytes")
unit("data", 1000000, "MB megabyte megabytes")
unit("data", 1000000000, "GB gigabyte gigabytes")
unit("data", 1000000000000, "TB terabyte terabytes")
unit("data", 1024, "KiB kib kibibyte kibibytes")
unit("data", 1048576, "MiB mib mebibyte mebibytes")
unit("data", 1073741824, "GiB gib gibibyte gibibytes")
unit("data", 1099511627776, "TiB tib tebibyte tebibytes")
unit("data", .125, "b bit bits")
unit("data", 125, "kb kilobit kilobits")
unit("data", 125000, "Mb megabit megabits")
unit("data", 125000000, "Gb gigabit gigabits")

local rates, pending, current_query = {}, nil, ""
local function currency(amount, from, to)
    from, to = from:upper(), to:upper()
    if not from:match("^%u%u%u$") or not to:match("^%u%u%u$") then return nil end
    if from == to then return amount, to end
    local key = from .. to
    local cached = rates[key]
    if cached then return amount * cached.rate, to, "Frankfurter · " .. cached.date end
    local url = "https://api.frankfurter.dev/v2/rates?base=" .. from .. "&quotes=" .. to
    local body, status = api.http_get(url)
    if not body then
        if status == "pending" then pending = url end
        return nil, nil, status == "pending" and "Fetching exchange rate…" or "Exchange rate unavailable"
    end
    local rate = tonumber(body:match('"rate"%s*:%s*([%d%.eE%+%-]+)'))
    local date = body:match('"date"%s*:%s*"([%d%-]+)"')
    local base = body:match('"base"%s*:%s*"(%u+)"')
    local quote = body:match('"quote"%s*:%s*"(%u+)"')
    if not finite(rate) or rate <= 0 or not date or base ~= from or quote ~= to then return nil, nil, "Exchange rate unavailable" end
    rates[key] = {rate = rate, date = date}
    return amount * rate, to, "Frankfurter · " .. date
end

function calculate(query)
    local text = query:match("^%s*(.-)%s*$")
    local left, target = text:match("^(.-)%s+[tT][oO]%s+(%S+)$")
    if not left then left, target = text:match("^(.-)%s+[iI][nN]%s+(%S+)$") end
    if left then
        local expression, source = left:match("^(.-)%s*([%a/]+)$")
        if not expression then return nil end
        local value = eval_math(expression)
        if value == nil then return nil end
        local a, b = units[source] or units[source:lower()], units[target] or units[target:lower()]
        if a and b then
            if a[1] ~= b[1] then return nil end
            local base = (value + a[3]) * a[2]
            if a[1] == "temperature" and base < 0 then return nil end
            return base / b[2] - b[3], target
        end
        if not a and not b then return currency(value, source, target) end
        return nil
    end
    local percentage, amount = text:match("^(.-)%%%s+[oO][fF]%s+(.+)$")
    if percentage then
        local a, b = eval_math(percentage), eval_math(amount)
        if a and b then return a * b / 100 end
        return nil
    end
    return eval_math(text)
end

local expressions = {}
local answers = {}

function on_query(query)
    current_query = query
    pending = nil
    answers = {}
    expressions = {}
    if query == "" or #query < 2 then
        return
    end
    local expr = query:gsub("%s+", "")
    local result, unit_name, detail = calculate(query)
    if finite(result) then
        local display = tostring(result)
        local rounded = tonumber(string.format("%.10g", result))
        if rounded then
            display = tostring(rounded)
        end
        if unit_name then display = display .. " " .. unit_name end
        local id = api.add_result(display, (detail or expr .. " =") .. " · Enter to copy", "accessories-calculator", "NoReturn")
        if id then
            answers[id] = display
            expressions[id] = query
            api.add_action(id, "Copy Result", 1, "edit-copy")
            api.add_action(id, "Copy Expression", 2, "edit-copy")
        end
    elseif detail then
        api.add_result(detail, query, "accessories-calculator", "NoReturn")
    end
end

function on_open(id)
    if answers[id] then api.copy_text(answers[id]) end
end

function on_action(id, action)
    if action == 1 then on_open(id)
    elseif action == 2 and expressions[id] then api.copy_text(expressions[id]) end
end

function on_idle()
    if pending then
        local body, status = api.http_get(pending)
        if body or status ~= "pending" then pending = nil; api.set_query(current_query) end
    end
end
