-- llm_policy.ir — façade over the Σ_pol IR: signature, terms, fields,
-- interpreter, elaboration. See docs/SIGMA-POL.md for the normative spec.
--
--   ir.compile(term, opts?) -> Policy     admission pipeline: check ->
--                                         normalize -> eval(𝔖). The returned
--                                         policy carries .term (normal form)
--                                         and .fingerprint (cache key).
--   ir.eval_sort(term, opts?) -> carrier, sort   evaluate a term of any sort
--                                         (tests, partial composition).
--
-- opts: { schema = fields.schema(...), customs = { [sym] = fn } }

local sig       = require("llm_policy.sig")
local term      = require("llm_policy.term")
local fields    = require("llm_policy.fields")
local interp    = require("llm_policy.interp")
local elaborate = require("llm_policy.elaborate")

local IR = {
    VERSION   = sig.VERSION,
    sig       = sig,
    term      = term,
    fields    = fields,
    interp    = interp,
    elaborate = elaborate,
}

-- The host-envelope meet: a caller's policy can NARROW the host's invariants,
-- never widen them. Pure term surgery — the result is the same policy with
-- pred = and(envelope, pred); composition is the algebra's ∧, not a mechanism.
-- The envelope must be a Pred term; the router applies config.policy_envelope
-- to every per-call policy_ir through this.
function IR.constrain(policy_term, envelope_pred)
    if type(policy_term) ~= "table" or policy_term[1] ~= "policy" then
        error("ir.constrain: expected a policy term")
    end
    local out = {}
    for i, v in ipairs(policy_term) do out[i] = v end
    out[3] = { "and", envelope_pred, policy_term[3] }
    return out
end

function IR.eval_sort(t, opts)
    local sort, err = term.check(t, opts and opts.schema)
    if sort == nil then error("ir: " .. err) end
    local nf = term.normalize(t)
    return interp.eval(nf, interp.default_algebra(opts)), sort, nf
end

function IR.compile(t, opts)
    local carrier, sort, nf = IR.eval_sort(t, opts)
    if sort ~= "Policy" then
        error("ir: expected a Policy term, got " .. sort)
    end
    carrier.term        = nf
    carrier.fingerprint = term.fingerprint(nf)
    return carrier
end

return IR
