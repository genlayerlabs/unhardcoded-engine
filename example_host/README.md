# example_host

The **minimal** reference for embedding the `llm_policy` core in a Python host.
One file, ~80 lines: load the core via lupa, install the `host` table (the I/O
the pure core delegates), `init` a catalog, run `execute`, print the decision.

```bash
nix-shell -p 'python3.withPackages(ps:[ps.lupa])' \
    --run 'python example_host/example.py'
```

It is a **teaching example**, not a production host. The `call_provider` is a
mock; there is no real HTTP, no async, no auth resolution, no provider-specific
backends. It exists to show the embedding contract:

1. Provide a `host` table: `call_provider`, `now_ms`, `log`, `env`
   (+ optional `sleep_ms`, `discover`).
2. `router = dofile("router.lua")` (a shim for `require("llm_policy")`).
3. `router.init(config)` then `router.execute(contract)`.

For the real host — async OpenAI-compatible shim, the auth resolver
(`none`/`bearer`/`oauth`), Codex (ChatGPT subscription), AntSeed — see the
**unhardcoded host** repo. Embedding in Rust (mlua, GenVM) is the same contract;
see `genvm/dispatch.lua` for the on-chain adapter.
