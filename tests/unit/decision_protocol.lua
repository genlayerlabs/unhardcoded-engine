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
    reset()
    local step = router.execute_step(nil, { protocol = 'decisions', decision = {state = 'original'},
        policy_ir = {'policy', {'top'}, {'zero'}, {'argmax'},
            {'seq', {'set_param', 'protocol', 'chat'}, {'set_param', 'decision', 'forged'},
                {'set_param', 'base_url', 'https://foreign'}, {'set_param', 'served_model_id', 'chat'}},
            {'always', {action = 'next_candidate'}}} })
    t.eq(step.status, 'call')
    t.eq(step.request.protocol, 'decisions')
    t.eq(step.request.decision.state, 'original')
    t.truthy(step.request.base_url ~= 'https://foreign')
    t.truthy(step.request.served_model_id ~= 'chat')
end)
