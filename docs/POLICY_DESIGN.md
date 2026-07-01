# llm_policy — design

> **Status:** implemented (R2 + Σ_pol IR). Defines the core `llm_policy`
> package — the **candidate object** and the **policy algebra** over it
> (`llm_policy/{filter,rank,mutate,sequence,policy,candidate,util}.lua`; entry
> `llm_policy.lua`, with `router.lua` a compatibility shim). Since the IR
> landed (`llm_policy/{sig,term,fields,interp,elaborate,ir}.lua`), policies
> are **terms**: declarative profiles lower to the Σ_pol IR and carry a
> canonical identity; the closure DSL described here remains as the verbs'
> implementation and the local-only escape hatch. Companions:
> [`SIGMA-POL.md`](./SIGMA-POL.md) (the IR: terms, encoding, hashing,
> normative semantics) and [`GENVM-LLM-POLICY.md`](./GENVM-LLM-POLICY.md).

## 1. What this is

`llm_policy` is a small, pure-Lua **algebra for defining how to select,
transform, and sequence LLM provider calls** — runnable identically inside the
GenVM (mlua/wasm) and in an off-chain host (lupa, luerl). You author a
**policy** as composed combinators over four verbs:

- **`filter`** — which candidates are eligible (pure predicates).
- **`rank` / `select`** — order the eligible candidates (pure scorers + a selector).
- **`mutate`** — transform the outgoing request for a chosen candidate (seeded).
- **`sequence`** — what to do when an attempt fails (declarative, fixed vocabulary).

It is **not** a router in the "moves traffic" sense, and **not** a gateway. It
produces a *decision*; the host performs the I/O. The previous name
(`llm-router`) described the engine that interprets a policy; `llm_policy`
describes the thing you actually write.

### What it is NOT (the exclusions are part of the definition)

- **No I/O.** It never opens a socket, reads a clock, or touches the filesystem.
- **No credentials.** It carries opaque `auth` handles; the host resolves them.
- **No notion of "agent" or tenant.** It has a generic `scope` tag; "agent" is a
  host interpretation.
- **No arbitrary control flow in `sequence`.** Failure handling is a declarative
  table over a closed action vocabulary, never user code.

## 2. The core idea: one algebra, two teleologies

The same algebra serves two consumers that want **opposite** things, and the
only difference between them is one explicit input — the `seed`:

| Consumer | Wants | Selector | `seed` |
|---|---|---|---|
| **subzero** (off-chain agent fleet) | **converge** on the best available; resilience + cost | `argmax` | `nil` / fixed |
| **GenVM greyboxing** (on-chain) | **diverge** unpredictably-but-reproducibly; attack defense | `chain` / seeded `sample` | `H(tx_id, node_addr)` |

> **GenVM diverges to defend. Subzero converges to resist. Same mechanism,
> inverted teleology.**

This is why the core must be *neutral* about convergence vs divergence: that
choice lives entirely in the policy (the selector + the seed), never in the
engine.

## 3. The `ctx`: everything enters explicitly

A policy is a pure function of an explicit context. No globals, no clocks, no
hidden state — this is what makes the same policy decide identically under mlua
and lupa.

```lua
ctx = {
  request = { needs = {...}, min_context = 8000, scope = "agent:1234",
              extra_candidates = {...}, auth_override = {...}, ... },
  state   = { ema = {...}, breakers = {...}, credits = {...} },  -- read-only snapshot
  now_ms  = 1699999999,    -- injected, never read from a clock
  seed    = 0xA53F...,      -- host-supplied; H(tx_id,node_addr) on-chain, nil/fixed off-chain
}
```

## 4. The candidate object, the catalog, and (re)definition

The algebra is only as good as the object it operates on. `filter` / `rank` /
`mutate` are pure functions of a candidate's **fields**, so a candidate must be
**completely defined and validated before any verb touches it** — no lazy or
partial candidates, no "fill in a default later." This section is the foundation
the verbs (§5) stand on.

### 4.1 Three levels: provider, model, candidate

Two objects are *authored*; the third is *derived* and is what the verbs see.

- **Provider** (authored — connection + identity):
  `{ provider_id, base_url, api_kind, auth, tier, scope, has_tee, no_log, discovery }`
- **Model** (authored — what it can do):
  `{ model_family, capabilities, served_by[] }`, where each
  `served_by` binds a provider to its `served_model_id` and per-pairing overrides
  (e.g. price).
- **Candidate** (derived = provider × served_by): the flattened unit `plan()`
  receives, with everything resolved.

### 4.2 Static object vs dynamic state

The object holds **stable identity and properties**. **Live signals** — EMA
latency, success rate, breaker state, discovered price, free credits — are **not
part of the object**; they live in `ctx.state`, keyed by the candidate's id.
A latency scorer reads `ctx.state.ema[id]`, not the object. This is why "redefining
an object" and "updating its health" are different operations — and it is where
the redefinition rules in §4.4 come from.

### 4.3 The candidate schema (what the verbs consume)

| field | from | required | default | **mutability** | consumed by |
|---|---|---|---|---|---|
| `provider_id` | provider | yes | — | **identity** | filter (state lookup), engine, state key |
| `model_family` | model | yes | — | **identity** | filter, engine, state key |
| `served_model_id` | served_by | yes | =model_family | **identity** | engine (wire model id) |
| `scope` | provider / injected | no | nil (global) | **identity** | filter (`scope_matches`) |
| `base_url` | provider | yes (static) | — | **routing-target** | engine |
| `api_kind` | provider | yes | openai_compatible | **routing-target** | mutate, host dispatch, engine |
| `auth` | provider | no | `{kind="none"}` | **routing-target** | host resolver |
| `capabilities` | model | yes (min: context) | — | **tunable** | filter (`requirements`), mutate |
| `tier` | provider | no | fallback | **tunable** | filter (`tier_in`) |
| `price_in` / `price_out` | served_by | no | +inf | **tunable** | scorer (`field`), filter (`cmp` ceiling) |
| `has_tee` / `no_log` | provider | no | false | **tunable** | filter (privacy) |
| `offer` | discovery | marketplace only | — | **dynamic** | engine (forwarded) |
| *(ema, breaker, credits)* | **`ctx.state` by id** | — | — | **dynamic** | scorer (`field`: latency/throughput), filter (`breaker_closed`) |

### 4.4 When and how a candidate is (re)defined

**When** — three ingestion moments, **one validator, one schema**. A candidate
that fails validation is rejected at definition and never reaches a verb:

1. **init** — static catalog, validated and **immutable** until re-init. The
   validator / on-chain default: fixed and auditable.
2. **ephemeral per-call** (`ctx.request.extra_candidates`) — a **complete**,
   validated candidate the host injects for one call; lives only for that call;
   never mutates the shared catalog. The lean path for dynamic / per-agent
   providers.
3. **runtime register** (`register_provider` / `register_model` + `unregister`)
   — mutates the live catalog; for session-stable providers.

All three feed the **same** `plan(candidates, ctx)`; the algebra is indifferent
to which moment a candidate came from.

**How** — the rule falls out of each field's mutability class:

> You may **hot-redefine the `tunable` fields** of a candidate keeping its `id`
> and accumulated state (EMA/breaker carry over — it is the same target).
> Changing any **`identity`** or **`routing-target`** field is **not a
> redefinition — it is a new candidate (new `id`)**; the old one is retired or
> explicitly migrated. **`dynamic`** fields are never redefined: they accumulate
> and are cleared only on `unregister` or explicit reset.

Rationale: keeping the `id` while changing `base_url`/`api_kind`/`auth` (target)
drags stale health from an endpoint that is no longer that one; changing
`provider_id`/`model_family`/`scope` (identity) is by definition a different
state slot.

**Per-call credentials are an execution override, not a redefinition.** Two
distinct cases the host chooses between:

- **Own-account provider** (the agent's ChatGPT subscription, its own key) → a
  distinct **identity** (`openai@agent:1234`) with **isolated** state. A rate
  limit on agent A's account says nothing about agent B's.
- **Shared gateway billed per caller** (one OpenRouter for many) → one **shared**
  candidate with **shared** health state; vary only the credential per call via
  `ctx.request.auth_override` (an ephemeral execution input, *not* a redefined
  object field). This keeps cross-fleet health learning intact.

### 4.5 Catalog vs policy

Two separable things:

- **Catalog (data):** providers, models, capabilities, `auth` handles, `scope`,
  `tier`, price. Per-deployment. The two real catalogs that matter: a **validator
  catalog** (reliable/private — partners with SLA, TEE) and a **subzero catalog**
  (pay-per-use, BYO-credentials: OpenRouter, subscription, AntSeed).
- **Policy (behavior):** the four-verb composition in §5.

The same policy runs against different catalogs; the same catalog runs under
different policies. Keep them orthogonal.

## 5. The four verbs

The verbs operate on the candidate objects of §4 and the `ctx` of §3.

### 5.1 `filter` — eligibility predicates (open)

A filter is `fn(cand, ctx) -> bool` (keep if true). Atoms compose via
combinators. The current `candidate_passes` logic becomes the standard library.

```lua
local F = require("llm_policy.filter")

-- atoms
F.requirements()      -- derives needs / min_context from ctx.request
F.tier_in{ "partner", "tee" }
F.scope_matches()     -- scoped providers only when ctx.request.scope matches
F.not_disabled()
F.breaker_closed()    -- reads ctx.state.breakers

-- combinators
F.all_of{ ... }   F.any_of{ ... }   F.none_of{ ... }
F.where(fn(c, ctx) ... end)   -- the one open door: an arbitrary pure predicate
```

### 5.2 `rank` / `select` — scorers + selector (open; the seed lives here)

A scorer is `fn(cand, ctx) -> [0,1]`. The selector turns a scorer into an
ordered candidate list — and is where entropy enters.

```lua
local R = require("llm_policy.rank")

-- (sigma-pol/v2) the composite atom scorers (quality/speed/cost/partner/
-- free_credit) and the R.weighted{...} combinator over them were REMOVED:
-- they folded raw fields + request knobs into one opaque, host-tuned number.
-- Score on the RAW fields instead — in the IR with field(...)/normalize/neg/
-- scale/add (SIGMA-POL.md §5.1), or here with the closure escape hatch:
R.custom(fn(c, ctx) ... end)        -- pure escape hatch (local-only, no identity)

-- selectors: scorer -> ordered list.  The convergence<->divergence axis.
R.argmax(scorer)                              -- deterministic (subzero)
R.chain{ {provider=, model=}, ... }           -- fixed priority whitelist (greybox)
R.softmax_sample(scorer, { temp = 0.5 })      -- seeded stochastic; LEGACY (uses math.exp,
                                              -- libm-dependent) — the IR `sample` op is the
                                              -- normative seeded selector (SIGMA-POL.md §5.3)
```

The scorer is shared and pure; only the selector reads `ctx.seed`. No seed →
reproducible `argmax`. Seed set → reproducible divergence. The IR adds
`ordered` (keep input order) and the transcendental-free rank-geometric
`sample`; breaker demotion, which the legacy selectors performed silently, is
written explicitly in the IR as `gate(not(is("breaker_open")), scorer)`.

### 5.3 `mutate` — per-attempt request transform (open; pure + declarative)

`mutate : (request, cand, ctx) -> request'`. It runs **per attempt**, after a
candidate is chosen and before the call, with the candidate in scope — so a
retry re-diversifies, and a provider-specific transform is possible.

Two sub-kinds, and the split is what keeps the core pure:

1. **Param transforms — pure, in Lua** (temperature/top_p/seed/max_tokens).
2. **Filter directives — declarative; the host applies them** (text/image filters
   like NFKC, RmZeroWidth, GaussianNoise, JpegRecompress — the Rust filters in
   the GenVM LLM module). The DSL *names* a seeded recipe; the host *executes*
   it. Same pattern as `auth`: the core emits an opaque directive, the host
   resolves it.

```lua
local M = require("llm_policy.mutate")

-- params (pure, in Lua)
M.jitter{ temperature = 0.2, top_p = 0.05 }   -- ± perturbation seeded by ctx.seed
M.set_param{ seed = "from_ctx" }              -- inject a per-node seed into the call
M.clamp{ max_tokens = 4096 }

-- declarative directives (host applies; DSL names + seeds them)
M.filter_text{ "NFKC", "RmZeroWidth", "NormalizeWS" }
M.filter_image{ { Unsharpen = {2.0,4.0} }, { GaussianNoise = 0.05 }, { JpegRecompress = 0.8 } }

-- combinators
M.pipe{ a, b, c }                 -- compose in order; splits sub-seeds
M.when(pred, m)                   -- conditional on (cand, ctx)
M.custom(fn(req, cand, ctx) ... end)   -- escape hatch: PARAMS ONLY, pure, no I/O
M.identity                        -- no-op (subzero)
```

Reproducibility is preserved end to end: `mutate` derives **sub-seeds** from
`ctx.seed` and bakes them into directives (a stochastic filter like Gaussian
noise carries its seed), so `same (policy, ctx, seed)` → `same request' + same
directives` → the host applies them deterministically.

### 5.4 `sequence` — failure handling (declarative, closed)

A table over a **fixed** action vocabulary. Deliberately not combinators:
programmable failure control flow is where a policy DSL rots into untestable
imperative soup, and on-chain it becomes an attack/consensus surface.

```lua
local balanced = {
  rate_limit   = { action = "next_candidate", open_breaker_ms = 30000 },
  server_error = { action = "retry_same", attempts = 1, backoff_ms = 500, then_action = "next_candidate" },
  auth_error   = { action = "disable_provider" },
  bad_request  = { action = "abort" },
  -- allowed actions: retry_same | next_candidate | next_provider_same_model | disable_provider | abort
}
```

## 6. A Policy, and how the engine consumes it

A policy binds the four verbs:

```lua
local policy = Policy{
  filter   = F.all_of{ F.not_disabled(), F.breaker_closed(), F.requirements(), F.scope_matches() },
  select   = R.argmax(R.custom(score_fields)),  -- v2: score raw fields, no composite atoms
  mutate   = M.identity,
  sequence = balanced,
}
```

Surface (all pure):

```
policy:plan(candidates, ctx)   -> { ordered = {...}, rejected = {...} }   -- filter + select, once
policy:mutate(request, cand, ctx) -> request'                             -- per attempt
policy.sequence[error_kind]    -> action                                   -- on failure
```

where `candidates = catalog ∪ ctx.request.extra_candidates` (§4.4), merged before
`plan`. The existing cooperative FSM (`execute_step`, Model B — yield-on-IO: the
host performs each call/wait off the Lua lock, the router stays pure) is
the **interpreter** and does not change shape: `plan` once → walk `ordered` → for
each attempt `mutate(request)` → emit the `call` step → on failure consult
`sequence` → advance → `mutate` again. The engine becomes an interpreter of the
algebra; today's scoring/filter/retry code becomes the standard library.

How a Policy is *built* (one language): a declarative profile lowers through
`llm_policy.elaborate` to a Σ_pol term and compiles via `ir.compile`
(check → normalize → eval), so every profile carries `trace.policy_fingerprint`;
a per-call term arrives as `contract.policy_ir` (data, never code), met with
the host envelope. Only profiles containing Lua closures take the legacy
closure-compile path — local-only, no identity. See SIGMA-POL.md §6.

## 7. The two reference policies

```lua
-- subzero: CONVERGE (best available, cascade on failure)
Policy{
  filter   = F.all_of{ F.not_disabled(), F.breaker_closed(), F.requirements() },
  select   = R.argmax(R.custom(score_fields)),  -- v2: raw fields (price/latency/context)
  mutate   = M.identity,                 -- converge => don't perturb
  sequence = balanced,
}   -- ctx.seed = nil

-- greybox: DIVERGE (attack defense; reproducible per node and per attempt)
Policy{
  filter   = F.all_of{ F.requirements(), F.tier_in{ "partner", "tee" } },   -- trusted only
  select   = R.softmax_sample(R.custom(score_fields), { temp = 0.5 }),
                                         -- closure form; the wire/normative seeded
                                         -- selector is the IR `sample` (SIGMA-POL §5.3)
  mutate   = M.pipe{
    M.filter_text{ "NFKC", "RmZeroWidth", "NormalizeWS" },
    M.jitter{ temperature = 0.3 },
    M.filter_image{ { GaussianNoise = 0.05 }, { JpegRecompress = 0.8 } },
  },
  sequence = strict,                     -- e.g. abort rather than cascade widely
}   -- ctx.seed = H(tx_id, node_addr)
```

Same `Policy`, same engine. The inversion is entirely in `select` (argmax ↔
softmax) + `mutate` (identity ↔ seeded recipe) + the `seed`.

## 8. The defining invariant (and its test)

> Given the same `(policy, catalog, ctx, seed)`, `plan` and `mutate` produce the
> **same** decision under mlua (GenVM) and lupa (off-chain host).

Purity makes this hold; the test makes it real. The conformance test is the
artifact's thesis statement as code: drive identical inputs through mlua and
lupa and assert identical `ordered` + `request'` + directives. On-chain
divergence comes only from different `seed` / `catalog` / `state`, by design.

The IR sharpens this from a property into an artifact: the executable spec is
`tests/golden/sigma_pol_v2.json` (encodings, fingerprints, decisions —
replayed bit-for-bit under lua5.4 and lupa), and initiality reduces
conformance of any new interpreter to a finite per-op checklist
(SIGMA-POL.md §7). The semantics use only correctly-rounded IEEE operations —
no transcendentals — so the invariant holds across libms, not just across
the two runtimes we test.

## 9. Relationship to hosts

The host owns everything the core excludes:

- **Supplies the `seed`:** `H(tx_id, node_addr)` on-chain (greybox), `nil`/fixed
  off-chain (subzero), a fixed value for audit/replay.
- **Resolves `auth` handles** → headers (`none` / `bearer` / `oauth`), including
  any per-call `ctx.request.auth_override` for shared gateways (§4.4).
- **Applies `mutate` directives** (runs the Rust text/image filters; the policy
  only named them).
- **Owns agents, tenancy, credential storage** (e.g. `add_provider(agent_id,
  oauth_key)`): it stores the key under an opaque handle and injects the
  provider as a `ctx.request.extra_candidates` entry — with a namespaced id for
  own-account providers (isolated state) or a shared id + `auth_override` for
  shared gateways (§4.4).

Three artifacts, this is the first: **`llm_policy` (the algebra)**, the **GenVM
greybox host** (on-chain interpreter + Rust filters + seed from tx/node), and
the **unhardcoded host** (off-chain interpreter + credentials + agent layer).

## 10. Migration from `router.lua`

Not a rewrite — an exposure:

- `score_candidate` (weighted sum) → field-based IR scorers (`field`/`normalize`/
  `neg`/`scale`/`add`); the v1 `R.weighted` over composite atoms was removed in v2.
- `candidate_passes` → `F.*` atoms.
- `build_candidate_matrix` → still builds the static set, but `plan` now ranks
  over `catalog ∪ ctx.request.extra_candidates` (one validator, one schema).
- `rank_candidates` → `policy:plan`.
- new `policy:mutate` stage, called per attempt inside `execute_step`.
- `classify_action` / retry FSM → unchanged; consumes `policy.sequence`.
- `execute_step` (Model B) → unchanged shape; calls `plan`/`mutate`/`sequence`.

The built-in dims stop being privileged and become one entry in a standard
library of policies; greybox's diversity policy is another entry.

## 11. Open questions

- **Name.** `llm_policy` is provisional. (`llm_routing_policy`, `llm_planner`
  considered; `_call`/`_dsl` rejected — `call` contradicts the no-I/O boundary,
  `dsl` overpromises syntax we won't build.)
- **`register_*` lifecycle.** Persistent runtime registration needs GC / removal
  rules and a story for what happens to a candidate's accumulated state on
  `unregister` (cleared) vs hot-redefine of `tunable` fields (kept) — §4.4 gives
  the rule; the persistent path needs the bookkeeping.
- **`mutate` directive registry.** The set of host-applicable filter names
  (text/image) needs to be a spec the policy can target and the host guarantees —
  versioned like the `sequence` action vocabulary.
- **Seed derivation on-chain.** Exactly how `H(tx_id, node_addr)` is computed and
  whether any policy decision is consensus-relevant (must be isolated from the
  equivalence check if so).
- **`sequence` vocabulary completeness.** Is the five-action set sufficient, or
  does greybox need a "fail-closed" action distinct from `abort`?
