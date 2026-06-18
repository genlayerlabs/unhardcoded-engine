-- Reliability as a host-supplied observation (sigma-pol: the algebra is
-- expressive over things the host observes). The host measures per-route
-- reliability however it likes and stamps it on the offer — exactly as it
-- stamps price — and the algebra selects on it POINTWISE, with no notion of
-- "route"/"peer" and no engine-side metrics fold. The candidate value wins over
-- the engine's legacy EMA, which remains only as a fallback for providers the
-- host did not stamp (e.g. static ones).

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config()
    return {
        providers = {
            mkt = { discovery = "marketplace", discovery_id = "mkt",
                    api_kind = "openai_compatible", auth = { kind = "none" },
                    tier = "marketplace", base_url = "http://mkt" },
            -- a static fallback so the curated family validates (served_by must
            -- be non-empty); its reliability comes from the engine EMA fallback.
            slow = { discovery = "static", base_url = "http://slow",
                     api_kind = "openai_compatible", auth_env = "SLOW_KEY",
                     tier = "fallback" },
        },
        models = {
            m1 = { served_by = { { provider = "slow" } },
                   capabilities = { context = 8000 } },
        },
        profiles = {
            -- pick the most reliable candidate, by the host-stamped field
            default = { retry_policy = "balanced",
                        scorer = { "field", "success_rate" },
                        selector = "argmax" },
        },
        retry_policies = {
            balanced = {
                timeout      = { action = "next_candidate" },
                bad_response = { action = "next_candidate" },
                unknown      = { action = "next_candidate" },
            },
        },
    }
end

-- two routes of the same family at the same price; the host has stamped each
-- offer with the reliability IT measured for that route.
local OFFERS = {
    { model_family = "m1", price_in_usd_per_mtok = 1.0, price_out_usd_per_mtok = 2.0,
      capabilities = { context = 8000 }, seller_endpoint = "http://mkt",
      peer_id = "routeBad",  success_rate = 0.10 },
    { model_family = "m1", price_in_usd_per_mtok = 1.0, price_out_usd_per_mtok = 2.0,
      capabilities = { context = 8000 }, seller_endpoint = "http://mkt",
      peer_id = "routeGood", success_rate = 0.99 },
}

local _time = 0
local CALLED = {}
local function mock_host()
    _time  = 0
    CALLED = {}
    host = {
        log      = function() end,
        env      = function() return nil end,
        sleep_ms = function() end,
        now_ms   = function() _time = _time + 50; return _time end,
        discover = function() return { ok = true, offers = OFFERS, fetched_at_ms = 0 } end,
        call_provider = function(req)
            -- record which route the engine pinned (req.offer is forwarded verbatim)
            CALLED[#CALLED + 1] = (req.offer and req.offer.peer_id) or "static"
            return { ok = true, response = { text = "served" } }
        end,
    }
end

t.test("selection runs on host-stamped reliability, pointwise, candidate over engine", function()
    r.reset()
    assert(router.init(config()))
    mock_host()
    -- static fallback's reliability comes from the engine EMA (the retained
    -- fallback path) — seed it mid so it cannot win the scorer.
    r.runtime().ema_metrics[r.pm_key("slow", "m1")] = { success_rate_ewma = 0.5, n = 0 }
    -- a MISLEADING engine slot for the marketplace family: the candidate-stamped
    -- value must override it (the host owns marketplace reliability).
    r.runtime().ema_metrics[r.pm_key("mkt", "m1")]  = { success_rate_ewma = 0.0, n = 0 }

    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok, "request served")
    t.eq(res.chosen.provider_id, "mkt",
         "marketplace beat the static fallback on stamped reliability (0.99 > 0.5)")
    t.eq(CALLED[1], "routeGood",
         "pinned the route the host stamped most reliable (0.99 > 0.10), not the engine's 0.0")
end)

t.test("an unstamped candidate falls back to the engine EMA (static providers keep working)", function()
    r.reset()
    assert(router.init(config()))
    mock_host()
    -- no marketplace offers this time: force the static fallback to be chosen and
    -- show its reliability is read from the engine EMA (the fallback path).
    host.discover = function() return { ok = true, offers = {}, fetched_at_ms = 0 } end
    r.runtime().ema_metrics[r.pm_key("slow", "m1")] = { success_rate_ewma = 0.7, n = 0 }

    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok, "request served by the static fallback")
    t.eq(res.chosen.provider_id, "slow", "static provider served")
end)
