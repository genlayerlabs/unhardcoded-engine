-- Price ceilings must act on real prices: candidates are enriched from the
-- metrics store at plan time, and marketplace candidates carry offer prices.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config_with_price_ceiling()
    return {
        providers = {
            cheap_p  = { discovery = "static", base_url = "http://cheap",
                         api_kind = "openai_compatible", auth_env = "K1", tier = "partner" },
            pricey_p = { discovery = "static", base_url = "http://pricey",
                         api_kind = "openai_compatible", auth_env = "K2", tier = "partner" },
            market_p = { discovery = "marketplace", discovery_id = "mkt",
                         api_kind = "openai_compatible", tier = "fallback" },
        },
        models = {
            m1 = {
                served_by = { { provider = "cheap_p" }, { provider = "pricey_p" } },
                capabilities = { context = 8000 },
                static_quality_hint = 0.7,
            },
        },
        profiles = {
            default = {
                filter = { price_max = { input = 1.0, output = 5.0 } },
                
                retry_policy = "balanced",
            },
        },
        retry_policies = { balanced = { unknown = { action = "next_candidate" } } },
    }
end

local METRICS = {
    models = {
        ["m1@cheap_p"]  = { price_in_usd_per_mtok = 0.5,  price_out_usd_per_mtok = 2.0 },
        ["m1@pricey_p"] = { price_in_usd_per_mtok = 10.0, price_out_usd_per_mtok = 50.0 },
    },
}

t.test("price_max filter rejects candidates priced over the ceiling", function()
    r.reset()
    host = { log = function() end, env = function() return nil end,
             now_ms = function() return 0 end, sleep_ms = function() end }
    assert(router.init(config_with_price_ceiling(), METRICS))
    local ranked, err, rejected = router.rank({ prompt = "x", profile = "default" })
    t.falsy(err)
    local providers = {}
    for _, row in ipairs(ranked) do providers[row.candidate.provider_id] = true end
    t.truthy(providers.cheap_p, "in-ceiling candidate survives")
    t.falsy(providers.pricey_p, "over-ceiling candidate filtered out")
    local why = nil
    for _, rej in ipairs(rejected) do
        if rej.provider == "pricey_p" then why = rej.reason end
    end
    t.truthy(why, "rejection recorded for pricey_p")
end)

t.test("marketplace candidates carry offer prices into filtering", function()
    r.reset()
    host = {
        log = function() end, env = function() return nil end,
        now_ms = function() return 0 end, sleep_ms = function() end,
        discover = function(id)
            return { ok = true, fetched_at_ms = 0, offers = {
                { model_family = "m1", seller_endpoint = "http://mkt",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 99.0, price_out_usd_per_mtok = 99.0 },
                { model_family = "m1", seller_endpoint = "http://mkt2",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 0.1, price_out_usd_per_mtok = 0.1 },
            } }
        end,
    }
    assert(router.init(config_with_price_ceiling(), METRICS))
    local ranked = router.rank({ prompt = "x", profile = "default" })
    local mkt_endpoints = {}
    for _, row in ipairs(ranked) do
        if row.candidate.provider_id == "market_p" then
            mkt_endpoints[row.candidate.base_url] = row.candidate.price_in
        end
    end
    t.eq(mkt_endpoints["http://mkt2"], 0.1, "cheap offer survives with its price")
    t.falsy(mkt_endpoints["http://mkt"], "over-ceiling offer filtered out")
end)
