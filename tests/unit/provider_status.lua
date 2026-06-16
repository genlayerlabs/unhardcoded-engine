-- M.provider_status: read-only live provider-health snapshot for the dashboard.
--
-- Covers: a healthy provider (available, breaker closed); a provider whose
-- breaker is opened by repeated failures (open + ms_until_recovery>0 +
-- available=false), then reads as recovered after the rate-limit window WITHOUT
-- a separate mutation; a disabled provider (disabled.kind + ms_until_recovery +
-- available=false) that reads as recovered after its TTL; and a guarantee that
-- calling provider_status never mutates RUNTIME.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function base_config()
    return {
        providers = {
            p1 = {
                discovery = "static", base_url = "http://p1",
                api_kind = "openai_compatible", auth_env = "P1_KEY",
                tier = "partner",
            },
            p2 = {
                discovery = "static", base_url = "http://p2",
                api_kind = "openai_compatible", auth_env = "P2_KEY",
                tier = "partner",
            },
        },
        models = {
            m1 = {
                served_by = { { provider = "p1" }, { provider = "p2" } },
                capabilities = { context = 8000 },
                static_quality_hint = 0.7,
            },
        },
        profiles = {
            default = { retry_policy = "balanced" },
        },
        retry_policies = {
            balanced = {
                rate_limit = { action = "next_candidate", open_breaker_ms = 30000 },
                unknown    = { action = "next_candidate" },
            },
        },
    }
end

local function reset()
    -- a minimal host so clock()/log don't crash
    host = {
        log = function() end, env = function() return nil end,
        sleep_ms = function() end, now_ms = function() return 0 end,
    }
    r.reset()
    assert(router.init(base_config()))
end

-- Drive the documented breaker path: update_breaker_on_failure isn't directly
-- exposed, so open the breaker through RUNTIME exactly as the loop would
-- (consecutive_failures past threshold). We open it at a known opened_at_ms so
-- recovery math is deterministic.
local function open_breaker(pid, opened_at_ms, failures)
    r.runtime().circuit_breakers[pid] = {
        open = true,
        opened_at_ms = opened_at_ms,
        consecutive_failures = failures or 3,
    }
end

-- ---- tests ----------------------------------------------------------------

t.test("provider_status schema and full roster from catalog", function()
    reset()
    local ps = router.provider_status(1000)
    t.eq(ps.schema, "router_provider_status", "schema tag")
    t.eq(ps.generated_at_ms, 1000, "generated_at_ms echoes now_ms")
    t.truthy(ps.providers.p1, "p1 present from catalog roster")
    t.truthy(ps.providers.p2, "p2 present from catalog roster")
end)

t.test("healthy provider is available with a closed breaker", function()
    reset()
    local ps = router.provider_status(1000)
    local p1 = ps.providers.p1
    t.truthy(p1.available, "healthy provider available")
    t.falsy(p1.breaker.open, "breaker closed")
    t.eq(p1.breaker.ms_until_recovery, 0, "no recovery wait when closed")
    t.truthy(p1.disabled == nil, "not disabled")
end)

t.test("open breaker reports open + ms_until_recovery>0 and unavailable", function()
    reset()
    -- breaker opened at t=1000, default window 30s; observe at t=1000+1000.
    open_breaker("p1", 1000, 4)
    local ps = router.provider_status(2000)
    local p1 = ps.providers.p1
    t.truthy(p1.breaker.open, "breaker reported open")
    t.eq(p1.breaker.consecutive_failures, 4, "failure count surfaced")
    t.eq(p1.breaker.opened_at_ms, 1000, "opened_at_ms surfaced")
    -- window = 30000; 1000 + 30000 - 2000 = 29000
    t.eq(p1.breaker.ms_until_recovery, 29000, "ms_until_recovery computed")
    t.falsy(p1.available, "open breaker → unavailable")
end)

t.test("breaker reads recovered past the window WITHOUT mutating RUNTIME", function()
    reset()
    open_breaker("p1", 1000, 4)
    -- advance now_ms past the 30s rate-limit window
    local ps = router.provider_status(1000 + 30000)
    local p1 = ps.providers.p1
    t.falsy(p1.breaker.open, "breaker reads recovered after the window")
    t.eq(p1.breaker.ms_until_recovery, 0, "no recovery wait once past window")
    t.truthy(p1.available, "recovered breaker → available")
    -- RUNTIME must still show the raw open breaker (we never reset it)
    t.truthy(r.runtime().circuit_breakers.p1.open,
             "RUNTIME breaker untouched (still open)")
end)

t.test("provider_status does not mutate RUNTIME (open-breaker case)", function()
    reset()
    open_breaker("p1", 1000, 4)
    -- also stage a disabled provider to exercise the disabled branch
    r.runtime().disabled_providers.p2 = { kind = "auth_error", at_ms = 1000 }
    local before = router.dump_state()
    -- call across both within-window and past-window views
    router.provider_status(2000)
    router.provider_status(1000 + 30000 + 99999)
    local after = router.dump_state()

    -- deep-equality on the parts provider_status could plausibly touch
    local function eq_breaker(b1, b2)
        return b1.open == b2.open
            and b1.opened_at_ms == b2.opened_at_ms
            and b1.consecutive_failures == b2.consecutive_failures
    end
    t.truthy(eq_breaker(before.circuit_breakers.p1, after.circuit_breakers.p1),
             "breaker state identical before/after")
    t.truthy(after.disabled_providers.p2 ~= nil,
             "disabled entry still present (not expired by a read)")
    t.eq(after.disabled_providers.p2.kind, "auth_error", "disabled kind intact")
    t.eq(after.disabled_providers.p2.at_ms, 1000, "disabled at_ms intact")
end)

t.test("disabled provider reports kind + ms_until_recovery and is unavailable", function()
    reset()
    r.runtime().disabled_providers.p1 = { kind = "auth_error", at_ms = 1000 }
    -- default disable TTL is 5min = 300000ms; observe 1s in.
    local ps = router.provider_status(2000)
    local p1 = ps.providers.p1
    t.truthy(p1.disabled, "disabled block present")
    t.eq(p1.disabled.kind, "auth_error", "disabled kind surfaced")
    t.eq(p1.disabled.at_ms, 1000, "disabled at_ms surfaced")
    -- 1000 + 300000 - 2000 = 299000
    t.eq(p1.disabled.ms_until_recovery, 299000, "disabled recovery computed")
    t.falsy(p1.available, "disabled → unavailable")
end)

t.test("disabled provider reads recovered after the TTL", function()
    reset()
    r.runtime().disabled_providers.p1 = { kind = "auth_error", at_ms = 1000 }
    -- advance past the 300000ms TTL
    local ps = router.provider_status(1000 + 300000 + 1)
    local p1 = ps.providers.p1
    t.truthy(p1.disabled == nil, "disabled cleared in the read after TTL")
    t.truthy(p1.available, "recovered disable → available")
end)

t.test("legacy string-shaped disabled entry does not crash (at_ms treated as 0)", function()
    reset()
    r.runtime().disabled_providers.p1 = "preexisting"  -- legacy string
    -- at_ms=0, TTL=300000 → at now_ms=1000 it's still within TTL
    local ps = router.provider_status(1000)
    local p1 = ps.providers.p1
    t.truthy(p1.disabled, "legacy string surfaced as disabled block")
    t.eq(p1.disabled.kind, "preexisting", "string used as kind")
    t.eq(p1.disabled.at_ms, 0, "unknown at_ms treated as 0")
    -- and past the TTL it reads recovered
    local ps2 = router.provider_status(300001)
    t.truthy(ps2.providers.p1.disabled == nil, "legacy disable expires after TTL")
end)

t.test("per-model EMA metrics and credits are surfaced", function()
    reset()
    -- seed a live EMA slot and a credits slot the way the engine/seeding does
    r.runtime().ema_metrics[r.pm_key("p1", "m1")] = {
        success_rate_ewma = 0.9,
        ema_latency_ms    = 123,
        n                 = 5,
        price_in          = 0.05,
        price_out         = 0.10,
        last_quality_eval = 0.8,
    }
    r.runtime().ema_metrics["__credits|p1"] = { free_credits_remaining_usd = 4.2 }

    local ps = router.provider_status(1000)
    local p1 = ps.providers.p1
    t.eq(p1.credits_remaining_usd, 4.2, "credits read from __credits slot")
    local mm = p1.models.m1
    t.truthy(mm, "per-model block present")
    t.eq(mm.success_rate, 0.9, "success_rate surfaced")
    t.eq(mm.avg_latency_ms, 123, "avg_latency_ms surfaced")
    t.eq(mm.observations, 5, "observations surfaced")
    t.eq(mm.price_in, 0.05, "price_in surfaced")
    t.eq(mm.price_out, 0.10, "price_out surfaced")
    t.eq(mm.last_quality_eval, 0.8, "last_quality_eval surfaced")
    -- __credits slot must NOT leak into models
    t.truthy(p1.models["p1"] == nil, "credits slot not treated as a model")
end)
