-- router-overlay.cascade-demo.lua — forces heurist > openrouter so the
-- cascade is observable: heurist times out (unreachable from this network),
-- router falls through to the openrouter-backed `dev` backend.

return {
    providers = {
        heurist = { tier = "partner" },
        dev     = { tier = "fallback" },
    },
    models = {
        ["meta-llama/llama-3.3-70b-instruct"] = { static_quality_hint = 0.85 },
        ["openrouter/auto"]                   = { static_quality_hint = 0.70 },
    },
    profiles = {
        default = {
            -- (sigma-pol/v2) `weights`/composite atoms removed. Tier is no longer
            -- a scoring dimension (the `partner` atom is gone), and a tier FILTER
            -- here would exclude the `dev` fallback the cascade exists to reach —
            -- so neither replaces the old partner-crank. The cascade order comes
            -- from this scorer (cheapest first; with no prices declared, ties
            -- keep catalog order — heurist before dev) plus the retry policy's
            -- `next_candidate` fall-through. For strict explicit tier priority,
            -- use the `chain` selector (see the greybox profile in dispatch.lua).
            scorer = { "neg", { "normalize", { "field", "price_in" } } },
            retry_policy = "default",
        },
    },
    retry_policies = {
        default = {
            rate_limit     = { action = "next_candidate" },
            timeout        = { action = "next_candidate" },
            server_error   = { action = "next_candidate" },
            auth_error     = { action = "disable_provider" },
            content_filter = { action = "abort" },
            unknown        = { action = "next_candidate" },
        },
    },
}
