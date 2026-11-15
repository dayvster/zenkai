-- Developer tools under one prefix: `dev: <tool> <input>`.
--
-- Every result copies its value on Enter and keeps the launcher open. A bare
-- `dev:` (or a partial tool name) lists the tools; Enter fills in the prefix.

local values = {}      -- result id -> text to copy
local tool_queries = {} -- result id -> query to switch to

local function trim(text)
    return text:match("^%s*(.-)%s*$")
end

local function add(title, subtitle)
    local id = api.add_result(title, subtitle .. " · Enter to copy", "edit-copy", "NoReturn")
    if id then
        values[id] = title
        api.add_action(id, "Copy", 1, "edit-copy")
    end
end

local function info(title, subtitle)
    api.add_result(title, subtitle or "", "dialog-information", "NoReturn")
end

-- Base64 ----------------------------------------------------------------------

local b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64_index = {}
for i = 1, 64 do b64_index[b64_chars:sub(i, i)] = i - 1 end

local function b64_digit(n)
    return b64_chars:sub(n + 1, n + 1)
end

local function b64_encode(text)
    local out = {}
    for i = 1, #text, 3 do
        local a, b, c = text:byte(i, i + 2)
        local n = (a << 16) | ((b or 0) << 8) | (c or 0)
        out[#out + 1] = b64_digit(n >> 18) .. b64_digit((n >> 12) & 63)
            .. (b and b64_digit((n >> 6) & 63) or "=") .. (c and b64_digit(n & 63) or "=")
    end
    return table.concat(out)
end

-- Accepts standard and URL-safe alphabets, with or without padding.
local function b64_decode(text)
    text = text:gsub("%s", ""):gsub("%-", "+"):gsub("_", "/"):gsub("=+$", "")
    if text == "" or #text % 4 == 1 or text:find("[^%w+/]") then return nil end
    local out = {}
    for i = 1, #text, 4 do
        local n, count = 0, 0
        for j = i, math.min(i + 3, #text) do
            n = (n << 6) | b64_index[text:sub(j, j)]
            count = count + 1
        end
        n = n << (6 * (4 - count))
        out[#out + 1] = string.char(n >> 16, (n >> 8) & 255, n & 255):sub(1, count - 1)
    end
    return table.concat(out)
end

-- Decoded bytes are only worth showing when they are readable text.
local function readable(text)
    return utf8.len(text) ~= nil and not text:find("[%z\1-\8\11\12\14-\31\127]")
end

local function tool_b64(input)
    if input == "" then return info("Base64", "Type text to encode, or Base64 to decode") end
    add(b64_encode(input), "Base64 encoded")
    local decoded = b64_decode(input)
    if decoded and decoded ~= "" and readable(decoded) then add(decoded, "Base64 decoded") end
end

-- URL encoding ----------------------------------------------------------------

local function url_encode(text)
    return (text:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function url_decode(text)
    return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function tool_url(input)
    if input == "" then return info("URL encoding", "Type text to percent-encode or decode") end
    add(url_encode(input), "URL encoded")
    if input:find("%%%x%x") then
        local decoded = url_decode(input)
        if readable(decoded) then add(decoded, "URL decoded") end
    end
end

-- UUID ------------------------------------------------------------------------

-- Random v4 UUIDs from math.random: fine for test data, not for secrets.
local function uuid4()
    local function hex(n) return string.format("%0" .. n .. "x", math.random(0, (1 << (4 * n)) - 1)) end
    return hex(8) .. "-" .. hex(4) .. "-4" .. hex(3) .. "-"
        .. string.format("%x", math.random(8, 11)) .. hex(3) .. "-" .. hex(12)
end

local function tool_uuid()
    for _ = 1, 3 do add(uuid4(), "Random UUID v4") end
end

-- Timestamps ------------------------------------------------------------------

-- Days since 1970-01-01 <-> civil date (proleptic Gregorian, UTC).
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = y // 400
    local yoe = y - era * 400
    local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function civil_from_days(z)
    z = z + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp + (mp < 10 and 3 or -9)
    return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end

local function iso_utc(seconds)
    local days, rest = seconds // 86400, seconds % 86400
    local y, m, d = civil_from_days(days)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, rest // 3600, rest // 60 % 60, rest % 60)
end

local function relative(seconds)
    local delta = seconds - api.now() // 1000
    local amount = math.abs(delta)
    local units = { { 31536000, "year" }, { 2592000, "month" }, { 86400, "day" }, { 3600, "hour" }, { 60, "minute" } }
    for _, unit in ipairs(units) do
        if amount >= unit[1] then
            local n = amount // unit[1]
            local text = n .. " " .. unit[2] .. (n == 1 and "" or "s")
            return delta < 0 and text .. " ago" or "in " .. text
        end
    end
    return "just now"
end

local function show_time(seconds, millis)
    add(iso_utc(seconds), relative(seconds) .. " · ISO 8601 UTC")
    add(tostring(seconds), "Unix seconds")
    add(tostring(millis), "Unix milliseconds")
end

local function tool_ts(input)
    if input == "" or input:lower() == "now" then
        local millis = api.now()
        return show_time(millis // 1000, millis)
    end
    local number = input:match("^-?%d+$") and math.tointeger(tonumber(input))
    if number then
        -- Treat 12+ digit values as milliseconds (seconds that large are past year 5000).
        if math.abs(number) >= 100000000000 then return show_time(number // 1000, number) end
        return show_time(number, number * 1000)
    end
    local y, mo, d, rest = input:match("^(%d%d%d%d)-(%d%d)-(%d%d)(.*)$")
    if y then
        local h, mi, s = rest:match("^[T ](%d%d):(%d%d):?(%d?%d?)Z?$")
        local valid_rest = rest == "" or rest == "Z" or h ~= nil
        h, mi, s = tonumber(h) or 0, tonumber(mi) or 0, tonumber(s) or 0
        if valid_rest and h < 24 and mi < 60 and s < 60 then
            y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
            local days = days_from_civil(y, mo, d)
            -- Round-trip the date so 2023-02-31 is rejected rather than read as March 3rd.
            local cy, cm, cd = civil_from_days(days)
            if cy == y and cm == mo and cd == d then
                local seconds = days * 86400 + h * 3600 + mi * 60 + s
                return show_time(seconds, seconds * 1000)
            end
        end
    end
    info("Not a timestamp", "Use Unix seconds or milliseconds, or YYYY-MM-DD [HH:MM[:SS]] (UTC)")
end

-- Colors ----------------------------------------------------------------------

local function rgb_to_hsl(r, g, b)
    r, g, b = r / 255, g / 255, b / 255
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local l = (max + min) / 2
    if max == min then return 0, 0, l end
    local d = max - min
    local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
    local h
    if max == r then h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    return h * 60, s, l
end

local function hsl_to_rgb(h, s, l)
    local function channel(n)
        local k = (n + h / 30) % 12
        local a = s * math.min(l, 1 - l)
        return math.floor((l - a * math.max(-1, math.min(k - 3, 9 - k, 1))) * 255 + 0.5)
    end
    return channel(0), channel(8), channel(4)
end

local function parse_color(text)
    local hex = text:match("^#?(%x+)$")
    if hex and (#hex == 3 or #hex == 6) then
        if #hex == 3 then hex = hex:gsub(".", "%0%0") end
        return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    end
    local r, g, b = text:match("^rgba?%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*[,)]")
    if r then
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r <= 255 and g <= 255 and b <= 255 then return r, g, b end
        return nil
    end
    local h, s, l = text:match("^hsla?%(%s*([%d.]+)%s*,%s*([%d.]+)%%%s*,%s*([%d.]+)%%%s*[,)]")
    h, s, l = tonumber(h), tonumber(s), tonumber(l) -- nil for "1.2.3"
    if h and s and l and s <= 100 and l <= 100 then
        return hsl_to_rgb(h % 360, s / 100, l / 100)
    end
end

local function tool_color(input)
    local r, g, b = parse_color(input:lower())
    if not r then return info("Not a color", "Use #rgb, #rrggbb, rgb(r, g, b) or hsl(h, s%, l%)") end
    local h, s, l = rgb_to_hsl(r, g, b)
    add(string.format("#%02x%02x%02x", r, g, b), "Hex")
    add(string.format("rgb(%d, %d, %d)", r, g, b), "RGB")
    add(string.format("hsl(%d, %d%%, %d%%)", math.floor(h + 0.5), math.floor(s * 100 + 0.5), math.floor(l * 100 + 0.5)), "HSL")
end

-- Text case -------------------------------------------------------------------

-- Splits "helloWorld", "hello_world", "Hello-World" and "hello world" alike.
local function words(text)
    local list = {}
    text = text:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    for word in text:gmatch("[^%s_%-%.]+") do list[#list + 1] = word:lower() end
    return list
end

local function capitalize(word)
    return word:sub(1, 1):upper() .. word:sub(2)
end

local function tool_case(input)
    local list = words(input)
    if #list == 0 then return info("Text case", "Type text to convert between cases") end
    local capitalized = {}
    for i, word in ipairs(list) do capitalized[i] = capitalize(word) end
    local camel = table.concat(capitalized):gsub("^%u", string.lower)
    add(table.concat(list, "_"), "snake_case")
    add(camel, "camelCase")
    add(table.concat(capitalized), "PascalCase")
    add(table.concat(list, "-"), "kebab-case")
    add(table.concat(list, "_"):upper(), "CONSTANT_CASE")
    add(table.concat(capitalized, " "), "Title Case")
    add(input:upper(), "UPPERCASE")
    add(input:lower(), "lowercase")
    local chars = utf8.len(input) or #input
    info(string.format("%d characters · %d words", chars, #list), "Length")
end

-- JSON ------------------------------------------------------------------------

local max_json_steps = 500

-- Validates JSON and re-emits it minified and pretty-printed, keeping key order.
-- Returns minified, pretty; or nil, message on a syntax error; or nil, nil, true
-- when the input needs more than max_json_steps tokens.
local function format_json(text)
    local pos, minified, pretty, depth, steps = 1, {}, {}, 0, 0
    local function fail(message) error({ message = message .. " at character " .. pos }, 0) end
    -- Tokens and escapes cost the most; counting them keeps a hook under the instruction limit.
    local function step()
        steps = steps + 1
        if steps > max_json_steps then error({ too_large = true }, 0) end
    end
    local function skip() pos = text:find("[^ \t\r\n]", pos) or #text + 1 end
    local function newline() pretty[#pretty + 1] = "\n" .. string.rep("  ", depth) end
    local function emit(token)
        step()
        minified[#minified + 1] = token
        pretty[#pretty + 1] = token
    end

    local value
    local function string_token()
        local start = pos
        pos = pos + 1
        while true do
            local special = text:find('["\\%c]', pos)
            if not special then fail("unterminated string") end
            local c = text:sub(special, special)
            if c == '"' then pos = special + 1; break end
            if c ~= "\\" then pos = special; fail("control character in string") end
            step()
            local escaped = text:sub(special + 1, special + 1)
            if escaped == "u" then
                if not text:sub(special + 2, special + 5):match("^%x%x%x%x$") then pos = special; fail("bad \\u escape") end
                pos = special + 6
            elseif escaped ~= "" and ('"\\/bfnrt'):find(escaped, 1, true) then
                pos = special + 2
            else
                pos = special; fail("bad escape")
            end
        end
        return text:sub(start, pos - 1)
    end

    local function container(open, close, member)
        emit(open)
        pos = pos + 1
        skip()
        if text:sub(pos, pos) == close then
            pos = pos + 1
            return emit(close)
        end
        depth = depth + 1
        while true do
            newline()
            member()
            skip()
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == close then break end
            if c ~= "," then pos = pos - 1; fail("expected ',' or '" .. close .. "'") end
            emit(",")
            skip()
        end
        depth = depth - 1
        newline()
        emit(close)
    end

    value = function()
        skip()
        local c = text:sub(pos, pos)
        if c == "{" then
            container("{", "}", function()
                if text:sub(pos, pos) ~= '"' then fail("expected a string key") end
                emit(string_token())
                skip()
                if text:sub(pos, pos) ~= ":" then fail("expected ':'") end
                pos = pos + 1
                minified[#minified + 1] = ":"
                pretty[#pretty + 1] = ": "
                value()
            end)
        elseif c == "[" then
            container("[", "]", value)
        elseif c == '"' then
            emit(string_token())
        else
            local literal = text:match("^true", pos) or text:match("^false", pos) or text:match("^null", pos)
            if not literal then
                -- Numbers: integer part without leading zeros, then optional fraction and exponent.
                local int = text:match("^-?%d+", pos)
                if int and not int:match("^-?0%d") then
                    local frac = text:match("^%.%d+", pos + #int) or ""
                    local exp = text:match("^[eE][+-]?%d+", pos + #int + #frac) or ""
                    literal = int .. frac .. exp
                end
            end
            if not literal then fail(c == "" and "unexpected end" or "unexpected '" .. c .. "'") end
            pos = pos + #literal
            emit(literal)
        end
    end

    local ok, err = pcall(function()
        value()
        skip()
        if pos <= #text then fail("trailing characters") end
    end)
    if not ok then
        -- Only parse errors are ours; anything else (like the sandbox's instruction limit) must propagate.
        if type(err) ~= "table" then error(err, 0) end
        if err.too_large then return nil, nil, true end
        return nil, err.message
    end
    return table.concat(minified), table.concat(pretty)
end

local function tool_json(input)
    if input == "" then return info("JSON", "Paste JSON to validate, minify and pretty-print") end
    local minified, pretty, too_large = format_json(input)
    if too_large then return info("JSON too large", "Formatting stops after " .. max_json_steps .. " tokens") end
    if not minified then return info("Invalid JSON", pretty) end
    add(minified, "Valid JSON · minified")
    -- The title shows one line; Enter copies the full indented text.
    local id = api.add_result("Pretty-printed (" .. select(2, pretty:gsub("\n", "")) + 1 .. " lines)",
        "Valid JSON · indented with 2 spaces · Enter to copy", "edit-copy", "NoReturn")
    if id then
        values[id] = pretty
        api.add_action(id, "Copy", 1, "edit-copy")
    end
end

-- Hashes ----------------------------------------------------------------------

local M32 = 0xffffffff

local function rol(x, n)
    return ((x << n) | (x >> (32 - n))) & M32
end

local function ror(x, n)
    return ((x >> n) | (x << (32 - n))) & M32
end

-- Pads to 64-byte blocks with the bit length appended big- or little-endian.
local function pad(text, little_endian)
    local bits = #text * 8
    local tail = "\128" .. string.rep("\0", (55 - #text) % 64)
    return text .. tail .. string.pack(little_endian and "<I8" or ">I8", bits)
end

local md5_shift = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}
local md5_k = {}
for i = 1, 64 do md5_k[i] = math.floor(math.abs(math.sin(i)) * 2 ^ 32) & M32 end

local function md5(text)
    local msg = pad(text, true)
    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for block = 1, #msg, 64 do
        local w = { string.unpack("<" .. string.rep("I4", 16), msg, block) }
        local a, b, c, d = a0, b0, c0, d0
        for i = 0, 63 do
            local f, g
            if i < 16 then f, g = (b & c) | (~b & d), i
            elseif i < 32 then f, g = (d & b) | (~d & c), (5 * i + 1) % 16
            elseif i < 48 then f, g = b ~ c ~ d, (3 * i + 5) % 16
            else f, g = c ~ (b | ~d), (7 * i) % 16 end
            f = (f + a + md5_k[i + 1] + w[g + 1]) & M32
            a, d, c = d, c, b
            b = (b + rol(f, md5_shift[i + 1])) & M32
        end
        a0, b0, c0, d0 = (a0 + a) & M32, (b0 + b) & M32, (c0 + c) & M32, (d0 + d) & M32
    end
    return string.format("%08x%08x%08x%08x", string.unpack(">I4>I4>I4>I4", string.pack("<I4<I4<I4<I4", a0, b0, c0, d0)))
end

local function sha1(text)
    local msg = pad(text, false)
    local h0, h1, h2, h3, h4 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    for block = 1, #msg, 64 do
        local w = { string.unpack(">" .. string.rep("I4", 16), msg, block) }
        for i = 17, 80 do w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1) end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 1, 80 do
            local f, k
            if i <= 20 then f, k = (b & c) | (~b & d), 0x5a827999
            elseif i <= 40 then f, k = b ~ c ~ d, 0x6ed9eba1
            elseif i <= 60 then f, k = (b & c) | (b & d) | (c & d), 0x8f1bbcdc
            else f, k = b ~ c ~ d, 0xca62c1d6 end
            a, b, c, d, e = (rol(a, 5) + (f & M32) + e + k + w[i]) & M32, a, rol(b, 30), c, d
        end
        h0, h1, h2, h3, h4 = (h0 + a) & M32, (h1 + b) & M32, (h2 + c) & M32, (h3 + d) & M32, (h4 + e) & M32
    end
    return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

local sha256_k = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256(text)
    local msg = pad(text, false)
    local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for block = 1, #msg, 64 do
        local w = { string.unpack(">" .. string.rep("I4", 16), msg, block) }
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = ror(x, 7) ~ ror(x, 18) ~ (x >> 3)
            local s1 = ror(y, 17) ~ ror(y, 19) ~ (y >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local t1 = hh + (ror(e, 6) ~ ror(e, 11) ~ ror(e, 25)) + ((e & f) ~ (~e & g)) + sha256_k[i] + w[i]
            local t2 = (ror(a, 2) ~ ror(a, 13) ~ ror(a, 22)) + ((a & b) ~ (a & c) ~ (b & c))
            hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
        end
        h[1], h[2], h[3], h[4] = (h[1] + a) & M32, (h[2] + b) & M32, (h[3] + c) & M32, (h[4] + d) & M32
        h[5], h[6], h[7], h[8] = (h[5] + e) & M32, (h[6] + f) & M32, (h[7] + g) & M32, (h[8] + hh) & M32
    end
    return string.format(string.rep("%08x", 8), table.unpack(h))
end

local function tool_hash(input)
    if input == "" then return info("Hashes", "Type text to hash with MD5, SHA-1 and SHA-256") end
    add(sha256(input), "SHA-256")
    add(sha1(input), "SHA-1")
    add(md5(input), "MD5")
end

-- Dispatch --------------------------------------------------------------------

-- `max` is the input size in bytes each tool handles within the per-hook instruction
-- limit (hashing costs about 19k instructions per 64-byte block for all three).
local tools = {
    { name = "b64", aliases = { "base64" }, run = tool_b64, max = 1000, help = "Base64 encode and decode" },
    { name = "url", aliases = { "urlenc" }, run = tool_url, max = 2000, help = "Percent-encode and decode" },
    { name = "uuid", aliases = { "guid" }, run = tool_uuid, help = "Generate random v4 UUIDs" },
    { name = "ts", aliases = { "time", "timestamp" }, run = tool_ts, max = 64, help = "Unix timestamps and UTC dates" },
    { name = "color", aliases = { "colour" }, run = tool_color, max = 64, help = "Convert hex, rgb() and hsl()" },
    { name = "case", aliases = { "text" }, run = tool_case, max = 2000, help = "snake_case, camelCase, kebab-case and more" },
    { name = "json", aliases = {}, run = tool_json, help = "Validate, minify and pretty-print" },
    { name = "hash", aliases = { "md5", "sha", "sha1", "sha256" }, run = tool_hash, max = 119, help = "MD5, SHA-1 and SHA-256" },
}

local function find_tool(name)
    for _, tool in ipairs(tools) do
        if tool.name == name then return tool end
        for _, alias in ipairs(tool.aliases) do
            if alias == name then return tool end
        end
    end
end

function on_query(query)
    values, tool_queries = {}, {}
    if query:sub(1, 4):lower() ~= "dev:" then return end
    local rest = trim(query:sub(5))
    local name, input = rest:match("^(%S+)%s*(.-)$")
    local tool = name and find_tool(name:lower())
    if tool then
        input = trim(input)
        if tool.max and #input > tool.max then
            return info("Input too long", "dev: " .. tool.name .. " takes up to " .. tool.max .. " bytes")
        end
        return tool.run(input)
    end

    -- No tool yet: list the ones whose name starts with what was typed.
    local typed = (name or ""):lower()
    local listed = 0
    for _, tool in ipairs(tools) do
        if tool.name:sub(1, #typed) == typed then
            local id = api.add_result("dev: " .. tool.name, tool.help, "applications-development", "NoReturn")
            if id then tool_queries[id] = "dev: " .. tool.name .. " " end
            listed = listed + 1
        end
    end
    if listed == 0 then info("No tool named \"" .. typed .. "\"", "Type dev: to see all tools") end
end

function on_open(id)
    if values[id] then api.copy_text(values[id]) end
    if tool_queries[id] then api.set_query(tool_queries[id]) end
end

function on_action(id, action)
    if action == 1 then on_open(id) end
end
