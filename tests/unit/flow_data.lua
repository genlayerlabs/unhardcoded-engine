local t=require('_assert')
local F=require('llm_policy.flow')
local D=require('llm_policy.flow_data')
local function policy()
    return {'policy',{'meets_req'},{'field','context'},{'argmax'},{'id'},{'always',{action='next_candidate'}}}
end
local function graph()
    return {'flow',{
        input={kind='input'},
        classify={kind='decision',policy=policy(),inputs={'input'},on_error='input',questions={
            ticket={type='choice',instructions='Choose department',criteria={sales='Sales',support='Support'}}}},
        selected={kind='data',operation='select',field='choice',equals='support',inputs={'input','classify'}},
        reply={kind='llm',policy=policy(),system='Draft replies',context='inputs',output_format='json',skip_empty=true,on_error='input',inputs={'selected'}},
        patch={kind='data',operation='overlay',inputs={'input','reply'},on_error='input'},
        output={kind='output',inputs={'patch'}}}}
end

t.test('typed flow admits and all semantic fields affect identity',function()
    local g=graph(); t.truthy(F.check(g))
    local nf=F.normalize(g); local encoded=F.encode(nf)
    t.eq(F.encode(F.normalize(nf)),encoded)
    g[2].selected.equals='sales'
    t.truthy(F.encode(F.normalize(g))~=encoded)
    g=graph(); g[2].reply.skip_empty=false
    t.truthy(F.encode(F.normalize(g))~=encoded)
    g=graph(); g[2].classify.questions.ticket.instructions='Different question'
    t.truthy(F.encode(F.normalize(g))~=encoded)
    g=graph(); g[2].patch.max_string_bytes=20
    t.truthy(F.encode(F.normalize(g))~=encoded)
end)

t.test('typed flow rejects hostile options, references and questions before effects',function()
    for _,edit in ipairs({
        function(g) g[2].selected.operation='eval' end,
        function(g) g[2].selected.code='os.execute' end,
        function(g) g[2].selected.inputs='input' end,
        function(g) g[2].selected.field={} end,
        function(g) g[2].reply.on_error='run_shell' end,
        function(g) g[2].reply.skip_empty='true' end,
        function(g) g[2].reply.timeout_ms=0 end,
        function(g) g[2].reply.questions={} end,
        function(g) g[2].classify.policy={'invalid'} end,
        function(g) g[2].classify.questions.ticket.criteria={} end,
        function(g) g[2].classify.questions.ticket.instructions='' end,
        function(g) g[2].patch.max_string_bytes=-1 end,
        function(g) g[2].patch.inputs={} end,
    }) do local g=graph(); edit(g); local ok,valid=pcall(F.check,g); t.truthy(ok); t.falsy(valid) end
end)

t.test('bounded record operations preserve values and reject unknown keys',function()
    local base={a='aaaa',b='bbbb',flag=true}
    t.eq(D.run({operation='project',path={'nested'}},{{nested=base}}).a,'aaaa')
    t.eq(D.run({operation='select',field='choice',equals='yes'},{base,{a={choice='yes'},b={choice='no'}}}).a,'aaaa')
    local out=D.run({operation='overlay'},{base,{flag=false}})
    t.eq(out.flag,false)
    out=D.run({operation='overlay',only_shrink=true,max_string_bytes=3,min_string_bytes=1},{base,{a='A',b='',flag='big'},{b='remove'}})
    t.eq(out.a,'A'); t.eq(out.b,nil); t.eq(out.flag,true)
    t.falsy(pcall(D.run,{operation='overlay'},{base,{invented='x'}}))
    t.falsy(pcall(D.run,{operation='union'},{{a=1},{a=2}}))
    t.eq(D.run({operation='union'},{{a=1},{b=2}}).b,2)
    t.falsy(pcall(D.run,{operation='project',path={'missing'}},{base}))
end)

t.test('reference flow skips generation after an empty selection',function()
    local calls=0
    local out,trace=F.run(graph(),{input={ticket='Need a quote'},encode_data=function() return 'json' end,
        run_node=function(node,prompt)
            calls=calls+1
            t.eq(node.kind,'decision')
            return {ticket={choice='sales'}}
        end})
    t.eq(calls,1); t.eq(out.ticket,'Need a quote')
    local skipped=false; for _,entry in ipairs(trace) do if entry.skipped then skipped=true end end
    t.truthy(skipped)
end)

t.test('reference flow performs selected generation and bounded fallback',function()
    local calls=0
    local out=F.run(graph(),{input={ticket='It broke'},encode_data=function() return 'json' end,
        run_node=function(node)
            calls=calls+1
            if node.kind=='decision' then return {ticket={choice='support'}} end
            return {ticket='Try restarting'}
        end})
    t.eq(calls,2); t.eq(out.ticket,'Try restarting')
    out=F.run(graph(),{input={ticket='It broke'},encode_data=function() return 'json' end,
        run_node=function() error('unavailable') end})
    t.eq(out.ticket,'It broke')
end)

t.test('legacy flow encoding stays byte-identical',function()
    local g={'flow',{u={kind='input'},g={kind='llm',system='Answer.',policy=policy(),inputs={'u'}},out={kind='output',inputs={'g'}}}}
    t.eq(F.encode(F.normalize(g)),[=[sigma-flow/v1:((input n0) (llm n1 system="Answer." policy=sigma-pol/v2:(policy (meets_req) (field "context") (argmax) (id) (always {"action":"next_candidate"})) inputs=[n0]) (output n2 inputs=[n1]))]=])
end)


t.test('reference serializes typed strings into ordinary generation nodes',function()
    local g={'flow',{
        input={kind='input'},
        value={kind='data',operation='project',path={'item'},inputs={'input'}},
        reply={kind='llm',system='',policy=policy(),inputs={'value'}},
        output={kind='output',inputs={'reply'}}}}
    local result=F.run(g,{input={item='hello'},encode_data=function(value) return '"'..value..'"' end,
        run_node=function(node,prompt) t.eq(prompt,'"hello"'); return 'reply' end})
    t.eq(result,'reply')
end)
