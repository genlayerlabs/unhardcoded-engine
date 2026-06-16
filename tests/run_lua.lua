-- Runner for all Lua unit tests. Run from repo root:
--   lua tests/run_lua.lua

package.path = package.path .. ";./tests/unit/?.lua"

local files = {
    "tests/unit/profile_inheritance.lua",
    "tests/unit/filter.lua",
    "tests/unit/derive_needs.lua",
    "tests/unit/execute.lua",
    "tests/unit/execute_step.lua",
    "tests/unit/policy_verbs.lua",
    "tests/unit/parity.lua",
    "tests/unit/declarative_policy.lua",
    "tests/unit/price_enrichment.lua",
    "tests/unit/provider_status.lua",
    "tests/unit/ir_term.lua",
    "tests/unit/ir_interp.lua",
    "tests/unit/ir_elaborate.lua",
    "tests/unit/ir_golden.lua",
    "tests/unit/flow_basic.lua",
}

for _, f in ipairs(files) do
    io.write("=== " .. f .. " ===\n")
    dofile(f)
end

local t = require("_assert")
local rc = t.summary()
os.exit(rc == 0 and 0 or 1)
