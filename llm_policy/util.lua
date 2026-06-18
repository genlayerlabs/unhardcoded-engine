-- llm_policy.util — small pure helpers shared across the package.
local U = {}

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function U.shallow_copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

function U.deep_copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = U.deep_copy(v) end
    return c
end

function U.table_keys(t)
    local ks = {}
    for k, _ in pairs(t) do ks[#ks + 1] = k end
    return ks
end

function U.table_contains(t, v)
    for _, x in ipairs(t) do
        if x == v then return true end
    end
    return false
end

-- Composite key for per-(provider,model[,peer]) runtime state (EMA, etc.).
-- Marketplace candidates pass the seller peer so reliability/latency is learned
-- per peer, not lumped per provider|family; static providers pass no peer and
-- key on provider|family (unchanged).
function U.pm_key(provider_id, model_family, peer_id)
    if peer_id then
        return provider_id .. "|" .. model_family .. "|" .. peer_id
    end
    return provider_id .. "|" .. model_family
end

-- Deterministic, portable PRNG (MINSTD LCG). Stays < 2^53 so it is identical
-- under any Lua (5.4 ints, mlua, float-only). Warms up so small seeds (1,2,3…)
-- decorrelate. Returns a closure yielding floats in (0,1). Used by seeded
-- selectors (rank) and seeded mutation (mutate) so divergence is reproducible.
function U.lcg(seed)
    local s = (seed or 0) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    local function step()
        s = (s * 16807) % 2147483647
        return s
    end
    for _ = 1, 4 do step() end
    return function() return step() / 2147483647 end
end

return U
