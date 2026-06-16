-- llm_policy.fields — the observation vocabulary: how a policy term sees a
-- candidate.
--
-- A policy never holds the candidate; it observes it through named fields
-- (`cmp`, `is`, `field` in the signature). The contract between the IR and the
-- many hosts is therefore NOT the candidate's representation but this
-- vocabulary: each field's sort, its source, and — critical for determinism —
-- its default when absent. Two hosts are conformant when they observe equally,
-- however they represent candidates internally.
--
-- Defaults are deliberately conservative: a missing price is +inf (a candidate
-- with no declared price does NOT pass a price ceiling), missing quality is 0,
-- missing latency is +inf, missing throughput/credits are 0. Note this is
-- stricter than the legacy declarative gates (`price_max` treated a missing
-- price as 0); the IR pins the conservative reading.
--
-- Extensibility: hosts/configs declare extra fields (`schema{ extensions }`)
-- without touching the signature. A term observing an undeclared field is
-- rejected at admission (term.check), never at runtime.

local util   = require("llm_policy.util")
local pm_key = util.pm_key

local Fl = {}

local function ema_of(cand, ctx)
    local ema = ctx.state and ctx.state.ema or nil
    return ema and ema[pm_key(cand.provider_id, cand.model_family)] or nil
end

-- Core vocabulary. get(cand, ctx) -> value | nil; nil means "absent, use default".
Fl.CORE = {
    price_in = { sort = "Num", default = math.huge, source = "state|catalog",
        get = function(c, ctx)
            local m = ema_of(c, ctx)
            return (m and m.price_in) or c.price_in
        end },
    price_out = { sort = "Num", default = math.huge, source = "state|catalog",
        get = function(c, ctx)
            local m = ema_of(c, ctx)
            return (m and m.price_out) or c.price_out
        end },
    -- (sigma-pol/v2) `quality` and `quality_hint` were REMOVED: neither denotes
    -- an observable. `last_quality_eval` is never computed (the committed
    -- metrics are hand-written placeholders), and `quality_hint` is a
    -- hand-assigned static number — a phantom, not a measurement. The algebra
    -- composes over reals (price, latency, context, …); a caller cannot order a
    -- policy by a quantity nobody observes. See SIGMA-POL §1.
    latency_ms = { sort = "Num", default = math.huge, source = "state",
        get = function(c, ctx)
            local m = ema_of(c, ctx)
            return m and m.ema_latency_ms
        end },
    tok_s = { sort = "Num", default = 0, source = "state",
        get = function(c, ctx)
            local m = ema_of(c, ctx)
            return m and m.ema_tok_s
        end },
    success_rate = { sort = "Num", default = 1, source = "state",
        get = function(c, ctx)
            local m = ema_of(c, ctx)
            return m and m.success_rate_ewma
        end },
    credits = { sort = "Num", default = 0, source = "state",
        get = function(c, ctx)
            local credits = ctx.state and ctx.state.credits or nil
            return credits and credits[c.provider_id]
        end },
    context = { sort = "Num", default = 0, source = "catalog",
        get = function(c, _ctx)
            return c.capabilities and c.capabilities.context
        end },
    has_tee = { sort = "Bool", default = false, source = "catalog",
        get = function(c, _ctx) return c.has_tee end },
    no_log = { sort = "Bool", default = false, source = "catalog",
        get = function(c, _ctx) return c.no_log end },
    breaker_open = { sort = "Bool", default = false, source = "state",
        get = function(c, ctx)
            local b = ctx.state and ctx.state.breakers or nil
            return b and (b[c.provider_id] == true)
        end },
    disabled = { sort = "Bool", default = false, source = "state",
        get = function(c, ctx)
            local d = ctx.state and ctx.state.disabled or nil
            return d and (d[c.provider_id] ~= nil)
        end },
}

local DEFAULT_TIER_ORDER = { "fallback", "marketplace", "partner" }

-- Build a schema: the core vocabulary plus declared extensions, plus the tier
-- total order (min_tier needs it). Extension decl:
--   { sort = "Num"|"Bool", default = <matching scalar>, get = fn(cand,ctx)? }
-- Default getter reads cand[name]. Core fields cannot be overridden.
function Fl.schema(opts)
    opts = opts or {}
    local decls = {}
    for name, d in pairs(Fl.CORE) do decls[name] = d end

    for name, d in pairs(opts.extensions or {}) do
        if type(name) ~= "string" then
            error("fields: extension name must be a string")
        end
        if Fl.CORE[name] then
            error("fields: cannot override core field '" .. name .. "'")
        end
        if type(d) ~= "table" or (d.sort ~= "Num" and d.sort ~= "Bool") then
            error("fields: extension '" .. name .. "' must declare sort Num or Bool")
        end
        if d.sort == "Num" and type(d.default) ~= "number" then
            error("fields: extension '" .. name .. "' needs a numeric default")
        end
        if d.sort == "Bool" and type(d.default) ~= "boolean" then
            error("fields: extension '" .. name .. "' needs a boolean default")
        end
        decls[name] = {
            sort    = d.sort,
            default = d.default,
            source  = d.source or "catalog",
            get     = d.get or function(c, _ctx) return c[name] end,
        }
    end

    local tier_order = opts.tier_order or DEFAULT_TIER_ORDER
    local tier_rank = {}
    for i, t in ipairs(tier_order) do tier_rank[t] = i end

    local schema = { decls = decls, tier_rank = tier_rank }

    function schema.decl(name) return decls[name] end

    -- The observation map: total by construction (default fills absence).
    function schema.observe(name, cand, ctx)
        local d = decls[name]
        if d == nil then error("fields: undeclared field '" .. tostring(name) .. "'") end
        local v = d.get(cand, ctx)
        if v == nil then return d.default end
        return v
    end

    return schema
end

local default_schema
function Fl.default()
    if default_schema == nil then default_schema = Fl.schema() end
    return default_schema
end

return Fl
