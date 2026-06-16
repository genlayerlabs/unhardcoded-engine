-- llm_policy.sig — Σ_pol: the policy-algebra signature, as data.
--
-- Every IR operation appears here with its input sorts (`ins`) and output sort
-- (`out`). Operational sorts (S_OP) mark positions that take subterms; every
-- other sort is a parameter (a scalar value carried inline in the term).
-- AC/associative ops are declared `variadic` with their unit / absorbing
-- constants, so normalization (llm_policy.term) is signature-driven rather
-- than op-by-op code.
--
-- The signature is versioned and APPEND-ONLY within a major version (see
-- docs/SIGMA-POL.md §1.1): adding a symbol keeps the tag — existing terms stay
-- byte-identical and a host predating the op rejects it at admission (unknown
-- op) rather than diverging. Removing or retyping a symbol, or changing the
-- encoding/normal form, is a major bump that rotates the tag and every
-- identity — which is exactly why dropping the composite scorer atoms took the
-- tag from sigma-pol/v1 to v2. Data extensibility still lives in the field
-- schema (llm_policy.fields) — candidates may carry any declared field; the
-- operations never grow per-field. Terms over this signature are the IR:
-- plain arrays { op, arg1, ..., argn }, serializable, hashable, and
-- interpretable by any conforming host (llm_policy.interp is the reference).

local S = {}

S.VERSION = "sigma-pol/v2"

-- Operational sorts: positions of these sorts take subterms.
S.OP_SORTS = {
    Pred = true, Scorer = true, Selector = true, Xform = true,
    FailPlan = true, Policy = true,
}

-- Parameter sorts and how to validate their values (see llm_policy.term):
--   Num        finite number
--   Count      positive integer (>= 1); a bounded count, e.g. top_k's k
--   Rel        "lt"|"le"|"eq"|"ne"|"ge"|"gt"
--   NumField   declared field of sort Num (schema-checked)
--   BoolField  declared field of sort Bool (schema-checked)
--   Tier       tier name present in the schema's tier order
--   Family     model-family name (open namespace, string)
--   Capability capability name (open namespace, string)
--   ParamName  request parameter name (string)
--   Scalar     number | string | boolean
--   Sym        host-registered extension name (string)
--   Provenance claim source name (string)
--   FailReason error kind (string)
--   Action     flat record over the sequence vocabulary (sequence.ACTIONS)
--   Recipe     array of filter-directive steps (strings or flat records)
--   Chain      array of { provider=, model= } records

S.RELS = { lt = true, le = true, eq = true, ne = true, ge = true, gt = true }

S.ops = {
    -- Pred — boolean algebra over candidate observations -----------------
    top           = { out = "Pred", ins = {} },
    bot           = { out = "Pred", ins = {} },
    ["and"]       = { out = "Pred", variadic = "Pred", ac = true, unit = "top", absorb = "bot" },
    ["or"]        = { out = "Pred", variadic = "Pred", ac = true, unit = "bot", absorb = "top" },
    ["not"]       = { out = "Pred", ins = { "Pred" } },
    meets_req     = { out = "Pred", ins = {} },              -- the whole requirements block (deliberately coarse)
    scope_matches = { out = "Pred", ins = {} },
    is            = { out = "Pred", ins = { "BoolField" } }, -- boolean field observation
    cmp           = { out = "Pred", ins = { "NumField", "Rel", "Num" } },
    tier_eq       = { out = "Pred", ins = { "Tier" } },
    min_tier      = { out = "Pred", ins = { "Tier" } },
    family_eq     = { out = "Pred", ins = { "Family" } },    -- model-family identity (or-compose for a set)
    has_cap       = { out = "Pred", ins = { "Capability" } },

    -- Scorer — semimodule over Num; population-relative (normalize) ------
    zero          = { out = "Scorer", ins = {} },
    add           = { out = "Scorer", variadic = "Scorer", ac = true, unit = "zero" },
    scale         = { out = "Scorer", ins = { "Num", "Scorer" } },
    gate          = { out = "Scorer", ins = { "Pred", "Scorer" } },  -- demote (×0), don't drop
    neg           = { out = "Scorer", ins = { "Scorer" } },          -- s ↦ 1 - s
    normalize     = { out = "Scorer", ins = { "Scorer" } },          -- min-max over the population
    clamp         = { out = "Scorer", ins = { "Num", "Num", "Scorer" } },
    field         = { out = "Scorer", ins = { "NumField" } },
    lit           = { out = "Scorer", ins = { "Num" } },
    -- NOTE (sigma-pol/v2): the composite scorer atoms quality/speed/cost/
    -- partner/free_credit were REMOVED. They folded raw fields + request knobs
    -- (max_cost_usd, max_latency_ms, token estimates) into one opaque number
    -- with baked-in host defaults — not observables. Score on the raw fields
    -- instead: field("price_in"), field("latency_ms"), etc., with normalize/
    -- neg/scale/add. Their removal is what bumps v1 -> v2 (§1.1).

    -- Selector — scored population -> ordering (seed enters here) --------
    argmax        = { out = "Selector", ins = {} },
    ordered       = { out = "Selector", ins = {} },          -- keep input order
    sample        = { out = "Selector", ins = { "Num" } },   -- rank-geometric, temp (transcendental-free)
    chain         = { out = "Selector", ins = { "Chain" } }, -- greybox priority whitelist
    top_k         = { out = "Selector", ins = { "Count", "Selector" } }, -- order by inner, keep first k (k >= 1)

    -- Xform — monoid of request transforms -------------------------------
    id            = { out = "Xform", ins = {} },
    seq           = { out = "Xform", variadic = "Xform", assoc = true, unit = "id" },
    set_param     = { out = "Xform", ins = { "ParamName", "Scalar" } },
    inject_seed   = { out = "Xform", ins = { "ParamName" } },
    clamp_param   = { out = "Xform", ins = { "ParamName", "Num", "Num" } },
    jitter        = { out = "Xform", ins = { "ParamName", "Num" } },
    filter_text   = { out = "Xform", ins = { "Recipe" } },
    filter_image  = { out = "Xform", ins = { "Recipe" } },
    custom        = { out = "Xform", ins = { "Sym" } },
    when          = { out = "Xform", ins = { "Pred", "Xform" } },

    -- FailPlan — finite function FailReason -> Action ---------------------
    always        = { out = "FailPlan", ins = { "Action" } },
    override      = { out = "FailPlan", ins = { "FailPlan", "FailReason", "Action" } },

    -- Policy — the single constructor -------------------------------------
    -- (sigma-pol/v2) The Evidence slot and its whole sub-algebra (ev_zero/
    -- ev_add/ev_scale/decay/from_prov) were REMOVED. Evidence never affected
    -- the decision — the interpreter built the policy from filter/scorer/
    -- selector/xform/failplan and ignored the evidence term — and `from_prov`
    -- read the phantom `quality`/uncomputed claims. A policy is now five slots.
    policy        = { out = "Policy",
                      ins = { "Pred", "Scorer", "Selector", "Xform", "FailPlan" } },
}

return S
