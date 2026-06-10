-- Σ_pol default interpreter (𝔖): per-op semantics over the existing verbs,
-- plus the full admission pipeline (ir.compile) and per-call IR policies
-- through the router.

local t  = require("_assert")
local ir = require("llm_policy.ir")

local function cand(over)
    local c = {
        provider_id = "p1", model_family = "m1", served_model_id = "m1",
        capabilities = { context = 8000 }, quality_hint = 0.7,
        tier = "partner", base_url = "http://p1", api_kind = "openai_compatible",
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function ctx(over)
    local c = {
        request = { requirements = {} },
        state = { ema = {}, breakers = {}, disabled = {}, credits = {} },
        now_ms = 0,
        seed = nil,
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function ev(term, opts) return (ir.eval_sort(term, opts)) end

t.test("cmp observes through the schema; missing price defaults to +inf (rejects)", function()
    local p = ev({ "cmp", "price_in", "le", 5 })
    local ok, why = p(cand(), ctx())                     -- no price anywhere
    t.falsy(ok, "missing price fails a price ceiling")
    t.contains(why, "cmp:price_in")

    local c = ctx()
    c.state.ema["p1|m1"] = { price_in = 3 }
    t.truthy(p(cand(), c), "EMA price 3 passes le 5")
end)

t.test("is / tier_eq / min_tier / has_cap", function()
    local disabled = ev({ "is", "disabled" })
    local c = ctx()
    t.falsy(disabled(cand(), c), "not disabled -> is() is false")
    c.state.disabled.p1 = "auth_error"
    t.truthy(disabled(cand(), c), "disabled -> is() true")

    t.truthy(ev({ "tier_eq", "partner" })(cand(), ctx()))
    t.truthy(ev({ "min_tier", "marketplace" })(cand(), ctx()), "partner >= marketplace")
    t.falsy(ev({ "min_tier", "partner" })(cand({ tier = "fallback" }), ctx()))

    t.truthy(ev({ "has_cap", "context" })(cand(), ctx()))
    local ok, why = ev({ "has_cap", "supports_tools" })(cand(), ctx())
    t.falsy(ok); t.contains(why, "missing_capability")
end)

t.test("boolean structure: and short-circuits with reason, not inverts", function()
    local p = ev({ "and", { "tier_eq", "partner" }, { "cmp", "quality_hint", "ge", 0.9 } })
    local ok, why = p(cand(), ctx())
    t.falsy(ok); t.contains(why, "cmp:quality_hint")

    t.truthy(ev({ "not", { "is", "breaker_open" } })(cand(), ctx()))
end)

t.test("scorers are population-relative; normalize min-maxes over the pool", function()
    local pop = { cand({ quality_hint = 0.2 }), cand({ provider_id = "p2", quality_hint = 0.8 }),
                  cand({ provider_id = "p3", quality_hint = 0.5 }) }
    local s = ev({ "normalize", { "field", "quality_hint" } })
    local v = s(pop, ctx())
    t.near(v[1], 0); t.near(v[2], 1); t.near(v[3], 0.5)

    local sum = ev({ "add", { "scale", 0.5, { "lit", 1 } }, { "field", "quality_hint" } })
    t.near(sum(pop, ctx())[2], 1.3, 1e-12, "0.5*1 + 0.8")

    local degenerate = s({ pop[1] }, ctx())
    t.near(degenerate[1], 0, 1e-12, "degenerate population pins to 0")
end)

t.test("argmax orders by score, stable on ties; sample is seed-reproducible", function()
    local pol = ir.compile({ "policy",
        { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "argmax" }, { "id" },
        { "always", { action = "next_candidate" } },
    })
    local pop = { cand({ quality_hint = 0.5 }),
                  cand({ provider_id = "p2", quality_hint = 0.9 }),
                  cand({ provider_id = "p3", quality_hint = 0.5 }) }
    local ordered = pol.plan(pop, ctx()).ordered
    t.eq(ordered[1].candidate.provider_id, "p2")
    t.eq(ordered[2].candidate.provider_id, "p1", "tie keeps input order")
    t.eq(ordered[3].candidate.provider_id, "p3")

    local sampler = ir.compile({ "policy",
        { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "sample", 0.3 }, { "id" },
        { "always", { action = "next_candidate" } },
    })
    local o1 = sampler.plan(pop, ctx({ seed = 42 })).ordered
    local o2 = sampler.plan(pop, ctx({ seed = 42 })).ordered
    for i = 1, #o1 do
        t.eq(o1[i].candidate.provider_id, o2[i].candidate.provider_id,
            "same seed -> same order at position " .. i)
    end

    -- temp = 0 collapses rank-geometric sampling to the argmax order exactly
    local sharp = ir.compile({ "policy",
        { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "sample", 0 }, { "id" },
        { "always", { action = "next_candidate" } },
    })
    local so = sharp.plan(pop, ctx({ seed = 99 })).ordered
    t.eq(so[1].candidate.provider_id, "p2", "temp=0: best first")
    t.eq(so[2].candidate.provider_id, "p1", "temp=0: tie keeps input order")
    t.eq(so[3].candidate.provider_id, "p3")
end)

t.test("chain selector whitelists and orders by priority", function()
    local sel = ev({ "chain", { { provider = "p3", model = "m1" }, { provider = "p1", model = "m1" } } })
    local scored = {
        { candidate = cand(), score = 0.9, score_breakdown = {} },
        { candidate = cand({ provider_id = "p2" }), score = 0.8, score_breakdown = {} },
        { candidate = cand({ provider_id = "p3" }), score = 0.1, score_breakdown = {} },
    }
    local out = sel(scored, ctx())
    t.eq(#out, 2, "p2 not in chain -> dropped")
    t.eq(out[1].candidate.provider_id, "p3", "chain order, not score order")
    t.eq(out[2].candidate.provider_id, "p1")
end)

t.test("xforms: set_param / inject_seed / clamp_param / jitter / filter_text / when", function()
    local c = ctx({ seed = 7 })
    local x = ev({ "seq",
        { "set_param", "max_tokens", 4096 },
        { "inject_seed", "seed" },
        { "clamp_param", "temperature", 0, 1 },
        { "filter_text", { "NFKC", "RmZeroWidth" } },
    })
    local req = x({ temperature = 1.7 }, cand(), c)
    t.eq(req.max_tokens, 4096)
    t.eq(req.seed, 7, "inject_seed reads ctx.seed")
    t.near(req.temperature, 1.0, 1e-12, "clamped to [0,1]")
    t.truthy(req._filters and req._filters.text, "filter directive attached for the host")

    local j = ev({ "jitter", "temperature", 0.3 })
    t.eq(j({ temperature = 0.7 }, cand(), ctx()).temperature, 0.7, "no seed -> no jitter")
    local r1 = j({ temperature = 0.7 }, cand(), c).temperature
    local r2 = j({ temperature = 0.7 }, cand(), c).temperature
    t.truthy(math.abs(r1 - 0.7) > 1e-9 and math.abs(r1 - 0.7) <= 0.3, "jittered within ±0.3")
    t.near(r1, r2, 0, "deterministic under the same seed")

    local w = ev({ "when", { "tier_eq", "fallback" }, { "set_param", "max_tokens", 100 } })
    t.eq(w({}, cand(), c).max_tokens, nil, "pred false -> untouched")
    t.eq(w({}, cand({ tier = "fallback" }), c).max_tokens, 100)
end)

t.test("custom resolves against the host registry only", function()
    local term = { "custom", "my_xform" }
    local got = ev(term, { customs = { my_xform = function(req) req.marked = true; return req end } })
    t.truthy(got({}, cand(), ctx()).marked)
    local ok = pcall(function() ev(term) end)
    t.falsy(ok, "unregistered Sym is rejected at compile, not at runtime")
end)

t.test("failplan evaluates to a retry table the engine understands", function()
    local seq = require("llm_policy.sequence")
    local fp = ev({ "override",
        { "override", { "always", { action = "next_candidate" } },
          "auth_error", { action = "disable_provider" } },
        "server_error", { action = "retry_same", attempts = 2, backoff_ms = 500 } })
    t.eq(seq.classify(fp, "auth_error").action, "disable_provider")
    t.eq(seq.classify(fp, "server_error").attempts, 2)
    t.eq(seq.classify(fp, "anything_else").action, "next_candidate", "base is the unknown fallback")
end)

t.test("evidence: from_prov('self') reads own quality state", function()
    local e = ev({ "from_prov", "self" })
    local c = ctx()
    t.near(e(cand(), c), 0.7, 1e-12, "falls back to quality_hint")
    c.state.ema["p1|m1"] = { last_quality_eval = 0.95 }
    t.near(e(cand(), c), 0.95)
    t.near(ev({ "ev_zero" })(cand(), c), 0)
end)

t.test("ir.compile: full pipeline, fingerprint, Policy-sort enforcement", function()
    local pol = ir.compile({ "policy",
        { "ev_zero" },
        { "and", { "not", { "is", "disabled" } }, { "min_tier", "partner" } },
        { "add", { "scale", 1, { "quality" } } },
        { "argmax" }, { "id" },
        { "always", { action = "next_candidate" } },
    })
    t.truthy(pol.fingerprint, "compiled policy carries its fingerprint")
    t.truthy(pol.term, "and its normal form")

    local pop = { cand(), cand({ provider_id = "p2", tier = "fallback" }) }
    local plan = pol.plan(pop, ctx())
    t.eq(#plan.ordered, 1, "fallback tier filtered out")
    t.eq(plan.rejected[1].reason, "min_tier")

    local ok, err = pcall(function() ir.compile({ "top" }) end)
    t.falsy(ok); t.contains(tostring(err), "expected a Policy term")
end)

-- ---- per-call IR policies through the router --------------------------------

local router = dofile("router.lua")
local r = router._test

local function router_config()
    return {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", tier = "fallback" },
        },
        models = {
            m1 = { served_by = { { provider = "p1" }, { provider = "p2" } },
                   capabilities = { context = 8000 }, static_quality_hint = 0.7 },
        },
        profiles = { default = { weights = { quality = 1.0 } } },
        fields = { region_score = { sort = "Num", default = 0 } },   -- declared extension
    }
end

local function fresh()
    r.reset()
    host = {
        log = function() end, env = function() return nil end, sleep_ms = function() end,
        now_ms = function() return 0 end,
        call_provider = function() return { ok = true, response = { text = "ok" } } end,
    }
    assert(router.init(router_config()))
end

t.test("contract.policy_ir: a policy arriving with the call is data, not code", function()
    fresh()
    local ranked = router.rank({
        profile = "default",
        policy_ir = { "policy",
            { "ev_zero" }, { "min_tier", "partner" },
            { "field", "quality_hint" }, { "argmax" }, { "id" },
            { "always", { action = "next_candidate" } },
        },
    })
    t.eq(#ranked, 1, "per-call IR policy filtered the fallback provider")
    t.eq(ranked[1].candidate.provider_id, "p1")
end)

t.test("contract.policy_ir works without any profile", function()
    fresh()
    local ranked = router.rank({
        profile = "nope_not_a_profile",
        policy_ir = { "policy",
            { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "argmax" }, { "id" },
            { "always", { action = "next_candidate" } },
        },
    })
    t.eq(#ranked, 2, "IR policy is a complete sentence; unknown profile is fine")
end)

t.test("config-declared fields are observable by per-call policies", function()
    fresh()
    local ranked = router.rank({
        policy_ir = { "policy",
            { "ev_zero" }, { "cmp", "region_score", "ge", 0 },
            { "field", "region_score" }, { "argmax" }, { "id" },
            { "always", { action = "next_candidate" } },
        },
    })
    t.eq(#ranked, 2, "extension field admitted and defaulted")
end)

t.test("a malformed per-call policy is rejected at admission", function()
    fresh()
    local ok, err = pcall(function()
        router.rank({ policy_ir = { "policy", { "ev_zero" }, { "cmp", "wat", "le", 1 },
            { "zero" }, { "argmax" }, { "id" }, { "always", { action = "next_candidate" } } } })
    end)
    t.falsy(ok, "undeclared field never reaches execution")
    t.contains(tostring(err), "undeclared field")
end)

t.test("gate demotes to 0 without dropping (the legacy breaker behavior, stated)", function()
    local pol = ir.compile({ "policy",
        { "ev_zero" }, { "top" },
        { "gate", { "not", { "is", "breaker_open" } }, { "field", "quality_hint" } },
        { "argmax" }, { "id" },
        { "always", { action = "next_candidate" } },
    })
    local c = ctx()
    c.state.breakers.p2 = true
    local pop = { cand({ quality_hint = 0.5 }), cand({ provider_id = "p2", quality_hint = 0.9 }) }
    local ordered = pol.plan(pop, c).ordered
    t.eq(#ordered, 2, "breaker-open candidate still listed (last resort)")
    t.eq(ordered[1].candidate.provider_id, "p1")
    t.eq(ordered[2].score, 0, "demoted to 0")
    t.truthy(ordered[2].score_breakdown.gated, "trace marks the gating")
end)

t.test("declarative profiles now compile through the IR (fingerprint in trace)", function()
    fresh()
    local res = router.execute({ profile = "default", prompt = "hi" })
    t.truthy(res.ok)
    t.truthy(res.trace.policy_fingerprint, "lowered profile carries its policy identity")

    local bd = router.rank({ profile = "default" })[1].score_breakdown
    t.truthy(bd.quality ~= nil, "named-atom breakdown preserved through the IR")
end)

t.test("config.policy_envelope: callers narrow, never widen", function()
    r.reset()
    host = {
        log = function() end, env = function() return nil end, sleep_ms = function() end,
        now_ms = function() return 0 end,
        call_provider = function() return { ok = true, response = { text = "ok" } } end,
    }
    local cfg = router_config()
    cfg.policy_envelope = { "min_tier", "partner" }     -- host invariant
    assert(router.init(cfg))

    local ranked = router.rank({
        policy_ir = { "policy",                         -- caller tries top (allow-all)
            { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "argmax" }, { "id" },
            { "always", { action = "next_candidate" } },
        },
    })
    t.eq(#ranked, 1, "envelope ∧ caller pred: fallback provider excluded anyway")
    t.eq(ranked[1].candidate.provider_id, "p1")

    local bad = { providers = cfg.providers, models = cfg.models,
                  profiles = cfg.profiles, policy_envelope = { "quality" } }
    r.reset()
    local ok, err = router.init(bad)
    t.falsy(ok, "non-Pred envelope rejected at init")
    t.contains(tostring(err), "Pred")
end)

t.test("IR FailPlan drives the engine sequence", function()
    fresh()
    local calls = 0
    host.call_provider = function()
        calls = calls + 1
        return { ok = false, error_kind = "rate_limit" }
    end
    local res = router.execute({
        prompt = "hi",
        policy_ir = { "policy",
            { "ev_zero" }, { "top" }, { "field", "quality_hint" }, { "argmax" }, { "id" },
            { "override", { "always", { action = "next_candidate" } },
              "rate_limit", { action = "abort" } },
        },
    })
    t.falsy(res.ok)
    t.eq(res.error, "rate_limit", "abort on first rate_limit, per the IR FailPlan")
    t.eq(calls, 1, "no cascade")
end)
