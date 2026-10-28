# Provenance Pipeline

**An agent-governed pipeline system.** AI agents are first-class users, operating under scoped permissions with full provenance on every write.

The CRM half is deliberately minimal. The point of this system is the governance layer around what agents are allowed to do — the data model exists to make that layer meaningful.

> **Status: Stages 1 and 2 complete.** The verifier finds each watched company's careers page, reads it in full, and records a verdict on every tracked posting through one audited write path; a repeat run pays the LLM only for pages whose roles may have changed. From the operator's pages any role or company can be checked now, a company or a role found elsewhere is added by its link, and a search profile has an agent of its own suggest the roles on watched pages that fit it, at no cost; only the operator tracks one. What an agent can't settle (a careers page found at low confidence, a list read only in part, an answer resting on the AI's judgment alone) waits in a review queue, with what was seen, for the operator to decide. Every agent write is checked against a credential issued for its run, with only the scopes that run needs; a write no scope allows is refused, and the refusal is on the record. Everything watched is checked at once from the dashboard, and a what-changed view reports what each check found, including lists that changed so much they may be another page now. Stage 2 has begun with the pipeline itself: an application per role, moved through its stages by the operator alone (no agent scope allows it, and an agent that tries is refused on the record), with what happened along the way. Each role's description is read from its own page, free and never by the LLM, and kept version by version; the operator's resume is held with the profile, in the database only. A draft agent writes cover letters and outreach notes from them, claiming only what the resume shows and flagging what the role asks that it doesn't; the operator edits and approves each one, and nothing is ever sent; it also reviews the resume against a role. The same writing, and a resume tailored to each application, can come from the operator's own Claude client on their subscription, through an MCP server that reads the record and saves what the client writes back under a credential per save. The people the operator deals with are kept as contacts at each company, linked to its applications: an outreach note can be addressed to one, and the client can add a contact and log what happened when told, but never move an application. Each role can be weighed against the resume from its own description, with a score from 0 to 100 and why, in the app or by the operator's own client, which can also find the roles that fit by meaning rather than the profile's exact words. And the review queue has a reviewer: the operator's own client recommends a decision on each item through MCP, never deciding one; the operator accepts it in one click or decides otherwise, and how often they agree is measured per kind. Next: Stage 3, governance completion. See [Build stages](#build-stages).

---

## The problem it solves

The first agent in the system is a **job finder**: it watches a curated set of companies (see [Sourcing](#sourcing-a-watch-list-not-a-search)), and verifies at each employer's own applicant tracking system which postings are actually still open.

That verification step is the product. Job aggregators scrape listing URLs but never check the employer's careers page, so they cannot distinguish a live posting from a filled one. Both failure directions are real:

| Observed | Aggregator said | Employer's ATS said |
|---|---|---|
| Case A | 5 months old, presumed stale | **Live**, accepting applications |
| Case B | Listed and current | **"Job not found"** |

### Why it can't just be an HTTP request

Most applicant tracking systems — Greenhouse, Lever, Ashby, Workable — render listings client-side. An HTTP fetch receives an empty shell.

That produces the worst available failure mode: the agent *reaches* the page, so it doesn't report an access error, but sees no roles in the DOM, so it reports "not found." **A parsing failure gets reported as a confident negative**, indistinguishable downstream from a true one.

There's no pattern-match shortcut either. Measured across 20 resolved careers pages, roughly **70% were hosted on the company's own domain** rather than a recognizable ATS URL — and those frequently embed a client-side job board anyway. The vendor is often invisible from the URL while the rendering requirement stays identical.

**So the verification worker needs a headless browser, not an HTTP client.**

## Sourcing: a watch list, not a search

The system does not search the job market. **It watches a chosen set of companies and reports what changed.**

That separates two jobs that browsing job sites does at once, badly:

| Job | How often | Who does it |
|---|---|---|
| Deciding which companies are worth watching | Rarely | A human — it's a judgment call |
| Checking whether those companies opened or closed a role | Constantly | The system — it's mechanical |

**Two inputs feed the watch list:**

1. **An imported base of companies.** The seed data came from job-board exports, and many of those postings turned out to be stale. That matters less than it sounds: postings are perishable, but the companies behind them are durable, and every posting is re-verified at the source, so a stale listing corrects itself on its first check. The listings were just how the companies were found.
2. **Manual capture.** Paste a company's domain, careers page, or ATS board, or a role's own page; the system finds the company's careers page and ATS, reads it, and adds the company to the watch list for good, and a pasted role is tracked. Job boards and ordinary browsing keep feeding the system — a find gets captured instead of living in a notes file. A job board's own link (LinkedIn, Indeed) is never read: it is kept beside the role as where it was found, and finds the role again if it is already on record.

**The tradeoff, stated plainly: roles at companies outside the list are missed.** There is no crawl, so the list only grows by judgment. That is deliberate. Search-then-filter optimizes for recall; watching a curated list optimizes for precision and fit, which is what this system is for.

**Nothing in the code is specific to one kind of role.** Verification reads every role a careers page shows (a *listing*) and checks whether a tracked *posting* is among them, without knowing what anyone is looking for. The only place a target field enters is a search profile stored as data — titles and keywords, exclusions, the places the user can work, work modes, and seniority as a title states it — which decides which roles are suggested; the user picks the ones to track. Another field, or another person, is another profile.

Two consequences shape the build. A company's careers page becomes a **watch target**, re-checked for months — a higher bar than resolving a page once for a single check. And re-verification makes postings **stateful**: `verified_live` → `not_found` is a lifecycle transition, not a correction, and the audit log is what makes "when did this role close?" answerable.

## Design principles

Three patterns, each discovered empirically while prototyping this in a commercial enrichment tool before writing any code:

**1. Require corroborating observables the agent can't fake.**
Rather than trusting an agent to self-report uncertainty, demand a second signal that makes its verdict diagnosable. Here that's `roles_listed_count` — total roles visible on the page, regardless of match:

- `not_found` + `23 roles listed` → credible negative
- `not_found` + `0 roles listed` → almost certainly a parse failure

A carefully specified output contract does **not** guarantee the agent can distinguish the states you defined.

**2. Prose reasoning beats the structured verdict.**
In practice the free-text evidence field was read every time to interpret the enum. A structured verdict is a lossy compression of a judgment — `audit_events.reasoning` is where the fidelity lives.

**3. Gate expensive operations behind cheap ones.**
Deterministic checks first (does the URL resolve? has the page changed?), model calls only on what survives. In prototyping, the AI research step cost ~25x the standard enrichment columns combined.

Three more came out of building it against real pages and real agents:

**4. A negative needs the whole list.**
A role is marked closed only when the verifier read every role the page lists: through the ATS's own API, to the end of its pagination, or up to the total the page states. Anything less (page one of fifty, a page that showed no roles and didn't say it has none, one job's ad instead of a list) is *inconclusive*, and no verdict is written. The rule is enforced twice: by the worker, and again at the write path.

**5. What the agent isn't sure of goes to a person, and the person's call is on the record too.**
A low-confidence find is held as a candidate, never watched. The operator confirms, rejects, sets the right page, says what kind of company it is, tracks or dismisses a role, records a check they made themselves, or undoes a verdict, and each of those is audited under the human's own identity with their reason. The agents raise what they can't settle in one review queue, each question with what was seen and an action proposed; an item the operator leaves as is comes back only when what was seen changes. An agent may recommend a decision on an item (the operator's own Claude client does, through MCP), never make it: the operator accepts it or decides otherwise, and how often they agree is measured per kind, the only ground on which a kind would ever be let act on its own. Imported research labels turned out to be wrong often enough that checks made at the source, by the verifier or a person, are the authority.

**6. A permission is checked where the write happens, not where the agent starts.**
Before 1.3 every agent write went through an audited service under a named actor, and "the verifier never tracks a role" held because no service did it: a convention. A scope table that nothing enforces describes intent. So the check sits where every write passes, at the model layer, down to the attributes a write sets, and an agent service also refuses to start without its credential. A write some future code path forgets to check is still caught, and refused on the record.

## The permission model

**This is the part that matters.** Each agent gets a deliberately different scope, enforced since 1.3:

| Agent | Granted | Explicitly cannot |
|---|---|---|
| Verifier (research) | `companies:enrich` (a careers page, how it was found, a free board, a suggested kind), `postings:verify` (verdicts and what a check observed; a title only while pending), `evidence:write` (page checks, LLM calls, roles' descriptions) | Track or dismiss a role, name a company or set its kind, decide a review item |
| Suggester | `postings:suggest` (propose a role, refresh or withdraw it while it is still a suggestion) | Track or dismiss a role, or touch one the operator decided on |
| Clay importer | `companies:import`, `postings:import` (the seed data) | Set a role's tracking, or rename a company on record |
| Review queue (a system grant) | `review:keep` (raise, restate, and close what resolved) | Decide an item |
| Draft agent | `drafts:write` (a new draft as it wrote it, and the LLM call that wrote it), `resume_reviews:write` (a review of the resume against a role, and its call); each run holds only the one it needs | Edit or approve a draft, delete a review, or send anything |
| Fit scorer | `fit:write` (how well a role fits the resume, and the LLM call that weighed it) | Track, dismiss or touch a role, change a score, or send anything |
| Assistant (the operator's own Claude client, through MCP) | only the scopes of the save tool it calls, a credential per call: `drafts:write` (a cover letter, an outreach note or a tailored resume), `resume_reviews:write`, `contacts:write` (add a contact, or update one without moving it to another company, and link one to an application), `activities:write` (log what the operator tells it, as the activity logger, and link the contact it names), `postings:suggest` (propose a role it judged may fit, from the stored lists, marked as its own), `fit:write` (how well a role fits, as it weighed it), `review:recommend` (a recommended decision on an open review item, as the review agent: one of its own actions, with why) | Track or dismiss a role; decide a review item or make the write it recommends; edit, approve or delete what it saved; delete a contact; edit or delete an activity; move a stage; or send anything |
| **— no agent —** | `applications:advance_stage` (starting an application or moving it between stages, enforced since 2a); editing or approving a draft; tracking a role; deciding a review item; deleting a contact | **Human-only by design** |

The last row is the point: the most consequential write is withheld from every agent. Read and enrich is safe to automate; drafting is safe-with-review; stage advancement and anything outbound is human-gated.

**How it is enforced** ([`Authority`](app/services/authority.rb), the permission model as code):

- **A credential per run.** Whatever starts an agent run (a rake task, a page's "check now", the background job) issues the agent a credential with exactly that run's scopes, presents it for the run, and revokes it when the run ends; it expires anyway after 4 hours (a batch) or 1 hour (one check). A resolve run can't write a verdict, and a verify run can't change a careers page. Only a SHA-256 digest of the token is stored, and an agent can't issue one.
- **Checked at every write.** Every create, update and destroy passes the check. While an agent acts, the write must be one of its scopes' rules: that model, that action, those attributes, in that state (the suggester may change a role only while it is still a suggestion). The credential is read again at each write, so revoking it stops its run at the next one.
- **Refusals are on the record.** A refused write becomes a `denied` audit event with what it tried and why, kept even when the transaction it stopped rolls back.
- **Every agent write names its credential** (`audit_events.credential_id`), and with it the run, its purpose and its scopes.
- **The audit log is append-only,** for everyone; an event in an agent's name needs that agent's credential.
- **The review queue's bookkeeping** is worked out from the record, not an agent's judgment: it writes under a grant fixed in code, checked by the same guard, limited to review items.
- **The operator's own writes are not checked** while the app is local, single-user and has no login; a login comes with a host (1.4).
- **Reads through MCP are read-only by construction:** every read tool's call runs inside a read-only transaction. Writes through MCP go through save tools, each under a credential for that one call.

The Agents page shows each agent's scopes as the code defines them, the credentials its runs held with what each wrote and was refused, and every refused write.

## Schema

```
companies     name, domain (dedup key), careers_page_url, ats_type,
              resolution_status, resolution_method, resolution_confidence,
              resolution_candidate_url, resolution_failure, resolved_at,
              kind, kind_suggestion, kind_evidence, board_vendor, board_token,
              board_overlap, board_evidence, board_confirmed_at,
              enrichment (jsonb), notes

postings      company_id, role_title, location, posting_url, job_url, posted_on,
              source_slice, tracking (suggested | tracked | dismissed),
              verification_state, roles_listed_count, work_mode,
              last_checked_at, fit (jsonb: why it was suggested),
              enrichment (jsonb)

search_profiles  name, titles, excluded_words, places, work_modes, levels
                 (what the operator is looking for: lists, edited on a page)

applications  posting_id (one per role), company_id, stage, stage_changed_on,
              comp_expectation, notes (the operator's alone to start or move)

activities    application_id, kind, occurred_on, summary, logged_by,
              contact_id (whom it was with)

contacts      company_id, name, role, kind (recruiter | hiring_manager |
              referrer | interviewer | other), email, linkedin_url, notes
              (other people's details: this database only, audited by
              hash, never the values)

application_contacts  application_id, contact_id (a contact linked to an
                      application at its own company, once)

role_descriptions  posting_id, text, content_hash, read_via, url, run_id,
                   first_read_at, last_read_at (one row per distinct text)

resumes       search_profile_id, text, content_hash (one row per version;
              audited by size and hash, never the text)

drafts        application_id, kind (cover_letter | outreach |
              tailored_resume), status (draft | approved), language,
              asked_language, guidance, subject, body (as it stands),
              written_subject, written_body (as written), drew_on (jsonb:
              resume lines), tailoring (jsonb: a tailored resume's changes),
              gaps (jsonb), notes, dropped_lines, resume_id, resume_hash,
              role_description_id, description_hash, llm_call_id, run_id,
              written_by (the drafter, or the assistant through MCP),
              reported_model, revises_id (the draft it polishes), contact_id
              (whom an outreach note is to), edited_at, approved_at
              (audited by size and hash, never the text)

fit_scores    posting_id, score (0 to 100), level, matches (jsonb, each with
              the resume lines behind it), gaps, why, dropped_lines,
              resume_id, resume_hash, role_description_id, description_hash,
              written_by, llm_call_id (every score kept, the newest shown;
              audited by its score, counts and hashes, never the text)

resume_reviews  application_id, language, strengths, gaps, suggestions
              (jsonb, each point with the resume lines behind it), note,
              dropped_lines, resume_id, resume_hash, role_description_id,
              description_hash, written_by, reported_model (audited by its
              counts and hashes, never the text)

page_checks   company_id, run_id, purpose (resolution | verification), step,
              url, final_url, outcome, reason, read_via, ats_vendor, ats_board,
              listing_count, stated_total, listings (jsonb snapshot),
              matches (jsonb: each posting's outcome and reasoning),
              complete (the worker's own answer: was the whole list read?),
              listings_incomplete, single_job_posting, many_employers,
              next_page_url, content_hash, reused_from_id, listings_read_at,
              checked_at

review_items  kind, company_id, subject (polymorphic: the company or one role),
              status (open | done | left), evidence, evidence_key, proposal,
              raised_by, decided_by, decision, note, decided_at,
              recommendation (jsonb: a recommended decision, one of the
              item's own actions with why, and what the operator then did)

agent_credentials  actor, scopes, token_digest, purpose, issued_by,
                   expires_at, revoked_at (one per agent run)

llm_calls     page_check_id, run_id, purpose (extract | resolve | match | relate | draft |
              review | fit), model,
              settings, prompt_version, input_tokens, output_tokens, cost_usd

audit_events  actor, action, target (polymorphic), changes_made (jsonb),
              credential_id (the run's credential, for an agent's write),
              model_version, reasoning, occurred_at
```

Notes on a few choices:

- **UUID primary keys** throughout (via `pgcrypto`).
- **JSONB `enrichment`** on both core tables. Upstream sources vary in shape — one export carries 7 columns, another 28. Structured core plus JSONB avoids a migration every time a source adds a field. Promote a key to a real column once it's filtered or sorted on regularly.
- **`source_slice` lives on postings, not companies**, because one company can surface in several geographic pulls — the slice describes where the posting was found.
- **`changes_made`, not `changes`** — the latter collides with `ActiveModel::Dirty#changes`.
- **Page checks are evidence, not changes.** Every page read, whatever its outcome, is a `page_checks` row with a snapshot of every listing it saw, unfiltered, so a later search profile can be applied to past checks. Changes to companies and postings go through `audit_events`.
- **`llm_calls` answers "what did this cost, and what produced it"** without the run directory: one row per model call, with the model the API reports having served, its settings, and a `prompt_version` hash over the prompt, output schema, and limits.
- **A repeat read is paid for only when the roles may have changed.** A page that links to exactly the role pages it did last time reuses that read's listings, and its check names the read it reused (`reused_from_id`); listings are read in full again once 14 days old (`listings_read_at`). A company whose free ATS board lists at least 90% of its page's roles has that board recorded beside the page (`board_*`, with the evidence) and read in its place for 30 days; the page stays the one on record.
- **Only the operator tracks a role.** A posting is `suggested` (proposed by the suggester, with why in `fit`), `tracked` (on the operator's watch list), or `dismissed` (declined for good: never checked or suggested again); the agent may suggest, never track. A suggestion the operator never acted on is withdrawn when it no longer fits the profile or its check found it gone: deleted, with its whole record kept in its last audit event. `job_url` is the role's own page at the employer, learned from the listing it matched, so the next check finds the role by its link before its title; `posting_url` stays where it was found.
- **Whether a list was read whole is the worker's own answer,** kept on each verification run's first check (`complete`): a role missing from part of a list has not closed, so what changed and the replays of Test B read it rather than guess.
- **An application's history is its audit log.** Each stage change records the stage and the date it happened (the operator's, not when it was typed), so velocity and conversion are measured from the record, not a copy of it.
- **A draft keeps what it was written from.** The resume and description versions it read are linked and hashed (a hash outlives a deleted resume), its LLM call names the model, settings, prompt version and cost, and the text as the drafter wrote it stays beside the operator's edits. Its audit events name its size and hash, never its text: a draft is the resume paraphrased.
- **A contact is someone else's personal data.** Its name, email, link and notes are audited as hashes, never the values, so deleting a contact takes them off the record; its activities and outreach notes stay as they were written, naming no one.
- **A credential is never deleted,** so every agent write can be traced to the run behind it. A refused write is an audit event too (`denied`), with what it tried.
- **The review queue is worked out from the record.** Each open item is a question the record asks now (one per question about one company or role), raised by the agent whose read led to it and closed by the operator's decision or when its evidence resolves, all audited. `evidence_key` fingerprints what was seen: an item left as is is raised again only when it changes.
- **Careers-page resolution is recorded beside the page:** how it was found, how sure we are (`high`, `medium`, `low`, or `confirmed` by a person), a held candidate, or why it failed. A low-confidence find waits in `resolution_candidate_url` and is never watched until a person confirms it.

### Verification fields

A **check** is an observation at the employer's own careers page that produced a verdict: `verified_live`, `not_found`, or `inaccessible`. An upstream answer that maps to none of these is not a check: the posting stays `pending`, and the raw answer is kept in `enrichment`.

- **`verification_state`** — the last check's verdict, or `pending` while there is no usable one.
- **`last_checked_at`** — when that verdict was observed. It is present exactly when a posting has a verdict (enforced by validation), so `nil` means one thing: no check has produced a verdict yet (it may have been checked and found inconclusive).
- **`roles_listed_count`** — roles visible on the page at that check, matched or not. This is the corroborating observable; `nil` means unknown, never a sentinel value.
- **`work_mode`** — as observed at that check.

Imported verdicts carry an operator-supplied check date. A bare date is day precision (stored at 12:00 UTC so the calendar day never shifts), and the posting's create event records where the date came from. The Stage 1.2 verifier becomes the main writer and records the exact time it looked. A verdict that changes is an audited update; a check that confirms the verdict only refreshes `last_checked_at` and what it observed, with the check's own record as its provenance (a role found at a new address is the exception: its `job_url` changes, audited); and a check that couldn't decide (it read only part of a list and found nothing) writes no verdict at all, so a role on page two is never marked closed.

## Build stages

**Stage 1 — Job Finder** ✅ A thin vertical slice through the whole stack rather than a horizontal layer, so something useful ships before the CRUD work and the governance model is proven on real data early.

- **1.1 — Schema and ingest** ✅
- **1.2 — Verification agent** ✅ (Playwright + LLM, Python worker; see [`workers/verifier`](workers/verifier)), in three slices:
  - **1.2a — Render and extract** ✅ read a careers page in a real browser and extract its listings; known job boards (Greenhouse, Lever, Ashby, Workday, Oracle Cloud) are read through their APIs instead.
  - **1.2b — Resolve careers pages** ✅ find each company's careers page from its domain, cheapest step first, with a confidence; low-confidence finds wait for a person. Measured by hiding the known pages of 71 labeled companies and finding them again: 87% found, none wrong at high or medium confidence.
  - **1.2c — Match and verdict** ✅ read each watched page in full (pagination, "load more", ATS APIs), match every tracked posting against it, and record verdicts that follow the evidence. Measured against the research labels on fresh reads: 98% agreement, and no closed role reported open.
  - **Cost pass** ✅ the LLM reads a page only when its role links changed (or every 14 days), and a company's own free ATS board is read in place of its page when it lists the same roles.
- **1.3 — Scoped writes and provenance** ✅ a credential per agent run with exactly that run's scopes, checked at every write down to the attributes it sets; refused writes audited; every agent write names its credential; an Agents page and `agents:` commands. See [The permission model](#the-permission-model).
- **1.4 — Monitoring on demand, and what changed** ✅ one role, one company, or everything, checked when the operator asks: "Check everything" on the dashboard shows its plan and ceiling and asks first, then runs in the background with its progress (137 companies in 47 minutes for $1.17, the first time). A what-changed view reports what each check of everything found: verdicts, suggestions made and withdrawn, careers pages, boards, new review questions, refused writes, and lists that changed a lot between whole reads (raised for review: often another page now). A schedule comes with Stage 4.
- **1.5 — Capture and watched roles** ✅ the first web UI. A search profile suggests roles from the watched pages, the user picks which to track, and each tracked role gets a "check now" that answers *still listed* or *no longer listed*. Paste a careers link, a posting link, or a company domain to resolve, verify, and add it to the watch list. In five slices:
  - **1.5a — Tracked roles and check now** ✅ a tracking state only the operator sets; each role's own page at the employer, matched before its title; `verifier:check`, the role's own page first, then its company's careers page.
  - **1.5b — The operator's pages** ✅ dashboard, roles, companies; track, dismiss, and check now from them.
  - **1.5c — The search profile and suggestions** ✅ a profile edited on its own page; the worker weighs every watched page's latest roles against it at no cost, and an agent of its own suggests the ones that fit, each with why, never one already on record. Refreshed when the profile is saved, on demand, and after every check.
  - **1.5d — Add by URL** ✅ a company by its domain, careers page, or ATS board, and a role by its own page, from the Companies and Roles pages: never added twice, read right away (its careers page found first), what that could cost asked first. A role's title is optional: its page names it. A careers page found at low confidence is confirmed, rejected, or set right on the company's page.
  - **1.5e — The review queue** ✅ what the agents can't settle, raised by them with what was seen and an action proposed: careers pages found at low confidence, suggested kinds, companies with no careers page found, lists read only in part, answers resting on the AI's judgment alone or on a read that saw no roles, and roles that couldn't be confirmed. Decided from the Review page or `review:decide`, through the same audited services as everywhere else.

**Build order was 1.2 → 1.5 → 1.3 → 1.4.** Capture needs only 1.2, so it shipped first to make the tool usable early; 1.3's check sits where every write passes, at the model layer, so it covered capture, suggestions and the review queue without reworking them. Monitoring is human-triggered first, so nothing waits on a host or a scheduler.

**Stage 2 — Pipeline system** ✅ Applications/activities/drafts, CRUD and review UI, MCP server exposing scoped tools, additional agents. In slices:

- **2a — Applications** ✅ one per role, started from its page (tracking it if it wasn't), moved through Interested, Applied, Screening, Interviewing, Offer and Accepted, or closed as Rejected, Withdrawn or No response, by the operator alone, each change dated and noted; what happened along the way logged; a pipeline page by stage, and `applications:` commands.
- **2b — Descriptions and the resume** ✅ each role's description read from its own page (through its board's job API, or the page rendered; never the LLM), when an application starts or when asked, kept as versions, a change shown in what changed; the operator's resume pasted on the Profile page, kept as versions in the database only.
- **2c — The draft agent** ✅ a cover letter or an outreach note for an application, written by Opus 5.5 from the resume, the role's description, the profile and the operator's notes, in the description's language unless another is asked: it claims only what the resume shows, cites the resume lines it drew on, and lists what the role asks that the resume doesn't show. Written in the background from the application's page, where the operator edits, approves and copies it; nothing is ever sent. `drafts:` commands.
- **2d — Writing through MCP** ✅ an MCP server (grown from the operator's read-only learning server) through which the operator's own Claude client, on their subscription rather than API credits, reads an application's materials and the shared writing rules, writes a resume review, a cover letter, an outreach note or a tailored resume, and saves it back as `agent:assistant` under a credential per call, read against the resume version it saw. The resume review also runs in the app, written by the drafter. `reviews:` commands.
- **2e — Contacts and the activity logger** ✅ the people the operator deals with at each company (recruiters, hiring managers, referrers, interviewers), kept with the company and linked to its applications, on both pages; an activity names whom it was with, and an outreach note, from the drafter or the client, can be addressed to one, opening with their first name. Through MCP the client adds and updates contacts and logs what the operator tells it, never moving a stage. `contacts:` commands.
- **2f — Fit scoring** ✅ each role weighed against the resume from its own description, by Haiku 4.5: a score from 0 to 100, the level the role asks, the strongest matches by resume line, the gaps, and why; only when asked, a batch with its cost shown first. On a role's page, and on the Roles page as a Fit column to filter and sort by, with the unscored weighed in the background from there. `fit:` commands. Or from the operator's own Claude client through MCP, on their subscription: it finds roles on the watched pages by meaning, rather than the profile's exact words, suggests the ones that may fit, has their descriptions read, and weighs each by the same rules.
- **2g — The review agent** ✅ the operator's own Claude client, through MCP, recommends a decision on each open review item (one of its own actions, with what it checked and why) and never decides one; the operator accepts or decides otherwise, and agreement is measured per kind. Recommendations sit on their items on the Review page with a one-click Accept, and agreement shows there and on the Agents page; MCP tools and a prompt to work through the queue; `review:accept` and `review:agreement`. No kind acts on its own: autonomy, if ever, is earned per kind on measured agreement.

**Stage 3 — Governance completion.** Full audit views, a review queue for drafts, analytics.

**Stage 4 — Showcase and distribution.** A local app anyone can run on their own machine, on a bundled made-up demo dataset: it works with no API key through free boards and stored reads, takes the user's own key for pages the LLM must read, and their own MCP client connects to it. Alongside it, a hosted read-only showcase of the same demo data. A schedule, a digest, and the production setup come with it, with a full review of the experience (the UI and its flows) and the project's write-up for the portfolio site. Last by design, so it ships a finished system, and nothing before it depends on it.

## Stack

- **Rails 8.1 / Ruby 3.4.8 / PostgreSQL** — core application and system of record
- **solid_queue** — for a schedule, once there is a host; until then the verifier runs on demand
- **Hotwire (Turbo, Stimulus) and importmap** — the operator's pages, plain Rails views with no build step
- **Python + Playwright** — agent workers (managed with uv). Required rather than preferred: the verification step needs headless rendering plus LLM tooling, and both are strongest there.
- **Claude, through the Anthropic API** — Haiku 4.5 reads pages, decides near-miss matches, and weighs fit; Opus 5.5 writes drafts and resume reviews. The key stays outside the repo and reaches the worker process alone.
- **MCP, through the Ruby SDK (gem `mcp`)** — the server the operator's own Claude client connects to
- **RSpec, Rubocop, Brakeman, bundler-audit**

## Setup

```bash
bundle install
bin/rails db:create db:migrate
```

Import Clay CSV exports (a directory or a single file). Clay carries no per-row check date, so an export that includes verdicts needs `VERIFIED_AT`, the date the verdicts were reached (ISO 8601). Without it, the import refuses to run and writes nothing; exports without verdicts don't need it. See [Verification fields](#verification-fields).

```bash
VERIFIED_AT=2026-09-22 bin/rails "clay:import[/path/to/clay-exports]"
bin/rails clay:summary
```

Every write the importer makes is recorded in `audit_events` as a create or an update, with `changes_made` holding `{ attribute => [before, after] }` (JSONB enrichment is diffed key by key). Rows are atomic, and re-importing a file writes nothing.

`clay:summary` breaks down postings by slice, verification state, and work mode, and lists **suspect negatives** — `not_found` verdicts with zero roles listed.

### The verifier

The worker lives in [`workers/verifier`](workers/verifier) (Python, managed with [uv](https://docs.astral.sh/uv/)):

```bash
cd workers/verifier && uv sync && uv run playwright install chromium
```

It calls the Anthropic API with a key kept outside the repo, in `~/.config/provenance-pipeline/anthropic.env` (mode 600, one line: `ANTHROPIC_API_KEY=...`). Rails reads it and hands it to the worker process alone; it is never exported to the shell. Tests never call the API.

Everything runs through rake. Each run writes its targets and results under `tmp/verifier/` (ignored) and records what it found through the one audited write path:

```bash
bin/rails verifier:resolve                       # find careers pages (backs up the database first)
bin/rails verifier:candidates                    # low-confidence finds waiting for a person
bin/rails "verifier:confirm[company_id]"         # or verifier:reject, verifier:set_page, verifier:kind
bin/rails "verifier:status[company name or id]"  # one company: its page, checks, postings, history
bin/rails verifier:verify                        # check everything: shows the plan and its cost; GO=1 runs it
bin/rails verifier:changes                       # what changed since the check of everything before the latest (FROM=)
bin/rails "verifier:describe[posting_id]"        # read a role's description (ROLES=applications|tracked for many); free
bin/rails verifier:find_boards                   # free boards listing the same roles as LLM-read pages (no API cost)
bin/rails "verifier:check[posting_id]"           # is this role still listed? its own page first, then its company's
bin/rails "verifier:track[posting_id]"           # or verifier:dismiss: your watch list, with NOTE="why"
bin/rails verifier:suggest                       # suggestions from the search profile (no API cost); PREVIEW=1 writes nothing
URL="acme.com" bin/rails verifier:add            # add a company by its domain, careers page, or ATS board, and read it
URL="https://..." bin/rails verifier:add_role    # add a role by its own page, tracked, and check it (TITLE, SOURCE optional)
bin/rails "verifier:hand_check[posting_id]"      # record a check you made yourself
bin/rails review:sync                            # bring the review queue in line with the record (no API cost)
bin/rails review:list                            # what waits for your judgment, with each item's id and recommendation (KIND=)
bin/rails "review:accept[item_id]"               # accept an item's recommendation, as the Review page's Accept does
bin/rails review:agreement                       # how recommendations came out, per kind: agreed, differed, resolved, pending
DECISION=leave NOTE="why" bin/rails "review:decide[item_id]"  # decide one item, as on the Review page
bin/rails agents:credentials                     # credentials agent runs held, what each wrote and was refused
NOTE="why" bin/rails "agents:revoke[credential_id]"  # stop a run: its next write is refused
bin/rails applications:list                      # the pipeline by stage, each application's id (STAGE= to filter)
STAGE=applied bin/rails "applications:start[posting_id]"  # start one for a role (ON=, NOTE=); only you can
STAGE=interviewing bin/rails "applications:move[id]"      # move it, on the day it happened (ON=, NOTE=)
KIND=call SUMMARY="..." bin/rails "applications:log[id]"  # log what happened (ON=, CONTACT= with whom)
bin/rails "applications:show[id]"                # its stage, the role's answer, its contacts, and its timeline
CONTACT_NAME="..." COMPANY="Acme" bin/rails contacts:add  # a contact (APPLICATION= links one; ROLE, KIND, CONTACT_EMAIL, LINKEDIN, NOTES)
bin/rails contacts:list                          # contacts by company, with their ids and links (COMPANY=, APPLICATION=)
ROLE="..." bin/rails "contacts:edit[id]"         # change what is given; contacts:link and contacts:unlink take APPLICATION=
bin/rails "contacts:delete[id]"                  # only you can; its activities and outreach notes stay, naming no one
KIND=cover_letter bin/rails "drafts:write[application_id]"  # a draft by the drafter (LANGUAGE=, STRESS=, CONTACT= for a note); Opus 5.5, ~6 cents
bin/rails drafts:list                            # drafts, newest first, with where each stands and its cost (APPLICATION=)
bin/rails "drafts:show[id]"                      # its text, its gaps, the resume lines it drew on, what it was written from
bin/rails "drafts:approve[id]"                   # approve it as it stands; nothing is sent
bin/rails "reviews:write[application_id]"         # a resume review by the drafter (LANGUAGE=); Opus 5.5, ~5 cents
bin/rails fit:score                              # the unscored roles as a plan with its cost; GO=1 weighs them (LIMIT=)
bin/rails "fit:score[posting_id]"                # how well one role fits the resume; Haiku 4.5, under a cent
bin/rails fit:list                               # roles by fit, best first, stale scores marked (MIN=70, LIMIT=)
bin/rails "fit:show[posting_id]"                 # its score, why, the level, matches by resume line, gaps
bin/rails reviews:list                           # reviews, newest first, who wrote each and its cost (APPLICATION=)
bin/rails "reviews:show[id]"                     # its strengths, gaps and suggestions with their lines, and its note
```

### Suggestions

A search profile (the Profile page) says what the operator is looking for: titles, excluded words, the places they can work, work modes, and levels. The worker's `suggest` command weighs every watched company's roles, as its page last listed them, against it: no page is fetched and the LLM is never called. A role fits when its title holds every word of one of the profile's titles, in any order, and none of an excluded one; when it is open to one of the places (a role in São Paulo, or open to Latin America, is open to Brazil; a region on the profile takes roles open to it, never every role inside it); and when its work mode and the level its title states are among those sought. What a role does not state (no place, no work mode, no level) still fits, marked. Each role comes back with its reasoning; Preview shows it all, the roles left out included, and writes nothing.

The suggester (`agent:suggester`) then writes each fitting role that is not already on record as a suggestion, matched against every role on record the way verification matches (its link, then its title), so a role the operator tracks or dismissed is never proposed again. The operator's own Claude client can propose roles too, judged by meaning (see [The MCP server](#the-mcp-server)): its suggestions are marked as its own, and a refresh neither refits nor withdraws them while their page lists them. It refreshes when the profile is saved, from **Find suggestions** on the Roles page, after every check now, and after `verifier:verify`. A suggestion the operator never acted on is withdrawn when it stops fitting, or when its check finds it gone from the whole list; one missing from a read that may be partial stays.

### Drafts

An application's page writes a cover letter or a short outreach note for it (the drafter, `agent:drafter`). The worker's `draft` command makes one structured call to Claude Opus 5.5, at medium effort, with what is on record alone: the operator's newest resume, the role's newest description, the search profile, and the operator's notes on the application. The description and the resume are data, never instructions; the operator's "anything to stress" is theirs.

- **Only what the resume shows.** No experience, skill, employer, figure or date the resume doesn't state, no total worked out from its dates, and no employer described beyond what the resume says of it. What the role asks for that the resume doesn't show is left out and listed as a gap.
- **Cited by line.** The resume goes to the model with its lines numbered, and the draft names the lines it drew on by number, as listings name links: each maps back to the resume's exact text, and a number the resume doesn't have is dropped and counted.
- **In the role's language** (the description's), unless another is asked.
- **To someone, or to no one.** An outreach note can be addressed to one of the company's contacts: it opens with their first name and fits what they do (for a recruiter, how the role fits; for a hiring manager, the work itself). Without one it opens "Hi [name]," for the operator to fill in.
- **Never sent.** The operator edits it, approves it (an edit after that returns it to a draft), and copies it out; only the operator can edit or approve one.
- **Written in the background**, one at a time per application, with what a draft costs on the record shown first (about 6 cents each so far). The run's targets file holds the whole resume, so it is removed when the run ends.

**A resume review** weighs the resume against the role, for the operator to decide what to stress and what to add: strengths with the resume lines behind them, gaps, suggestions naming the lines they touch, and a note. The drafter writes one from the application's page (the worker's `review`, the same model and record, about 6 cents, in English unless another language is asked), under a credential holding `resume_reviews:write` alone; or the operator's own Claude client writes one through MCP and saves it back. Its rules are the shared ones. Advice only: it writes nothing to send and claims nothing.

### Fit scores

How well a role fits the operator, so they can see which roles to apply to first (the fit scorer, `agent:fit_scorer`). The worker's `fit` makes one structured call per role to Claude Haiku 4.5 (the operator's choice: under a cent a role), with what is on record alone: the role's own description, the resume numbered by line, and the titles the profile searches for.

- **A score from 0 to 100, with its reasons.** The scale is anchored in the shared rules (`fit` in `writing_rules.md`): 85 and up shows every must-have at the level asked; 70 to 84 the must-haves, with gaps only in what is preferred; 50 to 69 is a stretch; 25 to 49 some of the work; under 25 another field. With it: the level the role asks beside the resume's, the strongest matches with the resume lines behind them, the gaps, and why in a sentence. Advice for ranking roles: it claims nothing.
- **Kept, never overwritten.** Every score is kept with the resume and description versions it read; the newest is the one shown, marked stale once either changes.
- **Only when asked.** From a role's page, or the unscored in one batch from the Roles page, what it could cost asked first; a description is read first when missing, free. The Roles page shows a Fit column to filter and sort by.
- **Scoped like any agent.** The fit scorer holds `fit:write` alone: it can't track, dismiss or touch a role.
- **Or on the operator's subscription, by meaning.** Through MCP, the operator's own Claude client weighs roles by the same rules and saves the scores. It can also find roles: it names the titles a role like the operator's goes by, the suggester's rules run over the stored lists with those titles, and it suggests the ones it judges may fit (marked as its own) whose own page still has them, then weighs them. See [The MCP server](#the-mcp-server).

The drafter and the fit scorer are the agents whose work is the model's. Without an API key their runs stop and say so; everything else keeps working, and the MCP path does the same work on the operator's own subscription.

### The MCP server

[`mcp/`](mcp) is a stdio [MCP](https://modelcontextprotocol.io) server (the Ruby SDK, gem `mcp`) through which the operator's own Claude client reads the record, writes a resume review, a cover letter, an outreach note or a tailored resume and saves it back, and keeps the operator's contacts and what happened, when told. The model's work is then paid for by the operator's Claude subscription, not by API credits. It grew from the operator's own read-only learning server.

- **Every read tool's call runs inside a read-only transaction,** so no read can write, and a tool's inputs (they come from a model) reach SQL only as bound parameters.
- **A save tool writes as `agent:assistant`,** under a credential issued for that one call with only that tool's scopes, revoked when it ends: checked at every write and audited like any agent's. A write its scopes don't allow comes back to the client as a refusal, kept on the record.
- **stdout carries the protocol,** and nothing else writes there: the protocol keeps a handle of its own, and the process's stdout, which a worker a tool starts inherits, goes to stderr. Rails boots in the background, so the server answers a client's first request at once; times are UTC; an answer is cut at 20,000 characters, and says so.
- **Tools:** `get_company_status` (a company by its name, domain, or a link on its site: its careers page and how it was found, its roles by answer with dismissed ones apart, its last check, its applications); `list_applications` (where each stands, what is written for it, its id); `get_application_materials` (what any writing about an application starts from: the role, its description, the resume numbered by line exactly as the in-app drafter numbers it, the profile, the notes, what is already written, the record's text fenced as data); `get_draft` (a draft in full, whom a note is to, what it rests on, and whether its inputs changed since); `get_writing_rules`; `list_contacts` (a company's contacts, or an application's, with their ids).
- **Prompts,** picked in the client with an application (completed as it is typed): `cover_letter`, `outreach_note` (also to a contact, completed from the application's company), `resume_review`, `tailored_resume`. Each carries the writing rules and the application's materials, so the client writes at once, and keeps the rules through every change asked of it.
- **Save tools,** used only when the operator says to save: `save_draft` (a cover letter, an outreach note, or a tailored resume with its changes) and `save_resume_review`. Each gives back the resume version the client read, so the lines it cites by number are read against the lines it saw (a version no longer on record is refused); a number the resume doesn't have is dropped and counted. A polished version is a new draft that names the one it revises. What is saved shows on the application's page, as the operator's to edit, approve, copy or delete; the record says the client wrote it and the model it reports.
- **Contacts and the activity logger:** `save_contact` adds a contact at an application's company (linked to it) or a company's, or updates one named, giving only what the operator said (never a guessed email or link; the same name twice is refused, naming the one on record); `log_activity` logs what happened, on the day it did or is booked for, with whom (linking them). **It never moves a stage:** when an interview, an offer or an application points to a later stage, its answer says so, and only the operator moves it. `save_draft` takes the contact an outreach note is to.
- **The writing rules live in one file,** [`writing_rules.md`](workers/verifier/src/verifier/writing_rules.md): the worker's drafter builds its prompt from it, and the server's prompts hand it to the client. Only what the resume shows, figures as it states them, an employer as it describes it, gaps listed rather than claimed.
- **Recommending on the review queue (2g):** `list_review_items` (with no kind, the counts alone, so the client asks which kind and how many before reading any; with a kind, or every kind when asked, the items and those with no recommendation yet), `get_review_item` (one item in full: its question, what to check, the actions it may recommend, and everything on record behind it: the company's careers page and how it was found, what the resolver tried, its latest page reads and stated totals, its boards, the roles in play, and for a role how it was last matched, all fenced as data), and `save_recommendation` (one of the item's own actions, with the page or kind it needs, a confidence, what was checked and why, as `agent:assistant` under `review:recommend`). The `review_queue` prompt works through a kind (completed as typed), with that kind's guidance; the client uses its own web search where the record can't settle an item, and recommends the page it finds even when the app may not read it (its roles then come back for hand checks), and decides nothing: the operator accepts or decides on the Review page.
- **Finding and weighing roles (2f):** `find_roles` runs the suggester's rules over the watched pages as last read (nothing fetched, nothing paid for) with the titles the client names in place of the profile's, so a role worded differently is found too, and lists the ones not on record, each with a key. `suggest_roles` proposes the ones the client judged may fit, each with why: since the lists are as last read, it first reads each one's own page (free, keeping nothing), and a role whose page is gone or can't be read isn't suggested; the rest become suggestions as `agent:assistant` under `postings:suggest`, and the descriptions just read are kept by the verifier under its own credential. `read_descriptions` has the verifier read a description a role on record lacks, as the role page's button does (a run tool: nothing is written as the client). `get_roles_to_weigh` gives the fit rules, the resume numbered by line with its version, and each role's description; `save_fit_score` saves a score as the assistant under `fit:write`, its lines read against the resume version it saw. Prompts: `find_roles` (find by meaning, suggest, weigh) and `weigh_roles` (the roles already offered with no current score). No tool tracks a role.
- **Layout:** `mcp/server.rb` (the entry point), `mcp/provenance_mcp.rb` (the shared parts and rules), one file per tool in `mcp/tools/` (a `ReadTool`, `SaveTool` or `RunTool` subclass with an `answer`), specs in `spec/mcp/` (each tool as the server calls it, and the whole server over stdio). `mcp/run.sh` starts it from a client on Windows, through WSL.

**Registering it with Claude Desktop** (Settings → Developer → Edit Config), on the machine that holds the database, with the repo's path inside WSL:

```json
{
  "mcpServers": {
    "provenance_pipeline": {
      "command": "wsl.exe",
      "args": ["bash", "/mnt/<drive>/<path>/provenance-pipeline/mcp/run.sh"]
    }
  }
}
```

**Use it from Desktop chat, not from a session with a shell.** A client that can run commands (Claude Code in this repository) can read the database around the tools, or write through `bin/rails runner` as the operator, unchecked. The governance holds for a client whose only way to the record is the tools: Claude Desktop chat, with no shell-capable server beside it. The record is the operator's private job search, so the server is registered on their machine only. `bundle exec ruby mcp/client.rb "<company>"` is a smoke client that connects the same way.

**In Desktop chat,** pick a prompt from the attachment menu's `provenance_pipeline` entry (Cover letter, Outreach note, Resume review, Tailored resume), type the application's company and role, and send: the client writes from the record and keeps the rules while you ask for changes. Or just ask ("review my resume against the Acme application"): it reads the rules and the materials through the tools. Or tell it what happened ("I had a call with Ana, the recruiter at Acme, today"): it logs it, adding Ana as a contact first if you say to, and tells you when the application looks ready to move; you move it on its page. Or pick Find roles that fit: the client names the titles a role like yours goes by, judges what find_roles lists, suggests what may fit when you say so, has the descriptions read, and gives you the roles weighed, best first; they show among your suggestions in the app, with their scores. Or pick Review the queue (a kind, if you like): it reads each open item, looks into what the record can't settle, and recommends a decision on each; you accept them on the Review page.

### The review queue

What the agents can't settle goes to the operator as a question about one company or role, with what was seen and an action proposed: confirm or reject a careers page found at low confidence, set a company's kind, find a careers page again or set it by hand, set a better page for a list read only in part, say whether a page whose list changed a lot is still the company's, look at a role's page and record what is there, or check a role again. The questions are worked out from the record, so the queue never disagrees with it: every write that can change what a company's record asks (a read, a decision, a withdrawn suggestion) brings that company's items in line, and an item whose evidence resolves closes on its own. Leaving an item as is takes a note, and it comes back only when what was seen changes. A decision goes through the same service as the same write anywhere else, and closes the item in the same transaction.

**A recommended decision** (2g): the operator's own Claude client, through MCP, may recommend one of an item's own actions, with the page or kind it needs, a confidence, what it checked, and why. It never decides one, and never recommends "still listed" or "no longer listed", which record what the operator saw themselves. On the Review page the recommendation sits on its item with **Accept**, named by what it does ("Accept: set this page", "Accept: leave it as is") and saying what follows, which carries it out as the operator's decision through the same path as any other, noting that they followed it; a line at the top of the page leads to the items that carry one; a check it recommends asks first, with its cost. What the operator then does is kept beside it, so agreement is measured per kind (agreed, differed, resolved by the record first, pending): the measure any later autonomy would be judged on. None is granted yet.

The tests that decide whether a slice works run locally against the private target list: `verifier:test_a`, `verifier:test_resolution`, and `verifier:test_b` (`REPLAY=1` replays each company's latest verification run, whole, with the worker's own answer to whether it read the whole list, at no API cost (runs from 1.4 on); `FRESH=1` reads the pages now).

### Backups

Every verifier batch that writes backs up first: `bin/rails db:backup` does the same by hand (checks started from the pages, at most once a day). Dumps go to `~/.local/share/provenance-pipeline/backups/` (owner-only), named with their UTC time. Each new dump prunes the folder to the 10 newest plus the newest of each week for a year. The test environment backs up into `tmp/backups/` instead, never beside the real dumps. To keep a copy on another disk as well, name a folder in `~/.config/provenance-pipeline/backup_mirror` (one line); each new dump is copied and pruned there the same way, and a failed copy is reported without stopping the batch.

A backup is proven by restoring it. Into a scratch database, then compare and drop it:

```bash
createdb provenance_pipeline_restore_check
pg_restore --no-owner --exit-on-error --dbname=provenance_pipeline_restore_check ~/.local/share/provenance-pipeline/backups/<newest>.dump
psql -d provenance_pipeline_restore_check -c "select count(*) from postings"
dropdb provenance_pipeline_restore_check
```

Boot the server:

```bash
bin/rails server
```

It serves the operator's pages at `http://localhost:3000`: the pipeline (applications by stage, each with a page to move it, log what happened and with whom, keep its contacts, write and approve its drafts, and read its timeline), a dashboard (where applications and the tracked roles stand, "Check everything" with its plan, ceiling and progress, recent checks and verdict changes, API credit spent), what changed since a check of everything, the roles (tracked, suggested with why, dismissed, filtered by answer and by fit, sorted by fit, the unscored weighed from there), each role's history, its description, its fit and the checks behind it, the companies watched (each with its contacts), the search profile with a preview of what it would suggest and the operator's resume, and the Review page: the questions waiting for the operator, by kind, each naming its company and role and decided with a button; a check asked from one is followed on the item until it says whether it settled it; and the Agents page: each agent's scopes, the credentials its runs held, with what each wrote, and every refused write. From them the operator adds a company or a role by its link, confirms or sets a company's careers page, tracks or dismisses a role with a note on the record, finds suggestions, and checks a role or a company now: the check runs in the background, one at a time, and a check that could spend says its ceiling and asks first. It is local and single-user, with no login, so it is never deployed as it is.

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path. The verifier's run directories (`tmp/verifier/`) and database backups (`~/.local/share/provenance-pipeline/backups/`) hold the same list, so they stay out of the repo too.
