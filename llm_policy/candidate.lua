-- llm_policy.candidate — the candidate object: config/provider/model
-- validation and the static candidate matrix (provider × served_by).
--
-- See docs/POLICY_DESIGN.md §4: a candidate must be completely defined and
-- validated before any verb (filter/rank/mutate) touches it. These functions
-- are pure — they read config data and return descriptors/errors, never
-- runtime state.
local C = {}

local VALID_TIERS     = { partner = true, marketplace = true, fallback = true }
local VALID_API_KIND  = { openai_compatible = true, openai_codex = true,
                          anthropic = true, google = true, bedrock = true,
                          ollama = true }
local VALID_PRIVACY   = { standard = true, no_log = true, tee_required = true }
local VALID_DISCOVERY = { static = true, marketplace = true }

local function validate_provider(id, p)
    if type(p) ~= "table" then return "providers." .. id .. " is not a table" end
    if not VALID_DISCOVERY[p.discovery] then
        return "providers." .. id .. ".discovery must be one of: static, marketplace"
    end
    if p.discovery == "static" and (type(p.base_url) ~= "string" or p.base_url == "") then
        return "providers." .. id .. ".base_url required for discovery=static"
    end
    if p.discovery == "marketplace" and type(p.discovery_id) ~= "string" then
        return "providers." .. id .. ".discovery_id required for discovery=marketplace"
    end
    if not VALID_API_KIND[p.api_kind] then
        return "providers." .. id .. ".api_kind must be one of: openai_compatible, openai_codex, anthropic, google, bedrock, ollama"
    end
    if p.tier ~= nil and not VALID_TIERS[p.tier] then
        return "providers." .. id .. ".tier must be one of: partner, marketplace, fallback"
    end
    return nil
end

local function validate_model(family, m, providers)
    if type(m) ~= "table" then return "models." .. family .. " is not a table" end
    if type(m.served_by) ~= "table" or #m.served_by == 0 then
        return "models." .. family .. ".served_by must be a non-empty list"
    end
    for i, s in ipairs(m.served_by) do
        if type(s.provider) ~= "string" or providers[s.provider] == nil then
            return "models." .. family .. ".served_by[" .. i .. "].provider does not resolve"
        end
    end
    if type(m.capabilities) ~= "table" then
        return "models." .. family .. ".capabilities required"
    end
    return nil
end

local function validate_profile(name, p, profiles_table)
    if type(p) ~= "table" then return "profiles." .. name .. " is not a table" end
    if p.extends ~= nil and profiles_table[p.extends] == nil then
        return "profiles." .. name .. ".extends references unknown profile: " .. tostring(p.extends)
    end
    -- (sigma-pol/v2) `weights` removed: it only weighted the composite scorer
    -- atoms (quality/speed/cost/…), all phantoms. Rank with an explicit
    -- `profile.scorer` term (scale/add over real fields).
    if p.weights ~= nil then
        return "profiles." .. name .. ".weights was removed in sigma-pol/v2; "
            .. "use profiles." .. name .. ".scorer (a Scorer term over real fields)"
    end
    return nil
end

function C.validate_config(config)
    if type(config) ~= "table" then return "config must be a table" end
    if type(config.providers) ~= "table" then return "config.providers required" end
    if type(config.models) ~= "table" then return "config.models required" end
    if type(config.profiles) ~= "table" then return "config.profiles required" end

    for id, p in pairs(config.providers) do
        local err = validate_provider(id, p)
        if err then return err end
    end
    for family, m in pairs(config.models) do
        local err = validate_model(family, m, config.providers)
        if err then return err end
    end
    for name, prof in pairs(config.profiles) do
        local err = validate_profile(name, prof, config.profiles)
        if err then return err end
    end
    return nil
end

-- Pre-compute the cross product of (provider, model) pairs at init time.
-- Marketplace providers contribute nothing here; their candidates are appended
-- per call from host.discover().
function C.build_candidate_matrix(providers, models)
    local list = {}
    for family, m in pairs(models) do
        for _, served in ipairs(m.served_by) do
            local p = providers[served.provider]
            if p ~= nil and p.discovery == "static" then
                list[#list + 1] = {
                    provider_id      = served.provider,
                    model_family     = family,
                    served_model_id  = served.provider_model_id or family,
                    capabilities     = m.capabilities,
                    quality_hint     = m.static_quality_hint,
                    tier             = p.tier or "fallback",
                    has_tee          = p.has_tee or false,
                    no_log           = p.no_log or false,
                    base_url         = p.base_url,
                    aws_region       = p.aws_region,
                    auth_env         = p.auth_env,
                    auth             = p.auth,   -- opaque to the router; the host resolves it
                    api_kind         = p.api_kind,
                    discovery        = "static",
                }
            end
        end
    end
    return list
end

-- expose sub-validators for completeness (not used by the public API today)
C._validate_provider = validate_provider
C._validate_model    = validate_model
C._validate_profile  = validate_profile

return C
