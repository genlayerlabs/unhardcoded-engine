-- R2.7 — the defining invariant: same (policy, catalog, ctx, seed) => same
-- decision. Default Policy (argmax, seed=nil) reproduces pre-R2 ranking;
-- a softmax profile diverges reproducibly by seed. This is the engine-level
-- foundation of the mlua≡lupa conformance test (docs/POLICY_DESIGN.md §8).

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config()
    return {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", tier = "partner" },
            p3 = { discovery = "static", base_url = "http://p3", api_kind = "openai_compatible", tier = "fallback" },
        },
        models = {
            m1 = {
                served_by = { { provider = "p1" }, { provider = "p2" }, { provider = "p3" } },
                capabilities = { context = 8000 },
                static_quality_hint = 0.7,
            },
        },
        profiles = {
            default = {},
            diverse = { 
                        selector = "softmax_sample", selector_opts = { temp = 0.5 } },
            -- greybox: deterministic priority chain (the genvm case), config-only
            greybox = { selector = "chain",
                        chain = { { provider = "p3", model = "m1" },
                                  { provider = "p1", model = "m1" } } },
        },
    }
end

local function fresh()
    r.reset()
    host = { now_ms = function() return 0 end, log = function() end, env = function() return nil end }
    assert(router.init(config()))
end

local function order(contract)
    local ranked = router.rank(contract)
    local ids = {}
    for i, item in ipairs(ranked) do ids[i] = item.candidate.provider_id end
    return ids
end

local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- ---- determinism & parity with pre-R2 behavior ---------------------------

t.test("argmax default is deterministic across calls", function()
    fresh()
    t.truthy(same(order({ profile = "default" }), order({ profile = "default" })),
             "identical inputs => identical order")
end)

-- (sigma-pol/v2) The "partner-over-fallback" score parity test was removed
-- with the partner atom: weighted profiles no longer score, so there is no
-- tier-based default ranking to reproduce. Determinism, seeded divergence and
-- the chain selector below are unaffected.

-- ---- seeded divergence is reproducible ------------------------------------

t.test("softmax profile is reproducible for a fixed seed", function()
    fresh()
    t.truthy(same(order({ profile = "diverse", seed = 7 }),
                  order({ profile = "diverse", seed = 7 })),
             "same seed => identical order")
end)

t.test("softmax profile diverges from argmax for some seed", function()
    fresh()
    local amax = order({ profile = "default" })   -- p1 first (stable argmax)
    t.eq(amax[1], "p1")
    local diverged = false
    for seed = 1, 30 do
        if order({ profile = "diverse", seed = seed })[1] ~= "p1" then diverged = true; break end
    end
    t.truthy(diverged, "seed drives a non-argmax top pick (greybox divergence)")
end)

t.test("greybox chain profile selects in fixed priority order, drops non-listed", function()
    fresh()
    local o = order({ profile = "greybox" })
    t.eq(#o, 2, "p2 dropped — only chained candidates are eligible")
    t.eq(o[1], "p3", "p3 is chain priority 1 (even though it's fallback tier)")
    t.eq(o[2], "p1", "p1 is chain priority 2")
end)

t.test("no seed collapses softmax to a stable order", function()
    fresh()
    -- seed=nil should be reproducible call-to-call (lcg(0) is deterministic)
    t.truthy(same(order({ profile = "diverse" }), order({ profile = "diverse" })),
             "nil seed is still reproducible")
end)
