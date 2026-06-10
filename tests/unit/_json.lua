-- Minimal JSON encode/decode for the test suite and the golden-vector
-- tooling. Test-only: the core stays dependency-free. Subset: objects,
-- arrays, strings (standard escapes + \uXXXX BMP), finite numbers, booleans.
-- null decodes to nil (avoid it in vectors). Encode treats a table as an
-- array iff it has a sequence part or is empty.

local J = {}

-- ---- encode -----------------------------------------------------------------

local ESC = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n",
              ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }

local function enc_str(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function enc_num(v)
    if v ~= v or v == math.huge or v == -math.huge then
        error("json: cannot encode non-finite number")
    end
    if v % 1 == 0 and v >= -2^53 and v <= 2^53 then
        return string.format("%.0f", v)
    end
    return string.format("%.17g", v)
end

function J.encode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return enc_num(v) end
    if t == "string" then return enc_str(v) end
    if t == "table" then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i, x in ipairs(v) do parts[i] = J.encode(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(v) do
            if type(k) ~= "string" then error("json: object keys must be strings") end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = enc_str(k) .. ":" .. J.encode(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("json: cannot encode " .. t)
end

-- ---- decode -----------------------------------------------------------------

local function decode_error(s, i, msg)
    error(string.format("json: %s at byte %d (…%s)", msg, i, s:sub(i, i + 12)))
end

local UNESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                f = "\f", n = "\n", r = "\r", t = "\t" }

local decode_value

local function skip_ws(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_string(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then decode_error(s, j, "unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "u" then
                local hex = s:sub(j + 2, j + 5)
                local cp = tonumber(hex, 16) or decode_error(s, j, "bad \\u escape")
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
                else
                    out[#out + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
                end
                j = j + 6
            else
                out[#out + 1] = UNESC[e] or decode_error(s, j, "bad escape")
                j = j + 2
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function decode_number(s, i)
    local j = s:find("[^%-%+%d%.eE]", i) or #s + 1
    local n = tonumber(s:sub(i, j - 1))
    if n == nil then decode_error(s, i, "bad number") end
    return n, j
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i) end
    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            if s:sub(i, i) ~= '"' then decode_error(s, i, "expected key") end
            local k; k, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
            local v; v, i = decode_value(s, i + 1)
            obj[k] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or '}'") end
            i = skip_ws(s, i + 1)
        end
    end
    if c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v; v, i = decode_value(s, i)
            arr[#arr + 1] = v
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    if c:match("[%-%d]") then return decode_number(s, i) end
    decode_error(s, i, "unexpected character")
end

function J.decode(s)
    local v, i = decode_value(s, 1)
    i = skip_ws(s, i)
    if i <= #s then decode_error(s, i, "trailing garbage") end
    return v
end

return J
