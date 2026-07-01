---
name: unhardcoded-engine-use
description: >-
  Use the unhardcoded-engine (Σ_pol) policy algebra — either to EMBED the pure
  Lua core in a host, or to AUTHOR a policy_ir term that decides which
  (provider, model) serves an LLM call. Load this skill when you need to
  integrate llm_policy into a host (lupa/mlua/luerl), write or dry-run a Σ_pol
  policy, understand the request/trace contract, or debug why a candidate was
  rejected. For extending the algebra itself (new operators/fields) use
  unhardcoded-engine-contribute instead.
---

# Using unhardcoded-engine (Σ_pol)

The engine is a **pure-Lua policy algebra**: you hand it a *contract* (what a
call needs) and a *policy* (how to choose), it returns which `(provider, model)`
to call, how to mutate the request, and what to do on failure. **It performs no
I/O and holds no credentials** — the host does all of that. Two ways to "use" it:
embed the core, or author a policy term. Most of what you need is here; the
normative detail lives in `docs/` (linked inline).

## A. Embedding the core in a host

The package is `llm_policy`. `router.lua` is a compat shim (`require("llm_policy")`).

```lua
local llm_policy = require("llm_policy")
llm_policy.init(config, metrics)         -- validate catalog + profiles, seed metrics
local result = llm_policy.execute({ prompt = "...", profile = "default" })
if result.ok then print(result.response.text) else print(result.error) end
```

**The host contract.** Install a global `host` table before `execute`; the core
delegates every side effect to it:

| Field | Contract |
|---|---|
| `call_provider(request)` | do the HTTP → `{ok, response, error_kind, http_status, error_message}` |
| `now_ms()` | millisecond clock |
| `log(level, event, fields)` | logging sink |
| `env(key)` | env-var resolver (auth lives here, never in the core) |
| `sleep_ms`, `discover`, `persist_state`, `load_state` | optional |

The core decides *which provider, when to retry, when to abort*; the host
*executes* the call and resolves auth from the provider's declared
`auth = {kind="none"|"bearer"|"oauth"}`. The minimal working reference is
`example_host/example.py` (~96 lines, lupa + a mock provider) — read it before
writing your own. mlua (Rust/GenVM) and luerl (Elixir) embed the same way.

**Public surface** (all on the `llm_policy` module):
- `init(config, metrics?)` — admit config, build the candidate matrix.
- `execute(contract)` — synchronous loop to completion.
- `execute_step(state, contract?, response?)` — cooperative async; yields on I/O
  so one process overlaps many in-flight calls (first call: `state=nil`).
- `rank(contract)` → `ordered, err, rejected` — **dry-run ranking, no HTTP**.
- `info()`, `provider_status(now_ms)` — read-only introspection / health.
- `dump_state()` / `restore_state(snap)`, `update_metrics(...)`,
  `invalidate_discovery(...)` — runtime state (breakers, EMA, credits).
- `M.ir` — offline term tooling: `ir.term.check/normalize/encode`, `ir.compile`.
- `M.dsl` — the closure verbs (filter/rank/mutate/sequence/policy), a
  **local-only escape hatch**; anything shipped or sent per-call should be IR.

Config/metrics schema is illustrated by `config.example.lua` /
`metrics.example.lua`; the design (candidate object, the three price-ingestion
moments, field mutability) is `docs/POLICY_DESIGN.md`.

## B. Authoring a Σ_pol policy term

A policy is **data** — a plain array over the closed, versioned signature
`sigma-pol/v2`, admitted before it runs (depth ≤ 64, ≤ 4096 nodes). Five slots
(the Evidence slot was removed in v2); fill the leading three — Pred, Scorer,
Selector — and keep the tail (Xform, FailPlan) as defaults:

```
["policy", <Pred>, <Scorer>, <Selector>, <Xform>, <FailPlan>]
```

- **Pred** — who is eligible: `and/or/not`, `meets_req`, `cmp(field, rel, num)`,
  `is(boolfield)`, `min_tier`/`tier_eq`, `family_eq`/`provider_eq`/`served_by_eq`,
  `has_cap`.
- **Scorer** — rank survivors (population-relative): `field(f)`, `lit`, `scale`,
  `add`, `neg`, `normalize`, `clamp`, `gate(pred, scorer)`.
- **Selector** — pick: `argmax`, `ordered`, `sample(temp)`, `top_k`, `chain`.
- **Xform** (default `["id"]`) — mutate the outgoing request per attempt.
- **FailPlan** (default `["always", {"action":"next_candidate"}]`) — error_kind → Action.

**Observation fields** a policy may reference (declared vocabulary, not ops):
`price_in`, `price_out`, `latency_ms`, `tok_s`, `success_rate`, `credits`,
`context`, `has_tee`, `no_log`, `breaker_open`, `disabled`; plus categoricals
`provider_id`, `model_family`, `scope`, `tier`. Hosts add more via
`config.fields`. The **normative** operator list, numeric model, encoding and
hashing rules are `docs/SIGMA-POL.md` — treat it as the source of truth.

Send a per-call policy as `policy_ir` in the contract; dry-run it with
`rank(...)` or admit/fingerprint it offline with `ir.term.check` /
`ir.term.encode` before spending a token.

## Non-obvious gotchas (the ones that bite)

- **`price_in`/`price_out`/`latency_ms` default to `+inf`.** A candidate with no
  observed price *fails* a ceiling like `cmp("price_out","le",25)` — this is
  deliberate (strict), not a bug. Seed prices via `metrics` or the catalog.
- **v2 removed the composite scorer atoms** (`quality`/`speed`/`cost`/`partner`/
  `free_credit`) and the Evidence slot — they folded raw fields into opaque
  numbers. **Score raw fields instead**: `field("price_out")` composed with
  `scale`/`add`/`normalize`/`neg`. Old policies using them are rejected.
- **Determinism is the defining invariant.** The same `(policy, catalog, ctx,
  seed)` selects identically under mlua, lupa and luerl — bit-for-bit (IEEE ops
  only, no transcendentals). If you need reproducible choice, pass `seed`.
- **The host envelope only narrows.** `config.policy_envelope` is `∧`-composed
  onto every caller policy, so a per-call term can only *tighten* the host's
  invariants, never widen them.
- **Identity is the fingerprint.** Every IR run stamps
  `trace.policy_fingerprint` (sha256 of the canonical encoding) — use it for
  caching, audit and on-chain commitment, not the raw term text.

## Reading the result

`execute` returns `{ ok, response|error, chosen, trace }`. When debugging a
choice, read `trace`: `ranked` (survivors with scores/tier), `rejected` (each
dropped candidate + reason — this is where a `+inf` price or a failed `meets_req`
shows up), `decision_path` (attempts/skips with latency and error_kind), and
`chosen` (`provider_id`, `model_family`, `served_model_id`, prices, `served_by`).

## Where to read more

- `docs/SIGMA-POL.md` — normative IR: terms, operators, numeric model, encoding, hashing.
- `docs/POLICY_DESIGN.md` — the candidate object and the four verbs; sync vs async execution.
- `docs/SIGMA-FLOW.md` — Σ_flow: composing several calls as a DAG (`flow_ir`).
- `docs/GENVM-LLM-POLICY.md` — the on-chain (greyboxing) embedding.
- `example_host/` — the minimal embedding reference.
- Production off-chain host (HTTP, providers, auth, dashboard): `genlayerlabs/unhardcoded`.
