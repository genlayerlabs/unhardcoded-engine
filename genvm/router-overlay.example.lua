-- router-overlay.example.lua — sample greybox overlay.
--
-- Install with: integrate.sh <build-out> --overlay <this-file>
--
-- The overlay shallow-merges over the catalog dispatch.lua auto-derives from
-- __llm.providers. Two validators running the same dispatch.lua but with
-- different overlays make different routing decisions — that is the
-- "greybox" property: same logic, divergent state.

return {

    -- Mark some backends as fallback so the scorer prefers partners first.
    -- (Auto-derived default is partner=everyone.)
    providers = {
        openai    = { tier = "fallback" },
        anthropic = { tier = "fallback" },
        xai       = { tier = "fallback" },
        google    = { tier = "fallback" },
        -- heurist / io_net / atoma keep tier="partner".
    },

    -- Tweak per-model quality hints so scoring can break ties intelligently.
    -- Pass capabilities to OR them in if you want to claim more support than
    -- the YAML advertised (use sparingly).
    models = {
        ["gpt-4o"]                                = { static_quality_hint = 0.92 },
        ["claude-haiku-4-5-20251001"]             = { static_quality_hint = 0.85 },
        ["meta-llama/llama-3.3-70b-instruct"]     = { static_quality_hint = 0.78 },
        ["meta-llama/Llama-3.3-70B-Instruct"]     = { static_quality_hint = 0.78 },
        ["gemini-2.5-flash"]                      = { static_quality_hint = 0.83 },
    },

    profiles = {
        default = {
            -- (sigma-pol/v2) `weights`/composite atoms removed; score on real
            -- fields. neg(normalize(price/latency)) = cheaper/faster ranks higher.
            scorer = { "add",
                { "scale", 0.55, { "neg", { "normalize", { "field", "price_in" } } } },
                { "scale", 0.25, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.20, { "normalize", { "field", "context" } } },
            },
            retry_policy = "default",
        },

        -- "validator" is what a privacy-sensitive validator might pick.
        -- It refuses anything that isn't a partner with TEE guarantees.
        validator = {
            extends = "default",
            hard_constraints = { privacy = "tee_required" },
        },
    },

    retry_policies = {
        default = {
            rate_limit     = { action = "next_candidate" },
            timeout        = { action = "retry_same", attempts = 1, then_action = "next_candidate" },
            server_error   = { action = "next_candidate" },
            auth_error     = { action = "disable_provider" },
            content_filter = { action = "abort" },
            unknown        = { action = "next_candidate" },
        },
    },
}
