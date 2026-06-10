-- llm_policy.elaborate — surface syntax -> Σ_pol terms.
--
-- The declarative profile format (filter/mutate specs, weights, selector,
-- retry tables) is sugar; this module desugars it into IR terms so existing
-- configs gain canonical form + hash without being rewritten. n-ary sugar
-- (all_of, weighted, pipe) lowers to the signature's variadic/binary ops;
-- legacy named atoms lower to field observations (not_disabled ->
-- not(is("disabled")), price/quality gates -> cmp).
--
-- Maps are lowered in sorted key order so elaboration is deterministic
-- (pairs() order is not). Note one pinned divergence: cmp observes through the
-- field schema, where a missing price defaults to +inf (candidate fails the
-- ceiling) — the legacy gate treated it as 0 (candidate passed).

local E = {}

local function sorted_keys(t)
    local ks = {}
    for k, _ in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

-- ---- filter spec -> Pred term ----------------------------------------------

local FILTER_ATOM = {
    requirements   = { "meets_req" },
    not_disabled   = { "not", { "is", "disabled" } },
    breaker_closed = { "not", { "is", "breaker_open" } },
    scope_matches  = { "scope_matches" },
}

function E.filter(spec)
    if spec == nil then
        return { "and", { "meets_req" }, { "not", { "is", "disabled" } } }
    end
    if type(spec) == "string" then
        local t = FILTER_ATOM[spec]
        if t == nil then error("elaborate: unknown filter atom '" .. spec .. "'") end
        return t
    end
    if type(spec) == "table" then
        if spec.all_of then
            local out = { "and" }
            for _, s in ipairs(spec.all_of) do out[#out + 1] = E.filter(s) end
            return out
        end
        if spec.any_of then
            local out = { "or" }
            for _, s in ipairs(spec.any_of) do out[#out + 1] = E.filter(s) end
            return out
        end
        if spec.none_of then
            local out = { "or" }
            for _, s in ipairs(spec.none_of) do out[#out + 1] = E.filter(s) end
            return { "not", out }
        end
        if spec.tier_in then
            local out = { "or" }
            for _, t in ipairs(spec.tier_in) do out[#out + 1] = { "tier_eq", t } end
            return #out == 2 and out[2] or out
        end
        if spec.quality_min then return { "cmp", "quality_hint", "ge", spec.quality_min } end
        if spec.quality_max then return { "cmp", "quality_hint", "lt", spec.quality_max } end
        if spec.price_max then
            local out = { "and" }
            if spec.price_max.input then
                out[#out + 1] = { "cmp", "price_in", "le", spec.price_max.input }
            end
            if spec.price_max.output then
                out[#out + 1] = { "cmp", "price_out", "le", spec.price_max.output }
            end
            return #out == 2 and out[2] or (#out == 1 and { "top" } or out)
        end
        if #spec > 0 then                       -- bare list = all_of
            local out = { "and" }
            for _, s in ipairs(spec) do out[#out + 1] = E.filter(s) end
            return out
        end
    end
    error("elaborate: invalid filter spec")
end

-- ---- weights -> Scorer term -------------------------------------------------

local WEIGHT_ATOM = {
    quality = "quality", speed = "speed", cost = "cost",
    free_credit = "free_credit", partner = "partner",
}

function E.scorer(weights)
    local out = { "add" }
    for _, name in ipairs(sorted_keys(weights or {})) do
        local w = weights[name]
        local atom = WEIGHT_ATOM[name]
        if atom and type(w) == "number" then
            out[#out + 1] = { "scale", w, { atom } }
        end
    end
    if #out == 1 then return { "zero" } end
    return out
end

-- ---- selector ----------------------------------------------------------------

function E.selector(profile, contract)
    if profile.selector == "softmax_sample" then
        local temp = (profile.selector_opts and profile.selector_opts.temp) or 1.0
        return { "sample", temp }
    end
    if profile.selector == "chain" then
        return { "chain", (contract and contract.chain) or profile.chain or {} }
    end
    return { "argmax" }
end

-- ---- mutate spec -> Xform term ------------------------------------------------

function E.mutate(spec)
    if spec == nil or spec == "identity" then return { "id" } end
    if type(spec) == "table" then
        if spec.pipe then
            local out = { "seq" }
            for _, s in ipairs(spec.pipe) do out[#out + 1] = E.mutate(s) end
            return out
        end
        if spec.filter_text  then return { "filter_text",  spec.filter_text } end
        if spec.filter_image then return { "filter_image", spec.filter_image } end
        if spec.jitter then
            local out = { "seq" }
            for _, name in ipairs(sorted_keys(spec.jitter)) do
                out[#out + 1] = { "jitter", name, spec.jitter[name] }
            end
            return #out == 2 and out[2] or out
        end
        if spec.set_param then
            local out = { "seq" }
            for _, name in ipairs(sorted_keys(spec.set_param)) do
                local v = spec.set_param[name]
                if v == "from_ctx" then
                    out[#out + 1] = { "inject_seed", name }
                else
                    out[#out + 1] = { "set_param", name, v }
                end
            end
            return #out == 2 and out[2] or out
        end
        if spec.clamp then
            local out = { "seq" }
            for _, name in ipairs(sorted_keys(spec.clamp)) do
                out[#out + 1] = { "clamp_param", name, 0, spec.clamp[name] }
            end
            return #out == 2 and out[2] or out
        end
        if #spec > 0 then                        -- bare list = pipe
            local out = { "seq" }
            for _, s in ipairs(spec) do out[#out + 1] = E.mutate(s) end
            return out
        end
    end
    error("elaborate: invalid mutate spec")
end

-- ---- retry table -> FailPlan term -----------------------------------------------

function E.failplan(retry_table)
    retry_table = retry_table or {}
    local base = retry_table.unknown or { action = "next_candidate" }
    local out = { "always", base }
    for _, reason in ipairs(sorted_keys(retry_table)) do
        if reason ~= "unknown" then
            out = { "override", out, reason, retry_table[reason] }
        end
    end
    return out
end

-- ---- full profile -> Policy term --------------------------------------------------
-- weights must already be merged/renormalized; retry_table already resolved.
--
-- The scorer is wrapped in gate(not(is("breaker_open")), ·): the legacy
-- selectors zeroed breaker-open candidates silently inside score_all; the IR
-- algebra hides nothing, so the lowering states it. Demoted to last, still
-- callable as final fallback — exactly the legacy behavior.

function E.profile(profile, opts)
    opts = opts or {}
    return { "policy",
        { "ev_zero" },
        E.filter(profile.filter),
        { "gate", { "not", { "is", "breaker_open" } },
          E.scorer(opts.weights or profile.weights) },
        E.selector(profile, opts.contract),
        E.mutate(profile.mutate),
        E.failplan(opts.retry_table),
    }
end

return E
