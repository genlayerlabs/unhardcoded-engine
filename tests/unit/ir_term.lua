-- Σ_pol terms: admission (check), normal forms (normalize), canonical
-- encoding (encode/fingerprint). See docs/SIGMA-POL.md.

local t = require("_assert")
local ir = require("llm_policy.ir")
local T  = ir.term

local function enc(x) return T.encode(T.normalize(x)) end

t.test("check: a well-formed policy term has sort Policy", function()
    local sort, err = T.check({ "policy",
        { "and", { "meets_req" }, { "cmp", "price_out", "le", 25 } },
        { "add", { "scale", 0.7, { "neg", { "normalize", { "field", "price_out" } } } },
                 { "scale", 0.3, { "field", "context" } } },
        { "argmax" },
        { "seq", { "filter_text", { "NFKC" } }, { "clamp_param", "temperature", 0, 1 } },
        { "override", { "always", { action = "next_candidate" } },
          "auth_error", { action = "disable_provider" } },
    })
    t.eq(err, nil, "no admission error")
    t.eq(sort, "Policy")
end)

-- unknown-op rejection is also the forward-compat guarantee of the
-- append-only signature (SIGMA-POL §1.1): an old host fails closed on a newer
-- op, it never silently diverges.
t.test("check: rejects unknown ops, bad arity, bad params", function()
    local sort, err = T.check({ "frobnicate" })
    t.falsy(sort); t.contains(err, "unknown op")

    sort, err = T.check({ "not" })
    t.falsy(sort); t.contains(err, "takes 1 argument")

    sort, err = T.check({ "cmp", "price_in", "lte", 5 })
    t.falsy(sort); t.contains(err, "relation")

    sort, err = T.check({ "cmp", "no_such_field", "le", 5 })
    t.falsy(sort); t.contains(err, "undeclared field")

    sort, err = T.check({ "cmp", "has_tee", "le", 5 })          -- Bool field in Num position
    t.falsy(sort); t.contains(err, "sort Bool")

    sort, err = T.check({ "is", "price_in" })                   -- Num field in Bool position
    t.falsy(sort); t.contains(err, "sort Num")

    sort, err = T.check({ "cmp", "price_in", "le", math.huge }) -- non-finite literal
    t.falsy(sort); t.contains(err, "finite")

    sort, err = T.check({ "min_tier", "platinum" })
    t.falsy(sort); t.contains(err, "unknown tier")

    sort, err = T.check({ "always", { action = "explode" } })
    t.falsy(sort); t.contains(err, "Action.action invalid")

    sort, err = T.check({ "and", { "meets_req" }, { "zero" } })  -- Scorer in a Pred slot
    t.falsy(sort); t.contains(err, "expected Pred")
end)

t.test("check: schema extensions admit declared fields only", function()
    local schema = ir.fields.schema{ extensions = {
        region_score = { sort = "Num", default = 0 },
    } }
    local sort = T.check({ "cmp", "region_score", "gt", 0.5 }, schema)
    t.eq(sort, "Pred", "extension field admitted")
    local s2, err = T.check({ "cmp", "region_score", "gt", 0.5 })
    t.falsy(s2, "default schema does not know it")
    t.contains(err, "undeclared field")
end)

t.test("check: family_eq admits a family name; or-composes into a set", function()
    t.eq(T.check({ "family_eq", "gpt-5.5" }), "Pred", "a family name admits")
    t.eq(T.check({ "or", { "family_eq", "gpt-5.5" }, { "family_eq", "claude-opus-4-8" } }),
         "Pred", "or of family_eq is the family-set filter")
    local sort, err = T.check({ "family_eq", 5 })             -- non-string family
    t.falsy(sort); t.contains(err, "string (Family)")
end)

t.test("check: top_k wraps an inner selector with a numeric k", function()
    t.eq(T.check({ "top_k", 3, { "argmax" } }), "Selector", "top_k(k, argmax) admits")
    t.eq(T.check({ "top_k", 5, { "sample", 0.5 } }), "Selector", "top_k over sample admits")
    local s1, e1 = T.check({ "top_k", 3 })                     -- missing inner selector
    t.falsy(s1); t.contains(e1, "argument")
    local s2, e2 = T.check({ "top_k", { "argmax" }, 3 })       -- args swapped: Count position gets a term
    t.falsy(s2)
    -- k is a Count (positive integer): a fractional/zero/negative k would make
    -- "the first k" implementation-defined across hosts, so admission rejects it.
    local s3, e3 = T.check({ "top_k", 2.5, { "argmax" } })
    t.falsy(s3); t.contains(e3, "Count")
    t.falsy(T.check({ "top_k", 0, { "argmax" } }), "k=0 is rejected")
    t.falsy(T.check({ "top_k", -1, { "argmax" } }), "negative k is rejected")
    t.eq(T.check({ "top_k", 2.0, { "argmax" } }), "Selector", "an integer-valued float admits")
end)

t.test("normalize: AC flatten + sort makes order irrelevant", function()
    local a = { "cmp", "price_in", "le", 5 }
    local b = { "is", "has_tee" }
    local c = { "meets_req" }
    t.eq(enc({ "and", a, { "and", b, c } }), enc({ "and", { "and", c, a }, b }),
        "and(a,and(b,c)) == and(and(c,a),b)")
    t.eq(T.fingerprint(T.normalize({ "and", a, b })),
         T.fingerprint(T.normalize({ "and", b, a })),
        "fingerprints agree across argument order")
end)

t.test("normalize: units, absorbing elements, involution", function()
    local p = { "is", "has_tee" }
    t.eq(enc({ "and", p, { "top" } }), enc(p), "top is the unit of and")
    t.eq(enc({ "or", p, { "bot" } }), enc(p), "bot is the unit of or")
    t.eq(enc({ "and", p, { "bot" } }), enc({ "bot" }), "bot absorbs and")
    t.eq(enc({ "or", p, { "top" } }), enc({ "top" }), "top absorbs or")
    t.eq(enc({ "not", { "not", p } }), enc(p), "double negation collapses")
    t.eq(enc({ "not", { "top" } }), enc({ "bot" }), "not(top) = bot")
end)

t.test("normalize: scorer semimodule laws (identities only, no 𝕍 arithmetic)", function()
    t.eq(enc({ "scale", 1, { "field", "context" } }), enc({ "field", "context" }), "scale(1) is identity")
    t.eq(enc({ "scale", 0, { "field", "context" } }), enc({ "zero" }), "scale(0) annihilates")
    t.eq(enc({ "add", { "field", "context" }, { "zero" } }), enc({ "field", "context" }), "zero is the unit of add")
    t.eq(enc({ "normalize", { "normalize", { "field", "price_in" } } }),
         enc({ "normalize", { "field", "price_in" } }), "normalize is idempotent")
    -- deliberately NOT fused: the normal form must not depend on the numeric
    -- model, so nested scales stay nested (already canonical)
    t.eq(enc({ "scale", 2, { "scale", 3, { "field", "context" } } }),
         T.encode({ "scale", 2, { "scale", 3, { "field", "context" } } }),
        "no float products in the normalizer")
    -- gate laws
    t.eq(enc({ "gate", { "top" }, { "field", "context" } }), enc({ "field", "context" }), "gate(top) is identity")
    t.eq(enc({ "gate", { "bot" }, { "field", "context" } }), enc({ "zero" }), "gate(bot) annihilates")
    t.eq(enc({ "gate", { "is", "has_tee" }, { "zero" } }), enc({ "zero" }), "gate of zero is zero")
end)

t.test("check: admission bounds reject pathological terms", function()
    local deep = { "field", "context" }
    for _ = 1, 100 do deep = { "neg", deep } end
    local sort, err = T.check(deep)
    t.falsy(sort); t.contains(err, "max depth")

    local wide = { "and" }
    for i = 1, 5000 do wide[i + 1] = { "top" } end
    sort, err = T.check(wide)
    t.falsy(sort); t.contains(err, "max size")
end)

t.test("normalize: seq is a monoid (flattens, keeps order, drops id)", function()
    local x = { "set_param", "max_tokens", 4096 }
    local y = { "filter_text", { "NFKC" } }
    t.eq(enc({ "seq", { "seq", x, { "id" } }, y }), enc({ "seq", x, y }),
        "nested seq flattens and id is dropped")
    local xy = enc({ "seq", x, y })
    local yx = enc({ "seq", y, x })
    t.truthy(xy ~= yx, "seq does NOT commute")
end)

t.test("normalize: FailPlan canonicalizes to base + sorted overrides, outer wins", function()
    local nc = { action = "next_candidate" }
    local ab = { action = "abort" }
    local dp = { action = "disable_provider" }
    -- outer override of rate_limit shadows the inner one
    local plan = { "override",
        { "override",
            { "override", { "always", nc }, "rate_limit", ab },
            "auth_error", dp },
        "rate_limit", dp }
    local canonical = { "override",
        { "override", { "always", nc }, "auth_error", dp },
        "rate_limit", dp }
    t.eq(enc(plan), enc(canonical), "outer override wins; reasons sorted")
    -- an override equal to the base is redundant
    t.eq(enc({ "override", { "always", nc }, "server_error", { action = "next_candidate" } }),
         enc({ "always", nc }), "override equal to base is dropped")
end)

t.test("encode: canonical, versioned, param tables key-sorted", function()
    local e = T.encode({ "always", { backoff_ms = 500, action = "retry_same" } })
    t.contains(e, ir.VERSION .. ":", "version prefix present")
    t.contains(e, '{"action":"retry_same","backoff_ms":500}', "record keys sorted")
    t.eq(T.encode({ "cmp", "price_in", "le", 5 }),
         T.encode({ "cmp", "price_in", "le", 5.0 }),
        "5 and 5.0 encode identically")
end)

t.test("check: chain entries are closed records (identity stays injective)", function()
    -- An extra key — worst case an array part — would make param_enc treat
    -- the entry as an array and DROP provider/model: two chains that select
    -- different providers would share one canonical encoding, hence one
    -- sha256 identity. Admission must reject what encoding cannot represent
    -- injectively.
    local sort, err = T.check({ "chain", { { provider = "p1", model = "m1" } } })
    t.eq(sort, "Selector", "clean chain admits: " .. tostring(err))

    sort, err = T.check({ "chain", { { provider = "p1", model = "m1", "smuggled" } } })
    t.falsy(sort, "array part in a chain entry is rejected")
    t.contains(err, "unknown key")

    sort, err = T.check({ "chain", { { provider = "p1", model = "m1", note = "x" } } })
    t.falsy(sort, "extra record key in a chain entry is rejected")
end)
