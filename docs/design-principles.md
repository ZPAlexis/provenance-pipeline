# Design principles

[← README](../README.md)

Three patterns, each discovered empirically while prototyping this in Clay, a commercial enrichment tool, before writing any code:

**1. Require corroborating observables the agent can't fake.**
Rather than trusting an agent to self-report uncertainty, demand a second signal that makes its verdict diagnosable. Here that's `roles_listed_count` — total roles visible on the page, regardless of match:

- `not_found` + `23 roles listed` → credible negative
- `not_found` + `0 roles listed` → almost certainly a parse failure

A carefully specified output contract does **not** guarantee the agent can distinguish the states you defined.

**2. Prose reasoning beats the structured verdict.**
In practice the free-text evidence field was read every time to interpret the enum. A structured verdict is a lossy compression of a judgment — `audit_events.reasoning` is where the fidelity lives.

**3. Gate expensive operations behind cheap ones.**
The checks run as a waterfall: deterministic ones first (does the URL resolve? has the page changed?), model calls only on what survives. In prototyping, the AI research step cost ~25x the standard enrichment columns combined. Where a step must cost nothing, it is free by construction: reading the board a proposed company named, when the operator tracks it, runs the worker with no API key at all, so no step of it can reach the AI.

Three more came out of building it against real pages and real agents:

**4. A negative needs the whole list.**
A role is marked closed only when the verifier read every role the page lists: through the ATS's own API, to the end of its pagination, or up to the total the page states. Anything less (page one of fifty, a page that showed no roles and didn't say it has none, one job's ad instead of a list) is *inconclusive*, and no verdict is written. The rule is enforced twice: by the worker, and again at the write path.

**5. What the agent isn't sure of goes to a person, and the person's call is on the record too.**
A low-confidence find is held as a candidate, never watched. The operator confirms, rejects, sets the right page, says what kind of company it is, tracks or archives a role or a company, records a check they made themselves, or undoes a verdict, and each of those is audited under the human's own identity with their reason. Their own AI assistant (Claude or another) may track or archive on their word, recorded as its own with their reason, never on its own judgment; a company it finds waits as a proposal until the operator tracks or declines it. The agents raise what they can't settle in one review queue, each question with what was seen and an action proposed; an item the operator leaves as is comes back only when what was seen changes. An agent may recommend a decision on an item (the operator's own AI assistant does, through MCP), never make it: the operator accepts it or decides otherwise, and how often they agree is measured per kind, the only ground on which a kind would ever be let act on its own. Imported research labels turned out to be wrong often enough that checks made at the source, by the verifier or a person, are the authority.

**6. A permission is checked where the write happens, not where the agent starts.**
Before 1.3 every agent write went through an audited service under a named actor, and "the verifier never tracks a role" held because no service did it: a convention. A scope table that nothing enforces describes intent. So the check sits where every write passes, at the model layer, down to the attributes a write sets, and an agent service also refuses to start without its credential. A write some future code path forgets to check is still caught, and refused on the record.

And one from making the record answerable:

**7. Every figure is worked out from the record, never kept beside it.**
An application's history is its audit log, so the days it spent in each stage come from the dates the operator gave, not from a counter that could drift; how long a role stayed listed comes from the times of the checks themselves; what the AI cost comes from each call as it was made. The analytics are read-only queries over that record, and a rate with fewer than five to go on says so rather than showing a percentage.
