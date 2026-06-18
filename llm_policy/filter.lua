-- llm_policy.filter — pure eligibility predicates and combinators.
--
-- A filter is `fn(cand, ctx) -> true | (false, reason)`. Atoms compose via
-- all_of/any_of/none_of; the first failing atom's reason propagates (preserving
-- today's trace.rejected reasons). Pure: reads ctx.request + ctx.state, never a
-- global. See docs/POLICY_DESIGN.md §5.1.

local F = {}

local NEED_TO_CAP = {
    tools      = "supports_tools",
    vision     = "supports_vision",
    json_mode  = "supports_json_mode",
    seed       = "supports_seed",
}

-- Auto-derive capability needs from request content (images/tools/json mode).
local function derive_needs(request)
    local needs = {}
    local req = request.requirements or {}
    if type(req.needs) == "table" then
        for _, n in ipairs(req.needs) do needs[n] = true end
    end
    if type(request.images) == "table" and #request.images > 0 then
        needs.vision = true
    end
    if type(request.tools) == "table" and #request.tools > 0 then
        needs.tools = true
    end
    if type(request.response_format) == "table"
       and request.response_format.type == "json_object" then
        needs.json_mode = true
    end
    return needs
end
F.derive_needs = derive_needs

-- ---- atoms: fn(cand, ctx) -> true | (false, reason) -----------------------

function F.requirements()
    return function(cand, ctx)
        local request = ctx.request
        local req  = request.requirements or {}
        local caps = cand.capabilities or {}

        for need, _ in pairs(derive_needs(request)) do
            local flag = NEED_TO_CAP[need]
            if flag and not caps[flag] then return false, "missing_capability:" .. need end
        end
        if req.min_context and (caps.context or 0) < req.min_context then
            return false, "min_context"
        end
        if req.model_family and cand.model_family ~= req.model_family then
            return false, "model_family"
        end
        if req.tier and cand.tier ~= req.tier then
            return false, "tier"
        end
        if req.privacy == "tee_required" and not cand.has_tee then
            return false, "tee_required"
        end
        if req.privacy == "no_log" and not (cand.no_log or cand.has_tee) then
            return false, "no_log"
        end
        if req.min_quality and (cand.quality_hint or 0) < req.min_quality then
            return false, "min_quality"
        end
        if req.min_tok_s then
            -- Throughput is host-observed, stamped on the candidate (like price);
            -- the engine no longer folds it. An unstamped candidate cannot
            -- guarantee the floor, so it is rejected.
            if (cand.tok_s or 0) < req.min_tok_s then
                return false, "min_tok_s"
            end
        end
        return true
    end
end

function F.not_disabled()
    return function(cand, ctx)
        -- ctx.state.disabled values are { kind, at_ms } tables (the engine
        -- snapshots only non-expired entries); legacy hosts may still pass
        -- plain reason strings. Either way: present = disabled.
        if (ctx.state.disabled or {})[cand.provider_id] ~= nil then
            return false, "disabled_provider"
        end
        return true
    end
end

function F.breaker_closed()
    return function(cand, ctx)
        if (ctx.state.breakers or {})[cand.provider_id] == true then
            return false, "breaker_open"
        end
        return true
    end
end

function F.tier_in(tiers)
    local set = {}
    for _, t in ipairs(tiers) do set[t] = true end
    return function(cand, _ctx)
        if set[cand.tier or "fallback"] then return true end
        return false, "tier"
    end
end

function F.scope_matches()
    return function(cand, ctx)
        if cand.scope == nil then return true end       -- global candidate
        if cand.scope == ctx.request.scope then return true end
        return false, "scope"
    end
end

-- ---- combinators ----------------------------------------------------------

function F.all_of(preds)
    return function(cand, ctx)
        for _, p in ipairs(preds) do
            local ok, why = p(cand, ctx)
            if not ok then return false, why end
        end
        return true
    end
end

function F.any_of(preds)
    return function(cand, ctx)
        for _, p in ipairs(preds) do
            if p(cand, ctx) then return true end
        end
        return false, "any_of"
    end
end

function F.none_of(preds)
    return function(cand, ctx)
        for _, p in ipairs(preds) do
            if p(cand, ctx) then return false, "none_of" end
        end
        return true
    end
end

function F.where(fn) return fn end

return F
