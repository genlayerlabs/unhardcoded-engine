-- Smoke test for filtering + ranking. Run from repo root:
--   lua tests/smoke_rank.lua
-- (Use a Lua 5.3+ interpreter; via nix-shell -p lua5_3 if needed.)

local router  = dofile("router.lua")
local config  = dofile("config.example.lua")
local metrics = dofile("metrics.example.lua")

host = {
    log     = function(lvl, ev, fields) end,
    now_ms  = function() return 1000000 end,
    discover = function(id)
        -- simulate one offer to exercise marketplace path
        if id == "antseed_buyer_node" then
            return {
                ok = true,
                fetched_at_ms = 1000000,
                offers = {
                    {
                        model_family    = "llama-3.3-70b",
                        seller_endpoint = "https://seller-foo.antseed.test/v1",
                        price_in_usd_per_mtok  = 0.10,
                        price_out_usd_per_mtok = 0.30,
                        est_tok_s = 40,
                        capabilities = { supports_tools = true, context = 128000 },
                    },
                },
            }
        end
        return { ok = false, error = "unknown discovery_id" }
    end,
}

assert(router.init(config, metrics))

local function show(label, contract)
    print("=== " .. label .. " ===")
    local ranked, err, rejected = router.rank(contract)
    if err then
        print("  error:", err)
        return
    end
    print(string.format("  survivors: %d   rejected: %d", #ranked, #rejected))
    for i, r in ipairs(ranked) do
        local b = r.score_breakdown
        print(string.format(
            "  #%d  %-10s %-20s  score=%.3f  (Q=%.2f S=%.2f C=%.2f F=%.0f P=%.1f)%s",
            i, r.candidate.provider_id, r.candidate.model_family,
            r.score, b.quality or 0, b.speed or 0, b.cost or 0,
            b.free_credit or 0, b.partner or 0,
            (b.gated or b.breaker_open) and "  [BREAKER OPEN]" or ""
        ))
    end
    if #ranked == 0 and #rejected > 0 then
        print("  reasons rejected (first 5):")
        for i = 1, math.min(5, #rejected) do
            local rj = rejected[i]
            print(string.format("    %s/%s  %s", rj.provider, rj.model, rj.reason))
        end
    end
    print()
end

-- 1. Default profile, no special needs
show("default profile, plain text", {
    prompt = "hello",
    profile = "default",
})

-- 2. Cheap explore: cost-heavy, free credits boost should push Comput3 to top
show("cheap_explore profile", {
    prompt = "explore",
    profile = "cheap_explore",
})

-- 3. Tools required, json mode required
show("tools + json_mode required", {
    prompt = "plan",
    tools = { { type = "function", ["function"] = { name = "x" } } },
    response_format = { type = "json_object" },
    profile = "default",
})

-- 4. Privacy: TEE required (only Atoma has TEE in example)
show("tee_only profile, privacy=tee_required", {
    prompt = "secret",
    requirements = { privacy = "tee_required" },
    profile = "tee_only",
})

-- 5. Vision required (only qwen-2.5-vl-72b in example)
show("vision required", {
    prompt = "describe",
    images = { { url = "..." } },
    profile = "default",
})

-- 6. Model family pin: cheapest deepseek-v3
show("model_family=deepseek-v3, cost-only override", {
    prompt = "x",
    requirements = { model_family = "deepseek-v3" },
    profile = "default",
    weights_override = { cost = 1.0, quality = 0, speed = 0, free_credit = 0, partner = 0 },
})

-- 7. Hard pin bypasses routing entirely
show("pin to comput3/hermes-3-405b", {
    prompt = "x",
    requirements = { pin = { provider = "comput3", model = "hermes-3-405b" } },
    profile = "default",
})

-- 8. Pin to non-existent pair
show("pin to bogus/bogus (should fail)", {
    prompt = "x",
    requirements = { pin = { provider = "bogus", model = "bogus" } },
    profile = "default",
})

-- 9. Marketplace (AntSeed offer should appear)
show("default with AntSeed offer in pool", {
    prompt = "x",
    profile = "default",
})

-- 10. Tier filter
show("tier=marketplace only", {
    prompt = "x",
    requirements = { tier = "marketplace" },
    profile = "default",
})

-- 11. min_tok_s should knock out candidates without observed throughput
show("min_tok_s = 39 (knocks out anything <39 tok/s observed)", {
    prompt = "x",
    requirements = { min_tok_s = 39 },
    profile = "default",
})

-- 12. Open circuit breaker → score 0
router._test.runtime().circuit_breakers["comput3"] = {
    open = true,
    opened_at_ms = host.now_ms() - 1000,  -- just opened
    consecutive_failures = 3,
}
show("breaker open on comput3", {
    prompt = "x",
    profile = "default",
})
router._test.runtime().circuit_breakers["comput3"] = nil
