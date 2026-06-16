-- Hard-requirement filtering, exercised end-to-end through the public
-- router.rank (engine builds a Policy whose filter is F.requirements +
-- F.not_disabled, and snapshots RUNTIME into ctx.state).

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function make_config()
    return {
        providers = {
            partner_a = { discovery = "static", base_url = "http://a", api_kind = "openai_compatible", tier = "partner" },
            tee_one   = { discovery = "static", base_url = "http://b", api_kind = "openai_compatible", tier = "partner", has_tee = true, no_log = true },
            mkt_one   = { discovery = "static", base_url = "http://m", api_kind = "openai_compatible", tier = "marketplace" },
        },
        models = {
            chat = {
                served_by = {
                    { provider = "partner_a" },
                    { provider = "tee_one" },
                    { provider = "mkt_one" },
                },
                capabilities = {
                    context            = 8000,
                    supports_tools     = true,
                    supports_json_mode = true,
                },
                static_quality_hint = 0.7,
            },
            vision_model = {
                served_by = { { provider = "partner_a" } },
                capabilities = { context = 4000, supports_vision = true },
                static_quality_hint = 0.65,
            },
        },
        profiles = {
            default = {},
        },
    }
end

local function fresh()
    r.reset()
    assert(router.init(make_config()))
end

-- survivors via the public dry-run rank
local function survivors(contract)
    local ranked, err, rejected = router.rank(contract)
    assert(not err, err)
    local out = {}
    for _, item in ipairs(ranked or {}) do out[#out + 1] = item.candidate end
    return out, rejected or {}
end

t.test("tee_required keeps only TEE providers", function()
    fresh()
    local s = survivors({ requirements = { privacy = "tee_required" } })
    t.eq(#s, 1, "only one survivor")
    t.eq(s[1].provider_id, "tee_one", "the TEE provider")
end)

t.test("no_log accepts only no_log/TEE providers", function()
    fresh()
    local s = survivors({ requirements = { privacy = "no_log" } })
    t.eq(#s, 1)
    t.eq(s[1].provider_id, "tee_one")
end)

t.test("vision need filters to vision-capable models", function()
    fresh()
    local s = survivors({ images = { { url = "x" } } })
    t.eq(#s, 1)
    t.eq(s[1].model_family, "vision_model")
end)

t.test("min_context filters models with too-small context", function()
    fresh()
    local s = survivors({ requirements = { min_context = 5000 } })
    t.truthy(#s >= 1)
    for _, c in ipairs(s) do t.eq(c.model_family, "chat", "only chat model") end
end)

t.test("tier filter restricts to a single tier", function()
    fresh()
    local s = survivors({ requirements = { tier = "marketplace" } })
    t.eq(#s, 1)
    t.eq(s[1].provider_id, "mkt_one")
end)

t.test("pin short-circuits to a single candidate", function()
    fresh()
    local s = survivors({ requirements = { pin = { provider = "partner_a", model = "chat" } } })
    t.eq(#s, 1)
    t.eq(s[1].provider_id, "partner_a")
    t.eq(s[1].model_family, "chat")
end)

t.test("pin to non-existent pair returns no survivors and a pin_not_found reason", function()
    fresh()
    local s, rejected = survivors({ requirements = { pin = { provider = "bogus", model = "bogus" } } })
    t.eq(#s, 0)
    t.eq(#rejected, 1)
    t.eq(rejected[1].reason, "pin_not_found")
end)

t.test("disabled provider is filtered out", function()
    fresh()
    r.runtime().disabled_providers["partner_a"] = "auth_error"
    local s = survivors({})
    for _, c in ipairs(s) do
        t.falsy(c.provider_id == "partner_a", "partner_a excluded")
    end
end)

t.test("tools need filters to tool-capable models", function()
    fresh()
    local s = survivors({ tools = { { type = "function" } } })
    t.truthy(#s >= 1)
    for _, c in ipairs(s) do t.eq(c.model_family, "chat") end
end)

t.test("json_mode via response_format filters correctly", function()
    fresh()
    local s = survivors({ response_format = { type = "json_object" } })
    t.truthy(#s >= 1)
    for _, c in ipairs(s) do t.eq(c.model_family, "chat", "only json-capable model survives") end
end)
