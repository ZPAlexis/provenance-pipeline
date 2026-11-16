# The permission model

[← README](../README.md)

Every agent's scopes, what each may never do, and how the rules are enforced. The README has the short form.

Each agent gets a deliberately different scope, enforced since 1.3:

| Agent | Granted | Explicitly cannot |
|---|---|---|
| Verifier (research) | `companies:enrich` (a careers page, how it was found, a free board, a suggested kind), `postings:verify` (verdicts and what a check observed; a title only while pending), `evidence:write` (page checks, LLM calls, roles' descriptions) | Track or archive a role or a company, name a company or set its kind, decide a review item |
| Suggester | `postings:suggest` (propose a role at a company the operator tracks, refresh or withdraw it while it is still a suggestion) | Track or archive a role or a company, or touch a role the operator decided on |
| Clay importer | `companies:import`, `postings:import` (the seed data) | Set a role's or a company's tracking or a company's proposal, or rename a company on record |
| Review queue (a system grant) | `review:keep` (raise, restate, and close what resolved) | Decide an item |
| Draft agent | `drafts:write` (a new draft as it wrote it, and the LLM call that wrote it), `resume_reviews:write` (a review of the resume against a role, and its call); each run holds only the one it needs | Edit or approve a draft, delete a review, or send anything |
| Fit scorer | `fit:write` (how well a role fits: each role scored 0 to 100 against the resume, with its matches by resume line, its gaps and why, by the [`fit` rules](../workers/verifier/src/verifier/writing_rules.md#fit), and since 4c the Background fit beside it, by [`background_fit`](../workers/verifier/src/verifier/writing_rules.md#background_fit); and the LLM call that weighed it) | Track, archive or touch a role, change a score, or send anything |
| AI assistant (the operator's own, Claude or another, through [MCP](mcp.md)) | only the scopes of the save tool it calls, a credential per call: 11 scopes, [listed below](#the-ai-assistants-scopes) | Act on its own judgment, decide, approve, delete, move a stage or send anything ([in full below](#the-ai-assistants-scopes)) |
| **— no agent —** | Starting an application or moving it between stages (no scope allows writing one, since 2a, so an agent that tries is refused on the record); editing or approving a draft; deciding a review item; editing the search profile (its company preferences aside, which the operator's own client may save on their word), the resume, or the background information; naming a company or setting its kind; deleting a contact; issuing or revoking a credential; asking for a check that writes a verdict or spends API credit (the client may read a role's description or its own page, free) | **Human-only by design** |

The last row is the point: the most consequential write is withheld from every agent. It is the code's own list (`Authority::HUMAN_ONLY`), shown on the Agents page. Read and enrich is safe to automate; drafting is safe-with-review; stage advancement and anything outbound is human-gated.

### The AI assistant's scopes

The operator's own AI assistant (Claude or another, through [MCP](mcp.md)) holds only the scopes of the save tool it calls, under a credential for that one call:

- `drafts:write`: a cover letter, an outreach note or a tailored resume
- `resume_reviews:write`: a review of the resume against a role
- `contacts:write`: add a contact, or update one without moving it to another company, and link one to an application
- `activities:write`: log what the operator tells it, as the activity logger, and link the contact it names
- `postings:suggest`: propose a role it judged may fit, from the stored lists, marked as its own
- `fit:write`: how well a role fits, as it weighed it
- `review:recommend`: a recommended decision on an open review item, as the review agent: one of its own actions, with why
- `watchlist:curate` (4a): on the operator's word, with their reason: track or archive a role or a company, add a role to a company they track, tracked and never checked, or change a role's own page; and (4b) start the free read of the board of a company proposed to them that it tracks
- `companies:suggest` (4b): propose a company that may fit, as suggested, with its name, domain and why, never tracked and never with a careers page
- `company_reviews:write` (4b): a review of how well a company fits the company preferences, as it researched it, never edited or deleted
- `company_preferences:write` (4b): on the operator's word, the company preferences alone, never the rest of the profile

It may never:

- track or archive anything on its own judgment
- set a verdict, a company's name, careers page or kind
- decide a review item or make the write it recommends
- edit, approve or delete what it saved
- delete a contact
- edit or delete an activity
- move a stage
- send anything

**How it is enforced** ([`Authority`](../app/services/authority.rb), the permission model as code):

- **A credential per run.** Whatever starts an agent run (a rake task, a page's "check now", the background job) issues the agent a credential with exactly that run's scopes, presents it for the run, and revokes it when the run ends; it expires anyway after 4 hours (a batch) or 1 hour (one check). A resolve run can't write a verdict, and a verify run can't change a careers page. Only a SHA-256 digest of the token is stored, and an agent can't issue one.
- **Checked at every write.** Every create, update and destroy passes the check. While an agent acts, the write must be one of its scopes' rules: that model, that action, those attributes, in that state (the suggester may change a role only while it is still a suggestion). The credential is read again at each write, so revoking it stops its run at the next one.
- **Refusals are on the record.** A refused write becomes a `denied` audit event with what it tried and why, kept even when the transaction it stopped rolls back.
- **Every agent write names its credential** (`audit_events.credential_id`), and with it the run, its purpose and its scopes.
- **The audit log is append-only,** for everyone; an event in an agent's name needs that agent's credential. The database holds it too: a trigger refuses any update, delete or truncate of `audit_events`, so a write that slips past the app (a bulk update, raw SQL, a console) is refused as well.
- **What the database deletes with a record is on the record too.** A withdrawn suggestion takes its fit scores with it: each gets its own destroy event first, in the form its creation took (its score, counts and hashes, never the resume's text), and its description versions are counted in the role's. A deleted contact's links to applications each get theirs, as one unlinked by hand does.
- **The review queue's bookkeeping** is worked out from the record, not an agent's judgment: it writes under a grant fixed in code, checked by the same guard, limited to review items.
- **The operator's own writes are not checked** while the app is local, single-user and has no login; a login comes before it is ever deployed.
- **Reads through MCP are read-only by construction:** every read tool's call runs inside a read-only transaction. Writes through MCP go through save tools, each under a credential for that one call.
- **Viewing a page writes nothing.** A check left queued or running past its time (the server stopped mid-way) shows as cut off and is polled no more; its row says so when the next check starts, and a queued one whose time ran out isn't run when its turn comes.

The Agents page shows each agent's scopes as the code defines them, the credentials its runs held with what each wrote and was refused, and every refused write. The Audit log page holds every event, the operator's included, narrowed by who made it, the kind of record, the action, the days, one record or the credential behind it, and an attribute it changed.
