#!/usr/bin/env bash
# integrate.sh — overlay llm-router into a built genvm tree.
#
# Replaces `genvm-llm-default.lua` with our `dispatch.lua` and drops
# `router.lua` next to `lib-llm.lua` so `require("router")` resolves.
#
# Workflow (mirrors the genvm developer's instructions):
#
#   # in the genvm repo
#   nix develop .#full
#   ./configure.rb
#   ninja -C build all          # produces build/out/
#
#   # in this repo
#   ./genvm/integrate.sh /path/to/genvm/build/out
#
#   # back in the genvm repo
#   ya-test-runner run --filter-name tests/cases/unstable/nondet/llm/call_llm.jsonnet
#
# Pass --overlay <path> to also install a router-overlay.lua module that
# customises profiles (filter/scorer/retry) per deployment.

set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <genvm-build-out-dir> [--overlay <path>]

Arguments:
  <genvm-build-out-dir>    The build/out directory produced by ninja in the
                           genvm repo. Must contain config/ and lib/.

Options:
  --overlay <path>         Install <path> as router-overlay.lua so
                           dispatch.lua picks it up at init time.

  --revert                 Restore the original genvm-llm-default.lua from
                           backup if integrate.sh has been run before.

EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

GENVM_OUT="$1"; shift || true
OVERLAY=""
REVERT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --overlay)  OVERLAY="$2"; shift 2;;
        --revert)   REVERT=1; shift;;
        -h|--help)  usage;;
        *) echo "unknown arg: $1" >&2; usage;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$GENVM_OUT/config/genvm-llm-default.lua"
LIBDIR="$GENVM_OUT/lib/genvm-lua"
BACKUP="$SCRIPT.pre-llm-router"

[[ -d "$GENVM_OUT/config" ]] || { echo "no config/ in $GENVM_OUT — did you build genvm?" >&2; exit 2; }
[[ -d "$LIBDIR" ]]            || { echo "no lib/genvm-lua/ in $GENVM_OUT" >&2; exit 2; }

if [[ $REVERT -eq 1 ]]; then
    [[ -f "$BACKUP" ]] || { echo "no backup at $BACKUP" >&2; exit 3; }
    mv -f "$BACKUP" "$SCRIPT"
    rm -f "$LIBDIR/router.lua" "$LIBDIR/router-overlay.lua"
    rm -f "$LIBDIR/llm_policy.lua"
    rm -rf "$LIBDIR/llm_policy"
    echo "reverted: $SCRIPT restored, router.lua + llm_policy removed"
    exit 0
fi

# Back up the original once.
if [[ ! -f "$BACKUP" ]]; then
    cp "$SCRIPT" "$BACKUP"
    echo "backed up original to $BACKUP"
fi

# Overlay dispatch.lua over the default script.
cp "$REPO_ROOT/genvm/dispatch.lua" "$SCRIPT"
echo "installed dispatch.lua → $SCRIPT"

# Drop the core where lua_path can find it. router.lua is a compat shim that
# requires the llm_policy package; copy both the entry file and (if present)
# the package directory of submodules.
cp "$REPO_ROOT/router.lua" "$LIBDIR/router.lua"
cp "$REPO_ROOT/llm_policy.lua" "$LIBDIR/llm_policy.lua"
[[ -d "$REPO_ROOT/llm_policy" ]] && cp -r "$REPO_ROOT/llm_policy" "$LIBDIR/llm_policy"
echo "installed router.lua + llm_policy → $LIBDIR/"

if [[ -n "$OVERLAY" ]]; then
    [[ -f "$OVERLAY" ]] || { echo "overlay not found: $OVERLAY" >&2; exit 4; }
    cp "$OVERLAY" "$LIBDIR/router-overlay.lua"
    echo "installed router-overlay.lua ← $OVERLAY"
fi

echo
echo "next:"
echo "  cd <genvm-repo>"
echo "  export OPENAIKEY=... HEURISTKEY=... # whatever backends you want to test"
echo "  ya-test-runner run --filter-name tests/cases/unstable/nondet/llm/call_llm.jsonnet"
