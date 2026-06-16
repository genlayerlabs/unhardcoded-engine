-- Profile inheritance resolution: extends, deep merge, cycle detection.
-- (sigma-pol/v2) Uses `hard_constraints` (a live nested-table field) as the
-- merge subject; the removed `weights` map used to play this role.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

t.test("profile without extends is returned as a deep copy", function()
    local profiles = {
        base = { hard_constraints = { min_context = 4000, min_tok_s = 10 } },
    }
    local rp = r.resolve_profile("base", profiles)
    t.eq(rp.hard_constraints.min_context, 4000, "min_context preserved")
    t.eq(rp.hard_constraints.min_tok_s,   10,   "min_tok_s preserved")

    -- mutate result; original should not change
    rp.hard_constraints.min_context = 999
    t.eq(profiles.base.hard_constraints.min_context, 4000, "original profile not mutated")
end)

t.test("child profile inherits and overrides parent constraints", function()
    local profiles = {
        base = { hard_constraints = { min_context = 4000, min_tok_s = 10, max_latency_ms = 5000 } },
        fast = { extends = "base", hard_constraints = { min_tok_s = 50 } },
    }
    local rp = r.resolve_profile("fast", profiles)
    t.eq(rp.hard_constraints.min_context,    4000, "parent min_context inherited")
    t.eq(rp.hard_constraints.min_tok_s,      50,   "child min_tok_s overrides")
    t.eq(rp.hard_constraints.max_latency_ms, 5000, "parent max_latency_ms inherited")
end)

t.test("child profile inherits non-overridden fields", function()
    local profiles = {
        base = { retry_policy = "balanced", hard_constraints = { min_context = 4000 } },
        derived = { extends = "base", hard_constraints = { min_context = 8000 } },
    }
    local rp = r.resolve_profile("derived", profiles)
    t.eq(rp.retry_policy, "balanced", "retry_policy inherited")
end)

t.test("hard_constraints from parent merge with child", function()
    local profiles = {
        base = { hard_constraints = { privacy = "tee_required" } },
        sub  = { extends = "base", hard_constraints = { min_context = 8000 } },
    }
    local rp = r.resolve_profile("sub", profiles)
    t.eq(rp.hard_constraints.privacy,     "tee_required", "parent constraint inherited")
    t.eq(rp.hard_constraints.min_context, 8000,           "child constraint added")
end)

t.test("cycle detection raises", function()
    local profiles = {
        a = { extends = "b" },
        b = { extends = "a" },
    }
    local ok, err = pcall(r.resolve_profile, "a", profiles)
    t.falsy(ok, "should error")
    t.contains(err, "cycle", "error mentions cycle")
end)

t.test("multi-level inheritance flattens correctly", function()
    local profiles = {
        root  = { hard_constraints = { min_context = 1, min_tok_s = 1, max_latency_ms = 1 } },
        mid   = { extends = "root", hard_constraints = { min_tok_s = 2 } },
        leaf  = { extends = "mid",  hard_constraints = { max_latency_ms = 3 } },
    }
    local rp = r.resolve_profile("leaf", profiles)
    t.eq(rp.hard_constraints.min_context,    1, "from root")
    t.eq(rp.hard_constraints.min_tok_s,      2, "from mid")
    t.eq(rp.hard_constraints.max_latency_ms, 3, "from leaf")
end)
