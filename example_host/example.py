#!/usr/bin/env python3
"""
example_host/example.py — the minimal way to embed the llm_policy core.

"Hello world" of embedding: load the core, install the `host` table (the I/O the
pure core delegates), init a catalog, run `execute`, print the decision + trace.

This is a *teaching reference*, not a production host: the call_provider is a
mock (no real HTTP, no auth, no async, no provider-specific backends). For the
real host — async OpenAI-compatible shim, the auth resolver (none/bearer/oauth),
Codex/AntSeed — see the unhardcoded host repo.

Run:
    nix-shell -p 'python3.withPackages(ps:[ps.lupa])' \
        --run 'python example_host/example.py'
"""
from __future__ import annotations

from pathlib import Path

import lupa
from lupa import LuaRuntime

CORE = Path(__file__).resolve().parents[1]   # repo root: llm_policy.lua + llm_policy/


def to_lua(lua, obj):
    if isinstance(obj, dict):
        return lua.table_from({k: to_lua(lua, v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple)):
        return lua.table_from([to_lua(lua, x) for x in obj])
    return obj


def to_py(obj):
    if lupa.lua_type(obj) != "table":
        return obj
    keys = list(obj.keys())
    if keys and all(isinstance(k, int) for k in keys) and set(keys) == set(range(1, len(keys) + 1)):
        return [to_py(obj[i]) for i in range(1, len(keys) + 1)]
    return {k: to_py(v) for k, v in obj.items()}


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)

    # The `host` table is the I/O the pure core delegates. The simplest possible
    # call_provider is a mock that echoes; a real host POSTs to the provider and
    # returns this same shape ({ ok, latency_ms, response = { text, ... } }).
    def call_provider(request):
        req = to_py(request)
        return to_lua(lua, {
            "ok": True,
            "latency_ms": 5,
            "response": {
                "text": f"[mock {req['provider_id']}/{req['model_family']}] hi back",
                "finish_reason": "stop",
            },
        })

    lua.globals()["host"] = lua.table_from({
        "now_ms":        lambda: 0,
        "log":           lambda level, event, fields: None,
        "env":           lambda key: None,
        "call_provider": call_provider,
    })

    # Make the core require-able, then load it (router.lua is a shim that does
    # `return require("llm_policy")`).
    lua.globals()["__core"] = str(CORE)
    lua.execute('package.path = __core.."/?.lua;"..__core.."/?/init.lua;"..package.path')
    lua.globals()["__router"] = str(CORE / "router.lua")
    lua.globals()["__config"] = str(CORE / "config.example.lua")

    router = lua.eval("dofile(__router)")
    config = lua.eval("dofile(__config)")

    ok, err = router.init(config)
    assert ok, f"router.init failed: {err}"

    result = to_py(router.execute(to_lua(lua, {
        "prompt":  "Say hi.",
        "profile": "default",
    })))

    print("ok      :", result["ok"])
    print("chosen  :", result["chosen"])
    print("response:", result["response"]["text"])
    print("trace   :")
    for ev in result["trace"]["decision_path"]:
        print("   ", ev.get("event"), ev.get("provider_id"), ev.get("model_family"),
              ev.get("outcome") or ev.get("error_kind") or "ok")


if __name__ == "__main__":
    main()
