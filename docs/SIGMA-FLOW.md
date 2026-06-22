# Σ_flow — the flow IR

Normative spec for `sigma-flow/v1`: a **composition layer over Σ_pol**. Where a
policy decides *which model serves one call*, a flow decides *how several calls
compose* — a DAG of LLM nodes between one input (the user's prompt) and one
output (the answer). A flow in this form is **data** — serializable, hashable,
admissible from untrusted callers — and its identity is defined the same way a
policy's is: the sha256 of a canonical encoding.

Σ_flow reuses Σ_pol wholesale: every node carries a Σ_pol **term** as its
`policy`, admitted and encoded by `llm_policy.term`. Σ_flow adds only the graph
on top. The reference modules are `llm_policy/flow.lua` (signature, admission,
normal form, encoding, reference driver) over `llm_policy/term.lua`.

## 0. What Σ_flow is *not* — declarative composition, not a workflow language

Σ_pol's charter forbids a workflow language: no loops, no I/O, no effects, no
non-determinism — *a term decides things, it does not do things.* Σ_flow keeps
every one of those guarantees, and is admitted to the same algebra family on
that basis, not in spite of it:

- **Acyclic, not looping.** A flow is a DAG (`flow.check` rejects cycles); there
  is no iteration construct. Evaluation visits each node once — O(|flow|), the
  graph analogue of Σ_pol's O(|term|).
- **No effects in the core.** `flow.run` is a pure scheduler; its single effect,
  `run_node`, is *delegated* to the host — exactly as a policy's only effect,
  `call_provider`, is. The core composes; the host calls.
- **Deterministic structure.** Admission, normal form and identity are total and
  reproducible; the encoding nests the policy bytes. Only the *text* a node
  produces is non-deterministic, and that lives host-side where it always did
  — fitting the validator-consensus model: same flow, same structure, replayable.
- **Declarative, hashable data.** A flow is a value with an identity
  (`sha256(encode(normalize(flow)))`), not a script. It is composed, downloaded,
  and committed — never *run* by the algebra itself.

So Σ_flow is not the imperative orchestration the anti-telos vetoes; it is the
*declarative composition* of Σ_pol decisions, under Σ_pol's own discipline. The
vetoed things — loops, side effects, non-deterministic structure, evaluation
that isn't O(|flow|) — remain vetoed, here as in Σ_pol.

## 1. The model

A flow is a directed acyclic graph with exactly **one source and one sink**:

- the **input** node — its output is the user's prompt, verbatim;
- any number of **llm** nodes — each receives the outputs of its predecessors,
  assembles them into one user message, and runs a Σ_pol-routed LLM call under
  its own `system` prompt and `policy`;
- the **output** node — its output is its single predecessor's output, verbatim.

Edges are **pull-model**: a node lists the ids it consumes in `inputs`, so an
edge `a → b` is recorded as `b.inputs ∋ a`. "Fusion" is not a special node — it
is simply an llm node with more than one input (e.g. a synthesizer reading two
drafts). The user's mental model holds exactly: *each node gets `(inputs,
system_prompt, sigma_pol)` and sends its output to the nodes it feeds.*

```lua
{ "flow", {
    u   = { kind = "input" },
    a   = { kind = "llm", system = "Answer concisely.",
            policy = <Σ_pol term>, inputs = { "u" } },
    b   = { kind = "llm", system = "Answer rigorously, show steps.",
            policy = <Σ_pol term>, inputs = { "u" } },
    f   = { kind = "llm", system = "Synthesize the single best answer from the drafts.",
            policy = <Σ_pol term>, inputs = { "a", "b" } },
    out = { kind = "output", inputs = { "f" } },
} }
```

A flow term is `{ "flow", nodes }`, mirroring a term's `{ op, args… }`: the tag
sits at `[1]`, the node map at `[2]`. Node ids are arbitrary labels — they carry
no meaning and do not survive normalization (§4).

## 2. Why a separate IR, not new Σ_pol ops

A policy is a finite **tree**; a flow is a **graph** (shared inputs, fan-out).
Σ_pol's whole machinery — admission, AC normal forms, the initial-algebra
interpreter — is defined over finite trees and must stay that way for the
uniqueness theorem (SIGMA-POL §7) to hold. Forcing a graph into the term algebra
would either duplicate shared subgraphs (changing identity) or smuggle
references into parameters (breaking the injectivity of `encode`). So Σ_flow is
its own signature with its own canonical form, and it **depends on** Σ_pol
(node.policy is a term) rather than extending it. The dependency is one-way:
Σ_pol never mentions flows.

Same versioning discipline as Σ_pol (SIGMA-POL §1.1): `sigma-flow/v1` is
**append-only**. Adding a node `kind` or an optional node key keeps the tag —
existing flows re-encode byte-for-byte and a host predating the addition rejects
it at admission (`unknown kind`) rather than diverging. Removing/retyping a key,
or changing the encoding/normal form, is a major bump that rotates every flow
identity.

## 3. Admission (`flow.check`)

Total, runs before anything executes, rejects a hostile flow before recursion:

1. **Shape.** `t[1] == "flow"`; `t[2]` is a map of string id → node record; each
   node has a `kind ∈ {input, llm, output}`.
2. **Single source / single sink.** Exactly one `input` node and exactly one
   `output` node.
3. **Arity by kind.** `input` has no `inputs`; `output` has exactly one input
   and is referenced by nobody; every `llm` node has ≥1 input.
4. **Closed references.** Every id in any `inputs` list exists in the map.
5. **Acyclic.** A topological sort succeeds (no cycle).
6. **Reachability.** Every node lies on some path input → output: no node is
   unreachable from the input and none is a dead end that never feeds the
   output. A flow with orphan nodes is rejected, not silently pruned (pruning
   would let two different submitted flows share one identity).
7. **Embedded policies.** Each `llm` node's `policy` passes `term.check(policy,
   schema)`; `system` is a string; the optional `template` is a string.
8. **Bounds** (`flow.LIMITS`, part of the spec): `max_nodes = 256`,
   `max_in_degree = 32`. Each policy is independently bounded by `term.LIMITS`.

## 4. Normal form and identity

Node ids are labels, so two flows that differ only by renaming must share one
identity. `flow.normalize` therefore **relabels to canonical ids**:

1. Normalize every node's policy with `term.normalize`.
2. Compute each node's **content key** = `(kind, system, term.encode(policy),
   template)` — everything but its incoming edges.
3. Assign canonical ids in a deterministic topological order: the `input` node
   is `n0`; then repeatedly, among nodes whose inputs are all already assigned,
   take the one smallest by `(content_key, sorted canonical ids of its inputs)`
   and give it the next id; the `output` node sorts last. Because a node's
   inputs are always assigned before it, the key is well-defined, and two nodes
   that tie on it are genuine duplicates (same kind, system, policy, and input
   set) whose relabeling is immaterial.
4. Rewrite every `inputs` list to canonical ids.

`flow.encode(normalize(f))` is the canonical, version-prefixed string: nodes in
canonical-id order, each rendered `(kind <id> system=<enc> policy=<term.encode>
inputs=[<ids>] template=<enc?>)`, with the embedded policy encoded by the Σ_pol
encoder (so a flow's bytes nest a policy's bytes). **Flow identity = sha256 of
that string**, computed host-side; `flow.fingerprint` is only a cache key. The
normal form performs no arithmetic and no LLM call — identity is a property of
structure alone, independent of any model's output (§6).

## 5. Reference driver (`flow.run`)

A flow executor inherently performs I/O (LLM calls), so — unlike Σ_pol's pure
interpreter — the core cannot *run* a flow by itself. Instead it provides a pure
**scheduler parameterized by one effect**, exactly as `interp.eval` is
parameterized by an algebra and the router by `call_provider`:

```lua
flow.run(flow_term, {
  input    = "<the user's prompt>",
  run_node = function(node, prompt) -> text end,  -- the only effect: a routed LLM call
  assemble = function(node, inputs) -> prompt end, -- optional; default below
})
```

- the `input` node's output is `opts.input`;
- each `llm` node, in topological order, assembles its user message from its
  predecessors' outputs (default `assemble`: a single input passes through;
  several are joined as labeled sections in canonical input order; a node
  `template` with `$1,$2,…` placeholders overrides this), then sets its output
  to `run_node(node, assembled)`;
- the `output` node's output is its predecessor's output; `flow.run` returns it.

The scheduling, assembly and ordering are deterministic and replayable; the
**content** of each node's answer is not — the same non-determinism Σ_pol
already lives with, handled at the genlayer layer by validator equivalence, not
by pinning bytes. A flow is reproducible in *structure* (which nodes, which
prompts, which policies, which topology), which is what its identity commits to.

## 6. Host vs core

Core (`unhardcoded-engine`) owns the **IR**: `flow.check / normalize / encode /
fingerprint / run`. It holds no data and makes no calls. The host
(`unhardcoded`) owns the **effects and the surface**:

- `run_node(node, prompt)` ↦ `router.execute{ prompt = prompt, system =
  node.system, policy_ir = node.policy }` — every node call flows through the
  existing Σ_pol router, so a node inherits the whole catalog, cascade, pricing
  and trace machinery for free;
- exposing a registered flow as a callable model, `model = flow:<id>`, beside
  today's `profile:<name>` and `policy_ir`, so any client (and any benchmark
  harness) calls a fusion exactly as it calls one model;
- a per-flow trace: the node DAG with each node's `policy_fingerprint`, chosen
  provider, tokens and cost — the flow-level twin of `decision_trace`.

## 7. The loop back to Σ_pol

Because the host makes a flow callable behind the same OpenAI-compatible
endpoint as a single model, *measuring* a flow against a model is apples-to-apples
by construction: an evaluation harness (a separate project — datasets, graders,
significance testing) hits `flow:<id>` and `gpt-5.5` the same way and compares
the traces. Its output — a score per flow on a benchmark — can be **registered
back as a `model_meta`-style field** (SIGMA-POL §3.1), so Σ_pol policies can then
rank *flows* by *your own* benchmarks. Σ_pol → Σ_flow → eval → back to Σ_pol as
data. The eval layer never depends on the IR; it depends only on the endpoint.
