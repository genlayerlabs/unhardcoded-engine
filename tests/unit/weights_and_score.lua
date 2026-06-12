-- Weight renormalization and score component math.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

-- ---- renormalize_weights -------------------------------------------------

t.test("renormalize sums positive weights to 1.0", function()
    local w = r.renormalize_weights({ quality = 1, speed = 1, cost = 2 })
    t.near(w.quality + w.speed + w.cost, 1.0, 1e-9, "sum is 1")
    t.near(w.quality, 0.25, 1e-9, "quality 1/4")
    t.near(w.cost,    0.50, 1e-9, "cost 2/4")
end)

t.test("renormalize zeroes out non-positive weights", function()
    local w = r.renormalize_weights({ quality = 1, speed = -3, cost = 0 })
    t.near(w.quality, 1.0, 1e-9, "only quality survives")
    t.eq(w.speed, 0,                "negative -> 0")
    t.eq(w.cost,  0,                "zero stays 0")
end)

t.test("renormalize with no positive weights returns input unchanged", function()
    local input = { quality = 0, speed = 0 }
    local w = r.renormalize_weights(input)
    t.eq(w.quality, 0)
    t.eq(w.speed,   0)
end)

t.test("renormalize nil yields fallback quality=1", function()
    local w = r.renormalize_weights(nil)
    t.eq(w.quality, 1.0, "fallback quality only")
end)

-- ---- score_candidate via small synthetic catalog ------------------------

local function fresh_init(metrics)
    r.reset()
    local config = {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", tier = "marketplace" },
        },
        models = {
            m1 = {
                served_by = { { provider = "p1" }, { provider = "p2" } },
                capabilities = { context = 8000 },
                static_quality_hint = 0.8,
            },
        },
        profiles = {
            qonly  = { weights = { quality = 1.0 } },
            partner_only = { weights = { partner = 1.0 } },
            even   = { weights = { quality = 1, speed = 1, cost = 1, partner = 1 } },
        },
    }
    assert(router.init(config, metrics))
end

t.test("seeded last_quality_eval drives R.quality instead of the static hint", function()
    -- seed_runtime_from_metrics dropped this field, so R.quality always fell
    -- back to the static hint and bench evals never influenced ranking.
    fresh_init({ models = { ["m1@p1"] = { last_quality_eval = 0.95 } } })
    local ranked, err = r.rank_candidates({ profile = "qonly" }, 0)
    t.falsy(err)
    t.eq(ranked[1].candidate.provider_id, "p1", "evaluated provider ranks first")
    t.near(ranked[1].score, 0.95, 1e-9, "score uses the seeded eval")
    t.near(ranked[2].score, 0.8,  1e-9, "unseeded candidate keeps the hint")
end)

t.test("quality-only weights produce score == quality_hint", function()
    fresh_init()
    local ranked, err = r.rank_candidates({ profile = "qonly" }, 0)
    t.falsy(err)
    t.eq(#ranked, 2, "two candidates")
    for _, r1 in ipairs(ranked) do
        t.near(r1.score, 0.8, 1e-9, "score equals quality_hint")
    end
end)

t.test("partner_only weights rank partner above marketplace", function()
    fresh_init()
    local ranked = r.rank_candidates({ profile = "partner_only" }, 0)
    t.eq(ranked[1].candidate.provider_id, "p1", "partner first")
    t.eq(ranked[2].candidate.provider_id, "p2", "marketplace second")
    t.near(ranked[1].score, 1.0, 1e-9)
    t.near(ranked[2].score, 0.5, 1e-9)
end)

t.test("open circuit breaker forces score to 0", function()
    fresh_init()
    r.runtime().circuit_breakers["p1"] = {
        open = true, opened_at_ms = 0, consecutive_failures = 3,
    }
    local ranked = r.rank_candidates({ profile = "qonly" }, 100)
    -- find p1 in ranked
    local p1_score
    for _, item in ipairs(ranked) do
        if item.candidate.provider_id == "p1" then p1_score = item.score end
    end
    t.eq(p1_score, 0, "p1 forced to 0 by open breaker")
end)

t.test("weights_override re-renormalizes after merging", function()
    fresh_init()
    local w = r.merged_weights({ weights = { quality = 1, speed = 0 } },
                               { weights_override = { speed = 1 } })
    t.near(w.quality + w.speed, 1.0, 1e-9, "renormalized after override")
    t.near(w.quality, 0.5, 1e-9)
    t.near(w.speed,   0.5, 1e-9)
end)
