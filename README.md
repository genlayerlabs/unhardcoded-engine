# llm_policy

A small, embeddable **policy algebra for LLM provider selection**, in pure Lua.
You describe *what you need from an LLM call* (a contract); a **policy** —
composed from four verbs over a declarative catalog — decides which
`(provider, model)` to call, with what request, and what to do on failure. The
embedding host performs the I/O.

The four verbs (see [`docs/POLICY_DESIGN.md`](./docs/POLICY_DESIGN.md)):

- **`filter`** — which candidates are eligible (pure predicates).
- **`rank` / `select`** — order the eligible candidates (pure scorers + selector).
- **`mutate`** — transform the outgoing request for a chosen candidate.
- **`sequence`** — what to do when an attempt fails (declarative, fixed vocabulary).

Two consumers, one language:

- **Off-chain (subzero ecosystem)** — a policy that *converges* on the best
  available provider: resilience + cost optimization for an agent fleet.
- **On-chain (GenVM greyboxing)** — each validator writes its own policy; the
  ease of writing 1000 *different* policies, over a well-defined provider object,
  **is** the security property. See [`docs/GENVM-LLM-POLICY.md`](./docs/GENVM-LLM-POLICY.md).

## Properties

- **Pure Lua, no I/O, no credentials, no globals.** The verbs are pure functions
  of an explicit `ctx`; the engine (the impure orchestrator) snapshots runtime
  state into `ctx` and performs no I/O itself. Embeddable in lupa (Python), mlua
  (Rust / GenVM), luerl (Elixir).
- **Two execution modes.** Synchronous (`execute`) and cooperative async
  (`execute_step`, yield-on-IO) so one host process overlaps many in-flight calls.
- **Host-resolved auth.** Providers declare `auth = {kind="none"|"bearer"|"oauth"}`;
  the host turns that into headers. The core never sees a key.
- **Same decision, two runtimes.** Given the same `(policy, catalog, ctx, seed)`,
  selection is identical under mlua and lupa — the defining invariant.

## Package

The core is the `llm_policy` package; `router.lua` is a compatibility shim
(`return require("llm_policy")`) so existing embedders keep working.

```lua
local llm_policy = require("llm_policy")   -- or dofile("router.lua")
llm_policy.init(config, metrics)
local result = llm_policy.execute({
  prompt       = "Classify this feedback as positive / negative / neutral: ...",
  requirements = { needs = { "json_mode" }, min_context = 4000 },
  profile      = "cheap_explore",
})
if result.ok then print(result.response.text) else print(result.error) end
```

## Repo layout

This repo **is** the core (sealed): pure Lua + a minimal embedding reference
(`example_host/`) + the on-chain adapter overlay (`genvm/`). The production
off-chain host moved to its own repo,
[`genlayerlabs/llm-policy-host`](https://github.com/genlayerlabs/llm-policy-host).
The core never references a host — hosts import the core.

```
# ── core (this repo) ──
llm_policy.lua             -- package entry (init / execute / execute_step / rank / …)
llm_policy/
  filter.lua  rank.lua  mutate.lua  sequence.lua  policy.lua   -- the algebra
  sig.lua  term.lua  fields.lua  interp.lua  elaborate.lua  ir.lua
                                                               -- the Σ_pol IR (policies as data)
  candidate.lua  util.lua                                      -- object + helpers
router.lua                 -- compat shim: return require("llm_policy")
config.example.lua         -- example catalog + profiles (schema illustration)
metrics.example.lua        -- example metrics seed
docs/
  POLICY_DESIGN.md         -- the candidate object + the policy algebra
  SIGMA-POL.md             -- the policy IR: terms, encoding, hashing, reference semantics
  GENVM-LLM-POLICY.md      -- using llm_policy as a node's greyboxing algebra
example_host/              -- the minimal embedding reference (~80 lines, mock provider)
tests/                     -- Lua unit tests (run_lua.lua, unit/, smoke_rank.lua)
genvm/                     -- on-chain greybox adapter overlay (dispatch.lua + integrate.sh); tests/
```

## Hosts

- **`example_host/`** — the minimal embedding reference (~80 lines): load the
  core, install the `host` table, `init`, `execute`. The "hello world" of
  embedding `llm_policy`.
- **Off-chain production host** —
  [`genlayerlabs/llm-policy-host`](https://github.com/genlayerlabs/llm-policy-host):
  the async OpenAI-compatible shim + Codex (ChatGPT subscription) + AntSeed + the
  auth resolver, serving the subzero agent ecosystem. It vendors this core as a
  git submodule.
- **On-chain adapter** — [`genvm/dispatch.lua`](./genvm/): a drop-in for
  genlayer-node's `genvm-llm-greybox.lua` that routes greyboxing through the
  algebra (see [`docs/GENVM-LLM-POLICY.md`](./docs/GENVM-LLM-POLICY.md)).
