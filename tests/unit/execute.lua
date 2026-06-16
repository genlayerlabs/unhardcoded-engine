-- Orchestration loop: M.execute end-to-end behavior against a mocked host.
--
-- Each test stages a sequence of responses per provider and verifies which
-- candidate ultimately ran, what trace events were emitted, and how RUNTIME
-- state changed (disabled providers, circuit breakers).

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function base_config()
    return {
        providers = {
            p1 = {
                discovery = "static", base_url = "http://p1",
                api_kind = "openai_compatible", auth_env = "P1_KEY",
                tier = "partner",
            },
            p2 = {
                discovery = "static", base_url = "http://p2",
                api_kind = "openai_compatible", auth_env = "P2_KEY",
                tier = "partner",
            },
            p3 = {
                discovery = "static", base_url = "http://p3",
                api_kind = "openai_compatible", auth_env = "P3_KEY",
                tier = "fallback",
            },
        },
        models = {
            m1 = {
                served_by = {
                    { provider = "p1" },
                    { provider = "p2" },
                    { provider = "p3" },
                },
                capabilities = { context = 8000 },
                static_quality_hint = 0.7,
            },
        },
        profiles = {
            default = { retry_policy = "balanced" },
        },
        retry_policies = {
            balanced = {
                rate_limit       = { action = "next_candidate", open_breaker_ms = 30000 },
                timeout          = { action = "next_candidate" },
                server_error     = { action = "retry_same", attempts = 1, backoff_ms = 0,
                                     then_action = "next_candidate" },
                auth_error       = { action = "disable_provider" },
                bad_request      = { action = "abort" },
                content_filter   = { action = "next_candidate" },
                model_unavailable = { action = "next_provider_same_model" },
                network_error    = { action = "retry_same", attempts = 2, backoff_ms = { 0, 0 },
                                     then_action = "next_candidate" },
                unknown          = { action = "next_candidate" },
            },
        },
    }
end

local _time = 0

local function mock_host(responses_by_provider)
    -- responses_by_provider is a table of {provider_id -> list of response tables}
    -- responses are consumed in order per provider.
    local counts = {}
    local call_log = {}
    _time = 0
    host = {
        log      = function() end,
        env      = function() return nil end,
        sleep_ms = function() end,
        now_ms   = function() _time = _time + 50; return _time end,
        call_provider = function(req)
            local pid = req.provider_id
            counts[pid] = (counts[pid] or 0) + 1
            call_log[#call_log + 1] = { provider = pid, attempt = counts[pid] }
            local responses = responses_by_provider[pid] or {}
            local resp = responses[counts[pid]]
            if resp == nil then
                return { ok = false, error_kind = "unknown",
                         http_status = 0, latency_ms = 0 }
            end
            return resp
        end,
    }
    return call_log
end

local function reset()
    r.reset()
    assert(router.init(base_config()))
end

-- ---- tests ---------------------------------------------------------------

t.test("execute returns ok on first-call success", function()
    reset()
    mock_host({ p1 = { { ok = true, response = { text = "hello" } } } })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok, "ok=true")
    t.eq(res.response.text, "hello", "response forwarded")
    t.eq(res.chosen.provider_id, "p1", "p1 chosen (highest tier)")
end)

t.test("rate_limit moves on to next candidate without retry", function()
    reset()
    local log = mock_host({
        p1 = { { ok = false, error_kind = "rate_limit", http_status = 429 } },
        p2 = { { ok = true, response = { text = "from p2" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2")
    t.eq(#log, 2, "exactly two calls")
end)

t.test("server_error retries same candidate once, then falls through", function()
    reset()
    local log = mock_host({
        p1 = {
            { ok = false, error_kind = "server_error", http_status = 500 },
            { ok = false, error_kind = "server_error", http_status = 500 },
        },
        p2 = { { ok = true, response = { text = "ok-from-p2" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2")

    local p1_calls = 0
    for _, c in ipairs(log) do
        if c.provider == "p1" then p1_calls = p1_calls + 1 end
    end
    t.eq(p1_calls, 2, "p1 attempted twice (initial + 1 retry)")
end)

t.test("auth_error disables the provider for the rest of the loop", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "auth_error", http_status = 401 } },
        p2 = { { ok = true, response = { text = "p2-ok" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2")
    t.eq(r.runtime().disabled_providers.p1.kind, "auth_error",
         "p1 marked disabled with the error_kind as reason")
    t.truthy(r.runtime().disabled_providers.p1.at_ms ~= nil,
             "disable is timestamped so it can TTL-expire")
end)

t.test("bad_request aborts immediately, no fallback", function()
    reset()
    local log = mock_host({
        p1 = { { ok = false, error_kind = "bad_request", http_status = 400 } },
        p2 = { { ok = true, response = { text = "shouldn't see this" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.falsy(res.ok, "abort means ok=false")
    t.contains(res.error, "bad_request")
    t.eq(#log, 1, "only p1 was called")
    t.truthy(r.runtime().circuit_breakers.p1 == nil,
             "a client-fault error is not breaker evidence against p1")
end)

t.test("client-fault kinds never open breakers (3 malformed requests ≠ provider down)", function()
    reset()
    -- Pre-fix, every cascading failure incremented consecutive_failures, so
    -- three of the CALLER's own malformed requests hit the threshold (3),
    -- opened p1's breaker, and the next valid request lost its best provider.
    mock_host({
        p1 = { { ok = false, error_kind = "bad_request",     http_status = 400 },
               { ok = false, error_kind = "bad_request",     http_status = 400 },
               { ok = false, error_kind = "bad_request",     http_status = 400 },
               { ok = true,  response = { text = "still here" } } },
    })
    for _ = 1, 3 do
        router.execute({ prompt = "malformed", profile = "default" })
    end
    local b = r.runtime().circuit_breakers.p1
    t.truthy(b == nil or (not b.open and (b.consecutive_failures or 0) == 0),
             "no breaker evidence accumulated from client faults")

    local res = router.execute({ prompt = "valid", profile = "default" })
    t.truthy(res.ok, "valid request succeeds")
    t.eq(res.chosen.provider_id, "p1", "p1 was never penalized for the caller's faults")
end)

t.test("exhausted candidates surface exhausted error", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "rate_limit" } },
        p2 = { { ok = false, error_kind = "rate_limit" } },
        p3 = { { ok = false, error_kind = "rate_limit" } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.falsy(res.ok)
    t.contains(res.error, "exhausted")
    t.contains(res.error, "rate_limit", "last error_kind preserved in message")
end)

t.test("trace records every attempt and the final selection", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "rate_limit" } },
        p2 = { { ok = true, response = { text = "good" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    local attempts = 0
    for _, e in ipairs(res.trace.decision_path) do
        if e.event == "attempted" then attempts = attempts + 1 end
    end
    t.eq(attempts, 2)
    t.truthy(#res.trace.ranked >= 2, "trace.ranked has the full ranked summary")
    t.truthy(res.trace.total_latency_ms ~= nil, "total_latency_ms set")
end)

t.test("trace attempts carry the upstream error message, truncated", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "rate_limit", http_status = 429,
                 error_message = "quota exceeded for key" } },
        p2 = { { ok = false, error_kind = "unknown", http_status = 402,
                 error_message = string.rep("x", 1000) } },
        p3 = { { ok = true, response = { text = "good" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    local by_provider = {}
    for _, e in ipairs(res.trace.decision_path) do
        if e.event == "attempted" then by_provider[e.provider_id] = e end
    end
    t.eq(by_provider.p1.error_message, "quota exceeded for key",
         "short message recorded verbatim")
    t.eq(#by_provider.p2.error_message, 300, "long message truncated to 300 chars")
    t.falsy(by_provider.p3.error_message, "successful attempt has no error_message")
end)

t.test("circuit breaker opens after rate_limit with open_breaker_ms", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "rate_limit" } },
        p2 = { { ok = true, response = { text = "ok" } } },
    })
    router.execute({ prompt = "hi", profile = "default" })
    local b = r.runtime().circuit_breakers.p1
    t.truthy(b, "breaker entry exists for p1")
    t.truthy(b.open, "breaker is open")
end)

t.test("EMA latency is updated on every call", function()
    reset()
    mock_host({
        p1 = { { ok = true, response = { text = "x" } } },
    })
    router.execute({ prompt = "hi", profile = "default" })
    local m = r.runtime().ema_metrics[r.pm_key("p1", "m1")]
    t.truthy(m, "metrics slot created")
    t.truthy(m.ema_latency_ms ~= nil, "latency recorded")
    t.eq(m.success_rate_ewma, 1, "success rate seeded to 1 on first OK")
end)

t.test("disabled provider is skipped if already disabled at execute time", function()
    reset()
    r.runtime().disabled_providers.p1 = "preexisting"
    local log = mock_host({
        p2 = { { ok = true, response = { text = "p2" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2")
    -- p1 should NOT have been called even once
    for _, c in ipairs(log) do
        t.falsy(c.provider == "p1", "p1 was skipped")
    end
end)

t.test("next_provider_same_model jumps over same-family candidates", function()
    reset()
    mock_host({
        p1 = { { ok = false, error_kind = "model_unavailable" } },
        p2 = { { ok = true, response = { text = "p2" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2",
         "skips to next provider serving the same model family")
end)

t.test("network_error retry_same with array backoff exhausts then falls through", function()
    reset()
    local log = mock_host({
        p1 = {
            { ok = false, error_kind = "network_error" },
            { ok = false, error_kind = "network_error" },
            { ok = false, error_kind = "network_error" },
        },
        p2 = { { ok = true, response = { text = "p2-after-net-retries" } } },
    })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok)
    t.eq(res.chosen.provider_id, "p2")

    local p1_calls = 0
    for _, c in ipairs(log) do
        if c.provider == "p1" then p1_calls = p1_calls + 1 end
    end
    t.eq(p1_calls, 3, "p1 called 3 times (initial + 2 retries)")
end)

t.test("execute on uninitialized router returns a clean error", function()
    r.reset()
    mock_host({})
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.falsy(res.ok)
    t.contains(res.error, "not initialized")
end)

t.test("contract.messages overrides contract.prompt in the built request", function()
    reset()
    local captured
    host = {
        log = function() end, env = function() return nil end,
        sleep_ms = function() end, now_ms = function() return 0 end,
        call_provider = function(req)
            captured = req
            return { ok = true, response = { text = "x" } }
        end,
    }
    router.execute({
        prompt   = "ignored",
        messages = {
            { role = "system", content = "you are terse" },
            { role = "user",   content = "hi" },
        },
        profile  = "default",
    })
    t.eq(#captured.messages, 2, "messages array passed through verbatim")
    t.eq(captured.messages[1].role, "system")
end)

t.test("chosen carries the prices the candidate was ranked with", function()
    reset()
    router.update_metrics("p1", "m1", { price_in = 2.5, price_out = 10.0 })
    mock_host({ p1 = { { ok = true, response = { text = "hi" } } } })
    local res = router.execute({ prompt = "hi", profile = "default" })
    t.truthy(res.ok, "ok=true")
    t.eq(res.chosen.price_in, 2.5, "price_in from metrics enrichment")
    t.eq(res.chosen.price_out, 10.0, "price_out from metrics enrichment")
end)
