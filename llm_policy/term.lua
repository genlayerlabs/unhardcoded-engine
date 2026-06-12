-- llm_policy.term — Σ_pol terms: admission (check), normal forms (normalize),
-- and canonical serialization (encode) for hashing.
--
-- A term is a plain array { op, arg1, ..., argn }. Whether a position holds a
-- subterm or a parameter is decided by the signature (llm_policy.sig), never
-- by inspecting the value — so structured parameters (Action records, filter
-- recipes) are unambiguous.
--
-- check(term, schema?)  -> sort | nil, err     total validation, no execution
-- normalize(term)       -> term'               canonical representative
-- encode(term)          -> string              deterministic; hash input
-- fingerprint(term)     -> string              cheap cache key (NOT identity;
--                                              identity = host-side sha256 of encode)
--
-- Normal form v1 (the equations E we commit to; everything else is a version
-- bump): AC ops flattened, units dropped, absorbing elements collapse,
-- children sorted by canonical encoding; seq flattened with id dropped (order
-- kept: monoid, not commutative); not(not p) = p, not(top) = bot, not(bot) =
-- top; scale(1,s) = s, scale(0,_) = zero, scale(_,zero) = zero; gate(top,s) =
-- s, gate(bot,_) = zero, gate(_,zero) = zero; normalize idempotent; FailPlan
-- collapses to always(base) + overrides sorted by reason, outer override
-- wins, entries equal to the base dropped.
--
-- The normalizer performs NO arithmetic in 𝕍: nested scales stay nested
-- (scale(a,scale(b,s)) is already canonical). Identities use only exact
-- comparisons against 0 and 1, so the normal form — and therefore the policy
-- hash — is independent of the numeric model.

local SIG      = require("llm_policy.sig")
local fields   = require("llm_policy.fields")
local sequence = require("llm_policy.sequence")

local T = {}

T.VERSION = SIG.VERSION

-- Admission bounds (part of the spec): terms from untrusted callers are
-- rejected before recursion can exhaust the stack or the validator's time.
T.LIMITS = { max_depth = 64, max_nodes = 4096 }

-- ===========================================================================
-- check
-- ===========================================================================

local ACTION_KEYS = {
    action = true, attempts = true, backoff_ms = true,
    then_action = true, open_breaker_ms = true,
}

local function is_finite_number(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function check_action(v)
    if type(v) ~= "table" then return "Action must be a record" end
    if not sequence.ACTIONS[v.action] then
        return "Action.action invalid: " .. tostring(v.action)
    end
    if v.then_action ~= nil and not sequence.ACTIONS[v.then_action] then
        return "Action.then_action invalid: " .. tostring(v.then_action)
    end
    if v.attempts ~= nil and not is_finite_number(v.attempts) then
        return "Action.attempts must be a number"
    end
    if v.open_breaker_ms ~= nil and not is_finite_number(v.open_breaker_ms) then
        return "Action.open_breaker_ms must be a number"
    end
    local b = v.backoff_ms
    if b ~= nil and not is_finite_number(b) then
        if type(b) ~= "table" then return "Action.backoff_ms must be a number or array" end
        for _, x in ipairs(b) do
            if not is_finite_number(x) then return "Action.backoff_ms entries must be numbers" end
        end
    end
    for k, x in pairs(v) do
        if not ACTION_KEYS[k] then
            -- the action VERBS are closed; extra keys are host-interpreted
            -- numeric knobs (e.g. mark_unavailable_ms) and must be numbers
            if type(k) ~= "string" or not is_finite_number(x) then
                return "Action key '" .. tostring(k) .. "' must map to a finite number"
            end
        end
    end
    return nil
end

local function check_recipe(v)
    if type(v) ~= "table" then return "Recipe must be an array" end
    for i, step in ipairs(v) do
        if type(step) ~= "string" then
            if type(step) ~= "table" then
                return "Recipe[" .. i .. "] must be a string or flat record"
            end
            for k, x in pairs(step) do
                if type(k) ~= "string" or not is_finite_number(x) then
                    return "Recipe[" .. i .. "] must map string keys to numbers"
                end
            end
        end
    end
    return nil
end

local CHAIN_KEYS = {
    provider = true, provider_id = true, model = true, model_family = true,
}

local function check_chain(v)
    if type(v) ~= "table" then return "Chain must be an array" end
    for i, e in ipairs(v) do
        if type(e) ~= "table"
           or type(e.provider or e.provider_id) ~= "string"
           or type(e.model or e.model_family) ~= "string" then
            return "Chain[" .. i .. "] must be { provider=, model= }"
        end
        -- Closed record. An extra key — worse, an array part — would make
        -- param_enc treat the entry as an array and DROP provider/model:
        -- two different admitted chains, one canonical encoding. Identity
        -- must stay injective over everything check admits.
        for k in pairs(e) do
            if not CHAIN_KEYS[k] then
                return "Chain[" .. i .. "]: unknown key '" .. tostring(k) .. "'"
            end
        end
    end
    return nil
end

-- Validate one parameter value against its declared sort.
local function check_param(sort, v, schema)
    if sort == "Num" then
        if not is_finite_number(v) then return "expected a finite number" end
    elseif sort == "Rel" then
        if not SIG.RELS[v] then return "expected a relation (lt|le|eq|ne|ge|gt)" end
    elseif sort == "NumField" or sort == "BoolField" then
        if type(v) ~= "string" then return "expected a field name" end
        local d = schema.decl(v)
        if d == nil then return "undeclared field '" .. v .. "'" end
        local want = (sort == "NumField") and "Num" or "Bool"
        if d.sort ~= want then
            return "field '" .. v .. "' has sort " .. d.sort .. ", expected " .. want
        end
    elseif sort == "Tier" then
        if type(v) ~= "string" or schema.tier_rank[v] == nil then
            return "unknown tier '" .. tostring(v) .. "'"
        end
    elseif sort == "Capability" or sort == "ParamName" or sort == "Sym"
        or sort == "Provenance" or sort == "FailReason" then
        if type(v) ~= "string" then return "expected a string (" .. sort .. ")" end
    elseif sort == "Scalar" then
        local t = type(v)
        if t ~= "string" and t ~= "boolean" and not is_finite_number(v) then
            return "expected a scalar (number|string|boolean)"
        end
    elseif sort == "Action" then
        return check_action(v)
    elseif sort == "Recipe" then
        return check_recipe(v)
    elseif sort == "Chain" then
        return check_chain(v)
    else
        return "internal: unknown parameter sort " .. tostring(sort)
    end
    return nil
end

local function check_rec(t, schema, path, depth, st)
    if depth > T.LIMITS.max_depth then
        return nil, path .. ": term exceeds max depth " .. T.LIMITS.max_depth
    end
    st.nodes = st.nodes + 1
    if st.nodes > T.LIMITS.max_nodes then
        return nil, path .. ": term exceeds max size " .. T.LIMITS.max_nodes .. " nodes"
    end
    if type(t) ~= "table" or type(t[1]) ~= "string" then
        return nil, path .. ": a term is { op, ... } with a string op"
    end
    local op = t[1]
    local entry = SIG.ops[op]
    if entry == nil then
        return nil, path .. ": unknown op '" .. op .. "'"
    end

    if entry.variadic then
        if #t < 2 then
            return nil, path .. ": " .. op .. " needs at least one argument"
        end
        for i = 2, #t do
            local sort, err = check_rec(t[i], schema,
                path .. "." .. op .. "[" .. (i - 1) .. "]", depth + 1, st)
            if sort == nil then return nil, err end
            if sort ~= entry.variadic then
                return nil, path .. "." .. op .. "[" .. (i - 1) .. "]: expected "
                    .. entry.variadic .. ", got " .. sort
            end
        end
        return entry.out, nil
    end

    if #t - 1 ~= #entry.ins then
        return nil, path .. ": " .. op .. " takes " .. #entry.ins
            .. " argument(s), got " .. (#t - 1)
    end
    for i, want in ipairs(entry.ins) do
        local v = t[i + 1]
        local p = path .. "." .. op .. "[" .. i .. "]"
        if SIG.OP_SORTS[want] then
            local sort, err = check_rec(v, schema, p, depth + 1, st)
            if sort == nil then return nil, err end
            if sort ~= want then
                return nil, p .. ": expected " .. want .. ", got " .. sort
            end
        else
            local err = check_param(want, v, schema)
            if err then return nil, p .. ": " .. err end
        end
    end
    return entry.out, nil
end

-- check(term, schema?) -> sort | nil, err. Pure, total, no execution.
function T.check(t, schema)
    return check_rec(t, schema or fields.default(), "$", 1, { nodes = 0 })
end

-- ===========================================================================
-- encode (canonical serialization; the hash input)
-- ===========================================================================

local function num_enc(v)
    if v == 0 then return "0" end           -- normalizes -0
    if v % 1 == 0 and v >= -2^53 and v <= 2^53 then
        return string.format("%.0f", v)
    end
    return string.format("%.17g", v)
end

local function str_enc(v)
    return '"' .. v:gsub("[\\\"\n\r\t]", {
        ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    }) .. '"'
end

local function param_enc(v)
    local t = type(v)
    if t == "number" then return num_enc(v) end
    if t == "string" then return str_enc(v) end
    if t == "boolean" then return v and "true" or "false" end
    if t == "table" then
        if #v > 0 or next(v) == nil then            -- array (or empty)
            local parts = {}
            for i, x in ipairs(v) do parts[i] = param_enc(x) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = str_enc(k) .. ":" .. param_enc(v[k]) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("term: cannot encode parameter of type " .. t)
end

local function encode_rec(t)
    local op = t[1]
    local entry = SIG.ops[op]
    if entry == nil then error("term: unknown op '" .. tostring(op) .. "'") end
    local parts = { op }
    if entry.variadic then
        for i = 2, #t do parts[#parts + 1] = encode_rec(t[i]) end
    else
        for i, want in ipairs(entry.ins) do
            local v = t[i + 1]
            parts[#parts + 1] = SIG.OP_SORTS[want] and encode_rec(v) or param_enc(v)
        end
    end
    return "(" .. table.concat(parts, " ") .. ")"
end

-- Deterministic canonical encoding, version-prefixed. Policy identity is
-- defined as sha256 of this string — the hash itself is the host's job (the
-- core stays dependency-free); fingerprint() below is only a cache key.
function T.encode(t)
    return T.VERSION .. ":" .. encode_rec(t)
end

-- Two independent 31-bit lanes; stays exact under float-only Lua. Cache key
-- quality only — collisions are survivable, so this is NOT policy identity.
function T.fingerprint(t)
    local s = T.encode(t)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 31 + b) % 2147483647
        h2 = (h2 * 37 + b) % 2147483629
    end
    return string.format("%d-%d", h1, h2)
end

-- ===========================================================================
-- normalize
-- ===========================================================================

local normalize_rec

-- Flatten same-op children, drop units, collapse on absorbing elements, sort
-- (AC only), then collapse empty/singleton.
local function normalize_variadic(op, entry, t)
    local kids = {}
    for i = 2, #t do
        local k = normalize_rec(t[i])
        if k[1] == op then
            for j = 2, #k do kids[#kids + 1] = k[j] end
        elseif k[1] == entry.unit then
            -- drop
        elseif entry.absorb and k[1] == entry.absorb then
            return { entry.absorb }
        else
            kids[#kids + 1] = k
        end
    end
    if #kids == 0 then return { entry.unit } end
    if #kids == 1 then return kids[1] end
    if entry.ac then
        local keyed = {}
        for i, k in ipairs(kids) do keyed[i] = { key = encode_rec(k), term = k } end
        table.sort(keyed, function(a, b) return a.key < b.key end)
        kids = {}
        for i, e in ipairs(keyed) do kids[i] = e.term end
    end
    local out = { op }
    for i, k in ipairs(kids) do out[i + 1] = k end
    return out
end

-- Collapse an override chain into base + reason map (outer override wins),
-- then re-emit canonically: always(base) wrapped by overrides sorted by
-- reason, dropping overrides equal to the base.
local function normalize_failplan(t)
    local overrides, order = {}, {}
    local cur = t
    while cur[1] == "override" do
        local reason, action = cur[3], cur[4]
        if overrides[reason] == nil then
            overrides[reason] = action
            order[#order + 1] = reason
        end
        cur = cur[2]
    end
    local base = cur[2]                       -- cur = { "always", action }
    table.sort(order)
    local out = { "always", base }
    local base_key = param_enc(base)
    for _, reason in ipairs(order) do
        if param_enc(overrides[reason]) ~= base_key then
            out = { "override", out, reason, overrides[reason] }
        end
    end
    return out
end

normalize_rec = function(t)
    local op = t[1]
    local entry = SIG.ops[op]
    if entry == nil then error("term: unknown op '" .. tostring(op) .. "'") end

    if entry.variadic then return normalize_variadic(op, entry, t) end

    -- normalize subterm children first
    local out = { op }
    for i, want in ipairs(entry.ins) do
        local v = t[i + 1]
        out[i + 1] = SIG.OP_SORTS[want] and normalize_rec(v) or v
    end

    if op == "not" then
        local p = out[2]
        if p[1] == "not" then return p[2] end
        if p[1] == "top" then return { "bot" } end
        if p[1] == "bot" then return { "top" } end
    elseif op == "scale" then
        -- identities only — no 𝕍 arithmetic in the normalizer (see header)
        local a, s = out[2], out[3]
        if a == 0 or s[1] == "zero" then return { "zero" } end
        if a == 1 then return s end
    elseif op == "gate" then
        local p, s = out[2], out[3]
        if p[1] == "top" then return s end
        if p[1] == "bot" or s[1] == "zero" then return { "zero" } end
    elseif op == "normalize" then
        if out[2][1] == "normalize" then return out[2] end
    elseif op == "override" or op == "always" then
        return normalize_failplan(out)
    end
    return out
end

function T.normalize(t)
    return normalize_rec(t)
end

return T
