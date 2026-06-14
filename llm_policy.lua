-- router.lua — embeddable LLM router
--
-- Public API (see docs/POLICY_DESIGN.md):
--   router.init(config, metrics?)              -> ok, err
--   router.execute(contract)                   -> { ok, response, error, trace, chosen }
--   router.execute_step(state_handle, contract?) -> { status = "done"|"wait", ... }
--   router.update_metrics(provider, model, delta)
--   router.invalidate_discovery(discovery_id)
--   router.dump_state() / router.restore_state(snapshot)
--   router.info()
--
-- The host must provide a `host` global with at least:
--   call_provider, now_ms, env, log
-- and optionally:
--   discover, sleep_ms, persist_state, load_state
--
-- This file does no I/O. The host owns all of it.

local M = {}

M.VERSION = "0.0.1"

-- ===========================================================================
-- Internal state
-- ===========================================================================

-- Frozen-after-init knowledge derived from config + metrics
local CATALOG = {
    providers = nil,    -- [provider_id] = provider_table
    models    = nil,    -- [model_family] = model_table
    profiles  = nil,    -- [profile_name] = resolved profile (inheritance flattened, weights renormalized)
    retry     = nil,    -- [retry_policy_name] = { [error_kind] = action_table }
    candidates = nil,   -- list of { provider_id, model_family, served_model_id, capabilities }
}

-- Mutable runtime state. dump_state/restore_state work on this.
local RUNTIME = {
    circuit_breakers   = {},  -- [provider_id] = { open, opened_at_ms, consecutive_failures }
    ema_metrics        = {},  -- [provider_id .. "|" .. model_family] = { ema_latency_ms, success_rate_ewma, n }
    disabled_providers = {},  -- [provider_id] = { kind = error_kind, at_ms } (legacy: reason_string)
    discovery_cache    = {},  -- [discovery_id] = { offers, fetched_at_ms }
    initialized        = false,
}

-- Defaults that can be overridden by config.defaults
local DEFAULTS = {
    circuit_breaker_threshold       = 3,
    circuit_breaker_rate_limit_ms   = 30 * 1000,
    circuit_breaker_failure_ms      = 5 * 60 * 1000,
    disable_provider_ttl_ms         = 5 * 60 * 1000,
    discovery_cache_ttl_ms          = 60 * 1000,
    ema_alpha                       = 0.2,
    free_credit_threshold_usd       = 1.0,
}

-- ===========================================================================
-- Helpers
-- ===========================================================================

local util           = require("llm_policy.util")
local clamp          = util.clamp
local shallow_copy   = util.shallow_copy
local deep_copy      = util.deep_copy
local table_keys     = util.table_keys
local table_contains = util.table_contains
local pm_key         = util.pm_key

local function host_log(level, event, fields)
    if host and host.log then
        host.log(level, event, fields or {})
    end
end

local function clock()
    return (host and host.now_ms and host.now_ms()) or 0
end

-- ===========================================================================
-- Config validation
-- ===========================================================================

local candidate       = require("llm_policy.candidate")
local validate_config = candidate.validate_config

-- Pure policy verbs + the Policy constructor. The engine below (impure: owns
-- RUNTIME) snapshots state into a ctx and drives these pure verbs.
local F        = require("llm_policy.filter")
local R        = require("llm_policy.rank")
local mutate   = require("llm_policy.mutate")
local sequence = require("llm_policy.sequence")
local Policy   = require("llm_policy.policy")
local ir       = require("llm_policy.ir")
local ELABORATE = ir.elaborate

-- ===========================================================================
-- Profile inheritance resolution
-- ===========================================================================

local function resolve_profile(name, profiles_table, seen)
    seen = seen or {}
    if seen[name] then
        error("profile inheritance cycle through: " .. name)
    end
    seen[name] = true

    local p = profiles_table[name]
    if p.extends == nil then
        return deep_copy(p)
    end

    local parent = resolve_profile(p.extends, profiles_table, seen)
    -- shallow merge: child fields override parent fields
    local merged = parent
    for k, v in pairs(p) do
        if k ~= "extends" then
            if type(v) == "table" and type(merged[k]) == "table" then
                -- shallow merge nested tables (weights, hard_constraints, etc.)
                local sub = shallow_copy(merged[k])
                for kk, vv in pairs(v) do sub[kk] = vv end
                merged[k] = sub
            else
                merged[k] = deep_copy(v)
            end
        end
    end
    return merged
end

local function renormalize_weights(weights)
    if weights == nil then return { quality = 1.0 } end
    local sum = 0
    for _, v in pairs(weights) do
        if type(v) == "number" and v > 0 then sum = sum + v end
    end
    if sum == 0 then return weights end
    local out = {}
    for k, v in pairs(weights) do
        if type(v) == "number" and v > 0 then
            out[k] = v / sum
        else
            out[k] = 0
        end
    end
    return out
end

-- ===========================================================================
-- Candidate matrix
-- ===========================================================================

-- The static (provider × model) candidate matrix lives in llm_policy.candidate.
local build_candidate_matrix = candidate.build_candidate_matrix

-- ===========================================================================
-- Metrics seeding
-- ===========================================================================

local function seed_runtime_from_metrics(metrics)
    if metrics == nil then return end
    if type(metrics.models) == "table" then
        for key, mm in pairs(metrics.models) do
            -- key is "<family>@<provider>" per metrics.toml convention; tolerate "<provider>|<family>" too
            local provider, family
            local at = string.find(key, "@", 1, true)
            local bar = string.find(key, "|", 1, true)
            if at then
                family   = string.sub(key, 1, at - 1)
                provider = string.sub(key, at + 1)
            elseif bar then
                provider = string.sub(key, 1, bar - 1)
                family   = string.sub(key, bar + 1)
            else
                -- skip malformed
                goto continue
            end
            local k = pm_key(provider, family)
            RUNTIME.ema_metrics[k] = {
                ema_latency_ms    = mm.ttft_ms_p50,
                ema_tok_s         = mm.tok_s_p50,
                success_rate_ewma = mm.success_rate_24h or 1.0,
                price_in          = mm.price_in_usd_per_mtok,
                price_out         = mm.price_out_usd_per_mtok,
                -- without this, R.quality always fell back to the static hint
                last_quality_eval = mm.last_quality_eval,
                n                 = 0,  -- bench observations don't count as live observations
            }
            ::continue::
        end
    end
    if type(metrics.providers) == "table" then
        for pid, pm in pairs(metrics.providers) do
            if pm.free_credits_remaining_usd ~= nil then
                RUNTIME.disabled_providers[pid] = nil
                -- Stash credit balance under a synthetic per-provider slot so scoring can read it
                RUNTIME.ema_metrics["__credits|" .. pid] = {
                    free_credits_remaining_usd = pm.free_credits_remaining_usd,
                }
            end
        end
    end
end

-- ===========================================================================
-- Public API: init
-- ===========================================================================

function M.init(config, metrics)
    local err = validate_config(config)
    if err then
        return false, err
    end

    -- Resolve profile inheritance and renormalize weights
    local resolved_profiles = {}
    for name, _ in pairs(config.profiles) do
        local rp = resolve_profile(name, config.profiles)
        rp.weights = renormalize_weights(rp.weights)
        resolved_profiles[name] = rp
    end

    -- Apply defaults overrides
    if type(config.defaults) == "table" then
        for k, v in pairs(config.defaults) do
            DEFAULTS[k] = v
        end
    end

    CATALOG.providers  = config.providers
    CATALOG.models     = config.models
    CATALOG.profiles   = resolved_profiles
    CATALOG.retry      = config.retry_policies or {}
    CATALOG.candidates = build_candidate_matrix(config.providers, config.models)
    -- Observation vocabulary for IR policies: core fields + config-declared
    -- extensions (config.fields) + tier order (config.tier_order). Host-blessed
    -- named Xforms (config.customs) resolve `custom(sym)` — never caller code.
    CATALOG.field_schema = ir.fields.schema{
        extensions = config.fields,
        tier_order = config.tier_order,
    }
    CATALOG.customs = config.customs or {}
    -- Host envelope: a Pred term ∧-ed onto every per-call policy_ir, so
    -- callers can narrow the host's invariants but never widen them.
    if config.policy_envelope ~= nil then
        local sort, perr = ir.term.check(config.policy_envelope, CATALOG.field_schema)
        if sort ~= "Pred" then
            return false, "config.policy_envelope must be a Pred term: " .. tostring(perr or sort)
        end
    end
    CATALOG.envelope = config.policy_envelope

    -- Reset runtime, then seed from metrics
    RUNTIME.circuit_breakers   = {}
    RUNTIME.ema_metrics        = {}
    RUNTIME.disabled_providers = {}
    RUNTIME.discovery_cache    = {}
    seed_runtime_from_metrics(metrics)
    RUNTIME.initialized = true

    host_log("info", "router_initialized", {
        providers_loaded = #table_keys(CATALOG.providers),
        models_loaded    = #table_keys(CATALOG.models),
        profiles_loaded  = #table_keys(CATALOG.profiles),
        candidates       = #CATALOG.candidates,
        version          = M.VERSION,
    })

    return true, nil
end

-- ===========================================================================
-- Public API: introspection
-- ===========================================================================

function M.info()
    if not RUNTIME.initialized then
        return { initialized = false }
    end
    return {
        version           = M.VERSION,
        initialized       = true,
        providers_loaded  = table_keys(CATALOG.providers),
        models_loaded     = table_keys(CATALOG.models),
        profile_names     = table_keys(CATALOG.profiles),
        candidates        = #CATALOG.candidates,
    }
end

-- ===========================================================================
-- Public API: state
-- ===========================================================================

function M.dump_state()
    return deep_copy(RUNTIME)
end

function M.restore_state(snapshot)
    if type(snapshot) ~= "table" then return false, "snapshot must be a table" end
    for k, v in pairs(snapshot) do
        if k ~= "initialized" then
            RUNTIME[k] = deep_copy(v)
        end
    end
    -- Back-compat: old snapshots stored disabled_providers as plain reason
    -- strings (permanent until restart). Upgrade them to the TTL-bearing
    -- { kind, at_ms } shape so they expire after a full TTL from now.
    for pid, d in pairs(RUNTIME.disabled_providers or {}) do
        if type(d) ~= "table" then
            RUNTIME.disabled_providers[pid] = { kind = tostring(d), at_ms = clock() }
        end
    end
    return true, nil
end

function M.update_metrics(provider_id, model_family, delta)
    local k = pm_key(provider_id, model_family)
    local cur = RUNTIME.ema_metrics[k] or { n = 0 }
    for kk, vv in pairs(delta) do cur[kk] = vv end
    RUNTIME.ema_metrics[k] = cur
end

function M.invalidate_discovery(discovery_id)
    RUNTIME.discovery_cache[discovery_id] = nil
end

-- ===========================================================================
-- Marketplace discovery
-- ===========================================================================

-- Returns a list of dynamic candidates assembled from host.discover() for every
-- marketplace provider in the catalog. Cached per discovery_id for TTL ms.
local function gather_marketplace_candidates(now_ms)
    local out = {}
    if not host or not host.discover then return out end

    for pid, p in pairs(CATALOG.providers) do
        if p.discovery == "marketplace" then
            local cached = RUNTIME.discovery_cache[p.discovery_id]
            local fresh = cached
                and (now_ms - (cached.fetched_at_ms or 0) < DEFAULTS.discovery_cache_ttl_ms)
            local offers
            if fresh then
                offers = cached.offers
            else
                local r = host.discover(p.discovery_id)
                if r and r.ok and type(r.offers) == "table" then
                    offers = r.offers
                    RUNTIME.discovery_cache[p.discovery_id] = {
                        offers = offers,
                        fetched_at_ms = r.fetched_at_ms or now_ms,
                    }
                else
                    host_log("warn", "discovery_failed", {
                        provider = pid,
                        discovery_id = p.discovery_id,
                        error = r and r.error or "no response",
                    })
                    offers = {}
                end
            end

            for _, offer in ipairs(offers or {}) do
                -- skip expired quotes
                if not offer.expires_at_ms or offer.expires_at_ms > now_ms then
                    out[#out + 1] = {
                        provider_id     = pid,
                        model_family    = offer.model_family,
                        served_model_id = offer.model_family,
                        capabilities    = offer.capabilities or {},
                        quality_hint    = offer.quality_hint,
                        price_in        = offer.price_in_usd_per_mtok,
                        price_out       = offer.price_out_usd_per_mtok,
                        tier            = p.tier or "marketplace",
                        has_tee         = p.has_tee or false,
                        no_log          = p.no_log or false,
                        base_url        = offer.seller_endpoint,
                        auth_env        = p.auth_env,
                        auth            = p.auth,   -- opaque to the router; the host resolves it
                        api_kind        = p.api_kind,
                        discovery       = "marketplace",
                        offer           = offer,   -- forwarded to host.call_provider
                    }
                end
            end
        end
    end
    return out
end

-- Filtering and scoring now live in the pure verb modules
-- (llm_policy.filter / llm_policy.rank). The engine below builds a Policy from
-- them and snapshots RUNTIME into ctx.state.

-- Pure recovery views — the SINGLE source of truth for breaker/disable
-- recovery math. Given the raw RUNTIME entry and now_ms, they compute the
-- effective state WITHOUT touching RUNTIME; the mutating *_state wrappers
-- below apply their verdict as a side effect, and any read-only consumer
-- (M.provider_status) uses the views directly. Duplicating this math
-- instead of sharing it is how the two copies drift.

-- -> { open, consecutive_failures, opened_at_ms, ms_until_recovery }
local function breaker_view(b, now_ms)
    if not b then
        return { open = false, consecutive_failures = 0, ms_until_recovery = 0 }
    end
    local cf = b.consecutive_failures or 0
    if not b.open then
        return { open = false, consecutive_failures = cf,
                 opened_at_ms = b.opened_at_ms, ms_until_recovery = 0 }
    end
    local opened = b.opened_at_ms or 0
    local window = DEFAULTS.circuit_breaker_rate_limit_ms
    if now_ms - opened >= window then
        -- auto-recovered (in the view; the wrapper resets RUNTIME)
        return { open = false, recovered = true, consecutive_failures = cf,
                 opened_at_ms = opened, ms_until_recovery = 0 }
    end
    return { open = true, consecutive_failures = cf, opened_at_ms = opened,
             ms_until_recovery = math.max(0, opened + window - now_ms) }
end

-- -> nil if absent/expired, else { kind, at_ms, ms_until_recovery }.
-- Accepts the { kind, at_ms } shape and legacy reason strings (at_ms
-- unknown -> 0, i.e. expiring/expired; the wrapper stamps them instead).
local function disable_view(d, now_ms)
    if d == nil then return nil end
    local kind, at_ms
    if type(d) == "table" then
        kind, at_ms = d.kind, d.at_ms or 0
    else
        kind, at_ms = tostring(d), 0
    end
    local ttl = DEFAULTS.disable_provider_ttl_ms
    if now_ms - at_ms >= ttl then return nil end
    return { kind = kind, at_ms = at_ms,
             ms_until_recovery = math.max(0, at_ms + ttl - now_ms) }
end

local function circuit_breaker_state(provider_id, now_ms)
    local b = RUNTIME.circuit_breakers[provider_id]
    if not b then return false end
    local v = breaker_view(b, now_ms)
    if b.open and not v.open then
        -- breaker auto-recovers
        b.open = false
        b.consecutive_failures = 0
    end
    return v.open
end

-- Disabled-provider check with TTL expiry. Entries are { kind, at_ms } and
-- auto-recover after DEFAULTS.disable_provider_ttl_ms, so one transient
-- auth_error cannot keep a provider disabled until process restart. Legacy
-- string entries (pre-TTL snapshots, injected state) are upgraded in place
-- with at_ms = now so they expire after a full TTL.
local function disabled_provider_state(provider_id, now_ms)
    local d = RUNTIME.disabled_providers[provider_id]
    if d == nil then return false end
    if type(d) ~= "table" then
        d = { kind = tostring(d), at_ms = now_ms }
        RUNTIME.disabled_providers[provider_id] = d
    end
    if disable_view(d, now_ms) == nil then
        -- disable auto-expires
        RUNTIME.disabled_providers[provider_id] = nil
        return false
    end
    return true
end

-- Read-only, live provider-side health snapshot for the host's dashboard.
-- STRICTLY non-mutating: consumes breaker_view/disable_view — the same
-- recovery math the engine's checks apply — without their side effects, so
-- a dashboard poll never resets a breaker or clears a disable. Walks
-- breakers, disables, EMA metrics and the static CATALOG roster.
function M.provider_status(now_ms)
    now_ms = now_ms or clock()
    local providers = {}

    local function ensure(pid)
        local p = providers[pid]
        if p == nil then
            p = {
                available = true,
                breaker   = breaker_view(nil, now_ms),
                disabled  = nil,
                credits_remaining_usd = nil,
                models    = {},
            }
            providers[pid] = p
        end
        return p
    end

    -- Seed the full roster from the static catalog so every configured
    -- provider is listed even with no breaker/EMA yet (available, empty).
    if CATALOG.providers then
        for pid in pairs(CATALOG.providers) do ensure(pid) end
    end

    for pid, b in pairs(RUNTIME.circuit_breakers or {}) do
        local v = breaker_view(b, now_ms)
        v.recovered = nil  -- wrapper-internal marker, not part of the schema
        ensure(pid).breaker = v
    end

    for pid, d in pairs(RUNTIME.disabled_providers or {}) do
        ensure(pid).disabled = disable_view(d, now_ms)
    end

    -- EMA metrics: per-model success-rate / latency / pricing, plus credits.
    for key, m in pairs(RUNTIME.ema_metrics or {}) do
        local credit_pid = string.match(key, "^__credits|(.+)$")
        if credit_pid then
            local p = ensure(credit_pid)
            -- seed writes free_credits_remaining_usd; accept the plain name
            -- too in case the writer is updated.
            p.credits_remaining_usd = m.free_credits_remaining_usd
                                       or m.credits_remaining_usd
        else
            -- pm_key joins provider_id.."|"..model_family; provider ids carry
            -- no "|", so the first "|" splits cleanly.
            local bar = string.find(key, "|", 1, true)
            if bar then
                local pid    = string.sub(key, 1, bar - 1)
                local family = string.sub(key, bar + 1)
                ensure(pid).models[family] = {
                    success_rate      = m.success_rate_ewma,
                    avg_latency_ms    = m.ema_latency_ms,
                    observations      = m.n or 0,
                    price_in          = m.price_in,
                    price_out         = m.price_out,
                    last_quality_eval = m.last_quality_eval,
                }
            end
        end
    end

    -- Final availability: not auth-disabled AND breaker not open.
    for _, p in pairs(providers) do
        p.available = (p.disabled == nil) and (not p.breaker.open)
    end

    return {
        schema          = "router_provider_status",
        generated_at_ms = now_ms,
        providers       = providers,
    }
end

local function merged_weights(profile, contract)
    local w = shallow_copy(profile.weights or {})
    local ov = contract.weights_override
    if type(ov) == "table" then
        for k, v in pairs(ov) do w[k] = v end
    end
    return renormalize_weights(w)
end

-- Snapshot the mutable RUNTIME into a read-only ctx.state for the pure verbs.
-- This is the impure bridge: only the engine reads/writes RUNTIME; the verbs
-- only see ctx. Applies circuit-breaker TTL recovery as a side effect.
local function build_ctx(contract, now_ms)
    local breakers = {}
    for pid, _ in pairs(RUNTIME.circuit_breakers) do
        breakers[pid] = circuit_breaker_state(pid, now_ms)
    end
    -- Snapshot only LIVE disables: TTL expiry happens here (engine side), so
    -- the pure verbs keep their simple "present = disabled" view.
    local disabled = {}
    for pid, _ in pairs(RUNTIME.disabled_providers) do
        if disabled_provider_state(pid, now_ms) then
            disabled[pid] = RUNTIME.disabled_providers[pid]
        end
    end
    local credits = {}
    for k, slot in pairs(RUNTIME.ema_metrics) do
        local pid = string.match(k, "^__credits|(.+)$")
        if pid then credits[pid] = slot.free_credits_remaining_usd end
    end
    return {
        request = contract,
        state = {
            ema      = RUNTIME.ema_metrics,
            breakers = breakers,
            disabled = disabled,
            credits  = credits,
            free_credit_threshold_usd = DEFAULTS.free_credit_threshold_usd,
        },
        now_ms = now_ms,
        seed   = contract.seed,
    }
end

-- The declarative vocabulary has exactly ONE compiler: llm_policy.elaborate
-- (spec -> Σ_pol term -> interp). The functions below only handle the closure
-- escape hatch — a profile whose verbs are WHOLE composed functions (F.* /
-- mutate.* sentences). Mixing declarative parts with closures inside one spec
-- is not supported: it would require a second, shadow lowering of the same
-- vocabulary, kept semantically identical to elaborate by hand forever.
local function compile_filter(spec)
    if spec == nil then return F.all_of{ F.requirements(), F.not_disabled() } end  -- default
    if type(spec) == "function" then return spec end  -- a composed F.* / F.where sentence
    error("llm_policy: a profile with closures must provide `filter` as a whole " ..
          "composed function (or none); declarative filter specs lower via the IR")
end

local function build_mutate(spec)
    if spec == nil or spec == "identity" then return mutate.identity end
    if type(spec) == "function" then return spec end  -- a composed mutate.* sentence
    error("llm_policy: a profile with closures must provide `mutate` as a whole " ..
          "composed function (or none); declarative mutate specs lower via the IR")
end

-- Does a declarative spec smuggle a Lua closure anywhere? Closures are the
-- local escape hatch: they cannot be lowered to IR (no term, no hash), so a
-- profile containing one takes the legacy compile path below.
local function spec_has_fn(spec)
    if type(spec) == "function" then return true end
    if type(spec) == "table" then
        for _, v in pairs(spec) do
            if spec_has_fn(v) then return true end
        end
    end
    return false
end

-- Build the Policy for a contract. ONE language: every policy is a Σ_pol term
-- (admission = check -> normalize -> eval; see docs/SIGMA-POL.md), arriving
-- either ready-made (contract.policy_ir — per-call data, host envelope
-- applied — or profile.policy_ir) or by lowering the declarative profile
-- through llm_policy.elaborate. The only exception: profiles carrying Lua
-- closures (custom-fn verbs) compile legacy-style and are unhashable —
-- local-only, never admissible over the wire.
local function build_policy_for(profile, contract)
    local ir_term
    if contract.policy_ir ~= nil then
        ir_term = contract.policy_ir
        if CATALOG.envelope ~= nil then
            ir_term = ir.constrain(ir_term, CATALOG.envelope)
        end
    elseif profile.policy_ir ~= nil then
        ir_term = profile.policy_ir            -- operator's own; no envelope
    elseif spec_has_fn(profile.filter) or spec_has_fn(profile.mutate)
        or type(profile.select) == "function" then
        -- legacy escape hatch: closures can't be terms
        local weights = merged_weights(profile, contract)
        local scorer  = R.weighted(weights)
        local selector
        if type(profile.select) == "function" then
            selector = profile.select          -- explicit R.* sentence
        elseif profile.selector == "softmax_sample" then
            selector = R.softmax_sample(scorer, profile.selector_opts)
        elseif profile.selector == "chain" then
            selector = R.chain(contract.chain or profile.chain or {})
        else
            selector = R.argmax(scorer)
        end
        local retry_table = (profile.retry_policy and CATALOG.retry[profile.retry_policy]) or {}
        return Policy.new{
            filter   = compile_filter(profile.filter),
            select   = selector,
            mutate   = build_mutate(profile.mutate),
            sequence = retry_table,
        }
    else
        ir_term = ELABORATE.profile(profile, {
            weights     = merged_weights(profile, contract),
            retry_table = (profile.retry_policy and CATALOG.retry[profile.retry_policy]) or {},
            contract    = contract,
        })
    end
    return ir.compile(ir_term, {
        schema  = CATALOG.field_schema,
        customs = CATALOG.customs,
    })
end

-- Filters see raw candidates (pol.plan), but prices live in the metrics
-- store — so price ceilings were no-ops on static candidates. Enrich at
-- plan time: fill nil price fields from ema_metrics (marketplace
-- candidates already carry their offer's prices, which win).
local function enrich_with_prices(c)
    if c.price_in ~= nil and c.price_out ~= nil then return c end
    local m = RUNTIME.ema_metrics[pm_key(c.provider_id, c.model_family)]
    if not m or (m.price_in == nil and m.price_out == nil) then return c end
    local e = {}
    for k, v in pairs(c) do e[k] = v end
    if e.price_in  == nil then e.price_in  = m.price_in  end
    if e.price_out == nil then e.price_out = m.price_out end
    return e
end

-- Resolve the plan for a contract. Returns ordered, err, rejected, policy, ctx;
-- the engine keeps policy+ctx for per-attempt mutation. M.rank uses the first 3.
local function resolve_plan(contract, now_ms)
    local profile_name = contract.profile or "default"
    local profile = CATALOG.profiles[profile_name]
    if profile == nil then
        if contract.policy_ir ~= nil then
            profile = {}   -- a per-call IR policy is a complete sentence; no profile needed
        else
            return nil, "unknown profile: " .. tostring(profile_name), {}, nil, nil
        end
    end

    local ctx = build_ctx(contract, now_ms)
    local pol = build_policy_for(profile, contract)

    local pool = {}
    for _, c in ipairs(CATALOG.candidates) do pool[#pool + 1] = enrich_with_prices(c) end
    for _, c in ipairs(gather_marketplace_candidates(now_ms)) do pool[#pool + 1] = enrich_with_prices(c) end
    if type(contract.extra_candidates) == "table" then   -- ephemeral per-call (e.g. per-agent)
        for _, c in ipairs(contract.extra_candidates) do pool[#pool + 1] = enrich_with_prices(c) end
    end

    -- Pin short-circuits filtering (the pinned candidate is still scored).
    local req = contract.requirements or {}
    if req.pin then
        for _, cand in ipairs(pool) do
            if cand.provider_id == req.pin.provider and cand.model_family == req.pin.model then
                return pol.select({ cand }, ctx), nil, {}, pol, ctx
            end
        end
        return {}, nil, { { reason = "pin_not_found", pin = req.pin } }, pol, ctx
    end

    local planned = pol.plan(pool, ctx)
    return planned.ordered, nil, planned.rejected, pol, ctx
end

local function rank_candidates(contract, now_ms)
    local ordered, err, rejected = resolve_plan(contract, now_ms)
    return ordered, err, rejected
end

-- ===========================================================================
-- Orchestration helpers (used by M.execute)
-- ===========================================================================

local function build_request(cand, contract)
    local messages
    if type(contract.messages) == "table" then
        messages = contract.messages
    elseif contract.prompt ~= nil then
        messages = { { role = "user", content = contract.prompt } }
    else
        messages = {}
    end

    local req = {
        provider_id     = cand.provider_id,
        model_family    = cand.model_family,
        served_model_id = cand.served_model_id,
        base_url        = cand.base_url,
        api_kind        = cand.api_kind,
        auth_env        = cand.auth_env,
        auth            = cand.auth,
        messages        = messages,
        tools           = contract.tools,
        response_format = contract.response_format,
        images          = contract.images,
        temperature     = contract.temperature,
        seed            = contract.seed,
        max_tokens      = contract.max_tokens,
        -- timeout_ms is the hard abort threshold for the host's HTTP call.
        -- Distinct from requirements.max_latency_ms, which is a scoring
        -- preference. Fall back to max_latency_ms only when timeout_ms is
        -- absent, so older contracts keep working.
        timeout_ms      = contract.timeout_ms
                          or (contract.requirements and contract.requirements.max_latency_ms)
                          or 30000,
    }
    if cand.discovery == "marketplace" then
        req.offer = cand.offer
    end
    return req
end

-- Error kinds attributable to the CLIENT's request (malformed body, filtered
-- content, oversized context) say nothing about provider health, so they must
-- not count toward the circuit breaker — otherwise a burst of malformed
-- requests opens every breaker in the catalog and the next valid request gets
-- no_candidates. Provider-fault kinds (timeout, server_error, network_error,
-- rate_limit, auth_error, bad_response, unknown) keep counting.
local CLIENT_FAULT_KINDS = {
    bad_request      = true,
    content_filter   = true,
    context_overflow = true,
}

local function update_breaker_on_failure(provider_id, now_ms, open_breaker_ms)
    local b = RUNTIME.circuit_breakers[provider_id]
            or { open = false, consecutive_failures = 0 }
    b.consecutive_failures = (b.consecutive_failures or 0) + 1
    if open_breaker_ms or b.consecutive_failures >= DEFAULTS.circuit_breaker_threshold then
        b.open = true
        b.opened_at_ms = now_ms
    end
    RUNTIME.circuit_breakers[provider_id] = b
end

local function update_breaker_on_success(provider_id)
    local b = RUNTIME.circuit_breakers[provider_id]
    if b then
        b.consecutive_failures = 0
        b.open = false
    end
end

local function update_ema(provider_id, model_family, latency_ms, ok)
    local k = pm_key(provider_id, model_family)
    local m = RUNTIME.ema_metrics[k] or { n = 0 }
    local alpha = DEFAULTS.ema_alpha

    if latency_ms ~= nil then
        if m.ema_latency_ms == nil then
            m.ema_latency_ms = latency_ms
        else
            m.ema_latency_ms = alpha * latency_ms + (1 - alpha) * m.ema_latency_ms
        end
    end

    local s = ok and 1 or 0
    if m.success_rate_ewma == nil then
        m.success_rate_ewma = s
    else
        m.success_rate_ewma = alpha * s + (1 - alpha) * m.success_rate_ewma
    end

    m.n = (m.n or 0) + 1
    RUNTIME.ema_metrics[k] = m
end

local function classify_action(profile, error_kind)
    local retry_table = (profile and profile.retry_policy and CATALOG.retry[profile.retry_policy]) or {}
    return sequence.classify(retry_table, error_kind)
end

local backoff_ms_for = sequence.backoff_ms_for

local function ranked_summary(ranked)
    local out = {}
    for i, item in ipairs(ranked) do
        out[i] = {
            provider_id  = item.candidate.provider_id,
            model_family = item.candidate.model_family,
            score        = item.score,
            tier         = item.candidate.tier,
        }
    end
    return out
end

-- ===========================================================================
-- Public API: execute (synchronous orchestration loop)
-- ===========================================================================

-- The orchestration loop is a resumable state machine. Its entire state lives
-- in `state_handle` so the host can drive it cooperatively: each provider call
-- and each backoff is a yield point. `M.execute` is a thin synchronous driver
-- over the same machine; async hosts drive it without blocking the Lua VM.
-- See docs/POLICY_DESIGN.md §6 for the step protocol (Model B, yield-on-IO).

-- Build the initial machine state from a contract. On a ranking error or an
-- empty candidate set, `state.done` is set to the terminal result.
local function new_run_state(contract)
    local started_at = clock()
    local ranked, err, rejected, pol, ctx = resolve_plan(contract, started_at)
    local state = {
        contract        = contract,
        started_at      = started_at,
        cursor          = 1,
        attempts        = 0,
        awaiting        = nil,   -- nil | "response" | "wait"
        pending_cand    = nil,
        call_start      = nil,
        last_error_kind = nil,
        done            = nil,
    }
    if err then
        state.done = {
            ok    = false,
            error = err,
            trace = { rejected = rejected or {}, decision_path = {}, started_at_ms = started_at },
        }
        return state
    end
    state.ranked  = ranked
    state.policy  = pol
    state.ctx     = ctx
    state.profile = CATALOG.profiles[contract.profile or "default"]
    state.trace   = {
        ranked        = ranked_summary(ranked),
        rejected      = rejected or {},
        decision_path = {},
        started_at_ms = started_at,
        -- IR policies carry their identity AND their normal-form term (the data
        -- a host can surface/copy/commit); legacy closure profiles have neither
        policy_fingerprint = pol and pol.fingerprint or nil,
        policy_term = pol and pol.term or nil,
    }
    if #ranked == 0 then
        state.trace.total_latency_ms = clock() - started_at
        state.done = { ok = false, error = "no_candidates", trace = state.trace }
    end
    return state
end

local function finish(state, result)
    state.done = result
    return { status = "done", result = result, state_handle = state }
end

-- Skip disabled providers and emit the next provider call, or terminate as
-- exhausted. Sets state.awaiting = "response" when it emits a call.
local function advance(state)
    local ranked = state.ranked
    while state.cursor <= #ranked do
        local cand = ranked[state.cursor].candidate
        if disabled_provider_state(cand.provider_id, clock()) then
            state.trace.decision_path[#state.trace.decision_path + 1] = {
                event        = "skipped",
                provider_id  = cand.provider_id,
                model_family = cand.model_family,
                reason       = "disabled_provider",
            }
            state.cursor   = state.cursor + 1
            state.attempts = 0
        else
            state.pending_cand = cand
            state.call_start   = clock()
            state.awaiting     = "response"
            -- mutate is per-attempt and candidate-aware (greybox re-diversifies
            -- on each retry); default policy uses mutate.identity (no change).
            local request = state.policy.mutate(build_request(cand, state.contract), cand, state.ctx)
            return {
                status       = "call",
                request      = request,
                state_handle = state,
            }
        end
    end
    state.trace.total_latency_ms = clock() - state.started_at
    return finish(state, {
        ok    = false,
        error = "exhausted: " .. (state.last_error_kind or "no_candidates"),
        trace = state.trace,
    })
end

-- Consume the response for the pending candidate. Returns a terminal/wait step,
-- or nil meaning "continue" (the caller should advance the cursor).
local function handle_response(state, response)
    response = response or { ok = false, error_kind = "unknown" }
    local cand    = state.pending_cand
    local elapsed = clock() - (state.call_start or clock())
    state.pending_cand = nil
    state.awaiting     = nil

    update_ema(cand.provider_id, cand.model_family, elapsed, response.ok and true or false)

    local event = {
        event        = "attempted",
        provider_id  = cand.provider_id,
        model_family = cand.model_family,
        attempt      = state.attempts + 1,
        latency_ms   = elapsed,
    }
    if not response.ok then
        event.error_kind  = response.error_kind or "unknown"
        event.http_status = response.http_status
        -- Keep the upstream error body in the trace (truncated): without it,
        -- "exhausted: <kind>" is all an operator ever sees of a failure.
        if response.error_message ~= nil then
            event.error_message = string.sub(tostring(response.error_message), 1, 300)
        end
    end
    state.trace.decision_path[#state.trace.decision_path + 1] = event

    if response.ok then
        update_breaker_on_success(cand.provider_id)
        state.trace.total_latency_ms = clock() - state.started_at
        return finish(state, {
            ok       = true,
            response = response.response,
            trace    = state.trace,
            chosen   = {
                provider_id     = cand.provider_id,
                model_family    = cand.model_family,
                served_model_id = cand.served_model_id,
                -- the prices this candidate was ranked with, so the caller
                -- can stamp an executed cost on the request record
                price_in        = cand.price_in,
                price_out       = cand.price_out,
            },
        })
    end

    local error_kind = response.error_kind or "unknown"
    state.last_error_kind = error_kind

    -- The failure plan travels with the Policy (legacy build assigns the
    -- profile's retry table to pol.sequence; IR policies carry their FailPlan).
    local action = sequence.classify(state.policy and state.policy.sequence or {}, error_kind)
    local act    = action.action or "next_candidate"

    if not CLIENT_FAULT_KINDS[error_kind] then
        update_breaker_on_failure(cand.provider_id, clock(), action.open_breaker_ms)
    end

    if act == "abort" then
        state.trace.total_latency_ms = clock() - state.started_at
        return finish(state, { ok = false, error = error_kind, trace = state.trace })

    elseif act == "disable_provider" then
        -- TTL'd, not permanent: expires after DEFAULTS.disable_provider_ttl_ms
        -- (see disabled_provider_state) so a transient auth_error self-heals.
        RUNTIME.disabled_providers[cand.provider_id] = { kind = error_kind, at_ms = clock() }
        state.trace.decision_path[#state.trace.decision_path + 1] = {
            event       = "provider_disabled",
            provider_id = cand.provider_id,
            reason      = error_kind,
        }
        state.cursor   = state.cursor + 1
        state.attempts = 0
        return nil

    elseif act == "retry_same" then
        local max = action.attempts or 1
        state.attempts = state.attempts + 1
        if state.attempts <= max then
            local back = backoff_ms_for(action, state.attempts)
            state.trace.decision_path[#state.trace.decision_path + 1] = {
                event        = "retry_scheduled",
                provider_id  = cand.provider_id,
                model_family = cand.model_family,
                attempt      = state.attempts,
                backoff_ms   = back,
            }
            if back > 0 then
                state.awaiting = "wait"
                return { status = "wait", until_ms = clock() + back, state_handle = state }
            end
            return nil  -- re-issue the same candidate immediately
        else
            state.attempts = 0
            local then_act = action.then_action or "next_candidate"
            if then_act == "abort" then
                state.trace.total_latency_ms = clock() - state.started_at
                return finish(state, { ok = false, error = error_kind, trace = state.trace })
            end
            state.cursor = state.cursor + 1
            return nil
        end

    elseif act == "next_provider_same_model" then
        local target = cand.model_family
        local found
        for j = state.cursor + 1, #state.ranked do
            if state.ranked[j].candidate.model_family == target then
                found = j
                break
            end
        end
        state.cursor   = found or (#state.ranked + 1)
        state.attempts = 0
        return nil

    else  -- next_candidate (default) and any unknown action
        state.cursor   = state.cursor + 1
        state.attempts = 0
        return nil
    end
end

local function run_step(state, input)
    if state.done then
        return { status = "done", result = state.done, state_handle = state }
    end
    if state.awaiting == "response" then
        local step = handle_response(state, input)
        if step then return step end   -- terminal or wait
    elseif state.awaiting == "wait" then
        state.awaiting = nil           -- resume: re-issue the same candidate
    end
    return advance(state)
end

-- Cooperative async entry point. First call passes the contract (state nil);
-- subsequent calls pass the prior step's state_handle plus, for a "call" step,
-- the provider response. Returns { status = "call"|"wait"|"done", ... }.
function M.execute_step(state, contract, response)
    if not RUNTIME.initialized then
        return finish({}, { ok = false, error = "router not initialized", trace = {} })
    end
    if state == nil then
        state = new_run_state(contract)
        if state.done then
            return { status = "done", result = state.done, state_handle = state }
        end
        return advance(state)
    end
    return run_step(state, response)
end

-- Synchronous driver: drives execute_step to completion using the host's
-- blocking call_provider and sleep_ms. Behavior is identical to the old loop.
function M.execute(contract)
    if not (host and host.call_provider) then
        return { ok = false, error = "host.call_provider missing", trace = {} }
    end
    local step = M.execute_step(nil, contract)
    while step.status ~= "done" do
        if step.status == "call" then
            local resp = host.call_provider(step.request) or { ok = false, error_kind = "unknown" }
            step = M.execute_step(step.state_handle, nil, resp)
        elseif step.status == "wait" then
            local back = (step.until_ms or 0) - clock()
            if back > 0 and host.sleep_ms then host.sleep_ms(back) end
            step = M.execute_step(step.state_handle, nil, nil)
        else
            return { ok = false, error = "internal: bad step status " .. tostring(step.status), trace = {} }
        end
    end
    return step.result
end

-- Public dry-run: returns the ranked candidate list without making any HTTP calls.
-- Useful for `conclave explain`-style introspection and for tests.
function M.rank(contract)
    if not RUNTIME.initialized then
        return nil, "router not initialized"
    end
    local now = (host and host.now_ms and host.now_ms()) or 0
    return rank_candidates(contract, now)
end

-- ===========================================================================
-- Test hooks (only exposed to make unit-testing pure helpers possible)
-- These are intentionally underscored to signal "do not use in production code".
-- ===========================================================================

-- Public verb DSL — for hosts and Lua "sentence" files that compose a Policy
-- directly (incl. the custom-fn escape hatches the declarative profile can't
-- express). A config profile covers the named combinators; this exposes the raw
-- verbs: `local dsl = require("llm_policy").dsl`.
M.dsl = { filter = F, rank = R, mutate = mutate, sequence = sequence, policy = Policy }

-- The Σ_pol IR: signature, terms (check/normalize/encode), field schema,
-- interpreter, and legacy-surface elaboration. `M.ir.compile(term)` is the
-- admission pipeline for policies that arrive as data (e.g. with the call).
M.ir = ir

M._test = {
    validate_config        = validate_config,
    resolve_profile        = resolve_profile,
    renormalize_weights    = renormalize_weights,
    build_candidate_matrix = build_candidate_matrix,
    rank_candidates        = rank_candidates,
    resolve_plan           = resolve_plan,
    merged_weights         = merged_weights,
    circuit_breaker_state  = circuit_breaker_state,
    build_request          = build_request,
    classify_action        = classify_action,
    backoff_ms_for         = backoff_ms_for,
    clamp                  = clamp,
    pm_key                 = pm_key,
    -- pure verb modules (for direct unit tests)
    filter                 = F,
    rank                   = R,
    mutate                 = mutate,
    sequence               = sequence,
    policy                 = Policy,
    catalog                = function() return CATALOG end,
    runtime                = function() return RUNTIME end,
    defaults               = function() return DEFAULTS end,
    reset                  = function()
        CATALOG.providers, CATALOG.models, CATALOG.profiles = nil, nil, nil
        CATALOG.retry, CATALOG.candidates = nil, nil
        RUNTIME.circuit_breakers   = {}
        RUNTIME.ema_metrics        = {}
        RUNTIME.disabled_providers = {}
        RUNTIME.discovery_cache    = {}
        RUNTIME.initialized        = false
    end,
}

return M
