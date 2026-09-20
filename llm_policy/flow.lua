-- llm_policy.flow — Σ_flow: a composition layer over Σ_pol (docs/SIGMA-FLOW.md).
--
-- A flow is a DAG of LLM nodes between one input (the user's prompt) and one
-- output (the answer); each node carries a Σ_pol term as its `policy`, admitted
-- and encoded by llm_policy.term. Σ_flow adds only the graph on top, with the
-- same data discipline: serializable, hashable, admissible from untrusted
-- callers, append-only within sigma-flow/v1.
--
--   check(flow, schema?) -> true | nil, err   total admission, no execution
--   normalize(flow)      -> flow'             canonical (label-independent)
--   encode(flow)         -> string            deterministic; the hash input
--   fingerprint(flow)    -> string            cache key (NOT identity)
--   run(flow, opts)      -> text, trace        reference driver; effect = opts.run_node
--
-- A flow term is { "flow", nodes } — the tag at [1], the id->node map at [2],
-- mirroring a term's { op, args... }. Node ids are labels and do NOT survive
-- normalization; identity is sha256(encode(normalize(flow))), host-side.

local term   = require("llm_policy.term")
local fields = require("llm_policy.fields")
local data = require("llm_policy.flow_data")

local F = {}

F.VERSION = "sigma-flow/v1"
-- Admission bounds (part of the spec): reject a hostile flow before recursion.
F.LIMITS  = { max_nodes = 256, max_in_degree = 32 }
F.KINDS   = { input = true, llm = true, output = true, decision = true, data = true }

-- ===========================================================================
-- shared helpers
-- ===========================================================================

local function str_enc(v)
    return '"' .. v:gsub("[\\\"\n\r\t]", {
        ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
    }) .. '"'
end

-- list of node ids, in stable insertion-independent order (sorted)
local function ids_of(nodes)
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function find_endpoints(nodes)
    local input_id, output_id
    for id, node in pairs(nodes) do
        if node.kind == "input" then input_id = id
        elseif node.kind == "output" then output_id = id end
    end
    return input_id, output_id
end

-- Optional decision routing selects ONE policy for an llm node. It is part of
-- the node's identity, not an opaque host extension. Existing flows are unchanged.
local function routing_key(r, normalized)
    if not r then return "" end
    local encode_policy = function(p)
        return term.encode(normalized and p or term.normalize(p))
    end
    local parts = {str_enc(r.instructions), encode_policy(r.policy), str_enc(r.fallback),
                   tostring(r.min_confidence), tostring(r.timeout_ms)}
    for _, id in ipairs(ids_of(r.choices)) do
        local c = r.choices[id]
        parts[#parts + 1] = str_enc(id) .. ":" .. str_enc(c.description) .. ":" .. encode_policy(c.policy)
    end
    return table.concat(parts, "|")
end

local function check_routing(r, schema)
    if type(r) ~= "table" then return nil, "routing must be a record" end
    local allowed = {policy=true, instructions=true, choices=true, fallback=true,
                     min_confidence=true, timeout_ms=true}
    for k in pairs(r) do if not allowed[k] then return nil, "unknown routing field" end end
    if type(r.instructions) ~= "string" or #r.instructions < 1 or #r.instructions > 2000 then
        return nil, "routing instructions must be 1..2000 bytes"
    end
    if term.check(r.policy, schema) ~= "Policy" then return nil, "invalid decision policy" end
    if type(r.choices) ~= "table" then return nil, "routing needs choices" end
    local count = 0
    for id, c in pairs(r.choices) do
        count = count + 1
        if type(id) ~= "string" or #id < 1 or #id > 64 or type(c) ~= "table" or
           type(c.description) ~= "string" or #c.description < 1 or #c.description > 2000 or
           term.check(c.policy, schema) ~= "Policy" then return nil, "invalid routing choice" end
        for k in pairs(c) do
            if k ~= "description" and k ~= "policy" then return nil, "unknown choice field" end
        end
    end
    if count < 2 or count > 16 then return nil, "routing needs 2..16 choices" end
    if type(r.fallback) ~= "string" or not r.choices[r.fallback] then return nil, "invalid routing fallback" end
    if type(r.min_confidence) ~= "number" or not (r.min_confidence >= 0 and r.min_confidence <= 1) then
        return nil, "invalid routing confidence"
    end
    if type(r.timeout_ms) ~= "number" or r.timeout_ms % 1 ~= 0 or r.timeout_ms < 100 or r.timeout_ms > 10000 then
        return nil, "invalid routing timeout"
    end
    return true
end

-- ===========================================================================
-- check
-- ===========================================================================

function F.check(flow, schema)
    schema = schema or fields.default()
    if type(flow) ~= "table" or flow[1] ~= "flow" or type(flow[2]) ~= "table" then
        return nil, '$: a flow is { "flow", <nodes map> }'
    end
    local nodes = flow[2]

    for id in pairs(nodes) do
        if type(id) ~= "string" then return nil, "invalid node id" end
    end

    local ids = ids_of(nodes)
    if #ids == 0 then return nil, "$: flow has no nodes" end
    if #ids > F.LIMITS.max_nodes then
        return nil, "$: flow exceeds max size " .. F.LIMITS.max_nodes .. " nodes"
    end

    local n_input, n_output = 0, 0
    for _, id in ipairs(ids) do
        local node = nodes[id]
        if type(node) ~= "table" then return nil, "node '" .. id .. "' must be a record" end
        local kind = node.kind
        if not F.KINDS[kind] then
            return nil, "node '" .. id .. "': unknown kind '" .. tostring(kind) .. "'"
        end
        if node.inputs ~= nil then
            if type(node.inputs) ~= "table" then return nil, "inputs must be an array" end
            local count=0
            for k,v in pairs(node.inputs) do
                count=count+1
                if type(k)~="number" or k%1~=0 or k<1 or k>#node.inputs or type(v)~="string" then return nil,"invalid input reference" end
            end
            if count~=#node.inputs then return nil,"sparse inputs" end
        elseif kind ~= "input" then return nil,"missing inputs" end
        local extra_ok, extra_err = data.check(node)
        if not extra_ok then return nil, "node " .. id .. ": " .. extra_err end
        if node.routing ~= nil then
            if kind ~= "llm" then return nil, "routing is only valid on llm nodes" end
            local ok, err = check_routing(node.routing, schema)
            if not ok then return nil, "node '" .. id .. "': " .. err end
        end
        local nin = (type(node.inputs) == "table") and #node.inputs or 0
        if kind == "input" then
            n_input = n_input + 1
            if nin > 0 then return nil, "input node '" .. id .. "' takes no inputs" end
        elseif kind == "output" then
            n_output = n_output + 1
            if nin ~= 1 then return nil, "output node '" .. id .. "' takes exactly one input" end
        else -- model or data node
            if nin < 1 then return nil, "llm node '" .. id .. "' needs at least one input" end
            if nin > F.LIMITS.max_in_degree then
                return nil, "llm node '" .. id .. "' exceeds max in-degree " .. F.LIMITS.max_in_degree
            end
            if kind == "llm" and type(node.system) ~= "string" then
                return nil, "llm node '" .. id .. "' needs a string system prompt"
            end
            if node.template ~= nil and type(node.template) ~= "string" then
                return nil, "llm node '" .. id .. "' template must be a string"
            end
            if kind ~= "data" then
                local sort, err = term.check(node.policy, schema)
                if sort == nil then return nil, "node '" .. id .. "' policy: " .. err end
                if sort ~= "Policy" then
                    return nil, "node '" .. id .. "' policy must be a Policy term, got " .. sort
                end
            end
        end
        for _, pre in ipairs(node.inputs or {}) do
            if nodes[pre] == nil then
                return nil, "node '" .. id .. "' references unknown input '" .. tostring(pre) .. "'"
            end
        end
    end
    if n_input ~= 1 then return nil, "$: a flow needs exactly one input node, found " .. n_input end
    if n_output ~= 1 then return nil, "$: a flow needs exactly one output node, found " .. n_output end

    local input_id, output_id = find_endpoints(nodes)
    -- the output node must be a sink (referenced by nobody)
    for _, id in ipairs(ids) do
        for _, pre in ipairs(nodes[id].inputs or {}) do
            if pre == output_id then return nil, "output node '" .. output_id .. "' must be a sink" end
        end
    end

    -- acyclic (Kahn) over pull-edges: edge pre -> id for pre in id.inputs
    local indeg, succ = {}, {}
    for _, id in ipairs(ids) do indeg[id] = 0; succ[id] = {} end
    for _, id in ipairs(ids) do
        for _, pre in ipairs(nodes[id].inputs or {}) do
            indeg[id] = indeg[id] + 1
            succ[pre][#succ[pre] + 1] = id
        end
    end
    local queue, seen = {}, 0
    for _, id in ipairs(ids) do if indeg[id] == 0 then queue[#queue + 1] = id end end
    local qi = 1
    while qi <= #queue do
        local id = queue[qi]; qi = qi + 1; seen = seen + 1
        for _, b in ipairs(succ[id]) do
            indeg[b] = indeg[b] - 1
            if indeg[b] == 0 then queue[#queue + 1] = b end
        end
    end
    if seen ~= #ids then return nil, "$: flow has a cycle" end

    -- reachability: every node on a path input -> output
    local function reach(start, edges)
        local hit, stack = { [start] = true }, { start }
        while #stack > 0 do
            local id = table.remove(stack)
            for _, nb in ipairs(edges[id] or {}) do
                if not hit[nb] then hit[nb] = true; stack[#stack + 1] = nb end
            end
        end
        return hit
    end
    local preds = {}
    for _, id in ipairs(ids) do preds[id] = nodes[id].inputs or {} end
    local from_in = reach(input_id, succ)
    local to_out  = reach(output_id, preds)
    for _, id in ipairs(ids) do
        if not (from_in[id] and to_out[id]) then
            return nil, "node '" .. id .. "' is not on a path input -> output"
        end
    end
    return true
end

-- ===========================================================================
-- normalize  (canonical relabeling; identity is label-independent)
-- ===========================================================================

-- A node's content key: everything but its incoming edges. Input order on
-- `inputs` IS semantic (it drives assembly/templates), so it is preserved, not
-- sorted — two flows differing in input order assemble different prompts and so
-- are different flows.
local function content_key(node)
    if node.kind == "llm" then
        return table.concat({
            "llm", node.system or "",
            term.encode(term.normalize(node.policy)),
            node.template or "",
        }, "\0") .. (node.routing and ("\0" .. routing_key(node.routing)) or "") .. (data.options(node) ~= "" and ("\0data=" .. data.options(node)) or "")
    end
    if node.kind == "decision" then return "decision\0" .. term.encode(term.normalize(node.policy)) .. "\0" .. data.options(node) end
    if node.kind == "data" then return "data\0" .. data.options(node) end
    return node.kind            -- input / output carry nothing else
end

function F.normalize(flow)
    local nodes = flow[2]
    local ids = ids_of(nodes)

    local newid = {}
    local function keyof(id)
        local node = nodes[id]
        local ins = {}
        for i, pre in ipairs(node.inputs or {}) do ins[i] = newid[pre] end  -- ordered, already assigned
        return content_key(node) .. "\1" .. table.concat(ins, ",")
    end

    local assigned, count = {}, 0
    while count < #ids do
        local ready = {}
        for _, id in ipairs(ids) do
            if not assigned[id] then
                local ok = true
                for _, pre in ipairs(nodes[id].inputs or {}) do
                    if not assigned[pre] then ok = false; break end
                end
                if ok then ready[#ready + 1] = id end
            end
        end
        table.sort(ready, function(a, b) return keyof(a) < keyof(b) end)
        local pick = ready[1]
        assigned[pick] = true
        newid[pick] = "n" .. count
        count = count + 1
    end

    local out = {}
    for _, id in ipairs(ids) do
        local node = nodes[id]
        local nn = { kind = node.kind }
        if node.kind ~= "input" then
            local ins = {}
            for i, pre in ipairs(node.inputs) do ins[i] = newid[pre] end  -- preserve order
            nn.inputs = ins
        end
        if node.kind == "llm" then
            nn.system = node.system
            nn.policy = term.normalize(node.policy)
            if node.template ~= nil then nn.template = node.template end
            if node.routing then
                local r = node.routing
                nn.routing = {policy=term.normalize(r.policy), instructions=r.instructions,
                    fallback=r.fallback, min_confidence=r.min_confidence, timeout_ms=r.timeout_ms, choices={}}
                for name, c in pairs(r.choices) do
                    nn.routing.choices[name] = {description=c.description, policy=term.normalize(c.policy)}
                end
            end
        end
        if node.kind == "decision" then nn.policy = term.normalize(node.policy) end
        data.copy_options(node, nn)
        out[newid[id]] = nn
    end
    return { "flow", out }
end

-- ===========================================================================
-- encode / fingerprint  (identity = sha256(encode), host-side)
-- ===========================================================================

local function canon_order(nodes)
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        return (tonumber(a:match("^n(%d+)$")) or 0) < (tonumber(b:match("^n(%d+)$")) or 0)
    end)
    return ids
end

function F.encode(flow)
    local nodes = flow[2]
    local parts = {}
    for _, id in ipairs(canon_order(nodes)) do
        local node = nodes[id]
        local seg = { node.kind, id }
        if node.kind == "llm" then
            seg[#seg + 1] = "system=" .. str_enc(node.system)
            seg[#seg + 1] = "policy=" .. term.encode(term.normalize(node.policy))
            if node.template ~= nil then seg[#seg + 1] = "template=" .. str_enc(node.template) end
            if node.routing then seg[#seg + 1] = "routing=" .. routing_key(node.routing, true) end
        end
        if node.kind == "decision" then seg[#seg + 1] = "policy=" .. term.encode(term.normalize(node.policy)) end
        local options = data.options(node)
        if options ~= "" then seg[#seg + 1] = "data=" .. options end
        if node.inputs then
            seg[#seg + 1] = "inputs=[" .. table.concat(node.inputs, ",") .. "]"
        end
        parts[#parts + 1] = "(" .. table.concat(seg, " ") .. ")"
    end
    return F.VERSION .. ":(" .. table.concat(parts, " ") .. ")"
end

function F.fingerprint(flow)
    local s = F.encode(flow)
    local h1, h2 = 5381, 52711
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 31 + b) % 2147483647
        h2 = (h2 * 37 + b) % 2147483629
    end
    return string.format("%d-%d", h1, h2)
end

-- ===========================================================================
-- run  (reference driver; the only effect is opts.run_node)
-- ===========================================================================

-- default assembly of a node's user message from its predecessors' outputs.
-- one input -> pass through; a `template` with $1,$2,… -> substitution;
-- otherwise labeled sections in input order.
local function default_assemble(node, parts)
    if node.template then
        return (node.template:gsub("%$(%d+)", function(n)
            local p = parts[tonumber(n)]; return p and p.text or ""
        end))
    end
    if #parts == 1 then return parts[1].text end
    local seg = {}
    for i, p in ipairs(parts) do seg[#seg + 1] = "[input " .. i .. "]\n" .. p.text end
    return table.concat(seg, "\n\n")
end

function F.run(flow, opts)
    local nodes = flow[2]
    local input_id, output_id = find_endpoints(nodes)
    local ids = ids_of(nodes)

    -- topological order (Kahn)
    local indeg, succ = {}, {}
    for _, id in ipairs(ids) do indeg[id] = 0; succ[id] = {} end
    for _, id in ipairs(ids) do
        for _, pre in ipairs(nodes[id].inputs or {}) do
            indeg[id] = indeg[id] + 1
            succ[pre][#succ[pre] + 1] = id
        end
    end
    local order, queue, qi = {}, {}, 1
    for _, id in ipairs(ids) do if indeg[id] == 0 then queue[#queue + 1] = id end end
    while qi <= #queue do
        local id = queue[qi]; qi = qi + 1
        order[#order + 1] = id
        for _, b in ipairs(succ[id]) do
            indeg[b] = indeg[b] - 1
            if indeg[b] == 0 then queue[#queue + 1] = b end
        end
    end

    local assemble = opts.assemble or default_assemble
    local out, trace, typed = {}, {}, {}
    if opts.input ~= nil then out[input_id] = opts.input else out[input_id] = "" end
    typed[input_id] = opts.typed_input or type(opts.input) == "table"
    for _, id in ipairs(order) do
        local node = nodes[id]
        local typed_parts = false
        for _,pre in ipairs(node.inputs or {}) do if typed[pre] then typed_parts=true end end
        if node.kind == "data" or node.kind == "decision" or (node.kind == "llm" and (typed_parts or data.options(node) ~= "")) then
            local values = {}; for i,pre in ipairs(node.inputs) do values[i]=out[pre] end
            local skipped = node.skip_empty and data.empty(values[1])
            local ok, result
            if skipped then ok,result=true,values[1]
            elseif node.kind == "data" then ok,result=pcall(data.run,node,values)
            else
                local prompt = values[1]
                if node.kind == "decision" then
                    if #values > 1 then prompt=values end
                else
                    local parts={}
                    for i,v in ipairs(values) do
                        local text = v
                        if typed[node.inputs[i]] then text=assert(opts.encode_data,"typed LLM input needs encode_data")(v) end
                        parts[i]={id=node.inputs[i],text=text}
                    end
                    prompt=assemble(node,parts)
                end
                ok,result=pcall(opts.run_node,node,prompt)
            end
            local fallback = not ok and node.on_error == "input"
            if not ok and not fallback then error(result) end
            if fallback then out[id]=values[1] else out[id]=result end
            if skipped or fallback then typed[id]=typed[node.inputs[1]]
            else typed[id]=node.kind ~= "llm" or node.output_format == "json" end
            trace[#trace+1]={node=id,kind=node.kind,skipped=skipped or false,fallback=fallback}
        elseif node.kind == "llm" then
            local parts = {}
            for i, pre in ipairs(node.inputs) do parts[i] = { id = pre, text = out[pre] or "" } end
            local prompt = assemble(node, parts)
            out[id] = opts.run_node(node, prompt)
            trace[#trace + 1] = {
                node = id,
                policy_fingerprint = term.fingerprint(term.normalize(node.policy)),
            }
        elseif node.kind == "output" then
            out[id] = out[node.inputs[1]]
            typed[id] = typed[node.inputs[1]]
        end
    end
    return out[output_id], trace
end

return F
