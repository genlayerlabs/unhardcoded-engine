---
name: unhardcoded-engine-contribute
description: >-
  Extend the unhardcoded-engine (Σ_pol) policy algebra — add a filter predicate,
  a scorer, a selector, an Xform, a FailPlan action, or a catalog field; and do
  it without breaking the invariants that make the core trustworthy
  (determinism, append-only signature, canonical normal form, golden
  conformance). Load this skill when changing anything under llm_policy/, adding
  an operator, or touching term admission/normalization/encoding. To merely use
  or embed the engine, use unhardcoded-engine-use instead.
---

# Contributing to unhardcoded-engine (Σ_pol)

This repo **is the sealed core**: pure Lua, no I/O, no globals, no credentials.
Its value is that every host in every language computes the *same decision* from
the same inputs, and that a policy's fingerprint is a stable identity. Every
change is judged against that. Read `docs/SIGMA-POL.md` (the normative contract)
and `docs/POLICY_DESIGN.md` (the rationale) before extending anything.

## The architecture, by module

The pipeline for a policy-as-data (IR) term:

```
sig.lua       closed, versioned signature: op → { out = <sort>, ins = {<sorts>} }.  S.VERSION = "sigma-pol/v2".
term.lua      admission (check: sorts/arity/bounds/fields), normal form, deterministic encoding, fingerprint.
interp.lua    the default algebra: each op → a carrier function (the semantics).
fields.lua    the observation vocabulary + schema; hosts extend via config.fields.
elaborate.lua declarative profiles / DSL sugar → IR terms (lowering).
```

The closure DSL (`filter.lua`, `rank.lua`, `mutate.lua`, `sequence.lua`,
`policy.lua`) is the **local-only escape hatch** — kept working, but the IR is
the shipped, hashable, admitted form. `sequence.lua` also owns the `ACTIONS`
vocabulary; the orchestration loop and `handle_response` live in `llm_policy.lua`.

**Carrier shapes** (what your `interp.lua` entry returns):
- **Pred** → `fn(cand, ctx) -> bool, reason?` (reason string when it rejects).
- **Scorer** → **population-relative** `fn(pop, ctx) -> scores[], breakdowns[]?`
  (score the whole candidate set at once; this is what makes `normalize` meaningful).
- **Selector** → orders the population using the seed.
- **Xform** → `fn(request, cand, ctx) -> request'` (must not mutate in place).
- **FailPlan** → classifies `error_kind` → an `Action`.

## Adding an operator — the path

| You add a… | sig.lua | interp.lua | elaborate.lua | DSL verb | term.lua | fields.lua | seq/loop | test |
|---|---|---|---|---|---|---|---|---|
| Pred atom | ✅ entry | ✅ carrier | opt. sugar | opt. `filter.lua` | auto* | — | — | ✅ |
| Scorer | ✅ | ✅ (pop-relative) | opt. | opt. `rank.lua` | auto* | — | — | ✅ |
| Selector | ✅ | ✅ | opt. | opt. `rank.lua` | auto* | — | — | ✅ |
| Xform | ✅ | ✅ | opt. | opt. `mutate.lua` | auto* | — | — | ✅ |
| FailPlan action | — | — | — | — | — | — | ✅ `sequence.lua` ACTIONS + `handle_response` | ✅ |
| Catalog field | — | — | — | — | ✅ check | ✅ (or host `config.fields`) | — | ✅ |

`auto*` = scalar params (Num/Count/Rel/…) are validated by the generic arity/sort
check; you only touch `term.lua` when an operator needs custom admission (e.g. a
field reference that must exist in the schema, or a structured param).

**A new field is config-time, not a signature change.** Declaring
`config.fields.foo = { sort="Num", default=0, get=fn(cand,ctx) }` is enough; the
signature never grows per-field (that's the whole point — an open field
vocabulary over a closed op set). Core fields cannot be overridden.

## Invariants you must not break

1. **Two-runtime determinism.** Same `(policy, catalog, ctx, seed)` ⇒ identical
   selection under mlua, lupa, luerl, **bit-for-bit**. Use only
   correctly-rounded IEEE ops — **no transcendentals, no libm-dependent math, no
   `os`/`io`/globals, no wall-clock**. A carrier that reads anything outside its
   explicit `ctx` breaks parity.
2. **The signature is append-only within a major version.** `sigma-pol/v2` is a
   locked tag. *Adding* a new op is fine. *Changing the semantics, arity, or
   encoding* of an existing op rotates every policy fingerprint and breaks every
   stored identity/commitment — that requires a **major version bump**, never a
   silent edit. When in doubt, add a new op rather than mutate one.
3. **Normal form stays canonical.** AC ops flatten and sort by encoding, units
   drop, absorbing elements collapse, `not(not p)=p`, `seq` flattens, FailPlan
   collapses and sorts. Two terms that decide identically must encode
   identically — if your op has algebraic identities, put them in `term.lua`
   normalization or the fingerprint will over-count distinct-but-equal policies.
4. **Golden vectors replay bit-for-bit.** `tests/golden/sigma_pol_v2.json` is the
   language-neutral conformance set. A changed fingerprint or encoding there
   **without a version bump is a red flag** — it means you changed observable
   semantics. Regenerate deliberately, review the diff.
5. **Purity.** Verbs are pure functions of `ctx`; the impure orchestrator
   snapshots runtime state into `ctx` and does the I/O. Never call the host from
   a carrier.

## Testing

```bash
lua tests/run_lua.lua          # runs the full unit suite from repo root
```

- Add a unit test in the matching file: `tests/unit/ir_term.lua` (admission,
  normal form, encoding), `ir_interp.lua` (semantics), `policy_verbs.lua` /
  `declarative_policy.lua` (DSL + elaboration), `execute.lua` /
  `execute_step.lua` (orchestration + FailPlan actions), `flow_basic.lua` (Σ_flow),
  `parity.lua` (declarative-vs-IR equivalence).
- For a **user-facing** op, add a conformance vector to the golden set:
  ```bash
  lua tests/golden/gen_vectors.lua      # regenerates tests/golden/sigma_pol_v2.json
  ```
  Review the resulting diff — a fingerprint change on an *existing* vector means
  you touched semantics; stop and reconsider (see invariant 2).
- The genvm on-chain surface has its own pytest under `genvm/tests/`.

## Where to read more

- `docs/SIGMA-POL.md` — normative signature, sorts, numeric model, encoding, hashing (the contract).
- `docs/POLICY_DESIGN.md` — why the core is pure; the candidate object and the four verbs.
- `docs/SIGMA-FLOW.md` — the Σ_flow composition layer (`flow.lua`, `sequence.lua`).
- `docs/GENVM-LLM-POLICY.md` — the on-chain embedding and why deterministic diversity is the security property.
- The comments at the top of `llm_policy/sig.lua` — the append-only rule and the v2 removals, verbatim.
