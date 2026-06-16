-- Declarative policy: a config profile expresses a full sentence — custom
-- `filter` and `mutate` as data, not just weights. build_policy_for compiles
-- the specs into the verb combinators.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config()
    return {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", auth_env = "K1", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", auth_env = "K2", tier = "fallback" },
        },
        models = {
            m1 = { served_by = { { provider = "p1" }, { provider = "p2" } },
                   capabilities = { context = 8000 }, static_quality_hint = 0.7 },
        },
        profiles = {
            -- a full sentence in config: filter (named combinators) + mutate
            hardened = {
                
                filter  = { "requirements", { tier_in = { "partner" } } },   -- bare list = all_of
                mutate  = { { filter_text = { "NFKC", "RmZeroWidth" } },
                            { jitter = { temperature = 0.5 } } },            -- bare list = pipe
                retry_policy = "balanced",
            },
        },
        retry_policies = { balanced = { unknown = { action = "next_candidate" } } },
    }
end

local captured
local function install_host()
    captured = nil
    local _t = 0
    host = {
        log = function() end, env = function() return nil end, sleep_ms = function() end,
        now_ms = function() _t = _t + 10; return _t end,
        call_provider = function(req) captured = req; return { ok = true, response = { text = "ok" } } end,
    }
end

local function fresh()
    r.reset(); install_host(); assert(router.init(config()))
end

t.test("declarative filter (tier_in) keeps only the partner candidate", function()
    fresh()
    local ranked = router.rank({ profile = "hardened" })
    t.eq(#ranked, 1, "tier_in{partner} drops the fallback")
    t.eq(ranked[1].candidate.provider_id, "p1")
end)

t.test("declarative mutate applies filter_text directive + seeded jitter", function()
    fresh()
    router.execute({ profile = "hardened", prompt = "hi", temperature = 0.7, seed = 42 })
    t.truthy(captured ~= nil, "provider was called")
    t.truthy(captured._filters and captured._filters.text ~= nil, "filter_text directive attached for the host")
    t.truthy(type(captured.temperature) == "number" and math.abs(captured.temperature - 0.7) > 1e-9,
             "temperature jittered away from 0.7 (seed set)")
end)

t.test("M.dsl exposes the verbs for programmatic composition", function()
    t.truthy(router.dsl and router.dsl.filter and router.dsl.rank
             and router.dsl.mutate and router.dsl.sequence and router.dsl.policy,
             "filter/rank/mutate/sequence/policy all exposed")
end)

t.test("unknown filter atom errors clearly", function()
    fresh()
    local ok = pcall(function()
        r.reset(); install_host()
        local cfg = config()
        cfg.profiles.bad = { filter = { "nope" }, retry_policy = "balanced" }
        assert(router.init(cfg))
        router.rank({ profile = "bad" })
    end)
    t.falsy(ok, "building a policy with an unknown filter atom raises")
end)
