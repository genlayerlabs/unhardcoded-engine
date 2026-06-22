-- config.example.lua
-- Example configuration for unhardcoded-engine. Copy to `config.lua` and edit.
-- See docs/POLICY_DESIGN.md §4 (the candidate object) for the schema.

return {

    -- ============================================================
    -- Providers
    -- ============================================================
    providers = {

        comput3 = {
            discovery = "static",
            base_url  = "https://api.comput3.ai/v1",
            api_kind  = "openai_compatible",
            auth_env  = "COMPUT3_API_KEY",
            tier      = "partner",
            notes     = "GenLayer partner — Hermes, DeepSeek, Qwen on H200",
        },

        io_net = {
            discovery = "static",
            base_url  = "https://api.intelligence.io.solutions/api/v1",
            api_kind  = "openai_compatible",
            auth_env  = "IONET_API_KEY",
            tier      = "partner",
        },

        heurist = {
            discovery = "static",
            base_url  = "https://llm-gateway.heurist.xyz",
            api_kind  = "openai_compatible",
            auth_env  = "HEURIST_API_KEY",
            tier      = "partner",
            notes     = "Free credits via referral code 'genlayer'",
        },

        morpheus = {
            discovery = "static",
            base_url  = "https://api.mor.org/api/v1",
            api_kind  = "openai_compatible",
            auth_env  = "MORPHEUS_API_KEY",
            tier      = "partner",
        },

        chutes = {
            discovery = "static",
            base_url  = "https://llm.chutes.ai/v1",
            api_kind  = "openai_compatible",
            auth_env  = "CHUTES_API_KEY",
            tier      = "partner",
        },

        atoma = {
            discovery = "static",
            base_url  = "https://api.atoma.network/v1",
            api_kind  = "openai_compatible",
            auth_env  = "ATOMA_API_KEY",
            tier      = "partner",
            has_tee   = true,
            no_log    = true,
        },

        antseed = {
            discovery    = "marketplace",
            discovery_id = "antseed_buyer_node",
            api_kind     = "openai_compatible",
            auth_env     = "ANTSEED_API_KEY",  -- may be unset for permissionless mode
            tier         = "marketplace",
            notes        = "Dynamic pricing via buyer node (antseed.com)",
        },

        -- non-partner fallbacks; commented out by default
        -- openrouter = {
        --     discovery = "static",
        --     base_url  = "https://openrouter.ai/api/v1",
        --     api_kind  = "openai_compatible",
        --     auth_env  = "OPENROUTER_API_KEY",
        --     tier      = "fallback",
        -- },
        -- groq = {
        --     discovery = "static",
        --     base_url  = "https://api.groq.com/openai/v1",
        --     api_kind  = "openai_compatible",
        --     auth_env  = "GROQ_API_KEY",
        --     tier      = "fallback",
        --     notes     = "Fast, low rate limits",
        -- },
    },

    -- ============================================================
    -- Models
    -- ============================================================
    models = {

        ["hermes-3-405b"] = {
            family = "hermes-3-405b",
            served_by = {
                { provider = "comput3", provider_model_id = "Hermes-3-Llama-3.1-405B" },
            },
            capabilities = {
                context           = 128000,
                supports_tools    = true,
                supports_json_mode = true,
                supports_seed     = true,
            },
            static_quality_hint = 0.78,
        },

        ["deepseek-v3"] = {
            family = "deepseek-v3",
            served_by = {
                { provider = "comput3",  provider_model_id = "deepseek-chat" },
                { provider = "morpheus", provider_model_id = "deepseek-chat" },
                { provider = "chutes",   provider_model_id = "deepseek-ai/DeepSeek-V3" },
                { provider = "atoma",    provider_model_id = "deepseek-chat" },
            },
            capabilities = {
                context            = 64000,
                supports_tools     = true,
                supports_json_mode = true,
                supports_seed      = true,
            },
            static_quality_hint = 0.82,
        },

        ["qwen-3-235b"] = {
            family = "qwen-3-235b",
            served_by = {
                { provider = "comput3" },
                { provider = "io_net" },
            },
            capabilities = {
                context        = 128000,
                supports_tools = true,
            },
            static_quality_hint = 0.76,
        },

        ["qwen-2.5-vl-72b"] = {
            family = "qwen-2.5-vl-72b",
            served_by = {
                { provider = "io_net" },
            },
            capabilities = {
                context          = 32000,
                supports_vision  = true,
            },
            static_quality_hint = 0.70,
        },

        ["llama-3.3-70b"] = {
            family = "llama-3.3-70b",
            served_by = {
                { provider = "io_net" },
                { provider = "morpheus" },
            },
            capabilities = {
                context            = 128000,
                supports_tools     = true,
                supports_json_mode = true,
                supports_seed      = true,
            },
            static_quality_hint = 0.72,
        },
    },

    -- ============================================================
    -- Profiles
    -- ============================================================
    -- These are TEMPLATES. Edit the scorer and constraints to taste; the library
    -- ships no built-in defaults. Two operators starting from the same template
    -- are encouraged to diverge — diversity is a feature (see docs/GENVM-LLM-POLICY.md).
    --
    -- (sigma-pol/v2) The composite scorer atoms (quality/speed/cost/partner/
    -- free_credit) were removed: a profile now carries an explicit `scorer` —
    -- a raw Σ_pol Scorer term over the RAW fields (field/normalize/neg/scale/
    -- add). `neg(normalize(field("price_in")))` means "cheaper scores higher".
    -- Tier preference is a filter concern now (min_tier), not a scorer atom.
    profiles = {

        default = {
            scorer = { "add",
                { "scale", 0.40, { "field", "context" } },
                { "scale", 0.25, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.35, { "neg", { "normalize", { "field", "price_in" } } } },
            },
            retry_policy = "balanced",
        },

        cheap_explore = {
            extends = "default",
            scorer = { "add",
                { "scale", 0.15, { "field", "context" } },
                { "scale", 0.15, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.55, { "neg", { "normalize", { "field", "price_in" } } } },
                { "scale", 0.15, { "normalize", { "field", "credits" } } },
            },
        },

        tee_only = {
            extends = "default",
            hard_constraints = { privacy = "tee_required" },
            scorer = { "add",
                { "scale", 0.50, { "field", "context" } },
                { "scale", 0.20, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.30, { "neg", { "normalize", { "field", "price_in" } } } },
            },
        },

        agent_tool_use = {
            extends = "default",
            -- Note: `needs` here is a hard constraint that the profile adds on top of
            -- what the contract declares. Future work: per-profile capability filters
            -- (the current schema folds these into the contract instead).
            scorer = { "add",
                { "scale", 0.50, { "field", "context" } },
                { "scale", 0.20, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.30, { "neg", { "normalize", { "field", "price_in" } } } },
            },
        },
    },

    -- ============================================================
    -- Retry policies (named tables, referenced from profiles)
    -- ============================================================
    retry_policies = {
        balanced = {
            -- success needs no entry: the engine returns on response.ok; only
            -- error kinds are classified, over the closed sequence.ACTIONS set.
            rate_limit          = { action = "next_candidate", open_breaker_ms = 30000 },
            timeout             = { action = "next_candidate" },
            server_error        = { action = "retry_same", attempts = 1, backoff_ms = 500, then_action = "next_candidate" },
            auth_error          = { action = "disable_provider" },
            bad_request         = { action = "abort" },
            content_filter      = { action = "next_candidate" },
            model_unavailable   = { action = "next_provider_same_model", mark_unavailable_ms = 300000 },
            context_overflow    = { action = "abort" },
            network_error       = { action = "retry_same", attempts = 2, backoff_ms = { 200, 600 }, then_action = "next_candidate" },
            payment_required    = { action = "next_candidate", open_breaker_ms = 300000 },
            unknown             = { action = "next_candidate" },
        },
    },

    -- ============================================================
    -- Σ_pol IR knobs (optional; see docs/SIGMA-POL.md)
    -- ============================================================

    -- Observation-vocabulary extensions: extra candidate fields that IR
    -- policies may observe via cmp/is/field. Sort Num|Bool; the default is
    -- mandatory (determinism when the field is absent). Reads cand[name]
    -- unless a getter is provided.
    -- fields = {
    --     region_score = { sort = "Num", default = 0 },
    -- },

    -- Host envelope: a Pred term ∧-ed onto every per-call `policy_ir`, so
    -- callers can narrow these invariants but never widen them.
    -- policy_envelope = { "and", { "min_tier", "marketplace" },
    --                            { "cmp", "price_out", "le", 50 } },

    -- Host-blessed named Xforms, referenced from terms as { "custom", "name" }.
    -- customs = { my_xform = function(req, cand, ctx) ... return req end },

    -- A profile may also pin a full IR policy directly:
    -- profiles.pinned = { policy_ir = { "policy", ... } }

    -- ============================================================
    -- Defaults overrides (optional)
    -- ============================================================
    defaults = {
        -- circuit_breaker_threshold     = 3,
        -- circuit_breaker_rate_limit_ms = 30000,
        -- circuit_breaker_failure_ms    = 300000,
        -- discovery_cache_ttl_ms        = 60000,
        -- ema_alpha                     = 0.2,
        -- free_credit_threshold_usd     = 1.0,
    },
}
