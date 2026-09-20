-- Bounded structured-data extensions for Sigma flow. No application vocabulary,
-- code evaluation, dynamic topology or I/O. Model effects remain host-owned.
local D = {}
D.keys = {"operation", "path", "field", "equals", "questions", "output_format",
    "skip_empty", "on_error", "context", "max_tokens", "timeout_ms",
    "max_string_bytes", "min_string_bytes", "only_shrink"}

local function integer(x, lo, hi)
    return type(x) == "number" and x % 1 == 0 and x >= lo and x <= hi
end
local function text(x, n) return type(x) == "string" and #x > 0 and #x <= n end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

function D.check(node)
    local kind = node.kind
    local allowed = {kind=true, inputs=true}
    if kind == "decision" then
        for _, k in ipairs({"policy", "questions", "skip_empty", "on_error", "timeout_ms"}) do allowed[k]=true end
        local qs = node.questions
        if type(qs) ~= "table" or count(qs) < 1 or count(qs) > 32 then return nil, "decision needs 1..32 questions" end
        for name, q in pairs(qs) do
            if not text(name,64) or type(q)~="table" or not text(q.instructions,2000) then return nil,"invalid question" end
            for k in pairs(q) do if k~="type" and k~="instructions" and k~="criteria" then return nil,"unknown question field" end end
            if q.type == "choice" then
                if type(q.criteria)~="table" or count(q.criteria)<1 or count(q.criteria)>32 then return nil,"invalid choice criteria" end
                for k,v in pairs(q.criteria) do if not text(k,64) or not text(v,2000) then return nil,"invalid criterion" end end
            elseif q.type == "score" then
                if type(q.criteria)~="table" or #q.criteria<2 or #q.criteria>32 or count(q.criteria)~=#q.criteria then return nil,"invalid score criteria" end
                for _,v in ipairs(q.criteria) do if not text(v,2000) then return nil,"invalid score criterion" end end
            elseif q.type == "noul" then
                if q.criteria ~= nil then
                    if type(q.criteria)~="table" then return nil,"invalid noul criteria" end
                    for k,v in pairs(q.criteria) do if (k~="true" and k~="false") or not text(v,2000) then return nil,"invalid noul criterion" end end
                    if count(q.criteria)~=2 then return nil,"invalid noul criteria" end
                end
            else return nil,"unknown question type" end
        end
    elseif kind == "data" then
        allowed.operation=true; allowed.on_error=true
        if node.operation == "project" then
            allowed.path=true
            if #node.inputs~=1 or type(node.path)~="table" or #node.path<1 or #node.path>16 or count(node.path)~=#node.path then return nil,"project needs one input and a bounded path" end
            for _,k in ipairs(node.path) do if not text(k,128) then return nil,"path components must be object keys" end end
        elseif node.operation == "select" then
            allowed.field=true; allowed.equals=true
            if #node.inputs~=2 or not text(node.field,128) or not text(node.equals,128) then return nil,"select needs records, mask, field and equals" end
        elseif node.operation == "overlay" then
            allowed.max_string_bytes=true; allowed.min_string_bytes=true; allowed.only_shrink=true
            if #node.inputs<2 or #node.inputs>3 then return nil,"overlay needs base, replacements and optional removals" end
        elseif node.operation == "union" then
            if #node.inputs<1 or #node.inputs>32 then return nil,"union needs 1..32 inputs" end
        else return nil,"unknown data operation" end
    elseif kind == "llm" then
        allowed = {output_format=true,skip_empty=true,on_error=true,context=true,max_tokens=true,timeout_ms=true}
    end
    for _,k in ipairs(D.keys) do
        if node[k]~=nil and not allowed[k] then return nil,"field not supported by node kind: "..k end
    end
    if kind=="decision" or kind=="data" then
        for k in pairs(node) do if not allowed[k] then return nil,"unknown node field" end end
    end
    if node.output_format~=nil and node.output_format~="json" then return nil,"invalid output_format" end
    if node.on_error~=nil and node.on_error~="input" then return nil,"invalid on_error" end
    if node.context~=nil and node.context~="inputs" then return nil,"invalid context" end
    for _,k in ipairs({"skip_empty","only_shrink"}) do if node[k]~=nil and type(node[k])~="boolean" then return nil,"invalid boolean field" end end
    if node.max_tokens~=nil and not integer(node.max_tokens,1,4096) then return nil,"invalid max_tokens" end
    if node.timeout_ms~=nil and not integer(node.timeout_ms,1,40000) then return nil,"invalid timeout_ms" end
    if node.max_string_bytes~=nil and not integer(node.max_string_bytes,1,1048576) then return nil,"invalid max_string_bytes" end
    if node.min_string_bytes~=nil and not integer(node.min_string_bytes,1,node.max_string_bytes or 1048576) then return nil,"invalid min_string_bytes" end
    return true
end

-- Type-tagged, length-delimited encoding; sorted keys, ordered integer indexes.
-- It only sees admitted, bounded static records, never runtime model output.
local function enc(v)
    local ty=type(v)
    if ty=="string" then return "s"..#v..":"..v end
    if ty=="boolean" then return v and "b1" or "b0" end
    if ty=="number" then return "n"..string.format("%.0f",v)..":" end
    local keys={}; for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return enc(a)<enc(b) end)
    local out={"t",tostring(#keys),":"}
    for _,k in ipairs(keys) do out[#out+1]=enc(k); out[#out+1]=enc(v[k]) end
    return table.concat(out)
end
D.encode=enc
function D.options(node)
    local out={}
    for _,k in ipairs(D.keys) do if node[k]~=nil then out[k]=node[k] end end
    return next(out) and enc(out) or ""
end
local function copy(v)
    if type(v)~="table" then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
function D.copy_options(node, out)
    for _,k in ipairs(D.keys) do if node[k]~=nil then out[k]=copy(node[k]) end end
end
function D.empty(v) return type(v)=="table" and next(v)==nil end
local function records(v)
    assert(type(v)=="table" and count(v)<=128,"expected at most 128 keyed records")
    for k in pairs(v) do assert(text(k,128),"record keys must be bounded strings") end
    return v
end

function D.run(node, parts)
    if node.operation=="union" then
        local out={}
        for _,part in ipairs(parts) do
            for k,v in pairs(records(part)) do assert(out[k]==nil,"duplicate union key"); out[k]=v end
        end
        return records(out)
    end
    if node.operation=="project" then
        local v=parts[1]
        for _,k in ipairs(node.path) do assert(type(v)=="table" and v[k]~=nil,"missing projection key"); v=v[k] end
        return v
    end
    local base=records(parts[1]); local other=records(parts[2]); local out={}
    if node.operation=="select" then
        for k,v in pairs(base) do
            if type(other[k])=="table" and other[k][node.field]==node.equals then out[k]=v end
        end
        return out
    end
    local removals=parts[3] and records(parts[3]) or {}
    for k in pairs(other) do assert(base[k]~=nil,"unknown replacement key") end
    for k in pairs(removals) do assert(base[k]~=nil,"unknown removal key") end
    for k,v in pairs(base) do
        if removals[k]==nil then
            local replacement=other[k]
            local accept=replacement~=nil
            if accept and node.max_string_bytes then accept=type(replacement)=="string" and #replacement<=node.max_string_bytes end
            if accept and node.min_string_bytes then accept=type(replacement)=="string" and #replacement>=node.min_string_bytes end
            if accept and node.only_shrink then accept=type(replacement)=="string" and type(v)=="string" and #replacement<#v end
            if accept then out[k]=replacement else out[k]=v end
        end
    end
    return out
end
return D
