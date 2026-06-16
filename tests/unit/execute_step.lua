-- Cooperative async loop: M.execute_step driven directly through the
-- call / wait / done protocol (Model B). The host does no I/O here; the test
-- feeds provider responses back into execute_step the way an async driver would.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function config(server_error_backoff)
    return {
        providers = {
            p1 = { discovery = "static", base_url = "http://p1",
                   api_kind = "openai_compatible", auth_env = "P1", tier = "partner" },
            p2 = { discovery = "static", base_url = "http://p2",
                   api_kind = "openai_compatible", auth_env = "P2", tier = "partner" },
            p3 = { discovery = "static", base_url = "http://p3",
                   api_kind = "openai_compatible", auth_env = "P3", tier = "fallback" },
        },
        models = {
            m1 = {
                served_by = { { provider = "p1" }, { provider = "p2" }, { provider = "p3" } },
                capabilities = { context = 8000 },
                static_quality_hint = 0.7,
            },
        },
        profiles = {
            default = { retry_policy = "balanced" },
        },
        retry_policies = {
            balanced = {
                rate_limit   = { action = "next_candidate", open_breaker_ms = 30000 },
                server_error = { action = "retry_same", attempts = 1,
                                 backoff_ms = server_error_backoff or 0,
                                 then_action = "next_candidate" },
                auth_error   = { action = "disable_provider" },
                bad_request  = { action = "abort" },
                unknown      = { action = "next_candidate" },
            },
        },
    }
end

local _time = 0
local function install_host()
    _time = 0
    host = {
        log = function() end, env = function() return nil end,
        sleep_ms = function() end,
        now_ms = function() _time = _time + 50; return _time end,
        -- deliberately NO call_provider: execute_step must not need it.
    }
end

local function reset(server_error_backoff)
    r.reset()
    install_host()
    assert(router.init(config(server_error_backoff)))
end

-- ---- tests ---------------------------------------------------------------

t.test("first call yields a 'call' step with a built request", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    t.eq(step.status, "call", "first step is a provider call")
    t.eq(step.request.provider_id, "p1", "highest-tier candidate first")
    t.truthy(step.request.base_url == "http://p1", "request carries provider fields")
    t.truthy(step.state_handle ~= nil, "state_handle returned")
end)

t.test("feeding an ok response terminates with done", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    step = router.execute_step(step.state_handle, nil,
        { ok = true, response = { text = "hello" } })
    t.eq(step.status, "done")
    t.truthy(step.result.ok)
    t.eq(step.result.response.text, "hello")
    t.eq(step.result.chosen.provider_id, "p1")
end)

t.test("rate_limit advances to the next candidate as a new call", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    t.eq(step.request.provider_id, "p1")
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "rate_limit" })
    t.eq(step.status, "call", "moves on without finishing")
    t.eq(step.request.provider_id, "p2", "next candidate")
    step = router.execute_step(step.state_handle, nil, { ok = true, response = { text = "p2" } })
    t.eq(step.status, "done")
    t.eq(step.result.chosen.provider_id, "p2")
end)

t.test("retry_same with zero backoff re-issues the same candidate (no wait)", function()
    reset(0)
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    t.eq(step.request.provider_id, "p1")
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "server_error" })
    t.eq(step.status, "call", "no wait when backoff is zero")
    t.eq(step.request.provider_id, "p1", "same candidate retried")
end)

t.test("retry_same with backoff yields a 'wait' step, then retries same candidate", function()
    reset(500)
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "server_error" })
    t.eq(step.status, "wait", "backoff produces a wait step")
    t.truthy(type(step.until_ms) == "number", "until_ms is a number")
    -- async driver resumes with nil after sleeping
    step = router.execute_step(step.state_handle, nil, nil)
    t.eq(step.status, "call", "resumes into a call")
    t.eq(step.request.provider_id, "p1", "same candidate after the wait")
end)

t.test("bad_request aborts as a done step", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "bad_request" })
    t.eq(step.status, "done")
    t.falsy(step.result.ok)
    t.contains(step.result.error, "bad_request")
end)

t.test("auth_error disables provider and advances", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "auth_error" })
    t.eq(step.status, "call")
    t.eq(step.request.provider_id, "p2", "skipped the disabled provider")
    t.eq(r.runtime().disabled_providers.p1.kind, "auth_error")
end)

t.test("exhausting all candidates yields a done step with 'exhausted'", function()
    reset()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    for _ = 1, 3 do
        t.eq(step.status, "call")
        step = router.execute_step(step.state_handle, nil, { ok = false, error_kind = "rate_limit" })
    end
    t.eq(step.status, "done")
    t.falsy(step.result.ok)
    t.contains(step.result.error, "exhausted")
    t.contains(step.result.error, "rate_limit")
end)

t.test("execute_step on an uninitialized router returns a clean done step", function()
    r.reset()
    install_host()
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    t.eq(step.status, "done")
    t.falsy(step.result.ok)
    t.contains(step.result.error, "not initialized")
end)

t.test("driving execute_step by hand matches M.execute", function()
    -- run the sync path
    reset()
    host.call_provider = function(req)
        if req.provider_id == "p1" then return { ok = false, error_kind = "rate_limit" } end
        return { ok = true, response = { text = "via " .. req.provider_id } }
    end
    local sync = router.execute({ prompt = "hi", profile = "default" })

    -- run the step path with the same staged responses
    reset()
    local function staged(req)
        if req.provider_id == "p1" then return { ok = false, error_kind = "rate_limit" } end
        return { ok = true, response = { text = "via " .. req.provider_id } }
    end
    local step = router.execute_step(nil, { prompt = "hi", profile = "default" })
    while step.status ~= "done" do
        if step.status == "call" then
            step = router.execute_step(step.state_handle, nil, staged(step.request))
        else
            step = router.execute_step(step.state_handle, nil, nil)
        end
    end
    t.eq(step.result.ok, sync.ok)
    t.eq(step.result.chosen.provider_id, sync.chosen.provider_id)
    t.eq(step.result.response.text, sync.response.text)
end)
