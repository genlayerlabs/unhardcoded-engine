-- Elaboration: the declarative surface -> Σ_pol terms. The declarative
-- vocabulary has exactly one compiler (elaborate); these tests pin its
-- lowerings term-by-term, plus the engine's wiring of an elaborated profile
-- against a from-scratch elaboration (same config, same ranking).

local t  = require("_assert")
local ir = require("llm_policy.ir")
local E  = ir.elaborate
local T  = ir.term

local function enc(x) return T.encode(T.normalize(x)) end

t.test("filter atoms lower to field observations", function()
    t.eq(enc(E.filter("not_disabled")), enc({ "not", { "is", "disabled" } }))
    t.eq(enc(E.filter("breaker_closed")), enc({ "not", { "is", "breaker_open" } }))
    t.eq(enc(E.filter({ price_max = { input = 5, output = 25 } })),
         enc({ "and", { "cmp", "price_in", "le", 5 }, { "cmp", "price_out", "le", 25 } }))
    t.eq(enc(E.filter({ tier_in = { "partner", "tee" } })),
         enc({ "or", { "tier_eq", "partner" }, { "tier_eq", "tee" } }))
    t.eq(enc(E.filter({ family_in = { "gpt-5.5", "claude-opus-4-8" } })),
         enc({ "or", { "family_eq", "gpt-5.5" }, { "family_eq", "claude-opus-4-8" } }),
        "family_in lowers to or(family_eq), like tier_in")
    t.eq(enc(E.filter({ family_in = { "gpt-5.5" } })), enc({ "family_eq", "gpt-5.5" }),
        "singleton family_in collapses to a single family_eq")
    t.eq(enc(E.filter({ "requirements", { tier_in = { "partner" } } })),
         enc({ "and", { "meets_req" }, { "tier_eq", "partner" } }),
        "bare list = all_of; singleton tier_in collapses")
end)

t.test("profile.scorer passes through (else zero); retry tables to FailPlan", function()
    -- (sigma-pol/v2) weighted scoring was removed; a profile carries an explicit
    -- raw IR Scorer term in `profile.scorer`, defaulting to zero (no scoring).
    local prof = { filter = { "requirements", { tier_in = { "partner" } } } }
    local zeroed = E.profile(prof, {})
    t.eq(T.check(zeroed), "Policy", "valid policy term with no scorer")
    t.contains(enc(zeroed), "zero", "absent profile.scorer → zero scorer")

    prof.scorer = { "field", "context" }
    local scored = E.profile(prof, {})
    t.eq(T.check(scored), "Policy")
    t.contains(enc(scored), "context", "explicit profile.scorer lowers into the term")

    local fp = E.failplan({
        rate_limit = { action = "next_candidate", open_breaker_ms = 30000 },
        auth_error = { action = "disable_provider" },
        unknown    = { action = "next_candidate" },
    })
    local sort = T.check(fp)
    t.eq(sort, "FailPlan")
end)

t.test("mutate specs lower to seq with per-param ops, maps in sorted order", function()
    t.eq(enc(E.mutate({ { filter_text = { "NFKC" } }, { jitter = { temperature = 0.3 } } })),
         enc({ "seq", { "filter_text", { "NFKC" } }, { "jitter", "temperature", 0.3 } }))
    t.eq(enc(E.mutate({ set_param = { seed = "from_ctx", user = "router" } })),
         enc({ "seq", { "inject_seed", "seed" }, { "set_param", "user", "router" } }),
        "from_ctx becomes inject_seed; keys sorted")
end)

-- ---- engine wiring vs hand elaboration --------------------------------------

local router = dofile("router.lua")
local r = router._test

local function config()
    return {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", tier = "fallback" },
            p3 = { discovery = "static", base_url = "http://p3", api_kind = "openai_compatible", tier = "marketplace" },
        },
        models = {
            m1 = { served_by = { { provider = "p1" }, { provider = "p2" }, { provider = "p3" } },
                   capabilities = { context = 8000 }, static_quality_hint = 0.7 },
        },
        profiles = {
            hardened = {
                scorer  = { "field", "context" },
                filter  = { "requirements", { tier_in = { "partner", "marketplace" } } },
                mutate  = { { filter_text = { "NFKC" } }, { jitter = { temperature = 0.5 } } },
                retry_policy = "balanced",
            },
        },
        retry_policies = { balanced = { unknown = { action = "next_candidate" } } },
    }
end

local function fresh()
    r.reset()
    host = {
        log = function() end, env = function() return nil end, sleep_ms = function() end,
        now_ms = function() return 0 end,
        call_provider = function() return { ok = true, response = { text = "ok" } } end,
    }
    assert(router.init(config()))
end

t.test("engine elaboration of a profile ranks like the hand-elaborated term", function()
    -- Both arms lower through elaborate (the declarative vocabulary has one
    -- compiler); this pins the ENGINE's wiring — retry table,
    -- schema — against a from-scratch elaboration of the same profile.
    fresh()
    local legacy = router.rank({ profile = "hardened" })

    local profile = r.catalog().profiles.hardened
    local term = E.profile(profile, {
        retry_table = r.catalog().retry.balanced,
    })
    fresh()
    local via_ir = router.rank({ policy_ir = term })

    t.eq(#via_ir, #legacy, "same survivor count")
    for i = 1, #legacy do
        t.eq(via_ir[i].candidate.provider_id, legacy[i].candidate.provider_id,
            "same order at position " .. i)
        t.near(via_ir[i].score, legacy[i].score, 1e-12, "same score at position " .. i)
    end
end)

t.test("engine-wired mutate behaves like the hand-elaborated one (directive + seeded jitter)", function()
    fresh()
    local captured
    host.call_provider = function(req) captured = req; return { ok = true, response = {} } end

    local profile = r.catalog().profiles.hardened
    local term = E.profile(profile, {
        retry_table = r.catalog().retry.balanced,
    })
    router.execute({ policy_ir = term, prompt = "hi", temperature = 0.7, seed = 42 })
    t.truthy(captured._filters and captured._filters.text, "filter_text directive attached")
    t.truthy(math.abs(captured.temperature - 0.7) > 1e-9, "temperature jittered under seed")
end)

t.test("pinned divergence: a candidate with no price fails an IR price ceiling", function()
    fresh()
    local ranked = router.rank({ policy_ir = { "policy",
        { "cmp", "price_in", "le", 5 },
        { "field", "context" }, { "argmax" }, { "id" },
        { "always", { action = "next_candidate" } },
    } })
    t.eq(#ranked, 0, "missing price defaults to +inf: conservative, unlike the legacy gate")
end)
