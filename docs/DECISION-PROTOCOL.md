# Decision model routing

Contracts and candidates may declare `protocol = "decisions"`. An omitted
protocol means `chat`, preserving existing callers and catalogs. Static models
declare `protocol` on the model; marketplace hosts declare it on each offer.

The engine partitions candidates by protocol before policies and pins. A policy,
pin, or fallback cannot cross that boundary. Unknown request protocols produce
no candidates. Hosts must validate the decision request before execution.

For decision requests, the opaque `contract.decision` object is forwarded as
`request.decision`, along with `request.protocol`, through every attempt. The
host owns protocol-specific transport and response validation. Provider identity,
wire model, auth, prices, deadlines, breakers and fallback selection retain their
existing semantics. This does not turn decisions into chat messages.
