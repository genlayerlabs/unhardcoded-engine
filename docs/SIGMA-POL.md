# Σ_pol — the policy IR

Normative spec for `sigma-pol/v2`: the term language policies are written in,
its canonical encoding, and the reference semantics. A policy in this form is
**data** — serializable, hashable, admissible from untrusted callers — and any
conforming interpreter, in any language, computes the same decision from it.

> **v2** removes everything in v1 that did not denote an observable — the
> algebra composes over reals, never over phantoms (§1):
> - the five composite scorer atoms (`quality`/`speed`/`cost`/`partner`/
>   `free_credit`), which folded raw fields, request knobs and baked targets
>   into one opaque number — score on the raw fields instead (§5.2);
> - the `quality`/`quality_hint` **fields** — `quality` was never computed and
>   `quality_hint` is a hand-assigned number; neither is an observation;
> - the **Evidence** slot and its sub-algebra (`ev_zero`/`ev_add`/`ev_scale`/
>   `decay`/`from_prov`), which never affected the decision and read the
>   phantom `quality` — a policy is now **five slots**.
>
> Removing operations and a slot is a major bump (§1.1), so every v1 policy
> fingerprint rotates under v2.

The mathematical development (multi-sorted signature, term algebra,
initiality) lives outside this repo; this document pins the engineering
choices that make the uniqueness theorem actually hold. The reference
implementation is `llm_policy/sig.lua` (signature), `term.lua` (admission,
normal form, encoding), `fields.lua` (observation vocabulary), `interp.lua`
(reference interpreter 𝔖).

## 1. What is fixed, and where

**Admissibility criterion (denotational).** The algebra is maximally
expressive *over things that exist*. Every symbol must denote an observable
the host reports or measures (a price, a latency, a capability, a tier) or
compose such observables explicitly (`and`/`scale`/`add`/`normalize`/…). A
**composite that folds fields, request knobs and host-chosen targets into one
opaque number is not an observation** and is not an admissible symbol — express
it as explicit composition over fields instead. A caller cannot order a policy
by a quantity nobody observes; phantom symbols add the illusion of
expressiveness, not expressiveness. This is why v2 removed the composite scorer
atoms, the `quality` fields, and the Evidence sub-algebra (the header), and it
is the test every future op or field must pass before it enters the signature.

The uniqueness of the interpreter is relative to four commitments. Each lives
in exactly one place:

1. **The signature Σ_pol** — the operation set (`sig.lua`), **append-only
   within a major version**. *Adding* an operation (with its sorts) keeps the
   `sigma-pol/v1` tag: every existing term re-encodes byte-for-byte (the new
   op appears in none of them, and the version prefix is unchanged), and a
   host that predates the op rejects it at admission (`unknown op`, §7) rather
   than diverging — so no committed identity rotates and no decision forks.
   *Removing or retyping* an operation, or changing the encoding/normal form
   (§4), is a **major bump** (`sigma-pol/v1` → `/v2`): it rotates the tag and,
   with it, every identity. The operations never grow per-field — data
   extensibility lives in the observation vocabulary (item 2).
2. **The observation vocabulary** — the named fields through which a policy
   sees a candidate (`fields.lua`): sort, source, and **default when absent**.
   The candidate's representation is each host's business; the observation map
   is the contract. Hosts/configs may *declare* additional fields
   (`config.fields`); terms observing undeclared fields are rejected at
   admission.
3. **The numeric model 𝕍** — v1 pins IEEE-754 double, with deterministic
   evaluation order (AC children are evaluated in normal-form order), and the
   semantics use **only correctly-rounded operations** (+, −, ×, ÷,
   comparisons): no transcendentals anywhere in 𝔖, so conforming hosts agree
   bit-for-bit regardless of their libm (this is why `sample` is
   rank-geometric, §5.3, not a softmax). Fixed-point arithmetic is a future
   version bump, not a config knob.
4. **The environment** — the PRNG (`util.lcg`, MINSTD, part of this spec),
   and the `custom(sym)` registry (`config.customs`): host-blessed named
   transforms. A term references them by name; it can never inject behavior.

## 2. Terms

A term is a plain array: `{ op, arg1, ..., argn }`. Whether a position holds a
subterm or a parameter is decided by the signature, never by inspecting the
value. JSON arrays map 1:1 (`["cmp","price_out","le",25]`).

Sorts: `Pred`, `Scorer`, `Selector`, `Xform`, `FailPlan`,
`Policy` (operational — subterm positions); parameters are scalars or flat
records (`Num`, `Count`, `Rel`, `NumField`, `BoolField`, `Tier`, `Family`,
`Capability`, `ParamName`, `Scalar`, `Sym`, `Provenance`, `FailReason`,
`Action`, `Recipe`, `Chain`). See `sig.lua` for the full operation table.

An `Action` record has a closed verb (`action`, optional `then_action` ∈
`sequence.ACTIONS`) and typed core keys (`attempts`, `backoff_ms` —
number or array, `open_breaker_ms`); any further key is a host-interpreted
knob and must map to a finite number.

A complete policy:

```lua
{ "policy",
  { "and", { "meets_req" },                               -- Pred
           { "not", { "is", "breaker_open" } },
           { "cmp", "price_out", "le", 25 } },
  { "add", { "scale", 0.7, { "neg", { "normalize", { "field", "price_in" } } } },  -- Scorer
           { "scale", 0.3, { "normalize", { "field", "context" } } } },
  { "argmax" },                                           -- Selector
  { "seq", { "filter_text", { "NFKC" } },                 -- Xform
           { "clamp_param", "temperature", 0, 1 } },
  { "override", { "always", { action = "next_candidate" } },  -- FailPlan
    "auth_error", { action = "disable_provider" } },
}
```

Admission (`term.check`) is total and runs before anything executes: arity,
sorts, parameter validity, field declarations, and **resource bounds** —
depth ≤ 64, nodes ≤ 4096 (`term.LIMITS`, part of the spec) — so a hostile
term is rejected before recursion can exhaust the validator. Terms are finite
trees; evaluation cost is O(|term|); there is no symbol for I/O, loops, or
effects.

## 3. Observation vocabulary (core)

| field | sort | source | default |
|---|---|---|---|
| `price_in`, `price_out` | Num | state EMA, else catalog | **+inf** |
| `latency_ms` | Num | state EMA | **+inf** |
| `tok_s` | Num | state EMA | 0 |
| `success_rate` | Num | state EMA | 1 |
| `credits` | Num | state | 0 |
| `context` | Num | catalog capabilities | 0 |
| `has_tee`, `no_log` | Bool | catalog | false |
| `breaker_open`, `disabled` | Bool | state | false |

Defaults are conservative by design: a candidate with no declared price does
**not** pass a price ceiling (the legacy declarative gate read missing as 0;
the IR pins the strict reading). Tier order defaults to
`fallback < marketplace < partner` and is declarable (`config.tier_order`).

The categorical candidate attributes `tier` (`tier_eq`, `min_tier`),
`model_family` (`family_eq`) and `provider_id` (`provider_eq`) are observed
directly off the candidate, not through the Num/Bool field schema — they carry
no numeric default and need no declaration. `family_eq` is the single-family
identity test; a *set* of families is the algebra's `or` of `family_eq` (the
`family_in` surface sugar lowers to exactly that), so "the cheapest among
{A, B, C}" is `or(family_eq A, family_eq B, family_eq C)` as the filter with a
`neg(normalize(field("price_in")))` scorer.

`provider_eq` is the same identity test over the provider id, for routing by
*who serves* rather than *what model*: restrict to a set of providers with
`or(provider_eq A, provider_eq B)` (sugar: `provider_in`), or disable one with
`not(provider_eq X)` (sugar: `provider_not_in`) — e.g. drop a marketplace
provider while keeping the rest of the catalog.

`served_by_eq` is the finer identity test over the *executed route* — the
marketplace peer that serves a candidate, or the provider itself for a direct
route (the same notion the engine reports as `chosen.served_by`). It lets a
policy route by *which peer* rather than just *which provider*: pin to a set of
peers with `or(served_by_eq A, served_by_eq B)` (sugar: `served_by_in`), or
exclude one with `not(served_by_eq X)` (sugar: `served_by_not_in`). `provider_eq`
groups every peer of a marketplace provider together; `served_by_eq` addresses
one peer within it.

### 3.1 Population-relative selection lives in the data, not the ops

A candidate's standing *relative to a population* — "in the top 5 by an
intelligence benchmark", "cheapest decile" — is **host-computed data, not a
term operation**. The host ranks its catalog (a deterministic fact of the
catalog, recomputed when the catalog changes, never per call) and exposes the
result as a declared `Num` field (`config.fields`), e.g. `bench_a_rank`. The
algebra then observes it with the ordinary per-candidate `cmp`:

- "top 5 by A" is `cmp("bench_a_rank", "le", 5)` — a plain, local Pred.
- The **intersection of independent shortlists** is just their `and`:
  `and(cmp("bench_a_rank","le",5), cmp("bench_b_rank","le",5),
  tier_eq("partner"), cmp("price_in","le",X))`, then ranked by a
  `neg(normalize(field("price_in")))` scorer for "the cheapest of the survivors".

This is deliberate. A predicate that ranked the *live* population itself would
be the algebra's only non-local Pred: its verdict on a candidate would depend
on which other candidates survived earlier host-side filtering (breakers,
disabled), so the same `(policy, ctx)` could decide differently across hosts —
the one thing the cross-host determinism property (§1, item 3) forbids. Keeping
the ranking in the catalog (data) keeps every Pred local and every decision
reproducible: expressiveness grows through the field vocabulary, not through a
population-relative op.

## 4. Normal form and identity

`term.normalize` applies the algebra's equations: AC ops (`and`, `or`, `add`)
flatten, drop units, collapse on absorbing elements, and sort
children by canonical encoding; `seq` flattens and drops `id` (order kept);
`not` is involutive; `scale(1)` is identity, `scale(0)` annihilates;
`gate(top,·)` is identity, `gate(bot,·)` and `gate(·,zero)` annihilate;
`normalize` is idempotent; a `FailPlan` collapses to `always(base)` plus
overrides sorted by reason (outer wins, redundant dropped).

The normalizer performs **no arithmetic in 𝕍**: nested scales stay nested
(`scale(a, scale(b, s))` is already canonical) and identities use only exact
comparisons against 0 and 1. The normal form — and therefore the hash — is
independent of the numeric model; moving 𝕍 to fixed-point changes decisions,
not identities.

`term.encode(normalize(t))` is the canonical, version-prefixed string.
**Policy identity = sha256 of that string**, computed host-side (the core
stays dependency-free). `term.fingerprint` is only a cache key.

### 4.1 Numeric encoding grammar (normative)

The rendering of a number parameter is part of the encoding spec, NOT an
implementation detail — two conforming hosts must render every admitted
number to identical bytes, regardless of language or libc:

- `-0` encodes as `0`.
- An integral value with `|v| ≤ 2^53` encodes in fixed notation, no
  fractional part, no exponent (`5`, not `5.0` or `5e0`); a leading `-`
  for negatives.
- Any other value encodes as C99 `%.17g` **with the exponent constrained
  to the form** `e±dd…` — lowercase `e`, sign always present, at least
  two digits zero-padded to two, more only when the exponent needs them
  (`1.0000000000000001e-05`, `2.5000000000000002e-10`, `1e+100`; never
  `e-5`, `e-010`, or `E-05`). Hosts whose printf pads to three digits
  (pre-C99 MSVC runtimes) must normalize; hosts without C formatting
  must reproduce these exact bytes.
- NaN and ±infinity are not representable: admission (`check`) rejects
  them before encoding is reached.

The golden vectors include exponent-form numbers; a host that delegates
rendering to a non-conforming printf will fail conformance replay rather
than silently fork the identity space.

## 5. Reference semantics (𝔖)

`interp.eval(term, alg)` is the fold; `interp.default_algebra(opts)` is 𝔖,
built over the existing pure verbs. Carriers:

| sort | carrier |
|---|---|
| Pred | `fn(cand, ctx) -> true \| (false, reason)` |
| Scorer | `fn(pop, ctx) -> { score... }` — population-relative (`normalize` requires it) |
| Selector | `fn(scored, ctx) -> ordered scored` — returns the full ordering (the failover sequence consumes it); seed enters here |
| Xform | `fn(req, cand, ctx) -> req'` |
| FailPlan | retry table `{ [reason] = Action }`, base under `unknown` |
| Policy | the engine's Policy object |

Scorers may return a second value (per-candidate named-atom breakdowns); it
feeds traces and is **not** part of the normative semantics.

Two deliberate differences from the legacy verbs:

- IR selectors do **not** silently zero breaker-open candidates inside the
  selector; demotion is written in the policy itself with
  `gate(not(is("breaker_open")), scorer)` — demote to score 0, keep as last
  resort — or exclusion with the same Pred in the filter. The algebra hides
  nothing (the legacy lowering states the gate explicitly).
- `jitter` salts its PRNG substream **per parameter name**, so two jittered
  parameters draw from independent, deterministic streams (the legacy
  map-based jitter drew sequentially in `pairs()` order, which is not
  specified across implementations).

### 5.1 `meets_req` — exact semantics

`meets_req` checks the whole `ctx.request.requirements` block against the
candidate. It is deliberately the one coarse primitive (the caller's
requirement vocabulary evolves without signature changes), so its semantics
are pinned **exhaustively** here; reference: `filter.lua F.requirements()`.
In evaluation order — the first failure is the rejection reason:

1. **Derived needs.** `needs` = the set in `requirements.needs`, plus
   `vision` if `request.images` is a non-empty list, plus `tools` if
   `request.tools` is a non-empty list, plus `json_mode` if
   `request.response_format.type == "json_object"`. For each need with a
   capability mapping (`tools→supports_tools`, `vision→supports_vision`,
   `json_mode→supports_json_mode`, `seed→supports_seed`), the candidate's
   capability flag must be truthy → else `missing_capability:<need>`.
   Needs without a mapping are ignored.
2. `min_context`: `capabilities.context` (default 0) `< min_context` →
   `min_context`.
3. `model_family`: candidate's family differs → `model_family`.
4. `tier`: candidate's tier differs → `tier`.
5. `privacy == "tee_required"`: candidate lacks `has_tee` → `tee_required`.
6. `privacy == "no_log"`: candidate has neither `no_log` nor `has_tee` →
   `no_log`.
7. `min_tok_s`: the state EMA `ema_tok_s` is absent **or** `< min_tok_s` →
   `min_tok_s` (no observation fails closed).
   *(v2: `min_quality` removed with the `quality` field — gate on a real
   observable instead.)*

### 5.2 Named scorers — REMOVED in v2

v1 carried five composite scorer atoms (`quality`, `speed`, `cost`,
`free_credit`, `partner`) — pointwise lifts of pinned formulas that folded raw
fields and request-side knobs (`max_latency_ms`, `max_cost_usd`,
`estimated_*_tokens`) into one number with baked-in defaults. **They were
removed in `sigma-pol/v2`** (§1): a composite that hides which fields it reads
and bakes host-chosen targets into the language is not an observable. The
defaults were normative, so the atoms were deterministic across conforming
hosts — the defect is not divergence but **opacity**: the term ranks by a
quantity the author never sees through. Note also that `cost`/`speed` read
request-side knobs, not just the candidate; v2's scorers observe the candidate
only, so "cheapest for my estimated token load" is no longer a scorer — gate
spend with a `cmp` ceiling.

Score on the **raw fields** instead, explicitly:

- "cheaper is better" — `neg(normalize(field("price_in")))` (or `price_out`).
- "faster is better" — `neg(normalize(field("latency_ms")))`.
- "more headroom" — `normalize(field("context"))`; "more reliable" —
  `field("success_rate")`.
- spend limits — a hard `cmp("price_out","le",X)` ceiling in the filter, never a
  scorer (a scorer ranks softly; only `cmp` gates). Recall the `price_in/out`
  fields default to **+inf**, so a missing price fails a ceiling — conservative
  by design (§3).

### 5.3 `sample` — exact semantics

`sample(temp)` is **rank-geometric**, not a softmax: `exp()` is a libm
transcendental, unspecified by IEEE-754, and a last-ulp disagreement between
two hosts' libms could flip a sampled pick — unacceptable for reproducible
greybox divergence. The pinned algorithm uses only correctly-rounded ops:

1. Order candidates by (score descending, input order on ties) — exactly the
   `argmax` ordering.
2. Let `t = max(temp, 0)` and `q = t / (t + 1)`. Assign weights by **initial
   rank**: `w₁ = 1`, `wᵢ₊₁ = wᵢ · q` (iterated multiplication, never `pow`).
3. Sample without replacement, proportional to the fixed initial weights:
   repeatedly draw `r = rng() · Σw` over the remaining pool (summed in pool
   order), pick the first candidate whose cumulative weight reaches `r`,
   remove it. `rng` is the pinned LCG seeded with `ctx.seed or 0`.

Weights depend on ranks only, not score gaps (scale-invariant — score units
are arbitrary anyway). `temp = 0` reproduces the argmax order exactly;
`temp → ∞` approaches uniform. The legacy closure-path `R.softmax_sample`
keeps the old exp-based behavior and is local-only, like everything on that
path.

### 5.4 `top_k` — shortlisting

`top_k(k, inner)` runs the inner Selector, then keeps only the first `k` of the
resulting order (a no-op when `k ≥ #pool`). `k` is of sort `Count` — a positive
integer; a non-integer, zero, or negative `k` is rejected at admission, so "the
first `k`" is never implementation-defined (no float truncation, no
negative-index slicing for hosts to diverge on). Since a Selector returns the whole
ordering and the engine consumes it as the failover sequence, this bounds how
many candidates a call may try — "the 3 fastest" is `top_k(3, argmax)` over a
speed Scorer; "the 5 best on benchmarks" is `top_k(5, argmax)` over a Scorer
that sums the benchmark fields. It composes over any inner Selector (e.g.
`top_k(3, sample(t))` shortlists a seeded draw).

## 6. Using it

```lua
local router = require("llm_policy")

-- per-call: the policy arrives with the contract, as data
router.execute({ prompt = "...", policy_ir = <term> })

-- pinned in a profile
profiles.edge = { policy_ir = <term> }

-- programmatic
local pol = router.ir.compile(<term>, { schema = ..., customs = ... })
```

Admission pipeline: `check → normalize → eval`. The compiled policy carries
`.term` (normal form) and `.fingerprint` (also surfaced as
`trace.policy_fingerprint`); hosts should cache compiled policies by identity
hash.

**There is one policy language.** Declarative profiles are lowered through
`llm_policy.elaborate` and compile as IR — every profile gets a canonical
form and an identity. The single exception is a profile carrying Lua
closures (custom-fn verbs): it compiles legacy-style, has no hash
(`policy_fingerprint = nil`), and is local-only — never admissible over the
wire. The lowering states what the legacy selectors did silently: the scorer
is wrapped in `gate(not(is("breaker_open")), ·)`.

**Host envelope.** `config.policy_envelope` is a Pred term (checked at init)
that the router ∧-s onto every per-call `policy_ir` via
`ir.constrain(policy_term, envelope_pred)`: callers can narrow the host's
invariants, never widen them. Composition is the algebra's `∧`, not a
mechanism:

```lua
policy_envelope = { "and", { "min_tier", "marketplace" },
                           { "cmp", "price_out", "le", 50 } }
```

## 7. Conformance

Initiality reduces conformance to a finite checklist: two implementations that
agree on every operation of Σ_pol (and share the vocabulary, 𝕍, PRNG, and
encoding above) agree on every term, by structural induction. The unit tests
in `tests/unit/ir_*.lua` are organized per-operation for exactly this reason;
a host porting the interpreter ports the checklist. A host implementing a
*subset* of the op set is conforming on that subset: by append-only (§1.1)
the only cross-host disagreement an extension can introduce is a term using an
op the host lacks, which it rejects at admission (`unknown op`) — a refusal,
never a divergent decision.

The executable half is **`tests/golden/sigma_pol_v2.json`**: language-neutral
vectors covering canonical encodings (including float formatting and AC
sorting), fingerprints, Pred verdicts with reasons, full policy decisions
(ordered/scores/rejected), seeded sampling, seeded Xforms, and FailPlan
classification. A conforming host replays the file and must
reproduce everything bit-for-bit (scores within 1e-12). Reference runner:
`tests/unit/ir_golden.lua`. Regenerating with `tests/golden/gen_vectors.lua`
must be **additive** outside a major bump: an append-only signature change
adds vectors for the new op and leaves every existing vector byte-stable;
editing an existing encoding is a §4 change and therefore a major bump.
