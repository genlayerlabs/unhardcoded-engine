-- llm_policy.interp — the unique homomorphism: eval(term, alg) folds a Σ_pol
-- term into any algebra; default_algebra() is the reference semantics 𝔖,
-- built over the existing pure verbs (filter/rank/mutate/sequence/policy).
--
-- eval knows nothing about policies — it only knows the recursion. All
-- semantics lives in the algebra table (op -> fn(args)). Swapping the algebra
-- yields other interpreters (pretty-printer, cost estimator, ...) for free;
-- initiality guarantees they agree on structure and differ only per-op.
--
-- Carriers of the default algebra (𝔖, v1 — Num pinned to IEEE-754 double):
--   Pred      fn(cand, ctx) -> true | (false, reason)
--   Scorer    fn(pop, ctx)  -> { score, ... }, { breakdown, ... }?
--             (population-relative: pointwise atoms are lifted; `normalize`
--             is why the carrier is relative to the population. The second
--             return — per-candidate named-atom breakdowns — is trace only,
--             NOT part of the normative semantics)
--   Selector  fn(scored, ctx) -> ordered scored   (seed enters here)
--   Xform     fn(req, cand, ctx) -> req'
--   FailPlan  retry table { [reason] = Action, unknown = Action }
--   Evidence  fn(cand, ctx) -> Num                (provisional)
--   Policy    Policy.new{...} (+ .evidence)
--
-- Unlike the legacy selectors, IR selectors do NOT silently gate breaker-open
-- candidates to score 0: state gating is the policy's own business, written in
-- its Pred (e.g. not(is("breaker_open"))). The algebra hides nothing.

local SIG      = require("llm_policy.sig")
local fieldsm  = require("llm_policy.fields")
local util     = require("llm_policy.util")
local F        = require("llm_policy.filter")
local Mut      = require("llm_policy.mutate")
local Policy   = require("llm_policy.policy")

local clamp = util.clamp
local lcg   = util.lcg

local I = {}

-- ===========================================================================
-- eval — the catamorphism
-- ===========================================================================

function I.eval(t, alg)
    local op = t[1]
    local entry = SIG.ops[op]
    if entry == nil then error("interp: unknown op '" .. tostring(op) .. "'") end
    local args = {}
    if entry.variadic then
        for i = 2, #t do args[i - 1] = I.eval(t[i], alg) end
    else
        for i, want in ipairs(entry.ins) do
            local v = t[i + 1]
            args[i] = SIG.OP_SORTS[want] and I.eval(v, alg) or v
        end
    end
    local f = alg[op]
    if f == nil then error("interp: algebra has no interpretation for '" .. op .. "'") end
    return f(args)
end

-- ===========================================================================
-- default algebra (𝔖)
-- ===========================================================================

-- Derive a per-stage seed so independent mutations decorrelate (same scheme as
-- llm_policy.mutate, but salted per parameter name — two jittered params draw
-- from independent streams, deterministically).
local function substream(ctx, salt)
    local base = ctx.seed or 0
    local h = 0
    for i = 1, #salt do h = (h * 31 + salt:byte(i)) % 2147483647 end
    return (base + h) % 2147483647
end

local function clone(req)
    local c = {}
    for k, v in pairs(req or {}) do c[k] = v end
    return c
end

-- lift a pointwise scorer fn(cand,ctx)->v into the population carrier; when
-- named, record the raw atom value per candidate (trace breakdown)
local function lift(point, name)
    return function(pop, ctx)
        local out, bds = {}, {}
        for i, c in ipairs(pop) do
            out[i] = (point(c, ctx))
            bds[i] = name and { [name] = out[i] } or {}
        end
        return out, bds
    end
end

local function empty_breakdowns(n)
    local bds = {}
    for i = 1, n do bds[i] = {} end
    return bds
end

local function merge_breakdowns(into, from)
    if from == nil then return into end
    for i = 1, #into do
        for k, v in pairs(from[i] or {}) do into[i][k] = v end
    end
    return into
end

local REL_FN = {
    lt = function(a, b) return a < b end,
    le = function(a, b) return a <= b end,
    eq = function(a, b) return a == b end,
    ne = function(a, b) return a ~= b end,
    ge = function(a, b) return a >= b end,
    gt = function(a, b) return a > b end,
}

-- opts: { schema = fields schema, customs = { [sym] = fn(req,cand,ctx) } }
function I.default_algebra(opts)
    opts = opts or {}
    local schema  = opts.schema or fieldsm.default()
    local customs = opts.customs or {}

    local alg = {}

    -- ---- Pred ---------------------------------------------------------
    alg.top = function() return function() return true end end
    alg.bot = function() return function() return false, "bot" end end
    alg["and"] = function(ps)
        return function(cand, ctx)
            for _, p in ipairs(ps) do
                local ok, why = p(cand, ctx)
                if not ok then return false, why end
            end
            return true
        end
    end
    alg["or"] = function(ps)
        return function(cand, ctx)
            for _, p in ipairs(ps) do
                if p(cand, ctx) then return true end
            end
            return false, "or"
        end
    end
    alg["not"] = function(a)
        return function(cand, ctx)
            if a[1](cand, ctx) then return false, "not" end
            return true
        end
    end
    alg.meets_req     = function() return F.requirements() end
    alg.scope_matches = function() return F.scope_matches() end
    alg.is = function(a)
        local name = a[1]
        return function(cand, ctx)
            if schema.observe(name, cand, ctx) then return true end
            return false, "is:" .. name
        end
    end
    alg.cmp = function(a)
        local name, rel, num = a[1], a[2], a[3]
        local relf = REL_FN[rel]
        return function(cand, ctx)
            if relf(schema.observe(name, cand, ctx), num) then return true end
            return false, "cmp:" .. name .. ":" .. rel
        end
    end
    alg.tier_eq = function(a)
        local tier = a[1]
        return function(cand, _ctx)
            if (cand.tier or "fallback") == tier then return true end
            return false, "tier"
        end
    end
    alg.min_tier = function(a)
        local rank = schema.tier_rank[a[1]]
        return function(cand, _ctx)
            local r = schema.tier_rank[cand.tier or "fallback"] or 0
            if r >= rank then return true end
            return false, "min_tier"
        end
    end
    alg.family_eq = function(a)
        local family = a[1]
        return function(cand, _ctx)
            if cand.model_family == family then return true end
            return false, "model_family"
        end
    end
    alg.has_cap = function(a)
        local cap = a[1]
        return function(cand, _ctx)
            if cand.capabilities and cand.capabilities[cap] then return true end
            return false, "missing_capability:" .. cap
        end
    end

    -- ---- Scorer (population-relative) -----------------------------------
    alg.zero = function() return function(pop, _ctx)
        local out = {}
        for i = 1, #pop do out[i] = 0 end
        return out, empty_breakdowns(#pop)
    end end
    alg.add = function(ss)
        return function(pop, ctx)
            local out, bds = {}, empty_breakdowns(#pop)
            for i = 1, #pop do out[i] = 0 end
            for _, s in ipairs(ss) do
                local v, b = s(pop, ctx)
                for i = 1, #pop do out[i] = out[i] + v[i] end
                merge_breakdowns(bds, b)
            end
            return out, bds
        end
    end
    alg.scale = function(a)
        local w, s = a[1], a[2]
        return function(pop, ctx)
            local v, b = s(pop, ctx)
            for i = 1, #v do v[i] = w * v[i] end
            return v, b
        end
    end
    alg.gate = function(a)
        local pred, s = a[1], a[2]
        return function(pop, ctx)
            local v, b = s(pop, ctx)
            b = b or empty_breakdowns(#pop)
            for i, c in ipairs(pop) do
                if not pred(c, ctx) then
                    v[i] = 0
                    b[i].gated = true
                end
            end
            return v, b
        end
    end
    alg.neg = function(a)
        local s = a[1]
        return function(pop, ctx)
            local v, b = s(pop, ctx)
            for i = 1, #v do v[i] = 1 - v[i] end
            return v, b
        end
    end
    alg.normalize = function(a)
        local s = a[1]
        return function(pop, ctx)
            local v, b = s(pop, ctx)
            local lo, hi = math.huge, -math.huge
            for i = 1, #v do
                if v[i] < lo then lo = v[i] end
                if v[i] > hi then hi = v[i] end
            end
            if hi <= lo then                       -- degenerate population
                for i = 1, #v do v[i] = 0 end
                return v, b
            end
            -- Map to [0,1]; endpoints are pinned (max→1, min→0) so an infinite
            -- bound (e.g. a missing price's +inf default) yields 1 at the top
            -- and never inf/inf = NaN. NaN scores are non-finite (un-JSON-able,
            -- non-deterministic comparisons), so they must never arise here.
            for i = 1, #v do
                local x = v[i]
                if x >= hi then x = 1
                elseif x <= lo then x = 0
                else
                    local d = (x - lo) / (hi - lo)
                    x = (d ~= d) and 0 or d         -- guard residual NaN
                end
                v[i] = x
            end
            return v, b
        end
    end
    alg.clamp = function(a)
        local lo, hi, s = a[1], a[2], a[3]
        return function(pop, ctx)
            local v, b = s(pop, ctx)
            for i = 1, #v do v[i] = clamp(v[i], lo, hi) end
            return v, b
        end
    end
    alg.field = function(a)
        local name = a[1]
        return lift(function(c, ctx) return schema.observe(name, c, ctx) end, name)
    end
    alg.lit = function(a)
        local n = a[1]
        return function(pop, _ctx)
            local out = {}
            for i = 1, #pop do out[i] = n end
            return out, empty_breakdowns(#pop)
        end
    end
    -- (sigma-pol/v2) composite scorer atoms quality/speed/cost/partner/
    -- free_credit removed — score on raw fields via `field(...)` instead.

    -- ---- Selector -------------------------------------------------------
    -- carrier: fn(scored, ctx) -> ordered scored; entries { candidate, score,
    -- score_breakdown }. Stable on ties via input order (cross-impl determinism).
    alg.argmax = function()
        return function(scored, _ctx)
            local out = {}
            for i, e in ipairs(scored) do
                out[i] = e
                e._i = i
            end
            table.sort(out, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a._i < b._i
            end)
            for _, e in ipairs(out) do e._i = nil end
            return out
        end
    end
    alg.ordered = function()
        return function(scored, _ctx) return scored end
    end
    -- Deterministic rank-geometric sampling (docs/SIGMA-POL.md §5.3). NOT a
    -- softmax: exp() is a libm transcendental, not specified by IEEE-754, so
    -- two hosts could disagree in the last ulp and flip a pick. This uses
    -- only correctly-rounded ops (mul/div/add/compare) — bit-identical
    -- everywhere. Order by (score desc, input order); weight by initial rank
    -- w_i = q^(i-1), q = t/(t+1), t = max(temp,0); sample without replacement
    -- proportional to the FIXED initial weights. temp=0 is exactly the argmax
    -- order; temp→inf approaches uniform.
    alg.sample = function(a)
        local t = a[1]
        if t < 0 then t = 0 end
        local q = t / (t + 1)
        return function(scored, ctx)
            local pool = {}
            for i, e in ipairs(scored) do
                pool[i] = e
                e._i = i
            end
            table.sort(pool, function(x, y)
                if x.score ~= y.score then return x.score > y.score end
                return x._i < y._i
            end)
            local w = 1
            for _, e in ipairs(pool) do
                e._w = w
                w = w * q
            end
            local rng = lcg(ctx.seed or 0)
            local out = {}
            while #pool > 0 do
                local total = 0
                for _, e in ipairs(pool) do total = total + e._w end
                local r = rng() * total
                local pick, acc = #pool, 0
                for i = 1, #pool do
                    acc = acc + pool[i]._w
                    if r <= acc then pick = i break end
                end
                out[#out + 1] = pool[pick]
                table.remove(pool, pick)
            end
            for _, e in ipairs(out) do e._i, e._w = nil, nil end
            return out
        end
    end
    alg.chain = function(a)
        local prio = {}
        for i, e in ipairs(a[1]) do
            prio[(e.provider or e.provider_id) .. "|" .. (e.model or e.model_family)] = i
        end
        return function(scored, _ctx)
            local out = {}
            for _, e in ipairs(scored) do
                local p = prio[e.candidate.provider_id .. "|" .. e.candidate.model_family]
                if p then
                    out[#out + 1] = e
                    e.score = -p
                    e.score_breakdown = { chain_priority = p }
                end
            end
            table.sort(out, function(x, y) return x.score > y.score end)
            return out
        end
    end
    -- top_k: order by the inner selector, then keep only the first k. The
    -- shortlist IS the failover sequence, so this bounds how many candidates
    -- the engine may try ("the 3 fastest", "the 5 best on benchmarks").
    alg.top_k = function(a)
        local k, inner = a[1], a[2]
        return function(scored, ctx)
            local ordered = inner(scored, ctx)
            local out = {}
            for i = 1, #ordered do
                if i > k then break end
                out[i] = ordered[i]
            end
            return out
        end
    end

    -- ---- Xform ----------------------------------------------------------
    alg.id  = function() return Mut.identity end
    alg.seq = function(xs)
        return function(req, cand, ctx)
            for _, x in ipairs(xs) do req = x(req, cand, ctx) end
            return req
        end
    end
    alg.set_param = function(a)
        return Mut.set_param({ [a[1]] = a[2] })
    end
    alg.inject_seed = function(a)
        return Mut.set_param({ [a[1]] = "from_ctx" })
    end
    alg.clamp_param = function(a)
        local name, lo, hi = a[1], a[2], a[3]
        return function(req, _cand, _ctx)
            local out = clone(req)
            if type(out[name]) == "number" then out[name] = clamp(out[name], lo, hi) end
            return out
        end
    end
    alg.jitter = function(a)
        local name, amount = a[1], a[2]
        return function(req, _cand, ctx)
            if ctx.seed == nil then return req end
            local rng = lcg(substream(ctx, "jitter:" .. name))
            local out = clone(req)
            local base = out[name]
            if type(base) == "number" then
                out[name] = base + (rng() * 2 - 1) * amount
            else
                out[name] = (rng() * 2 - 1) * amount
            end
            return out
        end
    end
    alg.filter_text  = function(a) return Mut.filter_text(a[1]) end
    alg.filter_image = function(a) return Mut.filter_image(a[1]) end
    alg.custom = function(a)
        local fn = customs[a[1]]
        if fn == nil then error("interp: custom Sym '" .. a[1] .. "' not registered") end
        return fn
    end
    alg.when = function(a)
        return Mut.when(a[1], a[2])
    end

    -- ---- FailPlan ---------------------------------------------------------
    alg.always = function(a)
        return { unknown = a[1] }
    end
    alg.override = function(a)
        local plan, reason, action = a[1], a[2], a[3]
        local out = {}
        for k, v in pairs(plan) do out[k] = v end
        out[reason] = action
        return out
    end

    -- ---- Policy -------------------------------------------------------------
    -- (sigma-pol/v2) the Evidence sub-algebra was removed (see sig.lua): it
    -- never affected the decision and `from_prov` read the phantom quality.
    -- A policy is five slots: filter / scorer / selector / xform / failplan.
    alg.policy = function(a)
        local pred, scorer, selector, xform, failplan =
            a[1], a[2], a[3], a[4], a[5]
        local pol = Policy.new{
            filter = pred,
            select = function(cands, ctx)
                local scores, bds = scorer(cands, ctx)
                local scored = {}
                for i, c in ipairs(cands) do
                    local bd = (bds and bds[i]) or {}
                    bd.raw = scores[i]
                    scored[i] = {
                        candidate = c,
                        score = scores[i],
                        score_breakdown = bd,
                    }
                end
                return selector(scored, ctx)
            end,
            mutate   = xform,
            sequence = failplan,
        }
        return pol
    end

    return alg
end

return I
