-- dispatch.lua — GenVM LLM script that routes through the `llm_policy` algebra.
--
-- Drop-in for genvm's `genvm-llm-default.lua` AND a replacement for
-- genlayer-node's `genvm-llm-greybox.lua`: same entry points
--   ExecPrompt(ctx, args, remaining_gen)
--   ExecPromptTemplate(ctx, args, remaining_gen)
-- and the same greybox surface (filter_text, meta.greybox priority chains,
-- select_providers_for, cascade on overload) — but the selection + fallback is
-- a `llm_policy` *sentence* (R.chain + cascade) instead of a hand-rolled loop.
-- HTTP/auth stay in Rust (`exec_prompt_in_provider`); the Lua side only decides
-- which (provider, model) to try next.
--
-- Greybox chains come from `meta.greybox = { text = N, image = M }` on each
-- model in the YAML (lower N = higher priority), exactly like
-- genvm-llm-greybox.lua. If no model declares meta.greybox, dispatch falls back
-- to a weighted `default` profile over the whole catalog (more lenient than the
-- production script, which errors).
--
-- Per-validator divergence ("greybox") is organic: each operator's catalog,
-- chains, and runtime state differ. An optional `router-overlay.lua` on the Lua
-- path shallow-merges over the auto-derived config (providers/models/profiles/
-- retry_policies) to tune further. See ../docs/GENVM-LLM-POLICY.md.

local lib_genvm = require("lib-genvm")
local lib_llm   = require("lib-llm")

-- ---------------------------------------------------------------------------
-- Optional overlay (skipped silently if absent).
-- ---------------------------------------------------------------------------

local function load_overlay()
    local ok, mod = pcall(require, "router-overlay")
    if ok and type(mod) == "table" then return mod end
    return {}
end

local function or_caps(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = out[k] or v end
    return out
end

-- model_name -> use_max_completion_tokens (consumed by the host shim per call).
local MODEL_UMCT = {}

-- ---------------------------------------------------------------------------
-- Catalog construction from `__llm.providers`.
-- ---------------------------------------------------------------------------

local function build_catalog(providers_db, overlay)
    local model_index = {}
    for backend_name, backend in pairs(providers_db) do
        for model_name, model_cfg in pairs(backend.models or {}) do
            local entry = model_index[model_name] or { served_by = {}, capabilities = {} }
            table.insert(entry.served_by, {
                provider          = backend_name,
                provider_model_id = model_name,
            })
            entry.capabilities = or_caps(entry.capabilities, {
                supports_json_mode = model_cfg.supports_json or false,
                supports_vision    = model_cfg.supports_image or false,
                supports_tools     = model_cfg.supports_tools or false,
                supports_seed      = true,
            })
            MODEL_UMCT[model_name] = model_cfg.use_max_completion_tokens or false
            model_index[model_name] = entry
        end
    end

    local providers = {}
    for backend_name, _ in pairs(providers_db) do
        providers[backend_name] = {
            base_url  = "managed-by-genvm",   -- Rust owns transport; these satisfy the schema only
            api_kind  = "openai_compatible",
            auth_env  = "managed-by-genvm",
            tier      = "partner",
            discovery = "static",
        }
    end

    local models = {}
    for model_name, entry in pairs(model_index) do
        models[model_name] = {
            served_by           = entry.served_by,
            capabilities        = entry.capabilities,
            static_quality_hint = 0.8,
        }
    end

    -- Default profiles/policies: `greybox` (deterministic chain + cascade) and a
    -- field-scored `default` fallback. Overlays shallow-merge on top.
    -- (sigma-pol/v2) `weights`/composite atoms removed; a profile carries a raw
    -- Scorer term over real fields (cheaper + faster + roomier context).
    local profiles = {
        default = {
            scorer = { "add",
                { "scale", 0.5, { "neg", { "normalize", { "field", "price_in" } } } },
                { "scale", 0.3, { "neg", { "normalize", { "field", "latency_ms" } } } },
                { "scale", 0.2, { "normalize", { "field", "context" } } },
            },
            retry_policy = "default",
        },
        greybox = { selector = "chain", retry_policy = "cascade" },
    }
    local retry_policies = {
        default = {
            rate_limit     = { action = "next_candidate" },
            timeout        = { action = "next_candidate" },
            server_error   = { action = "next_candidate" },
            auth_error     = { action = "disable_provider" },
            content_filter = { action = "abort" },
            unknown        = { action = "next_candidate" },
        },
        -- cascade mirrors genvm-llm-greybox.lua tryChain: fall through on any
        -- overload/transient, stop only on auth/bad-request/context overflow.
        cascade = {
            rate_limit        = { action = "next_candidate" },
            timeout           = { action = "next_candidate" },
            server_error      = { action = "next_candidate" },
            model_unavailable = { action = "next_candidate" },
            content_filter    = { action = "next_candidate" },
            network_error     = { action = "next_candidate" },
            auth_error        = { action = "disable_provider" },
            bad_request       = { action = "abort" },
            context_overflow  = { action = "abort" },
            unknown           = { action = "next_candidate" },
        },
    }

    -- shallow-merge overlay
    if overlay.providers then
        for name, ov in pairs(overlay.providers) do
            providers[name] = providers[name] or {}
            for k, v in pairs(ov) do providers[name][k] = v end
        end
    end
    if overlay.models then
        for name, ov in pairs(overlay.models) do
            models[name] = models[name] or { served_by = {}, capabilities = {} }
            for k, v in pairs(ov) do
                if k == "capabilities" then
                    models[name].capabilities = or_caps(models[name].capabilities, v)
                else
                    models[name][k] = v
                end
            end
        end
    end
    if overlay.profiles then
        for k, v in pairs(overlay.profiles) do profiles[k] = v end
    end
    if overlay.retry_policies then
        for k, v in pairs(overlay.retry_policies) do retry_policies[k] = v end
    end

    return { providers = providers, models = models, profiles = profiles, retry_policies = retry_policies }
end

-- ---------------------------------------------------------------------------
-- Greybox chains from meta.greybox (faithful to genvm-llm-greybox.lua).
-- ---------------------------------------------------------------------------

-- Scan providers for `meta.greybox = { text = N, image = M }`; return
-- { text = {...}, image = {...} } sorted by priority, plus whether any was found.
local function build_chains_from_meta(providers_db)
    local chains = { text = {}, image = {} }
    local found = false
    for pname, pdata in pairs(providers_db) do
        for mname, mdata in pairs(pdata.models or {}) do
            local meta = mdata.meta
            if type(meta) == "table" and type(meta.greybox) == "table" then
                found = true
                for chain_name, priority in pairs(meta.greybox) do
                    if chains[chain_name] then
                        table.insert(chains[chain_name], { provider = pname, model = mname, priority = priority })
                    end
                end
            end
        end
    end
    for _, chain in pairs(chains) do
        table.sort(chain, function(a, b) return a.priority < b.priority end)
    end
    return chains, found
end

-- Intersect an ordered chain with what select_providers_for says is available,
-- yielding an ordered { {provider=, model=}, ... } for contract.chain.
local function build_chain(search_in, chain)
    local out = {}
    for _, e in ipairs(chain) do
        local pd = search_in[e.provider]
        if pd and pd.models then
            for model_name, _ in pairs(pd.models) do
                if model_name == e.model then
                    out[#out + 1] = { provider = e.provider, model = e.model }
                    break
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Host shim: how the engine reaches back into genvm.
-- ---------------------------------------------------------------------------

local current_ctx = nil

local function classify_status(status)
    if status == 429 then return "rate_limit" end
    if status == 408 or status == 504 then return "timeout" end
    if status == 503 or status == 529 then return "server_error" end
    if status == 401 or status == 403 then return "auth_error" end
    if status == 404 then return "model_unavailable" end
    if status and status >= 500 then return "server_error" end
    if status == 400 then return "bad_request" end
    return "unknown"
end

local function call_provider(req)
    local system_msg, user_msg
    for _, m in ipairs(req.messages or {}) do
        if m.role == "system" then
            system_msg = (system_msg and (system_msg .. "\n") or "") .. (m.content or "")
        elseif m.role == "user" then
            user_msg = (user_msg and (user_msg .. "\n") or "") .. (m.content or "")
        end
    end

    local prompt = {
        system_message            = system_msg,
        user_message              = user_msg or "",
        temperature               = req.temperature or 0.7,
        images                    = req.images or {},
        max_tokens                = req.max_tokens or 1000,
        -- per-model flag (mirrors genvm-llm-greybox.lua setting it per chain entry)
        use_max_completion_tokens = MODEL_UMCT[req.served_model_id] or false,
        seed                      = req.seed,
    }

    local format = req.response_format
    if type(format) == "table" then
        if format.type == "json_object" then format = "json"
        elseif format.type == "bool"     then format = "bool"
        else format = "text" end
    end
    if format == nil then format = "text" end

    local genvm_req = {
        provider = req.provider_id,
        model    = req.served_model_id,
        prompt   = prompt,
        format   = format,
    }

    local ok, result = pcall(function()
        return lib_llm.rs.exec_prompt_in_provider(current_ctx, genvm_req)
    end)

    if ok then
        return { ok = true, response = result }
    end

    local ue = lib_genvm.rs.as_user_error(result)
    if ue == nil then
        return { ok = false, error_kind = "fatal", error_message = tostring(result),
                 _fatal = true, _raw = result }
    end
    local status = (ue.ctx and ue.ctx.status) or 0
    return { ok = false, error_kind = classify_status(status), http_status = status,
             error_message = tostring(ue.causes or ue) }
end

_G.host = {
    call_provider = call_provider,
    now_ms        = function()
        local ok, ms = pcall(function() return math.floor(os.clock() * 1000) end)
        if ok then return ms end
        return 0
    end,
    log = function(level, event, fields)
        lib_genvm.log{ level = level, message = event, fields = fields }
    end,
    env      = function(_) return nil end,
    sleep_ms = nil,
}

-- ---------------------------------------------------------------------------
-- Load the engine and initialise once per VM.
-- ---------------------------------------------------------------------------

local router = require("router")   -- compat shim -> the llm_policy package

local _catalog = build_catalog(lib_llm.providers, load_overlay())
local _ok, _err = router.init(_catalog)
if not _ok then
    error("dispatch.lua: router.init failed: " .. tostring(_err))
end

local RESOLVED_CHAINS, HAS_CHAINS = build_chains_from_meta(lib_llm.providers)

lib_genvm.log{
    level   = "info",
    message = "llm-router dispatch initialised",
    greybox = HAS_CHAINS,
}

-- ---------------------------------------------------------------------------
-- genvm mapped prompt -> router contract.
-- ---------------------------------------------------------------------------

local function build_contract(mapped)
    local messages = {}
    if mapped.prompt.system_message and #mapped.prompt.system_message > 0 then
        table.insert(messages, { role = "system", content = mapped.prompt.system_message })
    end
    table.insert(messages, { role = "user", content = mapped.prompt.user_message })

    local response_format
    if mapped.format == "json" or mapped.format == "bool" then
        response_format = { type = "json_object" }   -- bool needs JSON capability
    end

    return {
        profile         = "default",
        messages        = messages,
        temperature     = mapped.prompt.temperature,
        max_tokens      = mapped.prompt.max_tokens,
        seed            = mapped.prompt.seed,
        images          = mapped.prompt.images,
        response_format = response_format,
    }
end

local function dispatch(ctx, mapped)
    current_ctx = ctx
    local contract = build_contract(mapped)

    -- Greybox: pick a deterministic chain (text preferred, image fallback) from
    -- select_providers_for ∩ the meta-derived chains, then route via the chain
    -- selector. Mirrors genvm-llm-greybox.lua's just_in_backend.
    if HAS_CHAINS then
        local ok, search_in = pcall(function()
            return lib_llm.select_providers_for(mapped.prompt, mapped.format)
        end)
        if ok and type(search_in) == "table" then
            local text_chain  = build_chain(search_in, RESOLVED_CHAINS.text)
            local image_chain = build_chain(search_in, RESOLVED_CHAINS.image)
            local chain = (#text_chain > 0) and text_chain or image_chain
            if #chain > 0 then
                contract.profile = "greybox"
                contract.chain   = chain
            else
                -- chains configured but nothing compatible — fatal, like production
                lib_genvm.log{ level = "error", message = "greybox: no provider for prompt" }
                lib_genvm.rs.user_error({
                    causes = { "NO_PROVIDER_FOR_PROMPT" }, fatal = true,
                    ctx = { prompt = mapped.prompt },
                })
                return
            end
        end
    end

    local result = router.execute(contract)

    if result.ok then
        local r = result.response
        r.consumed_gen = 0
        return r
    end

    lib_genvm.log{ level = "error", message = "llm-router exhausted all candidates",
                   error = result.error, trace = result.trace }
    lib_genvm.rs.user_error({
        causes = { "ROUTER_FAILED", result.error or "unknown" }, fatal = true,
        ctx = { error = result.error, trace = result.trace },
    })
end

-- ---------------------------------------------------------------------------
-- Entry points called by genvm's Rust side.
-- ---------------------------------------------------------------------------

function ExecPrompt(ctx, args, remaining_gen)
    ---@cast args LLMExecPromptPayload
    args.prompt = lib_genvm.rs.filter_text(args.prompt, { 'NFKC', 'RmZeroWidth', 'NormalizeWS' })
    local mapped = lib_llm.exec_prompt_transform(args)
    return dispatch(ctx, mapped)
end

function ExecPromptTemplate(ctx, args, remaining_gen)
    ---@cast args LLMExecPromptTemplatePayload
    local mapped = lib_llm.exec_prompt_template_transform(args)
    return dispatch(ctx, mapped)
end
