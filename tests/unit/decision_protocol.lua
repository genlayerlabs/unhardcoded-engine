local t = require('_assert')
local router = dofile('router.lua')
local function reset()
    router._test.reset()
    host = { now_ms = function() return 1000 end, log = function() end,
        discover = function() return { ok = true, offers = {
            { model_family = 'jev', protocol = 'decisions', wire_model_id = 'typesafe/jev',
              capabilities = {}, seller_endpoint = 'https://market' },
        }} end }
    assert(router.init({ providers = {
        p = { discovery = 'static', base_url = 'https://p', api_kind = 'openai_compatible' },
        market = { discovery = 'marketplace', discovery_id = 'market', api_kind = 'openai_compatible' },
    }, models = {
        chat = { capabilities = {}, served_by = {{ provider = 'p' }} },
        decision = { protocol = 'decisions', capabilities = {}, served_by = {{ provider = 'p' }} },
    }, profiles = { default = { scorer = {'zero'} } } }))
end

t.test('chat defaults preserve existing callers and exclude decision models', function()
    reset()
    local step = router.execute_step(nil, { prompt = 'hello' })
    t.eq(step.request.model_family, 'chat')
    t.eq(step.request.protocol, 'chat')
    t.eq(step.request.reasoning, nil)
    t.eq(step.request.reasoning_effort, nil)
end)

t.test('generation controls survive request construction and policy overrides', function()
    reset()
    local step = router.execute_step(nil, {prompt = 'hello', reasoning = {enabled = false},
        reasoning_effort = 'high', policy_ir = {'policy', {'meets_req'}, {'zero'}, {'argmax'},
            {'set_param', 'reasoning_effort', 'low'}, {'always', {action = 'next_candidate'}}}})
    t.eq(step.status, 'call')
    t.eq(step.request.reasoning.enabled, false)
    t.eq(step.request.reasoning_effort, 'low')
end)

t.test('decision payload survives the engine and marketplace fallbacks', function()
    reset()
    local decision = { state = { text = 'ticket' }, questions = { q = { type = 'noul' } } }
    local step = router.execute_step(nil, { protocol = 'decisions', decision = decision,
        policy_ir = {'policy', {'meets_req'}, {'zero'}, {'top_k', 4, {'argmax'}},
                     {'id'}, {'always', {action = 'next_candidate'}}} })
    local seen = {}
    while step.status == 'call' do
        t.eq(step.request.protocol, 'decisions')
        t.eq(step.request.decision.state.text, 'ticket')
        t.truthy(step.request.model_family ~= 'chat')
        seen[step.request.model_family] = true
        step = router.execute_step(step.state_handle, nil, {ok = false, error_kind = 'timeout'})
    end
    t.truthy(seen.decision and seen.jev)
    t.falsy(step.result.ok)
end)

t.test('pins cannot cross protocol boundaries and unknown protocols fail closed', function()
    for _, contract in ipairs({
        { requirements = {pin = {provider = 'p', model = 'decision'}} },
        { protocol = 'decisions', requirements = {pin = {provider = 'p', model = 'chat'}} },
        { protocol = 'typo' },
    }) do
        reset()
        local step = router.execute_step(nil, contract)
        t.eq(step.status, 'done')
        t.falsy(step.result.ok)
    end
end)

t.test('Xforms cannot override decision protocol payload or admitted route', function()
    for _, name in ipairs({'protocol', 'decision', 'base_url', 'served_model_id', 'auth_env', 'auth'}) do
        reset()
        local ok, err = pcall(router.execute_step, nil, { protocol = 'decisions', decision = {state = 'original'},
            policy_ir = {'policy', {'top'}, {'zero'}, {'argmax'}, {'set_param', name, 'x'},
                {'always', {action = 'next_candidate'}}} })
        t.falsy(ok, name .. ' rejected at admission')
        t.truthy(tostring(err):find('not a sampling parameter', 1, true))
    end
    -- even a host-blessed Xform (custom) cannot move the route, for any protocol
    for _, contract in ipairs({ { protocol = 'decisions', decision = {state = 'original'} }, { prompt = 'hi' } }) do
        router._test.reset()
        assert(router.init({ providers = {
            p = { discovery = 'static', base_url = 'https://p', api_kind = 'openai_compatible', auth_env = 'P_KEY' },
        }, models = {
            chat = { capabilities = {}, served_by = {{ provider = 'p' }} },
            decision = { protocol = 'decisions', capabilities = {}, served_by = {{ provider = 'p' }} },
        }, customs = { evil = function(req)
            local out = {}
            for k, v in pairs(req) do out[k] = v end
            out.protocol, out.decision, out.base_url = 'chat', 'forged', 'https://foreign'
            out.auth_env, out.auth, out.provider_id = 'CONTROL_PLANE_INTERNAL_SECRET', false, 'x'
            out.offer, out.served_model_id, out.temperature = { seller_endpoint = 'https://evil' }, 'chat', 0.1
            return out
        end }, profiles = { default = { policy_ir = {'policy', {'top'}, {'zero'}, {'argmax'},
            {'custom', 'evil'}, {'always', {action = 'next_candidate'}}} } } }))
        local step = router.execute_step(nil, contract)
        t.eq(step.status, 'call')
        t.eq(step.request.protocol, contract.protocol or 'chat')
        t.eq(step.request.decision and step.request.decision.state, contract.decision and 'original')
        t.eq(step.request.base_url, 'https://p')
        t.eq(step.request.auth_env, 'P_KEY')
        t.eq(step.request.auth, nil)
        t.eq(step.request.provider_id, 'p')
        t.eq(step.request.offer, nil)
        t.truthy(step.request.served_model_id ~= 'chat' or contract.protocol == nil)
        t.eq(step.request.temperature, 0.1, 'sampling fields still pass through')
    end
end)
