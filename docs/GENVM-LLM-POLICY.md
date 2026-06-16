# genvm-llm-policy — using llm_policy to write your node's greyboxing

> **Status:** argument / design rationale. Companion to
> [`POLICY_DESIGN.md`](./POLICY_DESIGN.md). Makes the case for writing a GenVM
> validator's **greyboxing** script as an `llm_policy` *sentence* instead of a
> bespoke Lua script — and is honest about where that does and doesn't pay off.

## The claim

A GenVM node's greyboxing logic — *which* `(provider, model)` it calls, with
*what* prompt/params, and *what* it does on failure — is exactly a routing +
mutation + fallback policy. `llm_policy` is a small pure-Lua **algebra** for
writing such policies as composed combinators. So: write your node's greyboxing
as an `llm_policy` sentence. The expressivity of the algebra is not overhead —
**for greyboxing it is the security mechanism.**

## What greyboxing is today (grounded)

The production script (`genlayer-node/release/genvm-llm-greybox.lua`) does:

1. **Deterministic priority chains** — two chains (`text`, `image`), each an
   ordered list of `(provider, model)` from `meta.greybox: { text: N, image: M }`
   in the YAML (lower number = higher priority). It tries them in order with
   `pcall`, falling through on overload/error.
2. **Per-call OsRng seed** — "each LLM call gets its own random seed via OsRng —
   the inherent per-node variation." The diversity that resists attacks comes
   from the model's *sampling* entropy, **below routing**, not from picking a
   different provider.
3. **`filter_text`** — NFKC / RmZeroWidth / NormalizeWS on every prompt.
4. **Hot-reload** — `/tmp/greybox-config.json` overrides the chains at runtime.

So selection is **deterministic** (chains, identical across nodes by default);
divergence is **sampling-level** (OsRng) plus whatever config diversity each
operator introduces by hand.

## Why an algebra is a good idea here

### 1. Security *is* diversity — and an algebra makes diversity cheap

The greyboxing doc's own thesis: divergence across validators is the defense.
With 1000 nodes you want ~1000 *different* policies, so no single adversarial
input generalises across the network. A hand-rolled 180-line script is the
*hardest* thing to vary at scale — most operators will run it unchanged
(monoculture). A **language** makes a distinct policy a short, cheap
composition. The size of the expressible policy space is the entropy that
defeats targeted attacks.

### 2. It is *more* auditable, not less

A richer mechanism sounds like more to audit. The opposite holds: you audit the
**small pure core once** (the verbs are I/O-free, credential-free, deterministic
given `ctx`), and each node's policy is then a **short, legible sentence** — far
easier to review than N bespoke scripts. Fixed audited language + tiny
declarative policies beats a fleet of hand-edited 180-line files.

### 3. A well-defined provider object makes better sentences

The chain script knows only `(provider, model)`. `llm_policy`'s candidate object
([POLICY_DESIGN §4](./POLICY_DESIGN.md)) carries capabilities, tier, scope,
privacy (`has_tee`/`no_log`), price — plus per-node runtime in `ctx.state` (EMA
latency, circuit breakers, credits). So a greyboxing sentence can say things the
chain script cannot express at all:

```
filter = all_of{ tier_in{ "partner", "tee" }, breaker_closed(), requirements() }
select = argmax(score_fields)   -- v2: score raw fields (price, latency, context), no composite atoms
mutate = pipe{ filter_text{ "NFKC", "RmZeroWidth", "NormalizeWS" },
               jitter{ temperature = 0.3 } }
sequence = cascade-on-overload
```

"Prefer TEE/partner, drop providers I've recently been rate-limited by, weigh by
*my* cost and *my* observed latency, jitter the call, normalise the prompt." None
of that fits a static chain. When the provider object is poorly defined there is
no expressivity, and therefore no real diversity — which is exactly the gap
`llm_policy` closes.

## The correct locus of randomness

Stochastic **model selection** is *not* recommended: it is hard to reason about
and stresses consensus. Selection should stay **deterministic** (priority
`chain` or scored `argmax`) so it is reproducible and auditable. The
unpredictable part belongs in **`mutate`**: a per-call seed and seeded random
mutations (param jitter, prompt/image filters). So seeded-sampling selection
(the IR `sample` op — rank-geometric, transcendental-free; SIGMA-POL.md §5.3)
is a niche off-chain load-spreading tool, **not** the greyboxing mechanism.
Divergence lives in mutation; selection stays deterministic. A side benefit
of policies-as-terms for validators: a node's policy has a canonical hash
(SIGMA-POL.md §4), so an operator can commit to, publish, or audit a policy
without revealing catalog or state.

## Where the diversity actually comes from: the operators

In a real validator network the nodes are run by **independent companies**. Each
operator has different provider relationships, negotiated pricing, discounts,
free credits — often a different set of available providers entirely. That means
each node's **catalog and `ctx.state` differ by construction**, so a scored
selection diverges **organically**: not synthetic jitter, but each operator
ranking by *its own material conditions*. This divergence is **explainable and
auditable** ("this node chose X because X was cheapest/fastest *for it*") —
strictly better than opaque randomness, and impossible to express without a
well-defined provider object.

Mutation-level entropy (seed/jitter/filters) is then **defense-in-depth** for the
case operators overlap on the obvious pick — everyone has access to the few best
models for the hardest prompts, so the primary choice can still cluster there.

## Honest constraints (so this is a decision, not a slogan)

- **Consensus equivalence ceiling.** More model-level divergence → more
  answer-variance → more strain on GenLayer's equivalence-principle consensus.
  The algebra *enables* diversity; the protocol bounds how much is safe. This is
  GenLayer's knob, not `llm_policy`'s — but a greyboxing policy must be authored
  with it in mind.
- **Expressible ≠ drop-in.** To *replace* the production script on-chain,
  `llm_policy` must also match its operational surface: hot-reload JSON
  (`io.open`, no `os` in the mlua sandbox), `meta.greybox` YAML parsing,
  integration with `lib-llm.select_providers_for`, and the GenVM seed/OsRng
  plumbing. That is integration work, independent of the algebra's
  expressivity.
- **Completeness is audit surface.** A language is more to trust than a fixed
  script — mitigated, as above, by auditing the core *once* and keeping each
  node's policy a short sentence.

## What it takes (DONE — `genvm/dispatch.lua` is a drop-in)

`genvm/dispatch.lua` now is a drop-in for `genvm-llm-greybox.lua`, routing its
selection + fallback through `llm_policy`. Maps cleanly to the verbs:

- **`R.chain(chain)`** — deterministic selector ordering candidates by an
  explicit `(provider, model)` list. Implemented in `llm_policy/rank.lua`. The
  chain is supplied per-call via `contract.chain` (the host resolves it from
  `meta.greybox` ∩ `select_providers_for`).
- **`F.requirements()`** — modality/caps gate (the `select_providers_for` role);
  the greybox profile can add `tier_in` / `breaker_closed` for free.
- **`sequence` = cascade** — `next_candidate` on overload/transient, stop on
  auth/bad-request/context-overflow. Mirrors `tryChain`'s pcall loop.
- **`mutate`** — `filter_text` runs in `ExecPrompt` (as production); the
  programmatic form (`genvm/greybox-policy.example.lua`) moves it into `mutate`
  and can add `filter_image` / seeded `jitter`. The per-call OsRng seed stays a
  GenVM-runtime concern.
- **`meta.greybox` chains** parsed at load (`build_chains_from_meta`), text/image
  split by modality, exactly like the production script. No `meta.greybox` →
  dispatch falls back to a weighted `default` profile (more lenient than the
  production script, which errors).
- **Per-node diversity is mostly free**: each operator's catalog + `ctx.state`
  already differ; the algebra just lets each write its sentence cheaply.

Verified by `genvm/tests/test_genvm_surface.py` (chain order, cascade on
overload, non-chained providers never tried). Still pending for full parity:
hot-reload JSON (`/tmp/greybox-config.json`) and live testing inside a built
GenVM (the lupa surface test fakes `__llm`).

## Recommendation

It is not a bad idea — it is arguably the *right* tool — to write GenVM
greyboxing as `llm_policy` sentences, **if** the goal is one routing/greybox
language across the whole chain (and shared with the off-chain hosts). The
expressivity that looks like overhead is, for greyboxing, the security property:
cheap, auditable, economically-grounded per-node diversity that a chain script
cannot express. Keep the minimal script as the conservative default; adopt the
algebra where you want real, legible, fleet-wide policy diversity. The decision
hinges on **operational parity + audit appetite**, never on expressivity — that
side is already won.
