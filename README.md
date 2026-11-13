# Provenance Pipeline

**An agent-governed pipeline system.** AI agents are first-class users, operating under scoped permissions with full provenance on every write.

**What it is:** a job-search CRM, built for its author's own search, where AI agents do the legwork: they check at each employer's own careers page whether a role is still listed, suggest roles and companies that fit, draft cover letters and outreach, and score each role against the resume. **Why it matters:** the CRM is the setting; the point is the governance layer most teams skip when they put agents to work. Every agent acts under a credential scoped to the fields it may write, a write it isn't allowed is refused and recorded, every change lands in an append-only audit log, and the decisions that matter stay with the human-in-the-loop, including when their own Claude works through the MCP server.

> **Status: Stages 1, 2 and 3 complete; in Stage 4, 4a, 4b and 4c are complete, and the hosted public form is decided and paused until more of the review of the experience is done.** What works today, locally:
> - **Watching:** the verifier finds each watched company's careers page, reads it in full, and records whether each tracked role is still listed, through one audited write path; a repeat run pays the AI only for pages whose roles may have changed. Everything watched is checked at once from the dashboard, and a what-changed view says what each check found.
> - **Finding:** an agent suggests the roles on watched pages that fit a search profile, at no cost; the operator's own Claude client finds roles by meaning, and companies that fit what the operator wants of one, each researched and scored. Only the operator decides what is watched.
> - **The pipeline:** an application per role, moved through its stages by the operator alone; each role's description read and kept; cover letters, outreach notes, resume reviews and fit scores, from an in-app agent or from the operator's own client through MCP, and nothing ever sent; a role's fit read two ways, from the resume alone as a recruiter's screening system would and with the background the operator keeps beside it, each kind of writing given only the part of that background it may use; contacts, and what happened with them.
> - **Governance:** every agent write is checked against a credential issued for its run, refused on the record when no scope allows it, and kept in an append-only audit log that can be searched; what agents can't settle waits in a review queue, where the client recommends and the operator decides; analytics are read from the same record.
>
> Each stage in full: [Build stages](#build-stages).

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

**So the verification worker needs a headless browser, not an HTTP client.** (A hosted board's public API is the exception: when the worker recognizes one, it reads the list there, exact and free; the browser is for everything else.)

## Sourcing: a watch list, not a search

The system does not search the job market. **It watches a chosen set of companies and reports what changed.**

That separates two jobs that browsing job sites does at once, badly:

| Job | How often | Who does it |
|---|---|---|
| Deciding which companies are worth watching | Rarely | A human — it's a judgment call (their own Claude client may propose; they decide) |
| Checking whether those companies opened or closed a role | Constantly | The system — it's mechanical |

**Three inputs feed the watch list:**

1. **An imported base of companies.** The seed data came from job-board exports, and many of those postings turned out to be stale. That matters less than it sounds: postings are perishable, but the companies behind them are durable, and every posting is re-verified at the source, so a stale listing corrects itself on its first check. The listings were just how the companies were found.
2. **Manual capture.** Paste a company's domain, careers page, or ATS board, or a role's own page; the system finds the company's careers page and ATS, reads it, and adds the company to the watch list for good, and a pasted role is tracked. Job boards and ordinary browsing keep feeding the system — a find gets captured instead of living in a notes file. A job board's own link (LinkedIn, Indeed) is never read: it is kept beside the role as where it was found, and finds the role again if it is already on record.
3. **Proposals from the operator's own Claude client** (4b). Asked to, it searches the open web for companies that fit what the operator wants of one (kept on the profile), checks each against the record and its job board, and proposes it with a review: a score from 0 to 100, point by point, with its sources. A proposal is watched only once the operator tracks it, and one they decline is never proposed again.

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
Deterministic checks first (does the URL resolve? has the page changed?), model calls only on what survives. In prototyping, the AI research step cost ~25x the standard enrichment columns combined. Where a step must cost nothing, it is free by construction: reading the board a proposed company named, when the operator tracks it, runs the worker with no API key at all, so no step of it can reach the AI.

Three more came out of building it against real pages and real agents:

**4. A negative needs the whole list.**
A role is marked closed only when the verifier read every role the page lists: through the ATS's own API, to the end of its pagination, or up to the total the page states. Anything less (page one of fifty, a page that showed no roles and didn't say it has none, one job's ad instead of a list) is *inconclusive*, and no verdict is written. The rule is enforced twice: by the worker, and again at the write path.

**5. What the agent isn't sure of goes to a person, and the person's call is on the record too.**
A low-confidence find is held as a candidate, never watched. The operator confirms, rejects, sets the right page, says what kind of company it is, tracks or archives a role or a company, records a check they made themselves, or undoes a verdict, and each of those is audited under the human's own identity with their reason. Their own Claude client may track or archive on their word, recorded as its own with their reason, never on its own judgment; a company it finds waits as a proposal until the operator tracks or declines it. The agents raise what they can't settle in one review queue, each question with what was seen and an action proposed; an item the operator leaves as is comes back only when what was seen changes. An agent may recommend a decision on an item (the operator's own Claude client does, through MCP), never make it: the operator accepts it or decides otherwise, and how often they agree is measured per kind, the only ground on which a kind would ever be let act on its own. Imported research labels turned out to be wrong often enough that checks made at the source, by the verifier or a person, are the authority.

**6. A permission is checked where the write happens, not where the agent starts.**
Before 1.3 every agent write went through an audited service under a named actor, and "the verifier never tracks a role" held because no service did it: a convention. A scope table that nothing enforces describes intent. So the check sits where every write passes, at the model layer, down to the attributes a write sets, and an agent service also refuses to start without its credential. A write some future code path forgets to check is still caught, and refused on the record.

And one from making the record answerable:

**7. Every figure is worked out from the record, never kept beside it.**
An application's history is its audit log, so the days it spent in each stage come from the dates the operator gave, not from a counter that could drift; how long a role stayed listed comes from the times of the checks themselves; what the AI cost comes from each call as it was made. The analytics are read-only queries over that record, and a rate with fewer than five to go on says so rather than showing a percentage.

## The permission model

**This is the part that matters.** Each agent gets a deliberately different scope, enforced since 1.3:

| Agent | Granted | Explicitly cannot |
|---|---|---|
| Verifier (research) | `companies:enrich` (a careers page, how it was found, a free board, a suggested kind), `postings:verify` (verdicts and what a check observed; a title only while pending), `evidence:write` (page checks, LLM calls, roles' descriptions) | Track or archive a role or a company, name a company or set its kind, decide a review item |
| Suggester | `postings:suggest` (propose a role at a company the operator tracks, refresh or withdraw it while it is still a suggestion) | Track or archive a role or a company, or touch a role the operator decided on |
| Clay importer | `companies:import`, `postings:import` (the seed data) | Set a role's or a company's tracking or a company's proposal, or rename a company on record |
| Review queue (a system grant) | `review:keep` (raise, restate, and close what resolved) | Decide an item |
| Draft agent | `drafts:write` (a new draft as it wrote it, and the LLM call that wrote it), `resume_reviews:write` (a review of the resume against a role, and its call); each run holds only the one it needs | Edit or approve a draft, delete a review, or send anything |
| Fit scorer | `fit:write` (how well a role fits the resume, and the LLM call that weighed it) | Track, archive or touch a role, change a score, or send anything |
| Assistant (the operator's own Claude client, through MCP) | only the scopes of the save tool it calls, a credential per call: `drafts:write` (a cover letter, an outreach note or a tailored resume), `resume_reviews:write`, `contacts:write` (add a contact, or update one without moving it to another company, and link one to an application), `activities:write` (log what the operator tells it, as the activity logger, and link the contact it names), `postings:suggest` (propose a role it judged may fit, from the stored lists, marked as its own), `fit:write` (how well a role fits, as it weighed it), `review:recommend` (a recommended decision on an open review item, as the review agent: one of its own actions, with why), `watchlist:curate` (on the operator's word, with their reason: track or archive a role or a company, add a role to a company they track, tracked and never checked, or change a role's own page; 4a; and start the free read of the board of a company proposed to them that it tracks, 4b), `companies:suggest` (propose a company that may fit, as suggested, with its name, domain and why, never tracked and never with a careers page; 4b), `company_reviews:write` (a review of how well a company fits the company preferences, as it researched it, never edited or deleted; 4b), `company_preferences:write` (on the operator's word, the company preferences alone, never the rest of the profile; 4b) | Track or archive anything on its own judgment; set a verdict, a company's name, careers page or kind; decide a review item or make the write it recommends; edit, approve or delete what it saved; delete a contact; edit or delete an activity; move a stage; or send anything |
| **— no agent —** | Starting an application or moving it between stages (no scope allows writing one, since 2a, so an agent that tries is refused on the record); editing or approving a draft; deciding a review item; editing the search profile (its company preferences aside, which the operator's own client may save on their word), the resume, or the background information; naming a company or setting its kind; deleting a contact; issuing or revoking a credential; asking for a check that writes a verdict or spends API credit (the client may read a role's description or its own page, free) | **Human-only by design** |

The last row is the point: the most consequential write is withheld from every agent. It is the code's own list (`Authority::HUMAN_ONLY`), shown on the Agents page. Read and enrich is safe to automate; drafting is safe-with-review; stage advancement and anything outbound is human-gated.

**How it is enforced** ([`Authority`](app/services/authority.rb), the permission model as code):

- **A credential per run.** Whatever starts an agent run (a rake task, a page's "check now", the background job) issues the agent a credential with exactly that run's scopes, presents it for the run, and revokes it when the run ends; it expires anyway after 4 hours (a batch) or 1 hour (one check). A resolve run can't write a verdict, and a verify run can't change a careers page. Only a SHA-256 digest of the token is stored, and an agent can't issue one.
- **Checked at every write.** Every create, update and destroy passes the check. While an agent acts, the write must be one of its scopes' rules: that model, that action, those attributes, in that state (the suggester may change a role only while it is still a suggestion). The credential is read again at each write, so revoking it stops its run at the next one.
- **Refusals are on the record.** A refused write becomes a `denied` audit event with what it tried and why, kept even when the transaction it stopped rolls back.
- **Every agent write names its credential** (`audit_events.credential_id`), and with it the run, its purpose and its scopes.
- **The audit log is append-only,** for everyone; an event in an agent's name needs that agent's credential. The database holds it too: a trigger refuses any update, delete or truncate of `audit_events`, so a write that slips past the app (a bulk update, raw SQL, a console) is refused as well.
- **What the database deletes with a record is on the record too.** A withdrawn suggestion takes its fit scores with it: each gets its own destroy event first, in the form its creation took (its score, counts and hashes, never the resume's text), and its description versions are counted in the role's. A deleted contact's links to applications each get theirs, as one unlinked by hand does.
- **The review queue's bookkeeping** is worked out from the record, not an agent's judgment: it writes under a grant fixed in code, checked by the same guard, limited to review items.
- **The operator's own writes are not checked** while the app is local, single-user and has no login; a login comes with a host, in Stage 4.
- **Reads through MCP are read-only by construction:** every read tool's call runs inside a read-only transaction. Writes through MCP go through save tools, each under a credential for that one call.
- **Viewing a page writes nothing.** A check left queued or running past its time (the server stopped mid-way) shows as cut off and is polled no more; its row says so when the next check starts, and a queued one whose time ran out isn't run when its turn comes.

The Agents page shows each agent's scopes as the code defines them, the credentials its runs held with what each wrote and was refused, and every refused write. The Audit log page holds every event, the operator's included, narrowed by who made it, the kind of record, the action, the days, one record or the credential behind it, and an attribute it changed.

## Schema

```
companies     name, domain (dedup key), careers_page_url, ats_type,
              resolution_status, resolution_method, resolution_confidence,
              resolution_candidate_url, resolution_failure, resolved_at,
              kind, kind_suggestion, kind_evidence, board_vendor, board_token,
              board_overlap, board_evidence, board_confirmed_at,
              tracking (tracked | suggested: proposed by the operator's own client,
              4b | dismissed: archived, with its roles in play),
              proposal (jsonb, 4b: why it may fit, where it was found, and what the
              app's own free read of its board saw), enrichment (jsonb), notes

postings      company_id, role_title, location, posting_url, job_url, posted_on,
              source_slice, tracking (suggested | tracked | dismissed: archived),
              verification_state, roles_listed_count, work_mode,
              last_checked_at, fit (jsonb: why it was suggested),
              enrichment (jsonb)

search_profiles  name, titles, excluded_words, places, work_modes, levels
                 (what the operator is looking for: lists, edited on a page);
                 and (4b) what they want of a company: company_wants and
                 company_avoids (their own words), company_stages, company_sizes,
                 company_models, company_industries, company_excluded (the words
                 to avoid); the words and the avoid list audited by a hash alone

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

backgrounds   search_profile_id, looking_for, role_preferences,
              not_on_resume, a hash of each part, content_hash (4c: the
              operator's background beyond the resume, one row per version,
              each part read only by what may use it; audited by each part's
              size and hash, never the text)

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
              written_by, reported_model, llm_call_id, run_id (every score
              kept, the newest shown; audited by its score, counts and
              hashes, never the text);
              since 4c `score` is the ATS fit, and beside it the Background
              fit: background_score, background_why, covered (the gaps the
              background covers, with its lines and where to address each),
              preferences (match or miss), background_dropped_lines,
              background_id, background_hash

company_reviews  company_id, score (0 to 100), why, stage, size, business_model,
              industries, regions (in the preferences' own values, for the
              pages to filter on), facts and points (jsonb: each fact, and each
              preference's match, miss or unknown, with its evidence and links),
              concerns, questions, sources, preferences_digest, written_by,
              reported_model (4b: every review kept, the newest shown, stale when
              the preferences or the places change; audited by its score,
              counts and digests, never the text)

resume_reviews  application_id, language, strengths, gaps, suggestions
              (jsonb, each point with the resume lines behind it), note,
              dropped_lines, resume_id, resume_hash, role_description_id,
              description_hash, written_by, reported_model, llm_call_id,
              run_id (audited by its
              counts and hashes, never the text); since 4c background_id
              and background_hash (the part it read), and a point drawn
              from the background carries its background_lines, flagged
              for the operator to confirm (drafts carry the same)

page_checks   company_id, run_id, purpose (resolution | verification), step,
              url, final_url, outcome, reason, read_via, ats_vendor, ats_board,
              listing_count, stated_total, listings (jsonb snapshot),
              matches (jsonb: each posting's outcome and reasoning),
              complete (the worker's own answer: was the whole list read?),
              listings_incomplete, single_job_posting, many_employers,
              next_page_url, content_hash, reused_from_id, listings_read_at,
              http_status, explicit_no_openings (the page said it has none),
              input_truncated, duration_ms, notes, checked_at

review_items  kind, company_id, subject (polymorphic: the company or one role),
              status (open | done | left), evidence, evidence_key, proposal,
              raised_by, decided_by, decision, note, decided_at,
              recommendation (jsonb: a recommended decision, one of the
              item's own actions with why, and what the operator then did)

agent_credentials  actor, scopes, token_digest, purpose, issued_by,
                   expires_at, revoked_at (one per agent run)

check_runs    kind (role | company | all | describe | draft | review | fit),
              company_id, posting_id, request (jsonb: what a draft, review or
              fit was asked for), status (queued | running | done | failed),
              requested_by, ceiling_usd, answer, summary, tally (jsonb),
              cost_usd, run_id, total, error, started_at, finished_at
              (a check asked for from the pages, run in the background,
              which the page polls)

llm_calls     page_check_id, run_id, purpose (extract | resolve | match | relate | draft |
              review | fit), model,
              settings, prompt_version, input_tokens, output_tokens, cost_usd,
              called_at

audit_events  actor, action, target (polymorphic), changes_made (jsonb),
              credential_id (the run's credential, for an agent's write),
              model_version, reasoning, occurred_at
              (append-only: a trigger refuses update, delete, truncate)
```

Notes on a few choices:

- **UUID primary keys** throughout (via `pgcrypto`).
- **JSONB `enrichment`** on both core tables. Upstream sources vary in shape — one export carries 7 columns, another 28. Structured core plus JSONB avoids a migration every time a source adds a field. Promote a key to a real column once it's filtered or sorted on regularly.
- **`source_slice` lives on postings, not companies**, because one company can surface in several geographic pulls — the slice describes where the posting was found.
- **`changes_made`, not `changes`** — the latter collides with `ActiveModel::Dirty#changes`.
- **Page checks are evidence, not changes.** Every page read, whatever its outcome, is a `page_checks` row with a snapshot of every listing it saw, unfiltered, so a later search profile can be applied to past checks. Changes to companies and postings go through `audit_events`.
- **`llm_calls` answers "what did this cost, and what produced it"** without the run directory: one row per model call, with the model the API reports having served, its settings, and a `prompt_version` hash over the prompt, output schema, and limits.
- **A repeat read is paid for only when the roles may have changed.** A page that links to exactly the role pages it did last time reuses that read's listings, and its check names the read it reused (`reused_from_id`); listings are read in full again once 14 days old (`listings_read_at`). A company whose free ATS board lists at least 90% of its page's roles has that board recorded beside the page (`board_*`, with the evidence) and read in its place for 30 days; the page stays the one on record.
- **Only the operator tracks a company or a role,** by hand or through their own Claude client on their word (4a: the assistant's `watchlist:curate`, with their reason on the record); no agent does on its own judgment. A company can also be `suggested` (4b): proposed by the operator's own client (`companies:suggest`), with why in `proposal`, and not watched, checked, suggested from or reviewed until tracked. Tracking one reads the board it was proposed with at once, always free (the worker is started with no API key at all): kept as its careers page, by the verifier, only when the board's vendor records the same company or its page links home; held for the operator to confirm when nothing ties it to the company. Archiving one declines it, and it is never proposed again. Why it may fit is the operator's business: the audit log holds it by a hash alone. A company is `tracked` or `dismissed` (archived, 4a): it is watched only while tracked and its careers page is found, and archiving it archives its tracked and suggested roles too, each on the record with the operator's note; it is refused while an application there is open, and tracking the company again brings those roles back as they were. A posting is `suggested` (proposed by the suggester, with why in `fit`), `tracked` (on the operator's watch list), or `dismissed` (archived: never checked or suggested again); the suggester may suggest, never track. A suggestion the operator never acted on is withdrawn when it no longer fits the profile or its check found it gone: deleted, with its whole record kept in its last audit event. `job_url` is the role's own page at the employer, learned from the listing it matched, so the next check finds the role by its link before its title; `posting_url` stays where it was found.
- **Whether a list was read whole is the worker's own answer,** kept on each verification run's first check (`complete`): a role missing from part of a list has not closed, so what changed and the accuracy test's replays (`verifier:test_b`, see [Tests](#tests)) read it rather than guess.
- **An application's history is its audit log.** Each stage change records the stage and the date it happened (the operator's, not when it was typed), so velocity and conversion are measured from the record, not a copy of it. Moved to the stage it is at, on another day, a stage is re-dated in place: its new date is recorded, and its timeline and its days in the stage go by it.
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

Imported verdicts carry an operator-supplied check date. A bare date is day precision (stored at 12:00 UTC so the calendar day never shifts), and the posting's create event records where the date came from. The verifier (1.2) is the main writer now, and records the exact time it looked. A verdict that changes is an audited update; a check that confirms the verdict only refreshes `last_checked_at` and what it observed, with the check's own record as its provenance (a role found at a new address is the exception: its `job_url` changes, audited); and a check that couldn't decide (it read only part of a list and found nothing) writes no verdict at all, so a role on page two is never marked closed.

## Build stages

**Stage 1 — Job Finder** ✅ A thin vertical slice through the whole stack rather than a horizontal layer, so something useful ships before the CRUD work and the governance model is proven on real data early.

- **1.1 — Schema and ingest** ✅
- **1.2 — Verification agent** ✅ (Playwright + LLM, Python worker; see [`workers/verifier`](workers/verifier)), in three slices:
  - **1.2a — Render and extract** ✅ read a careers page in a real browser and extract its listings; known job boards (Greenhouse, Lever, Ashby, Workday, Oracle Cloud) are read through their APIs instead.
  - **1.2b — Resolve careers pages** ✅ find each company's careers page from its domain, cheapest step first, with a confidence; low-confidence finds wait for a person. Measured by hiding the known pages of 71 labeled companies and finding them again: 87% found, none wrong at high or medium confidence.
  - **1.2c — Match and verdict** ✅ read each watched page in full (pagination, "load more", ATS APIs), match every tracked posting against it, and record verdicts that follow the evidence. Measured on fresh reads of 59 roles with research labels: 58 called right, 54 as labeled and 4 where hand checks showed the label wrong; the one miss was a live role left as couldn't confirm. No closed role was reported open, and every role it reported closed was (12 of 12).
  - **Cost pass** ✅ the LLM reads a page only when its role links changed (or every 14 days), and a company's own free ATS board is read in place of its page when it lists the same roles.
- **1.3 — Scoped writes and provenance** ✅ a credential per agent run with exactly that run's scopes, checked at every write down to the attributes it sets; refused writes audited; every agent write names its credential; an Agents page and `agents:` commands. See [The permission model](#the-permission-model).
- **1.4 — Monitoring on demand, and what changed** ✅ one role, one company, or everything, checked when the operator asks: "Check everything" on the dashboard shows its plan and ceiling and asks first, then runs in the background with its progress (137 companies in 47 minutes for $1.17, the first time). A what-changed view reports what each check of everything found: verdicts, suggestions made and withdrawn, careers pages, boards, new review questions, refused writes, and lists that changed a lot between whole reads (raised for review: often another page now). A schedule comes with Stage 4.
- **1.5 — Capture and watched roles** ✅ the first web UI. A search profile suggests roles from the watched pages, the user picks which to track, and each tracked role gets a "check now" that answers *still listed* or *no longer listed*. Paste a careers link, a posting link, or a company domain to resolve, verify, and add it to the watch list. In five slices:
  - **1.5a — Tracked roles and check now** ✅ a tracking state only the operator sets; each role's own page at the employer, matched before its title; `verifier:check`, the role's own page first, then its company's careers page.
  - **1.5b — The operator's pages** ✅ dashboard, roles, companies; track, archive ("dismiss", as it was then called), and check now from them.
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

**Stage 3 — Governance completion** ✅ (decided 2026-10-28, complete 2026-10-29). The record made answerable, and read-only throughout: no new agent, scope or kind of write. Each part is read on a page, by a command and through an MCP read tool.

- **3.1 — The audit log, searchable** ✅ every write on record on one page, newest first, narrowed by who made it (the operator, every agent, or one), the kind of record, the action (created, changed, deleted, refused), a date range, one record or the credential behind it, and an attribute it changed; each event with what it changed, why, and its credential. The pages that show history link to it, already narrowed. The same from the command line (`audit:list`), and through MCP (`query_audit_log`), so the operator's client can answer who did what and why.
- **3.2 — A review queue for drafts** ✅ met by 2c and 2g: nothing an agent writes takes effect until the operator approves a draft or accepts a recommendation.
- **3.3 — Analytics** ✅ in raw SQL over the audit log and the evidence, every input a bound parameter, on an Analytics page. The pipeline so far: how far applications get (each counted at every stage up to its furthest) and the rate from one stage to the next; the days in each stage, from the operator's own stage dates (a move made the same day as the stage before carries that date forward; an application still at a stage counts its days so far); how they end (accepted of those closed, an offer of those applied); and what is open now, beside the tracked roles still listed with no application. The watch: how long roles stay listed (first seen listed to first seen gone, by the checks' own days), the roles the reads matched and the answers that changed week by week, and how fresh the tracked roles' answers are. The agents: what the AI cost by day (with a running total), purpose and model, a verification read and a role confirmed listed (a read through a board's API needs no AI and still counts); the review queue's agreement per kind; and what each actor wrote and was refused, beside the credentials issued. A rate needs at least 5 to go on; below that the page says so. The same from the command line (`analytics:report`) and through MCP (`get_analytics`), a section at a time and for a period.

**Review pass** ✅ (2026-11-02 to 11-03). A full review of the project after Stage 3, closed step by step: the dependencies brought up to date (the AI SDK's major version among them); every MCP tool's record text fenced as data; private text kept out of the logs; the audit log made append-only in the database itself (a trigger); no page view that writes; the docs; specs for the commands; and every company on the private target list taken out of the repository and its history.

**Stage 4 — Showcase and distribution.** Last by design, so it ships a finished system, and nothing before it depends on it.

- **4a — Curating the watch list** ✅ (decided 2026-11-04, complete 2026-11-05). The first part of the review of the experience, from the operator's own use: a company tracked or archived as a role is, watched only while tracked; archiving one archives its roles in play, each on the record, and is refused while an application there is open; tracking it again brings them back. The Companies page has Tracked, Archived and All, with what needs a look (no careers page yet, a page to confirm, no role tracked, roles tracked none of which is still listed), each company's domain, careers page, roles (its tracked ones by answer) and application, and archives several at once; a company's page tracks or archives it, its careers page's details in a fold; review cards link the company's domain. "Archive" replaces "Dismiss" on the pages, the stored word unchanged. Adding reads nothing unless asked ("Add and check", "Add and read"), so it costs nothing: a role added so needs its title, a company can be given its careers page to be watched as given, and a role can be added from its company's page; a role's own page is changed from its page, never to a job board's link. The operator's own Claude client does the same through MCP on their word (`watchlist:curate`, held by the assistant alone; "track or archive" is no longer the operator's alone), lists the companies as the page does, and adds a role tracked and never checked.
- **4b — Finding companies** ✅ (decided 2026-11-05, settled 2026-11-06, complete 2026-11-10). The operator's own Claude client searches the open web for companies that fit preferences kept on the profile, researches each, and proposes it with a review; only the operator, or the client on their word, decides what is watched. A company the client proposes is held as `suggested`, with why, where it was found and what the app's own free read of its board saw, found on record as Add by URL finds it (refused when tracked or archived, refreshed when proposed already); nothing checks it, suggests its roles, asks about it or looks for its careers page until it is tracked, and tracking it reads its board at once, always free, the careers page still the verifier's write. The profile holds what the operator wants of a company (what they want and avoid, in their words, and the stages, sizes, business models, industries and words to avoid), audited by a hash where it is their own words, and saved by them or by their client on their word; a company review, the client's, scores a company from 0 to 100 against them, point by point with its sources, its facts in the preferences' own values, a company that does what they avoid capped at 49, stale when the preferences or the places change; the rules for it are shared (`company_fit` in `writing_rules.md`). On the pages: the Profile page keeps the company preferences in a form of their own (saving them finds no role suggestions); the Companies page has a Suggested tab beside Tracked, Archived and All, where proposals are tracked or declined, one or several under one note, each with where it was found, what its board listed and why; every tab has a Fit column (the newest review's score, stale ones marked), sorted best first when asked, filtered by fit (85, 70 or 50 and up, not reviewed, stale) and by what the reviews found (stage, size, business model, an industry, a region); and a company's page shows its proposal and its company review in full, point by point with the sources, and the scores before it. Through MCP the client reads the preferences with the rules (and saves them on the operator's word), checks candidates against the record and their boards (free, recording nothing), proposes and reviews them, lists the companies by fit and what is due a review, and reads a company's proposal and review; the `find_companies` and `review_companies` prompts run the flow. A role's company fit (its company's newest review) shows beside the role's own fit on the Roles page, sortable by either, on a role's page, in `fit:list`, and through `find_roles` and `get_roles_to_weigh`; it is never weighed into a role's fit.
- **4c — Your background, and fit read two ways** ✅ (decided 2026-11-11, complete 2026-11-12). From the operator's own use: their client's fit reviews, on which most of their pruning rested, couldn't see the background that lives outside the resume and the company preferences. The profile gains a background in three parts, pasted (never a file), kept version by version, audited by each part's size and hash, and the operator's alone to edit. Each part is read only by what may use it: what they're looking for (motivation, for role fit and for cover letters and outreach notes, never a claim of experience), role preferences (role fit alone), and background not on the resume (role fit, and resume reviews and tailored resumes). Company reviews don't read it. A role's fit is read two ways: the ATS fit, the resume alone as a recruiter's screening system would read it, shown in the tables, and the Background fit beside it on a role's page, with the gaps the background covers (and where to address each, the resume or the cover letter) and how the role sits with each role preference. The background never raises the ATS fit; each reading goes stale on its own, and the roles weighed before the background are picked to weigh again, only when asked. A resume review or a tailored resume flags each point drawn from the background, "from your background, not on the resume", with its lines, for the operator to confirm; a cover letter or an outreach note takes only its motivation from it, so every claim still traces to a line of the resume, and one that cites a background line is refused. Every reading records the version of the part it read, and says when that part changed since. The same holds through MCP, where each kind of writing is given only its part, and in the app's own agents, whose prompts changed on purpose: a smoke run on made-up records caught the fit scorer citing resume lines as a role preference's, fixed before it shipped.

Its hosted form is proposed and paused (2026-11-02): one hosted app, for recruiters and for anyone trying it on their own job search. A visitor connects their own Claude client through the MCP connector, signing in with the connector's own sign-in (OAuth), and picks the made-up demo data, a fresh start, or their own file, loaded from the pages: that makes a workspace, kept only while in use, with the file theirs to download at any time. The pages hold the writes only a person may make, so no agent moves an application there either; the visitor's own Claude does the model's work, on their subscription; the Python agents stay as the proof of the agent design, shown through their record on the demo data. It runs on the operator's own server, in Docker. A schedule, a digest, the production setup, a full review of the experience (the UI and its flows) and the project's write-up for the portfolio site come with it. It resumes after a review of the tool from the operator's own use.

## Stack

- **Rails 8.1 / Ruby 3.4.8 / PostgreSQL 16** — core application and system of record
- **solid_queue** — for a schedule, once there is a host; until then the verifier runs on demand
- **Hotwire (Turbo, Stimulus) and importmap** — the operator's pages, plain Rails views with no build step
- **Python + Playwright** — agent workers (managed with uv). Required rather than preferred: the verification step needs headless rendering plus LLM tooling, and both are strongest there.
- **Claude, through the Anthropic API** — Haiku 4.5 reads pages, decides near-miss matches, and weighs fit; Opus 5.5 writes drafts and resume reviews. The key stays outside the repo and reaches the worker process alone.
- **MCP, through the Ruby SDK (gem `mcp`)** — the server the operator's own Claude client connects to
- **fx** — database functions and triggers in migrations and `schema.rb`, so the audit log's append-only trigger is rebuilt wherever the schema loads (the test database, CI, a fresh setup)
- **RSpec, RuboCop, Brakeman, bundler-audit**; ruff and pytest for the worker

## Setup

It needs Ruby 3.4.8 and PostgreSQL 16; it was built in WSL (Ubuntu), with the Ruby from mise.

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
COMPANY_NAME="..." bin/rails "verifier:rename[company_id]"  # rename a company, audited as you
bin/rails "verifier:status[company name or id]"  # one company: its page, checks, postings, history
bin/rails "verifier:extract[https://...]"        # read one careers page and list what it shows; records nothing (MODEL=)
bin/rails verifier:verify                        # check everything: shows the plan and its cost; GO=1 runs it
bin/rails verifier:changes                       # what changed since the check of everything before the latest (FROM=)
bin/rails "verifier:describe[posting_id]"        # read a role's description (ROLES=applications|tracked for many); free
bin/rails verifier:find_boards                   # free boards listing the same roles as LLM-read pages (no API cost)
bin/rails "verifier:check[posting_id]"           # is this role still listed? its own page first, then its company's
bin/rails "verifier:track[posting_id]"           # or verifier:dismiss (archive it): your watch list, with NOTE="why"
bin/rails "verifier:dismiss_company[company_id]" # archive a company and its roles in play (NOTE=); verifier:track_company undoes it (ROLES=0 leaves its roles)
bin/rails verifier:proposals                     # the companies your own Claude client proposed (4b): track one (verifier:track_company reads its board then, free) or decline it (verifier:dismiss_company)
bin/rails companies:preferences                  # what you want of a company (4b); WANTS=, AVOIDS=, STAGES=, SIZES=, MODELS=, INDUSTRIES=, EXCLUDED= save them
bin/rails companies:reviews                      # companies by their newest review, best first, stale ones marked (MIN=, LIMIT=); DUE=1 lists those due one
bin/rails "companies:review[company id or name]" # one company's newest review in full: its points, facts with sources, concerns and questions
bin/rails verifier:suggest                       # suggestions from the search profile (no API cost); PREVIEW=1 writes nothing
URL="acme.com" bin/rails verifier:add            # add a company by its domain, careers page, or ATS board (COMPANY_NAME, PAGE=its careers page, watched as given; CHECK=1 reads it)
URL="https://..." bin/rails verifier:add_role    # add a role by its own page, tracked (TITLE, needed without CHECK=1; SOURCE; COMPANY_ID at a company on record)
URL="https://..." bin/rails "verifier:own_page[posting_id]"  # change a role's own page at the employer (NOTE optional)
bin/rails "verifier:hand_check[posting_id]"      # record a check you made yourself
REASON="why" bin/rails "verifier:undo_verdict[posting_id]"  # undo the verifier's latest verdict on a role, restoring what it replaced
REASON="why" bin/rails "postings:move[posting_id,Company Name,domain.com]"  # move a role to the company really hiring (one an aggregator listed)
bin/rails verifier:backfill_job_urls             # each role's own page, from the listing it already matched (no API cost)
bin/rails verifier:forget_private_runs           # remove run folders that quote the resume, left from before (PREVIEW=1 lists)
bin/rails privacy:names                          # no company on the record named in the repo or an unpushed commit (local CI runs it)
bin/rails review:sync                            # bring the review queue in line with the record (no API cost)
bin/rails review:list                            # what waits for your judgment, with each item's id and recommendation (KIND=)
bin/rails "review:accept[item_id]"               # accept an item's recommendation, as the Review page's Accept does
bin/rails review:agreement                       # how recommendations came out, per kind: agreed, differed, resolved, pending
DECISION=leave NOTE="why" bin/rails "review:decide[item_id]"  # decide one item, as on the Review page
bin/rails agents:credentials                     # credentials agent runs held, what each wrote and was refused
WHO=verifier KIND=role bin/rails audit:list      # the audit log, newest first (ACTION, ATTRIBUTE, FROM, TO, RECORD, CREDENTIAL, PAGE)
SINCE=2026-10-01 bin/rails analytics:report      # the pipeline, the watch and the agents, as the Analytics page has them (SECTION=)
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

The commands run most have specs of their own (`spec/tasks/`), run as the operator runs them: what each prints, that its writes are audited as theirs and backed up first, and that a command given something wrong is refused before any backup. A name is given in `COMPANY_NAME` or `CONTACT_NAME`, never `NAME`, which shells set already (WSL sets it to the machine's name).

### Suggestions

A search profile (the Profile page) says what the operator is looking for: titles, excluded words, the places they can work, work modes, and levels. The worker's `suggest` command weighs every watched company's roles, as its page last listed them, against it: no page is fetched and the LLM is never called. A role fits when its title holds every word of one of the profile's titles, in any order, and none of an excluded one; when it is open to one of the places (a role in São Paulo, or open to Latin America, is open to Brazil; a region on the profile takes roles open to it, never every role inside it); and when its work mode and the level its title states are among those sought. What a role does not state (no place, no work mode, no level) still fits, marked. Each role comes back with its reasoning; Preview shows it all, the roles left out included, and writes nothing.

The suggester (`agent:suggester`) then writes each fitting role that is not already on record as a suggestion, matched against every role on record the way verification matches (its link, then its title), so a role the operator tracks or archived is never proposed again. The operator's own Claude client can propose roles too, judged by meaning (see [The MCP server](#the-mcp-server)): its suggestions are marked as its own, and a refresh neither refits nor withdraws them while their page lists them. It refreshes when the profile is saved, from **Find suggestions** on the Roles page, after every check now, and after `verifier:verify`. A suggestion the operator never acted on is withdrawn when it stops fitting, or when its check finds it gone from the whole list; one missing from a read that may be partial stays.

### Drafts

An application's page writes a cover letter or a short outreach note for it (the drafter, `agent:drafter`). The worker's `draft` command makes one structured call to Claude Opus 5.5, at medium effort, with what is on record alone: the operator's newest resume, the role's newest description, the search profile, and the operator's notes on the application. The description and the resume are data, never instructions; the operator's "anything to stress" is theirs.

- **Only what the resume shows.** No experience, skill, employer, figure or date the resume doesn't state, no total worked out from its dates, and no employer described beyond what the resume says of it. What the role asks for that the resume doesn't show is left out and listed as a gap.
- **Cited by line.** The resume goes to the model with its lines numbered, and the draft names the lines it drew on by number, as listings name links: each maps back to the resume's exact text, and a number the resume doesn't have is dropped and counted.
- **What the operator is looking for, as motivation (4c).** When the background's first part is saved, the drafter is given it (and no other part) for why they want the role, never as a claim of experience; the draft records the version it read. The in-app resume review reads background not on the resume, and flags what it draws from it for the operator to confirm.
- **In the role's language** (the description's), unless another is asked.
- **To someone, or to no one.** An outreach note can be addressed to one of the company's contacts: it opens with their first name and fits what they do (for a recruiter, how the role fits; for a hiring manager, the work itself). Without one it opens "Hi [name]," for the operator to fill in.
- **Never sent.** The operator edits it, approves it (an edit after that returns it to a draft), and copies it out; only the operator can edit or approve one.
- **Written in the background**, one at a time per application, with what a draft costs on the record shown first (about 6 cents each so far). The run's targets and results quote the resume, so its files are removed as soon as its results are read; the record keeps what was written.

**A resume review** weighs the resume against the role, for the operator to decide what to stress and what to add: strengths with the resume lines behind them, gaps, suggestions naming the lines they touch, and a note. The drafter writes one from the application's page (the worker's `review`, the same model and record, about 5 cents, in English unless another language is asked), under a credential holding `resume_reviews:write` alone; or the operator's own Claude client writes one through MCP and saves it back. Its rules are the shared ones. Advice only: it writes nothing to send and claims nothing.

### Fit scores

How well a role fits the operator, so they can see which roles to apply to first (the fit scorer, `agent:fit_scorer`). The worker's `fit` makes one structured call per role to Claude Haiku 4.5 (the operator's choice: under a cent a role), with what is on record alone: the role's own description, the resume numbered by line, the titles the profile searches for, and since 4c the operator's background (below).

- **A score from 0 to 100, with its reasons.** The scale is anchored in the shared rules (`fit` in `writing_rules.md`): 85 and up shows every must-have at the level asked; 70 to 84 the must-haves, with gaps only in what is preferred; 50 to 69 is a stretch; 25 to 49 some of the work; under 25 another field. With it: the level the role asks beside the resume's, the strongest matches with the resume lines behind them, the gaps, and why in a sentence. Advice for ranking roles: it claims nothing.
- **Kept, never overwritten.** Every score is kept with the resume and description versions it read; the newest is the one shown, marked stale once either changes.
- **Only when asked.** From a role's page, or the unscored in one batch from the Roles page, what it could cost asked first; a description is read first when missing, free. The Roles page shows a Fit column to filter and sort by.
- **Read two ways (4c): the ATS fit and the Background fit.** The score above is the ATS fit, the resume alone as a recruiter's screening system would read it, and the tables show it. When the operator's background is saved, the Background fit beside it reads that too: its own score and why, the gaps of the ATS reading the background covers (each with the background lines and where to address it, the resume or the cover letter), and how the role sits with the role preferences. The background never raises the ATS fit (`background_fit` in `writing_rules.md`). Each reading goes stale on its own, and the roles weighed before the background are picked to weigh again. In the app and through MCP alike: the fit scorer reads the background (all three parts) and gives both readings, and the Roles page weighs again, when asked, the roles weighed before the background.
- **Beside it, the company's fit (4b), never in it.** The Roles page and a role's page show the role's company fit (its company's newest review against the company preferences, linked to it), and the list sorts by either; role fit stays the role against the resume, in the app and through the client, and company fit the company against the preferences. Two scores, never merged: the fit scorer never reads a company review, and the client is told never to weigh one in.
- **Scoped like any agent.** The fit scorer holds `fit:write` alone: it can't track, archive or touch a role.
- **Or on the operator's subscription, by meaning.** Through MCP, the operator's own Claude client weighs roles by the same rules and saves the scores. It can also find roles: it names the titles a role like the operator's goes by, the suggester's rules run over the stored lists with those titles, and it suggests the ones it judges may fit (marked as its own) whose own page still has them, then weighs them. See [The MCP server](#the-mcp-server).

The drafter and the fit scorer are the agents whose work is the model's. Without an API key their runs stop and say so; everything else keeps working, and the MCP path does the same work on the operator's own subscription.

### The MCP server

[`mcp/`](mcp) is a stdio [MCP](https://modelcontextprotocol.io) server (the Ruby SDK, gem `mcp`) through which the operator's own Claude client reads the record, writes a resume review, a cover letter, an outreach note or a tailored resume and saves it back, keeps the operator's contacts and what happened, curates their watch list when told, and finds and reviews companies that may fit them. The model's work is then paid for by the operator's Claude subscription, not by API credits. It grew from the operator's own read-only learning server.

- **Every read tool's call runs inside a read-only transaction,** so no read can write, and a tool's inputs (they come from a model) reach SQL only as bound parameters.
- **The record's text comes back between markers,** such as `<record>…</record>` or `<draft>…</draft>`: names, titles, places, notes, drafts and reasoning, which came from pages read, from a model or from a person, are data to the client, never instructions. A marker inside that text is taken out, so it can't close its fence early; the tool's own framing (counts, ids, what to do next) stays outside.
- **A save tool writes as `agent:assistant`,** under a credential issued for that one call with only that tool's scopes, revoked when it ends: checked at every write and audited like any agent's. A write its scopes don't allow comes back to the client as a refusal, kept on the record.
- **stdout carries the protocol,** and nothing else writes there: the protocol keeps a handle of its own, and the process's stdout, which a worker a tool starts inherits, goes to stderr. Rails boots in the background, so the server answers a client's first request at once; times are UTC; an answer is cut at 20,000 characters, and says so.
- **Tools:** `get_company_status` (a company by its id, name, domain, or a link on its site: whether it is tracked, proposed or archived, its careers page and how it was found, its roles by answer with archived ones apart and each with its id, its last check, its applications, and (4b) why it was proposed and its newest company review in full); `list_applications` (where each stands, what is written for it, its id); `get_application_materials` (what any writing about an application starts from: the role, its description, the resume numbered by line exactly as the in-app drafter numbers it, the profile, the notes, what is already written, the record's text fenced as data); `get_draft` (a draft in full, whom a note is to, what it rests on, and whether its inputs changed since); `get_writing_rules`; `list_contacts` (a company's contacts, or an application's, with their ids).
- **Prompts,** picked in the client with an application (completed as it is typed): `cover_letter`, `outreach_note` (also to a contact, completed from the application's company), `resume_review`, `tailored_resume`. Each carries the writing rules and the application's materials, so the client writes at once, and keeps the rules through every change asked of it.
- **Save tools,** used only when the operator says to save: `save_draft` (a cover letter, an outreach note, or a tailored resume with its changes) and `save_resume_review`. Since 4c, given the kind of writing, `get_application_materials` also gives the part of the operator's background that kind may use (background not on the resume for a resume review or a tailored resume; what they're looking for for a cover letter or an outreach note), and a strength, suggestion or change drawn from it cites its lines (`background_lines`, with the `background_version`), flagged for the operator to confirm. A letter or a note uses what they're looking for as motivation alone, records the version it read, and is refused when it cites a background line. Each gives back the resume version the client read, so the lines it cites by number are read against the lines it saw (a version no longer on record is refused); a number the resume doesn't have is dropped and counted. A polished version is a new draft that names the one it revises. What is saved shows on the application's page, as the operator's to edit, approve, copy or delete; the record says the client wrote it and the model it reports.
- **Contacts and the activity logger:** `save_contact` adds a contact at an application's company (linked to it) or a company's, or updates one named, giving only what the operator said (never a guessed email or link; the same name twice is refused, naming the one on record); `log_activity` logs what happened, on the day it did or is booked for, with whom (linking them). **It never moves a stage:** when an interview, an offer or an application points to a later stage, its answer says so, and only the operator moves it. `save_draft` takes the contact an outreach note is to.
- **The writing rules live in one file,** [`writing_rules.md`](workers/verifier/src/verifier/writing_rules.md): the worker's drafter builds its prompt from it, and the server's prompts hand it to the client. Only what the resume shows, figures as it states them, an employer as it describes it, gaps listed rather than claimed. Since 4c, three sections say how each kind of writing may use the operator's background (`background_fit`, `background_resume`, `background_letter`): context for judging, never a source of claims.
- **Recommending on the review queue (2g):** `list_review_items` (with no kind, the counts alone, so the client asks which kind and how many before reading any; with a kind, or every kind when asked, the items and those with no recommendation yet), `get_review_item` (one item in full: its question, what to check, the actions it may recommend, and everything on record behind it: the company's careers page and how it was found, what the resolver tried, its latest page reads and stated totals, its boards, the roles in play, and for a role how it was last matched, all fenced as data), and `save_recommendation` (one of the item's own actions, with the page or kind it needs, a confidence, what was checked and why, as `agent:assistant` under `review:recommend`). The `review_queue` prompt works through a kind (completed as typed), with that kind's guidance; the client uses its own web search where the record can't settle an item, and recommends the page it finds even when the app may not read it (its roles then come back for hand checks), and decides nothing: the operator accepts or decides on the Review page.
- **How the search is going (3.3):** `get_analytics`: the Analytics page's figures in plain text, a section (the pipeline, the watch, the agents) or all three, for a period; figures only, never a record's own text. Where a rate has too few to go on it says so, and the server's instructions tell the client to say so too.
- **The audit log (3.1):** `query_audit_log`: every write on record, newest first, narrowed as on the Audit log page (who, the kind of record, the action, an attribute changed, the days, one record or a credential), each event with who made it and under which credential, what was done to which record (its id, to narrow to it next), what changed, and why. An answer holds as many whole events as fit, and says where the older ones start.
- **Finding and weighing roles (2f):** `find_roles` runs the suggester's rules over the watched pages as last read (nothing fetched, nothing paid for) with the titles the client names in place of the profile's, so a role worded differently is found too, and lists the ones not on record, each with a key. `suggest_roles` proposes the ones the client judged may fit, each with why: since the lists are as last read, it first reads each one's own page (free, keeping nothing), and a role whose page is gone or can't be read isn't suggested; the rest become suggestions as `agent:assistant` under `postings:suggest`, and the descriptions just read are kept by the verifier under its own credential. `read_descriptions` has the verifier read a description a role on record lacks, as the role page's button does (a run tool: nothing is written as the client). `get_roles_to_weigh` gives the fit rules, the resume numbered by line with its version, and each role's description; `save_fit_score` saves a score as the assistant under `fit:write`, its lines read against the resume version it saw. Prompts: `find_roles` (find by meaning, suggest, weigh) and `weigh_roles` (the roles already offered with no current score). Since 4c a role is weighed two ways: `get_roles_to_weigh` also gives the operator's background, numbered B1, B2 and so on with its version, and the `background_fit` rules, `save_fit_score` takes the Background fit beside the ATS fit, and `weigh_roles` (or `before_background`) picks the roles weighed before the background to weigh again. None of these tracks a role: the client tracks one only on the operator's word (below).
- **The watch list, on the operator's word (4a):** `list_companies` lists the companies as the Companies page does (tracked, proposed, archived or all; no careers page yet, a page to confirm, no role tracked, none still listed; by fit, or due a review, 4b; words in a name, domain or place), each with its id, careers page, roles, application, last check and fit (a proposal with where it was found and what its board listed), 50 a page, in name order or best fit first. `track_or_archive_companies` and `track_or_archive_roles` change several at once, all or none, those already so left as they are: archiving a company archives its roles in play and is refused while an application there is open, tracking it again brings them back, and a role at an archived company is tracked only once its company is. `add_role` adds a role to a company on record, tracked and never checked (nothing spent; its title needed). `set_role_page` changes a role's own page, never to a job board's link. Tracking a company proposed to the operator (4b) has the board it was proposed with read at once, free; archiving one declines it. Each takes the operator's reason, recorded with the change as the assistant's, "on the operator's word"; the server's instructions tell the client never to change the watch list on its own judgment.
- **Finding companies (4b):** `get_company_preferences` gives what the operator wants of a company (their words fenced as data), the places and titles, the version a review is saved against, how many are due a review, and the `company_fit` rules; `save_company_preferences` saves them only on the operator's word (`company_preferences:write`, those fields alone, their words on the record by a hash). `check_company` says whether each candidate is on record and in which state (one tracked or archived is never proposed) and reads a known board among its links through the board's own API, free (the worker started with no API key), with the roles there that fit the profile; it records nothing, and the app reads no company's own site here. `suggest_companies` proposes up to 10 (`companies:suggest`), each read the same way first; one on record is refused saying in which state, a link that is another company's board on record is refused, and one proposed already has its why brought up to date. `save_company_review` saves a review (`company_reviews:write`) against the preferences version the client read. Prompts: `find_companies` (how many, a company to find more like, a focus: it searches the open web, checks, proposes and reviews, deciding nothing) and `review_companies` (tracked with no review, stale, or proposed; asked without which or how many, it gives the counts and asks first). The server's instructions say to review only when asked, to read LinkedIn only in what the operator pastes (nothing here can stop the client's own web tools, so that rule is the client's to keep), and to keep company fit and role fit apart. The values the tools take (stages, sizes, models, sources) are literals in `ProvenanceMcp::CompanyValues`, since the tools load before Rails boots; a spec ties them to the app's own.
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

**In Desktop chat,** pick a prompt from the attachment menu's `provenance_pipeline` entry (Cover letter, Outreach note, Resume review, Tailored resume), type the application's company and role, and send: the client writes from the record and keeps the rules while you ask for changes. Or just ask ("review my resume against the Acme application"): it reads the rules and the materials through the tools. Or tell it what happened ("I had a call with Ana, the recruiter at Acme, today"): it logs it, adding Ana as a contact first if you say to, and tells you when the application looks ready to move; you move it on its page. Or pick Find roles that fit: the client names the titles a role like yours goes by, judges what find_roles lists, suggests what may fit when you say so, has the descriptions read, and gives you the roles weighed, best first; they show among your suggestions in the app, with their scores. Or pick Review the queue (a kind, if you like): it reads each open item, looks into what the record can't settle, and recommends a decision on each; you accept them on the Review page. Or tell it what to clean up ("archive the companies with no role tracked: I've lost interest in them"): it lists them first, changes the watch list only on your word, and records your reason with each change, as its own. Or pick Find companies that fit (how many, a company like the ones you want, a focus): it reads what you want of a company, searches the open web, checks each candidate against your record and its job board, proposes those that may fit and reviews each; they wait on the Companies page's Suggested tab for you to track or decline. Or pick Review companies: it tells you how many are due and asks which and how many first.

### The review queue

What the agents can't settle goes to the operator as a question about one company or role, with what was seen and an action proposed: confirm or reject a careers page found at low confidence, set a company's kind, find a careers page again or set it by hand, set a better page for a list read only in part, say whether a page whose list changed a lot is still the company's, look at a role's page and record what is there, or check a role again. The questions are worked out from the record, so the queue never disagrees with it: every write that can change what a company's record asks (a read, a decision, a withdrawn suggestion) brings that company's items in line, and an item whose evidence resolves closes on its own. Leaving an item as is takes a note, and it comes back only when what was seen changes. A decision goes through the same service as the same write anywhere else, and closes the item in the same transaction.

**A recommended decision** (2g): the operator's own Claude client, through MCP, may recommend one of an item's own actions, with the page or kind it needs, a confidence, what it checked, and why. It never decides one, and never recommends "still listed" or "no longer listed", which record what the operator saw themselves. On the Review page the recommendation sits on its item with **Accept**, named by what it does ("Accept: set this page", "Accept: leave it as is") and saying what follows, which carries it out as the operator's decision through the same path as any other, noting that they followed it; a line at the top of the page leads to the items that carry one; a check it recommends asks first, with its cost. What the operator then does is kept beside it, so agreement is measured per kind (agreed, differed, resolved by the record first, pending): the measure any later autonomy would be judged on. None is granted yet.

### Backups

Every verifier batch that writes backs up first: `bin/rails db:backup` does the same by hand (checks started from the pages, at most once a day). Dumps go to `~/.local/share/provenance-pipeline/backups/` (owner-only), named with their UTC time. Each new dump prunes the folder to the 10 newest plus the newest of each week for a year. The test environment backs up into `tmp/backups/` instead, never beside the real dumps. To keep a copy on another disk as well, name a folder in `~/.config/provenance-pipeline/backup_mirror` (one line); each new dump is copied and pruned there the same way, and a failed copy is reported without stopping the batch.

A backup is proven by restoring it. Into a scratch database, then compare and drop it:

```bash
createdb provenance_pipeline_restore_check
pg_restore --no-owner --exit-on-error --dbname=provenance_pipeline_restore_check ~/.local/share/provenance-pipeline/backups/<newest>.dump
psql -d provenance_pipeline_restore_check -c "select count(*) from postings"
dropdb provenance_pipeline_restore_check
```

### The pages

Boot the server:

```bash
bin/rails server
```

It serves the operator's pages at `http://localhost:3000`: the pipeline (applications by stage, each with a page to move it, log what happened and with whom, keep its contacts, write and approve its drafts, and read its timeline), a dashboard (where applications and the tracked roles stand, "Check everything" with its plan, ceiling and progress, recent checks and verdict changes, API credit spent), what changed since a check of everything, the audit log (every write on record, narrowed by who made it, the kind of record, the action, the days, one record or credential, and an attribute it changed), the analytics (the pipeline: how far applications get, how long they sit in each stage, how they end, what is open now; the watch: how long roles stay listed, answers week by week, how fresh they are; the agents: AI cost, agreement on the review queue, writes and refusals), the roles (tracked, suggested with why, archived, filtered by answer and by fit, sorted by fit, the unscored or those weighed before the background weighed from there), each role's history, its description, its fit (the ATS fit and the Background fit) and the checks behind it, the companies (tracked or archived, narrowed to those with no careers page yet, a page to confirm, no role tracked, or roles tracked none of which is still listed; each with its domain, careers page, roles and application, and a page of its own with its contacts), the search profile with a preview of what it would suggest, the company preferences, the operator's resume and their background in three parts, and the Review page: the questions waiting for the operator, by kind, each naming its company (its domain linked) and role and decided with a button; a check asked from one is followed on the item until it says whether it settled it; and the Agents page: each agent's scopes, the credentials its runs held, with what each wrote, and every refused write. From them the operator adds a company or a role by its link (a role also from its company's page), reading nothing unless they ask, confirms or sets a company's careers page, changes a role's own page, tracks or archives a role or a company with a note on the record (several at once from the lists; archiving a company archives its roles in play), finds suggestions, and checks a role or a company now: the check runs in the background, one at a time, and a check that could spend says its ceiling and asks first. It is local and single-user, with no login, so it is never deployed as it is.

### Tests

`bin/ci` runs everything the project is held to, locally: RuboCop, the gem and importmap audits, Brakeman, the privacy check, RSpec (`bundle exec rspec`), and the worker's lint and tests (`uv run ruff check .`, `uv run pytest`). GitHub's workflow runs the same on every push, the privacy check aside, which needs the record. No test calls the AI.

The accuracy tests behind the measured figures (1.2b, 1.2c) run locally against the private target list, so they aren't part of CI: `verifier:test_resolution` (hide each labeled company's known careers page and find it again), `verifier:test_a` (can the renderer extract listings at all: every careers page with a recorded roles count read, its count within 25% or 3 of the recorded one), and `verifier:test_b` (verify the labeled roles end to end: `REPLAY=1` replays each company's latest verification run, whole, with the worker's own answer to whether it read the whole list, at no API cost (runs from 1.4 on); `FRESH=1` reads the pages now).

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path. The verifier's run directories (`tmp/verifier/`) and database backups (`~/.local/share/provenance-pipeline/backups/`) hold the same list, so they stay out of the repo too. A draft's, a resume review's or a fit's run files quote the resume (and the part of the background they were given), so they are removed as soon as the run's results are read. The logs keep the record's private text out too: the resume and the background, what is written for an application, notes, pay, what happened, and the people (a contact's name, role, link and notes) are filtered from a request's parameters, from the values in logged SQL, and from a record printed in a console.

**No company on the record is named in the repo either,** in code, specs, docs or a commit message: examples name made-up ones (Acme, Contoso). `bin/rails privacy:names` checks the repo's files (tracked, and new ones not ignored) and the commits not yet pushed against every company name and domain on the record, and local CI runs it before anything is pushed. It runs only where the record is, so GitHub's CI can't. A name the repo may carry anyway (a tool the project uses that is also a company, a name that is also a word, checked then only as written) is allowed in `~/.config/provenance-pipeline/names_allowed.yml`, which names companies on the record too, so it stays outside the repo.
