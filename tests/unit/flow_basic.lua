-- Σ_flow basics: admission, label-independent identity, and the reference
-- driver over a mixture-of-agents fusion (two drafters -> one synthesizer).

local t = require("_assert")
local F = require("llm_policy.flow")

-- a minimal but complete Σ_pol Policy term (balanced-ish), reused per node
local function POLICY()
    return { "policy",
        { "meets_req" },
        { "field", "context" },
        { "argmax" },
        { "id" },
        { "always", { action = "next_candidate" } },
    }
end

-- mixture-of-agents: u -> {a, b} -> f -> out
local function MOA(ids)
    ids = ids or { u = "u", a = "a", b = "b", f = "f", out = "out" }
    local n = {}
    n[ids.u]   = { kind = "input" }
    n[ids.a]   = { kind = "llm", system = "Answer concisely.",          policy = POLICY(), inputs = { ids.u } }
    n[ids.b]   = { kind = "llm", system = "Answer rigorously, show steps.", policy = POLICY(), inputs = { ids.u } }
    n[ids.f]   = { kind = "llm", system = "Synthesize the single best answer from the drafts.",
                   policy = POLICY(), inputs = { ids.a, ids.b }, template = "Draft A:\n$1\n\nDraft B:\n$2" }
    n[ids.out] = { kind = "output", inputs = { ids.f } }
    return { "flow", n }
end

t.test("a well-formed fusion is admitted", function()
    t.truthy(F.check(MOA()))
end)

t.test("normalize is idempotent and label-independent", function()
    local f1 = F.normalize(MOA())
    t.eq(F.encode(F.normalize(f1)), F.encode(f1), "normalize idempotent")

    -- the same graph with different node labels has the same identity
    local f2 = F.normalize(MOA({ u = "start", a = "left", b = "right", f = "join", out = "end" }))
    t.eq(F.encode(f2), F.encode(f1), "identity is independent of node labels")

    -- the canonical encoding nests Σ_pol policy bytes and is version-prefixed
    t.contains(F.encode(f1), "sigma-flow/v1:")
    t.contains(F.encode(f1), "sigma-pol/v2:")   -- nested policy bytes are v2
end)

t.test("swapping the two drafters' system prompts changes identity", function()
    local swapped = MOA()
    swapped[2].a.system, swapped[2].b.system = swapped[2].b.system, swapped[2].a.system
    t.truthy(F.encode(F.normalize(swapped)) ~= F.encode(F.normalize(MOA())),
        "different fusions get different identities")
end)

t.test("the reference driver schedules the DAG and assembles via template", function()
    local seen = {}
    local out, trace = F.run(MOA(), {
        input = "What is 17 * 23?",
        run_node = function(node, prompt)
            seen[#seen + 1] = { system = node.system, prompt = prompt }
            if node.system:find("Synthesize") then return "FINAL: 391" end
            return node.system:find("concisely") and "391" or "17*23 = 391 (steps...)"
        end,
    })
    t.eq(out, "FINAL: 391", "the output node returns the synthesizer's answer")
    t.eq(#seen, 3, "three llm nodes ran")
    -- the synthesizer saw both drafts assembled by its template
    local synth = seen[3]
    t.contains(synth.prompt, "Draft A:\n391")
    t.contains(synth.prompt, "Draft B:\n17*23 = 391")
    t.eq(#trace, 3, "trace records each llm node")
end)

t.test("admission rejects malformed flows", function()
    -- a cycle (f feeds back into a)
    local cyc = MOA()
    cyc[2].a.inputs = { "u", "f" }
    local ok, err = F.check(cyc)
    t.falsy(ok); t.contains(err, "cycle")

    -- two input nodes
    local two_in = MOA()
    two_in[2].b = { kind = "input" }
    local ok2, err2 = F.check(two_in)
    t.falsy(ok2); t.contains(err2, "exactly one input")

    -- a dangling node not on any input->output path
    local dangle = MOA()
    dangle[2].z = { kind = "llm", system = "orphan", policy = POLICY(), inputs = { "u" } }
    local ok3, err3 = F.check(dangle)
    t.falsy(ok3); t.contains(err3, "path input -> output")
end)
