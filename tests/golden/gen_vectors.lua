-- Golden-vector generator for sigma-pol/v2 conformance.
--
-- Builds the vector inputs, computes every expectation with the REFERENCE
-- implementation (this repo), and writes tests/golden/sigma_pol_v2.json.
-- The vectors are the executable spec: a host implementing Σ_pol in any
-- language replays the same JSON and must reproduce encoding, fingerprint,
-- and decisions bit-for-bit (scores within 1e-12).
--
-- Regenerate from repo root after any INTENTIONAL semantic change (which is
-- a version bump — see docs/SIGMA-POL.md):
--   lua tests/golden/gen_vectors.lua

package.path = package.path .. ";./?.lua;./tests/unit/?.lua"

local ir   = require("llm_policy.ir")
local json = require("_json")

local T = ir.term

local OUT = "tests/golden/sigma_pol_v2.json"

-- ---- shared fixtures ---------------------------------------------------------

local function cand(over)
    local c = {
        provider_id = "p1", model_family = "m1", served_model_id = "m1",
        capabilities = { context = 8000 }, quality_hint = 0.7,
        tier = "partner", base_url = "http://p1", api_kind = "openai_compatible",
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local POP = {
    cand{},
    cand{ provider_id = "p2", quality_hint = 0.9, tier = "marketplace" },
    cand{ provider_id = "p3", quality_hint = 0.4, tier = "fallback" },
}

local CTX = {
    request = { requirements = {} },
    state = {
        ema = { ["p1|m1"] = { price_in = 3, price_out = 12, last_quality_eval = 0.85 } },
        breakers = { p2 = true },
    },
    now_ms = 0,
    seed = 42,
}

-- ---- vector definitions -------------------------------------------------------

local VECTORS = {}

local function add(v) VECTORS[#VECTORS + 1] = v end

-- 1. canonical encoding: AC sorting makes argument order irrelevant
add{ name = "encoding-ac-sorting", kind = "encoding",
     term = { "and", { "meets_req" }, { "is", "has_tee" }, { "cmp", "price_in", "le", 5 } } }

-- 2. canonical number formatting (%.17g for non-integers)
add{ name = "encoding-number-format", kind = "encoding",
     term = { "and", { "cmp", "context", "ge", 0.1 }, { "cmp", "context", "ge", 4000 } } }

-- 2b. exponent-form numbers: the spec's §4.1 grammar (e±dd, C99 two-digit
-- minimum). A host whose printf pads exponents to three digits (or renders
-- shortest-round-trip instead of %.17g) forks the identity space — this
-- vector makes that a conformance failure instead of a silent divergence.
add{ name = "encoding-number-exponent-form", kind = "encoding",
     term = { "and",
         { "cmp", "context", "ge", 1e-05 },
         { "cmp", "price_out",    "le", 2.5e-10 },
         { "cmp", "context",      "le", 1e+100 } } }

-- 3. FailPlan normal form: outer override wins, reasons sorted, redundant dropped
add{ name = "encoding-failplan-canonical", kind = "encoding",
     term = { "override",
         { "override",
             { "override", { "always", { action = "next_candidate" } },
               "rate_limit", { action = "abort" } },
             "auth_error", { action = "disable_provider" } },
         "rate_limit", { action = "disable_provider" } } }

-- 4. Pred semantics incl. the pinned default: missing price = +inf
add{ name = "pred-price-ceiling", kind = "pred",
     term = { "cmp", "price_in", "le", 5 },
     cases = {
         { candidate = cand{}, ctx = { request = {}, now_ms = 0 },
           note = "no price anywhere -> +inf -> fails" },
         { candidate = cand{}, ctx = CTX, note = "EMA price 3 -> passes" },
         { candidate = cand{ provider_id = "px", price_in = 4 },
           ctx = { request = {}, now_ms = 0 }, note = "catalog price 4 -> passes" },
     } }

-- 5. Pred: boolean structure and tier order
add{ name = "pred-structure", kind = "pred",
     term = { "and", { "min_tier", "marketplace" }, { "not", { "is", "breaker_open" } } },
     cases = {
         { candidate = POP[1], ctx = CTX, note = "partner, breaker closed" },
         { candidate = POP[2], ctx = CTX, note = "marketplace but breaker open" },
         { candidate = POP[3], ctx = CTX, note = "fallback < marketplace" },
     } }

-- 5b. Pred: model-family set membership — the family_in lowering (or of
-- family_eq). The cheapest-among-{A,B,C} use case rests on this predicate.
add{ name = "pred-family-set", kind = "pred",
     term = { "or", { "family_eq", "gpt-5.5" }, { "family_eq", "claude-opus-4-8" } },
     cases = {
         { candidate = cand{ model_family = "gpt-5.5" }, ctx = CTX, note = "in the set" },
         { candidate = cand{ model_family = "claude-opus-4-8" }, ctx = CTX, note = "in the set" },
         { candidate = cand{ model_family = "gemini-3.1-pro" }, ctx = CTX,
           note = "not in the set -> or fails" },
     } }

-- 6. Policy decision: argmax over a gated, weighted scorer
add{ name = "policy-argmax-gate", kind = "policy",
     term = { "policy",
         { "min_tier", "marketplace" },
         { "gate", { "not", { "is", "breaker_open" } },
           { "add", { "scale", 0.6, { "field", "context" } },
                    { "scale", 0.4, { "neg", { "normalize", { "field", "price_in" } } } } } },
         { "argmax" }, { "id" },
         { "always", { action = "next_candidate" } } },
     candidates = POP, ctx = CTX }

-- 7. Policy decision: seeded softmax sample
add{ name = "policy-sample-seeded", kind = "policy",
     term = { "policy",
         { "top" }, { "field", "context" },
         { "sample", 0.5 }, { "id" },
         { "always", { action = "next_candidate" } } },
     candidates = POP, ctx = CTX }

-- 8. Policy decision: population-relative normalize
add{ name = "policy-normalize", kind = "policy",
     term = { "policy",
         { "top" }, { "normalize", { "field", "context" } },
         { "argmax" }, { "id" },
         { "always", { action = "next_candidate" } } },
     candidates = POP, ctx = { request = { requirements = {} }, now_ms = 0 } }

-- 8b. Policy decision: top_k shortlists to k after the inner selector orders
add{ name = "policy-top-k", kind = "policy",
     term = { "policy",
         { "top" }, { "field", "context" },
         { "top_k", 2, { "argmax" } }, { "id" },
         { "always", { action = "next_candidate" } } },
     candidates = POP, ctx = { request = { requirements = {} }, now_ms = 0 } }

-- 9. Xform: params, seed injection, clamping, per-param seeded jitter, directive
add{ name = "xform-seq-seeded", kind = "xform",
     term = { "seq",
         { "set_param", "max_tokens", 4096 },
         { "inject_seed", "seed" },
         { "clamp_param", "temperature", 0, 1 },
         { "jitter", "top_p", 0.1 },
         { "filter_text", { "NFKC", "RmZeroWidth" } } },
     request = { temperature = 1.7, top_p = 0.9 },
     candidate = POP[1], ctx = CTX }

-- 10. FailPlan classification through the engine vocabulary
add{ name = "failplan-classify", kind = "failplan",
     term = { "override",
         { "override", { "always", { action = "next_candidate" } },
           "auth_error", { action = "disable_provider" } },
         "server_error", { action = "retry_same", attempts = 2, backoff_ms = 500 } },
     cases = { "auth_error", "server_error", "rate_limit" } }

-- ---- compute expectations with the reference implementation --------------------

local sequence = require("llm_policy.sequence")

for _, v in ipairs(VECTORS) do
    local sort, err = T.check(v.term)
    assert(sort, (v.name or "?") .. ": " .. tostring(err))
    local nf = T.normalize(v.term)
    v.expect = {
        sort        = sort,
        encoding    = T.encode(nf),
        fingerprint = T.fingerprint(nf),
    }

    if v.kind == "pred" then
        local p = ir.eval_sort(v.term)
        for _, case in ipairs(v.cases) do
            local ok, why = p(case.candidate, case.ctx)
            case.expect_ok = ok and true or false
            case.expect_reason = why
        end
    elseif v.kind == "policy" then
        local pol = ir.compile(v.term)
        local plan = pol.plan(v.candidates, v.ctx)
        local ordered, scores = {}, {}
        for i, e in ipairs(plan.ordered) do
            ordered[i] = e.candidate.provider_id
            scores[i]  = e.score
        end
        local rejected = {}
        for i, r in ipairs(plan.rejected) do
            rejected[i] = { provider = r.provider, reason = r.reason }
        end
        v.expect.ordered  = ordered
        v.expect.scores   = scores
        v.expect.rejected = rejected
    elseif v.kind == "xform" then
        local x = ir.eval_sort(v.term)
        v.expect.request = x(v.request, v.candidate, v.ctx)
    elseif v.kind == "failplan" then
        local fp = ir.eval_sort(v.term)
        local out = {}
        for i, kind in ipairs(v.cases) do
            out[i] = { kind = kind, action = sequence.classify(fp, kind) }
        end
        v.expect.classified = out
    end
end

-- ---- write ---------------------------------------------------------------------

local doc = { version = ir.VERSION, vectors = VECTORS }
local parts = { '{"version":' .. json.encode(doc.version) .. ',"vectors":[' }
for i, v in ipairs(VECTORS) do
    parts[#parts + 1] = json.encode(v) .. (i < #VECTORS and "," or "")
end
parts[#parts + 1] = "]}"

local f = assert(io.open(OUT, "w"))
f:write(table.concat(parts, "\n"), "\n")
f:close()
print("wrote " .. OUT .. " (" .. #VECTORS .. " vectors)")
