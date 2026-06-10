-- llm_policy.rank — pure scorers, combinators, and selectors.
--
-- A scorer is `fn(cand, ctx) -> [0,1]`. A combinator turns scorers into a
-- scorer. A selector is `fn(scored, ctx) -> ordered_scored`:
--   R.argmax        -> deterministic best-first (the default; subzero & greybox)
--   R.softmax_sample-> seeded stochastic order — an OPTIONAL off-chain
--                      load-spread tool, NOT the greybox mechanism. Selection
--                      should stay deterministic; divergence belongs in `mutate`
--                      (per-call seed + random mutations). See docs/GENVM-LLM-POLICY.md.
--
-- Everything is a pure function of its arguments. State enters via ctx.state
-- (a read-only snapshot), never a global. See docs/POLICY_DESIGN.md §5.2.
--
-- ctx shape consumed here:
--   ctx.request = contract (requirements-bearing fields)
--   ctx.state.ema[pm_key]                = { ema_latency_ms, last_quality_eval,
--                                            price_in, price_out, ema_tok_s }
--   ctx.state.credits[provider_id]       = remaining_usd
--   ctx.state.free_credit_threshold_usd  = number
--   ctx.seed                             = integer | nil

local util   = require("llm_policy.util")
local clamp  = util.clamp
local pm_key = util.pm_key

local R = {}

-- ---- atom scorers (the standard library; today's hardcoded dims) ----------

function R.quality()
    return function(cand, ctx)
        local m = ctx.state.ema[pm_key(cand.provider_id, cand.model_family)]
        local q = (m and m.last_quality_eval) or cand.quality_hint or 0.5
        return clamp(q, 0, 1)
    end
end

function R.speed()
    return function(cand, ctx)
        local req = ctx.request.requirements or {}
        local target = req.max_latency_ms or 5000
        local m = ctx.state.ema[pm_key(cand.provider_id, cand.model_family)]
        local lat = m and m.ema_latency_ms
        if lat == nil then return 0.5 end
        return clamp(1 - (lat / target), 0, 1)
    end
end

function R.cost()
    return function(cand, ctx)
        local req = ctx.request.requirements or {}
        local m = ctx.state.ema[pm_key(cand.provider_id, cand.model_family)]
        local price_in  = (m and m.price_in)  or 0
        local price_out = (m and m.price_out) or 0
        local in_toks  = req.estimated_input_tokens  or 1000
        local out_toks = req.estimated_output_tokens or 500
        local cost_usd = (price_in * in_toks + price_out * out_toks) / 1e6
        if cost_usd <= 0 then return 1.0 end
        local target = req.max_cost_usd or 0.01
        return clamp(1 - (cost_usd / target), 0, 1)
    end
end

function R.free()
    return function(cand, ctx)
        local credits = ctx.state.credits or {}
        local rem = credits[cand.provider_id]
        local thr = ctx.state.free_credit_threshold_usd or 1.0
        if rem and rem >= thr then return 1.0 end
        return 0.0
    end
end

local TIER_SCORE = { partner = 1.0, marketplace = 0.5, fallback = 0.0 }

function R.partner_tier()
    return function(cand, _ctx)
        return TIER_SCORE[cand.tier or "fallback"] or 0
    end
end

-- ---- combinators -> a scorer ----------------------------------------------

-- Standard-library atom names, so `weighted{ quality=.., speed=.. }` reads like
-- the old profile weights and reproduces the old weighted sum exactly.
local ATOMS = {
    quality     = R.quality,
    speed       = R.speed,
    cost        = R.cost,
    free_credit = R.free,
    partner     = R.partner_tier,
}

-- weights: { quality=, speed=, cost=, free_credit=, partner= }. Already
-- renormalized by the caller (profile resolution); used as-is here.
function R.weighted(weights)
    local terms = {}
    for name, w in pairs(weights or {}) do
        local atom = ATOMS[name]
        if atom and type(w) == "number" then
            terms[#terms + 1] = { name = name, w = w, f = atom() }
        end
    end
    return function(cand, ctx)
        local raw, breakdown = 0, {}
        for _, t in ipairs(terms) do
            local s = t.f(cand, ctx)
            breakdown[t.name] = s
            raw = raw + t.w * s
        end
        breakdown.weights = weights   -- preserved for trace/debug (parity with old breakdown)
        return raw, breakdown
    end
end

function R.custom(fn) return fn end

-- ---- selectors: scorer -> ordered list (ctx.seed enters HERE) -------------

-- Score every candidate, gating breaker-open ones to 0 (preserving today's
-- behavior: open breaker => score 0, still listed but last). Returns the
-- scored array of { candidate, score, score_breakdown }.
local function score_all(scorer, candidates, ctx)
    local breakers = ctx.state.breakers or {}
    local scored = {}
    for _, cand in ipairs(candidates) do
        local raw, breakdown = scorer(cand, ctx)
        breakdown = breakdown or {}
        local open = breakers[cand.provider_id] == true
        breakdown.raw = raw
        breakdown.breaker_open = open
        scored[#scored + 1] = {
            candidate = cand,
            score = open and 0 or raw,
            score_breakdown = breakdown,
        }
    end
    return scored
end

local lcg = util.lcg

-- Deterministic best-first. Stable on ties (preserves input order) so the
-- ordering is reproducible across Lua implementations (table.sort is not stable).
function R.argmax(scorer)
    return function(candidates, ctx)
        local scored = score_all(scorer, candidates, ctx)
        for i, e in ipairs(scored) do e._i = i end
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a._i < b._i
        end)
        for _, e in ipairs(scored) do e._i = nil end
        return scored
    end
end

-- Seeded stochastic ordering: sample without replacement with probability
-- proportional to exp(score/temp). seed=nil collapses toward argmax-ish but is
-- still seeded by 0; greybox passes ctx.seed = H(tx_id, node_addr).
-- LEGACY (closure-path only): math.exp is a libm transcendental, NOT pinned
-- by IEEE-754, so this can differ across hosts in the last ulp and flip a
-- pick. The IR `sample` op (llm_policy.interp) is the deterministic,
-- transcendental-free replacement; declarative profiles lower to it.
function R.softmax_sample(scorer, opts)
    local temp = (opts and opts.temp) or 1.0
    return function(candidates, ctx)
        local scored = score_all(scorer, candidates, ctx)
        local rng = lcg(ctx.seed or 0)
        local pool = {}
        for i, e in ipairs(scored) do pool[i] = e end
        local out = {}
        while #pool > 0 do
            local total, ws = 0, {}
            for i, e in ipairs(pool) do
                local w = math.exp(e.score / temp)
                ws[i] = w
                total = total + w
            end
            local r = rng() * total
            local pick, acc = #pool, 0
            for i = 1, #pool do
                acc = acc + ws[i]
                if r <= acc then pick = i; break end
            end
            out[#out + 1] = pool[pick]
            table.remove(pool, pick)
        end
        return out
    end
end

-- Deterministic priority chain (the greybox mechanism). `chain` is an ordered
-- list { {provider=, model=}, ... } (index = priority; from meta.greybox or a
-- hot-reload JSON). Candidates not in the chain are dropped — you only call what
-- the chain whitelists. Order is fixed (no scoring, no breaker gating); the
-- engine's `sequence` cascades on actual failure, like the production tryChain
-- pcall loop. Identical across nodes given the same chain.
function R.chain(chain)
    local prio = {}
    for i, e in ipairs(chain) do
        prio[(e.provider or e.provider_id) .. "|" .. (e.model or e.model_family)] = i
    end
    return function(candidates, _ctx)
        local scored = {}
        for _, cand in ipairs(candidates) do
            local p = prio[cand.provider_id .. "|" .. cand.model_family]
            if p then
                scored[#scored + 1] = {
                    candidate = cand,
                    score = -p,        -- lower priority number = earlier
                    score_breakdown = { chain_priority = p },
                }
            end
        end
        table.sort(scored, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return false
        end)
        return scored
    end
end

R._score_all = score_all   -- exposed for the policy layer / tests

return R
