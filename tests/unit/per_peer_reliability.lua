-- Per-peer reliability: marketplace candidates that share provider|family but
-- come from different seller peers must learn reliability/latency PER PEER, so a
-- broken cheap peer is demoted while a good peer of the same family is not, and
-- next_candidate rotates to the other peer instead of falling off the provider.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config()
    return {
        providers = {
            mkt = {
                discovery = "marketplace", discovery_id = "mkt",
                api_kind = "openai_compatible", auth = { kind = "none" },
                tier = "marketplace", base_url = "http://mkt",
            },
            -- a static fallback so the curated family validates (served_by must
            -- be non-empty); seeded with a high price below so it ranks last and
            -- is never reached.
            slow = {
                discovery = "static", base_url = "http://slow",
                api_kind = "openai_compatible", auth_env = "SLOW_KEY",
                tier = "fallback",
            },
        },
        models = {
            m1 = { served_by = { { provider = "slow" } },
                   capabilities = { context = 8000 } },
        },
        profiles = {
            -- cheapest-first so the cheaper (broken) peer is tried before the
            -- pricier good one, exercising the rotation.
            default = { retry_policy = "balanced",
                        scorer = { "neg", { "field", "price_in" } },
                        selector = "argmax" },
        },
        retry_policies = {
            balanced = {
                timeout       = { action = "next_candidate" },
                bad_response  = { action = "next_candidate" },
                unknown       = { action = "next_candidate" },
            },
        },
    }
end

-- two peers serving the same family; peerBad is cheaper (ranked first).
local OFFERS = {
    { model_family = "m1", price_in_usd_per_mtok = 0.5, price_out_usd_per_mtok = 1.0,
      capabilities = { context = 8000 }, seller_endpoint = "http://mkt", peer_id = "peerBad" },
    { model_family = "m1", price_in_usd_per_mtok = 1.0, price_out_usd_per_mtok = 2.0,
      capabilities = { context = 8000 }, seller_endpoint = "http://mkt", peer_id = "peerGood" },
}

local _time = 0
local function mock_host()
    _time = 0
    host = {
        log      = function() end,
        env      = function() return nil end,
        sleep_ms = function() end,
        now_ms   = function() _time = _time + 50; return _time end,
        discover = function() return { ok = true, offers = OFFERS, fetched_at_ms = 0 } end,
        -- keyed by the pinned peer, not the provider: the broken seller returns
        -- empty content (bad_response); the good one serves.
        call_provider = function(req)
            local peer = req.offer and req.offer.peer_id
            if peer == "peerGood" then
                return { ok = true, response = { text = "served" } }
            end
            return { ok = false, error_kind = "bad_response", http_status = 200 }
        end,
    }
end

t.test("marketplace reliability is learned per seller peer", function()
    r.reset()
    assert(router.init(config()))
    mock_host()
    -- price the static fallback above both peers so order is peerBad < peerGood < slow
    r.runtime().ema_metrics[r.pm_key("slow", "m1")] = { price_in = 99, n = 0 }

    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok, "request served")
    t.eq(res.chosen.provider_id, "mkt", "served by the marketplace provider")

    local ema = r.runtime().ema_metrics
    local bad  = ema[r.pm_key("mkt", "m1", "peerBad")]
    local good = ema[r.pm_key("mkt", "m1", "peerGood")]
    t.truthy(bad ~= nil,  "peerBad has its own EMA slot")
    t.truthy(good ~= nil, "peerGood has its own EMA slot")
    t.eq(bad.success_rate_ewma, 0,  "broken peer demoted")
    t.eq(good.success_rate_ewma, 1, "good peer not penalised")
    -- the peer-blind key must NOT be used for marketplace outcomes
    t.truthy(ema[r.pm_key("mkt", "m1")] == nil, "no peer-blind antseed|family slot")
end)
