-- llm_policy.sig — Σ_pol: the policy-algebra signature, as data.
--
-- Every IR operation appears here with its input sorts (`ins`) and output sort
-- (`out`). Operational sorts (S_OP) mark positions that take subterms; every
-- other sort is a parameter (a scalar value carried inline in the term).
-- AC/associative ops are declared `variadic` with their unit / absorbing
-- constants, so normalization (llm_policy.term) is signature-driven rather
-- than op-by-op code.
--
-- The signature is CLOSED and versioned: adding, removing, or retyping a
-- symbol is a version bump (see docs/SIGMA-POL.md). Data extensibility lives
-- in the field schema (llm_policy.fields) — candidates may carry any declared
-- field; the operations never grow per-field. Terms over this signature are
-- the IR: plain arrays { op, arg1, ..., argn }, serializable, hashable, and
-- interpretable by any conforming host (llm_policy.interp is the reference).

local S = {}

S.VERSION = "sigma-pol/v1"

-- Operational sorts: positions of these sorts take subterms.
S.OP_SORTS = {
    Pred = true, Scorer = true, Selector = true, Xform = true,
    FailPlan = true, Evidence = true, Policy = true,
}

-- Parameter sorts and how to validate their values (see llm_policy.term):
--   Num        finite number
--   Rel        "lt"|"le"|"eq"|"ne"|"ge"|"gt"
--   NumField   declared field of sort Num (schema-checked)
--   BoolField  declared field of sort Bool (schema-checked)
--   Tier       tier name present in the schema's tier order
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
    quality       = { out = "Scorer", ins = {} },
    speed         = { out = "Scorer", ins = {} },
    cost          = { out = "Scorer", ins = {} },
    free_credit   = { out = "Scorer", ins = {} },
    partner       = { out = "Scorer", ins = {} },

    -- Selector — scored population -> ordering (seed enters here) --------
    argmax        = { out = "Selector", ins = {} },
    ordered       = { out = "Selector", ins = {} },          -- keep input order
    sample        = { out = "Selector", ins = { "Num" } },   -- rank-geometric, temp (transcendental-free)
    chain         = { out = "Selector", ins = { "Chain" } }, -- greybox priority whitelist

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

    -- Evidence — provisional semimodule (claims by provenance) -----------
    ev_zero       = { out = "Evidence", ins = {} },
    ev_add        = { out = "Evidence", variadic = "Evidence", ac = true, unit = "ev_zero" },
    ev_scale      = { out = "Evidence", ins = { "Num", "Evidence" } },
    decay         = { out = "Evidence", ins = { "Num", "Evidence" } },
    from_prov     = { out = "Evidence", ins = { "Provenance" } },

    -- Policy — the single constructor -------------------------------------
    policy        = { out = "Policy",
                      ins = { "Evidence", "Pred", "Scorer", "Selector", "Xform", "FailPlan" } },
}

return S
