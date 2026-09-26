-- Caller-supplied policies are untrusted data: they may shape their own call
-- but never redirect it, mutate breaker/disable state shared with every other
-- caller beyond host bounds, loop without bound, or carry unbounded payloads.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function reset(extra)
    r.reset()
    local time = 0
    host = { log = function() end, env = function() return nil end, sleep_ms = function() end,
             now_ms = function() time = time + 1; return time end }
    local cfg = {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1", api_kind = "openai_compatible", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2", api_kind = "openai_compatible", tier = "partner" },
            p3 = { discovery = "static", base_url = "http://p3", api_kind = "openai_compatible", tier = "fallback" },
        },
        models = { m1 = { served_by = { { provider = "p1" }, { provider = "p2" }, { provider = "p3" } },
                          capabilities = { context = 8000 } } },
        profiles = { default = { retry_policy = "host" } },
        retry_policies = { host = {
            rate_limit = { action = "next_candidate", open_breaker_ms = 3e12 },
            timeout    = { action = "disable_provider" },
            bad_request = { action = "disable_provider" },
        } },
    }
    for k, v in pairs(extra or {}) do cfg[k] = v end
    assert(router.init(cfg))
end

local function caller(fail)
    return { "policy", { "top" }, { "zero" }, { "argmax" }, { "id" }, fail }
end

local function first_failure(contract, kind)
    local step = router.execute_step(nil, contract)
    t.eq(step.status, "call")
    local pid = step.request.provider_id
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = kind })
    return pid, step
end

t.test("caller open_breaker_ms is clamped to the host bound", function()
    reset()
    local pid = first_failure({ prompt = "hi", policy_ir = caller(
        { "always", { action = "next_candidate", open_breaker_ms = 3e12 } }) }, "rate_limit")
    local b = r.runtime().circuit_breakers[pid]
    t.truthy(b.open, "breaker still opens (bounded)")
    t.truthy(b.open_until_ms - b.opened_at_ms <= r.defaults().caller_open_breaker_max_ms,
        "caller window clamped")
end)

t.test("host profile keeps its own open_breaker_ms", function()
    reset()
    local pid = first_failure({ prompt = "hi" }, "rate_limit")
    local b = r.runtime().circuit_breakers[pid]
    t.eq(b.open_until_ms - b.opened_at_ms, 3e12)
end)

t.test("caller disable_provider only on auth_error", function()
    reset()
    local fp = { "always", { action = "disable_provider" } }
    local pid = first_failure({ prompt = "hi", policy_ir = caller(fp) }, "timeout")
    t.eq(r.runtime().disabled_providers[pid], nil, "timeout: not disabled by a caller")
    reset()
    pid = first_failure({ prompt = "hi", policy_ir = caller(fp) }, "auth_error")
    t.truthy(r.runtime().disabled_providers[pid], "auth_error: disabled")
end)

t.test("host profile disable_provider works, but never on client-fault kinds", function()
    reset()
    local pid, step = first_failure({ prompt = "hi" }, "timeout")
    t.truthy(r.runtime().disabled_providers[pid])
    reset()
    pid, step = first_failure({ prompt = "hi" }, "bad_request")
    t.eq(r.runtime().disabled_providers[pid], nil, "bad_request never disables")
    t.eq(step.status, "call", "moves to the next candidate instead")
    reset()
    pid = first_failure({ prompt = "hi", policy_ir = caller({ "always", { action = "disable_provider" } }) },
        "bad_request")
    t.eq(r.runtime().disabled_providers[pid], nil)
end)

t.test("admission caps retry attempts and backoff", function()
    for _, a in ipairs({
        { action = "retry_same", attempts = 1e9 },
        { action = "retry_same", attempts = 11 },
        { action = "retry_same", attempts = 1.5 },
        { action = "retry_same", attempts = 2, backoff_ms = -1 },
        { action = "retry_same", attempts = 2, backoff_ms = 1e12 },
        { action = "retry_same", attempts = 2, backoff_ms = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    }) do
        t.eq(router.ir.term.check({ "always", a }), nil, "rejected")
    end
    t.eq(router.ir.term.check({ "always", { action = "retry_same", attempts = 10, backoff_ms = { 0, 500 } } }),
        "FailPlan")
end)

t.test("per-execution attempt cap ends a zero-backoff retry loop from any source", function()
    reset({ profiles = { default = { filter = function() return true end, retry_policy = "loop" } },
            retry_policies = { loop = { unknown = { action = "retry_same", attempts = 1e9, backoff_ms = 0 } } } })
    local step, calls = router.execute_step(nil, { prompt = "hi" }), 0
    while step.status == "call" and calls < 10000 do
        calls = calls + 1
        step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "unknown" })
    end
    t.eq(calls, r.defaults().max_attempts_per_execution)
    t.eq(step.status, "done")
    t.eq(step.result.error, "exhausted: attempt_cap")
end)

t.test("admission bounds parameter payload sizes", function()
    local long = string.rep("a", 257)
    local many = {}
    for i = 1, 65 do many[i] = "NFKC" end
    local chain = {}
    for i = 1, 65 do chain[i] = { provider = "p", model = "m" } end
    for _, term in ipairs({
        { "provider_eq", long },
        { "has_cap", long },
        { "set_param", "temperature", long },
        { "filter_text", many },
        { "filter_text", { long } },
        { "custom", long },
    }) do
        t.eq(router.ir.term.check(term), nil, "rejected: " .. term[1])
    end
    t.eq(router.ir.term.check({ "chain", chain }), nil, "long chain rejected")
    t.eq(router.ir.term.check({ "provider_eq", string.rep("a", 256) }), "Pred")
end)

t.test("set_param/clamp_param/jitter/inject_seed only name sampling fields", function()
    for _, term in ipairs({
        { "set_param", "auth_env", "CONTROL_PLANE_INTERNAL_SECRET" },
        { "set_param", "auth", false },
        { "set_param", "messages", "x" },
        { "clamp_param", "base_url", 0, 1 },
        { "jitter", "provider_id", 1 },
        { "inject_seed", "offer" },
    }) do
        t.eq(router.ir.term.check(term), nil, "rejected: " .. term[2])
    end
    t.eq(router.ir.term.check({ "set_param", "timeout_ms", 22000 }), "Xform")
    t.eq(router.ir.term.check({ "set_param", "reasoning_effort", "low" }), "Xform")
end)
