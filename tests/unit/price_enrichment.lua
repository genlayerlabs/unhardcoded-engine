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

t.test("served_model_id is the offer's wire id, falling back to the family", function()
    r.reset()
    host = {
        log = function() end, env = function() return nil end,
        now_ms = function() return 0 end, sleep_ms = function() end,
        discover = function(id)
            return { ok = true, fetched_at_ms = 0, offers = {
                -- provider-neutral family + a distinct raw wire slug
                { model_family = "m1", wire_model_id = "vendor/m1",
                  seller_endpoint = "http://with-wire",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 0.1, price_out_usd_per_mtok = 0.1 },
                -- no wire_model_id: the family IS the wire id (back-compat)
                { model_family = "m1", seller_endpoint = "http://no-wire",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 0.2, price_out_usd_per_mtok = 0.2 },
            } }
        end,
    }
    assert(router.init(config_with_price_ceiling(), METRICS))
    local ranked = router.rank({ prompt = "x", profile = "default" })
    local served = {}
    for _, row in ipairs(ranked) do
        if row.candidate.provider_id == "market_p" then
            served[row.candidate.base_url] = row.candidate.served_model_id
        end
    end
    -- the policy-facing family stays neutral, the wire id is the slug
    t.eq(served["http://with-wire"], "vendor/m1",
        "served_model_id is the offer's wire_model_id when present")
    t.eq(served["http://no-wire"], "m1",
        "served_model_id falls back to the family when no wire id (back-compat)")
end)

t.test("marketplace offer prices win over provider-family metrics when scoring", function()
    r.reset()
    host = {
        log = function() end, env = function() return nil end,
        now_ms = function() return 0 end, sleep_ms = function() end,
        discover = function(id)
            return { ok = true, fetched_at_ms = 0, offers = {
                { model_family = "m1", seller_endpoint = "http://expensive-offer",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 9.0, price_out_usd_per_mtok = 9.0 },
                { model_family = "m1", seller_endpoint = "http://cheap-offer",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 0.1, price_out_usd_per_mtok = 0.1 },
            } }
        end,
    }
    assert(router.init(config_with_price_ceiling(), METRICS))
    router.update_metrics("market_p", "m1", { price_in = 42.0, price_out = 42.0 })

    local ranked = router.rank({
        policy_ir = { "policy",
            { "provider_eq", "market_p" },
            { "neg", { "normalize", { "field", "price_in" } } },
            { "argmax" },
            { "id" },
            { "always", { action = "next_candidate" } },
        },
    })

    t.eq(#ranked, 2, "both marketplace offers survive")
    t.eq(ranked[1].candidate.base_url, "http://cheap-offer",
        "cheapest offer ranks first even when provider-family metrics disagree")
    t.eq(ranked[1].candidate.price_in, 0.1, "candidate keeps its offer price")
    t.truthy(ranked[1].score > ranked[2].score, "offer prices produce different scores")
end)

t.test("static prices apply host multiplier at rank time and keep raw price", function()
    r.reset()
    local mult = 0.5
    host = {
        log = function() end, env = function() return nil end,
        now_ms = function() return 0 end, sleep_ms = function() end,
        price_multiplier = function(provider_id, _source_name)
            if provider_id == "cheap_p" then return mult end
            return 1.0
        end,
    }
    assert(router.init(config_with_price_ceiling(), METRICS))

    local term = { "policy",
        { "provider_eq", "cheap_p" },
        { "neg", { "normalize", { "field", "price_in" } } },
        { "argmax" },
        { "id" },
        { "always", { action = "next_candidate" } },
    }
    local ranked = router.rank({ policy_ir = term })
    local c = ranked[1].candidate
    t.eq(c.raw_price_in, 0.5, "raw input price stays from metrics")
    t.eq(c.raw_price_out, 2.0, "raw output price stays from metrics")
    t.eq(c.price_in, 0.25, "ranking input price uses multiplier")
    t.eq(c.price_out, 1.0, "ranking output price uses multiplier")
    t.eq(c.price_multiplier, 0.5, "candidate carries multiplier used")

    mult = 2.0
    ranked = router.rank({ policy_ir = term })
    c = ranked[1].candidate
    t.eq(c.raw_price_in, 0.5, "raw price is unchanged after multiplier changes")
    t.eq(c.price_in, 1.0, "new multiplier applies without updating metrics")
    t.eq(c.price_multiplier, 2.0, "candidate carries new multiplier")
end)

t.test("marketplace prices apply source multiplier at rank time and keep raw offer", function()
    r.reset()
    local cfg = config_with_price_ceiling()
    cfg.providers.market_p.source = "market_source"
    host = {
        log = function() end, env = function() return nil end,
        now_ms = function() return 0 end, sleep_ms = function() end,
        price_multiplier = function(provider_id, source_name)
            if provider_id == "market_p" and source_name == "market_source" then
                return 0.25
            end
            return 1.0
        end,
        discover = function(id)
            return { ok = true, fetched_at_ms = 0, offers = {
                { model_family = "m1", seller_endpoint = "http://mkt",
                  quality_hint = 0.7,
                  price_in_usd_per_mtok = 0.8, price_out_usd_per_mtok = 4.0 },
            } }
        end,
    }
    assert(router.init(cfg, METRICS))
    local ranked = router.rank({
        policy_ir = { "policy",
            { "provider_eq", "market_p" },
            { "neg", { "normalize", { "field", "price_in" } } },
            { "argmax" },
            { "id" },
            { "always", { action = "next_candidate" } },
        },
    })
    local c = ranked[1].candidate
    t.eq(c.raw_price_in, 0.8, "raw marketplace input price stays on candidate")
    t.eq(c.raw_price_out, 4.0, "raw marketplace output price stays on candidate")
    t.eq(c.price_in, 0.2, "ranking price uses source multiplier")
    t.eq(c.price_out, 1.0, "ranking output price uses source multiplier")
    t.eq(c.offer.price_in_usd_per_mtok, 0.8, "cached offer stays raw")
end)
