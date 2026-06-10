-- Golden conformance vectors: replay tests/golden/sigma_pol_v1.json against
-- the reference implementation. A host porting Σ_pol to another language
-- replays the same file; agreement here + per-op tests = conformance (the
-- initiality argument, docs/SIGMA-POL.md §7). Regenerate with
-- tests/golden/gen_vectors.lua only on intentional (version-bumped) changes.

local t    = require("_assert")
local json = require("_json")
local ir   = require("llm_policy.ir")
local sequence = require("llm_policy.sequence")

local T = ir.term

local f = assert(io.open("tests/golden/sigma_pol_v1.json", "r"))
local doc = json.decode(f:read("a"))
f:close()

t.test("golden: file version matches the implementation", function()
    t.eq(doc.version, ir.VERSION)
    t.truthy(#doc.vectors >= 10, "vector set is non-trivial")
end)

local function near(a, b)
    return a == b or math.abs(a - b) <= 1e-12 * math.max(1, math.abs(a), math.abs(b))
end

local function deep_eq(a, b, path)
    if type(a) == "number" and type(b) == "number" then
        return near(a, b) or (path .. ": " .. a .. " ~= " .. b)
    end
    if type(a) ~= type(b) then return path .. ": type mismatch" end
    if type(a) ~= "table" then
        return a == b or (path .. ": " .. tostring(a) .. " ~= " .. tostring(b))
    end
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        local r = deep_eq(a[k], b[k], path .. "." .. tostring(k))
        if r ~= true then return r end
    end
    return true
end

for _, v in ipairs(doc.vectors) do
    t.test("golden: " .. v.name, function()
        local sort, err = T.check(v.term)
        t.eq(err, nil, "admission")
        t.eq(sort, v.expect.sort, "sort")
        local nf = T.normalize(v.term)
        t.eq(T.encode(nf), v.expect.encoding, "canonical encoding")
        t.eq(T.fingerprint(nf), v.expect.fingerprint, "fingerprint")

        if v.kind == "pred" then
            local p = ir.eval_sort(v.term)
            for i, case in ipairs(v.cases) do
                local ok, why = p(case.candidate, case.ctx)
                t.eq(ok and true or false, case.expect_ok, "case " .. i .. " verdict")
                if case.expect_ok == false then
                    t.eq(why, case.expect_reason, "case " .. i .. " reason")
                end
            end
        elseif v.kind == "policy" then
            local pol = ir.compile(v.term)
            local plan = pol.plan(v.candidates, v.ctx)
            t.eq(#plan.ordered, #v.expect.ordered, "survivor count")
            for i, pid in ipairs(v.expect.ordered) do
                t.eq(plan.ordered[i].candidate.provider_id, pid, "order @" .. i)
                t.truthy(near(plan.ordered[i].score, v.expect.scores[i]),
                    "score @" .. i .. ": " .. plan.ordered[i].score
                    .. " vs " .. v.expect.scores[i])
            end
            t.eq(#plan.rejected, #v.expect.rejected, "rejected count")
            for i, r in ipairs(v.expect.rejected) do
                t.eq(plan.rejected[i].provider, r.provider, "rejected provider @" .. i)
                t.eq(plan.rejected[i].reason, r.reason, "rejected reason @" .. i)
            end
        elseif v.kind == "xform" then
            local x = ir.eval_sort(v.term)
            local got = x(v.request, v.candidate, v.ctx)
            t.eq(deep_eq(got, v.expect.request, "request"), true, "transformed request")
        elseif v.kind == "failplan" then
            local fp = ir.eval_sort(v.term)
            for i, case in ipairs(v.expect.classified) do
                local r = deep_eq(sequence.classify(fp, case.kind), case.action,
                    "classify(" .. case.kind .. ")")
                t.eq(r, true, "classification @" .. i)
            end
        elseif v.kind == "evidence" then
            local e = ir.eval_sort(v.term)
            t.truthy(near(e(v.candidate, v.ctx), v.expect.value), "evidence value")
        end
    end)
end
