# Provenance Pipeline

**An agent-governed pipeline system.** AI agents are first-class users, operating under scoped permissions with full provenance on every write.

The CRM half is deliberately minimal. The point of this system is the governance layer around what agents are allowed to do — the data model exists to make that layer meaningful.

> **Status: Stage 1.2 complete.** The verifier finds each watched company's careers page, reads it in full, and records a verdict on every tracked posting through one audited write path. A repeat run pays the LLM only for pages whose roles may have changed. Next: manual capture (1.5). See [Build stages](#build-stages).

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
2. **Manual capture.** Paste a posting URL or a company domain; the system resolves the company's careers page and ATS, verifies, and adds the company to the watch list for good. Job boards and ordinary browsing keep feeding the system — a find gets captured instead of living in a notes file.

**The tradeoff, stated plainly: roles at companies outside the list are missed.** There is no crawl, so the list only grows by judgment. That is deliberate. Search-then-filter optimizes for recall; watching a curated list optimizes for precision and fit, which is what this system is for.

**Nothing in the code is specific to one kind of role.** Verification reads every role a careers page shows (a *listing*) and checks whether a tracked *posting* is among them, without knowing what anyone is looking for. The only place a target field enters is a search profile stored as data — titles and keywords, seniority, locations and work mode, exclusions — which decides which roles are suggested; the user picks the ones to track. Another field, or another person, is another profile.

Two consequences shape the build. A company's careers page becomes a **watch target**, re-checked on a schedule for months — a higher bar than resolving a page once for a single check. And re-verification makes postings **stateful**: `verified_live` → `not_found` is a lifecycle transition, not a correction, and the audit log is what makes "when did this role close?" answerable.

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

Two more came out of building the verifier against real pages:

**4. A negative needs the whole list.**
A role is marked closed only when the verifier read every role the page lists: through the ATS's own API, to the end of its pagination, or up to the total the page states. Anything less (page one of fifty, a page that showed no roles and didn't say it has none, one job's ad instead of a list) is *inconclusive*, and no verdict is written. The rule is enforced twice: by the worker, and again at the write path.

**5. What the agent isn't sure of goes to a person, and the person's call is on the record too.**
A low-confidence find is held as a candidate, never watched. The operator confirms, rejects, sets the right page, says what kind of company it is, records a check they made themselves, or undoes a verdict, and each of those is audited under the human's own identity with their reason. Imported research labels turned out to be wrong often enough that checks made at the source, by the verifier or a person, are the authority.

## The permission model

**This is the part that matters.** Each agent gets a deliberately different scope:

| Agent | Granted | Explicitly cannot |
|---|---|---|
| Research / job-finder | `companies:read`, `companies:enrich`, `postings:write` | Touch applications or stages |
| Activity logger | `activities:write`, `applications:read` | Change stage |
| Draft agent | `drafts:write` | Send anything, or finalize a draft |
| **— no agent —** | `applications:advance_stage` | **Human-only by design** |

The last row is the point: the most consequential write is withheld from every agent. Read and enrich is safe to automate; drafting is safe-with-review; stage advancement and anything outbound is human-gated.

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
              last_checked_at, enrichment (jsonb)

page_checks   company_id, run_id, purpose (resolution | verification), step,
              url, final_url, outcome, reason, read_via, ats_vendor, ats_board,
              listing_count, stated_total, listings (jsonb snapshot),
              matches (jsonb: each posting's outcome and reasoning),
              listings_incomplete, single_job_posting, many_employers,
              next_page_url, content_hash, reused_from_id, listings_read_at,
              checked_at

llm_calls     page_check_id, run_id, purpose (extract | resolve | match), model,
              settings, prompt_version, input_tokens, output_tokens, cost_usd

audit_events  actor, action, target (polymorphic), changes_made (jsonb),
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
- **Only the operator tracks a role.** A posting is `suggested` (proposed by the agent), `tracked` (on the operator's watch list), or `dismissed` (declined for good, never checked again); the agent may suggest, never track. `job_url` is the role's own page at the employer, learned from the listing it matched, so the next check finds the role by its link before its title; `posting_url` stays where it was found.
- **Careers-page resolution is recorded beside the page:** how it was found, how sure we are (`high`, `medium`, `low`, or `confirmed` by a person), a held candidate, or why it failed. A low-confidence find waits in `resolution_candidate_url` and is never watched until a person confirms it.

### Verification fields

A **check** is an observation at the employer's own careers page that produced a verdict: `verified_live`, `not_found`, or `inaccessible`. An upstream answer that maps to none of these is not a check: the posting stays `pending`, and the raw answer is kept in `enrichment`.

- **`verification_state`** — the last check's verdict, or `pending` while there is no usable one.
- **`last_checked_at`** — when that verdict was observed. It is present exactly when a posting has a verdict (enforced by validation), so `nil` means one thing: never checked.
- **`roles_listed_count`** — roles visible on the page at that check, matched or not. This is the corroborating observable; `nil` means unknown, never a sentinel value.
- **`work_mode`** — as observed at that check.

Imported verdicts carry an operator-supplied check date. A bare date is day precision (stored at 12:00 UTC so the calendar day never shifts), and the posting's create event records where the date came from. The Stage 1.2 verifier becomes the main writer and records the exact time it looked. A verdict that changes is an audited update; a check that confirms the verdict only refreshes `last_checked_at` and what it observed, with the check's own record as its provenance; and a check that couldn't decide (it read only part of a list and found nothing) writes no verdict at all, so a role on page two is never marked closed.

## Build stages

**Stage 1 — Job Finder.** A thin vertical slice through the whole stack rather than a horizontal layer, so something useful ships before the CRUD work and the governance model is proven on real data early.

- **1.1 — Schema and ingest** ✅
- **1.2 — Verification agent** ✅ (Playwright + LLM, Python worker; see [`workers/verifier`](workers/verifier)), in three slices:
  - **1.2a — Render and extract** ✅ read a careers page in a real browser and extract its listings; known job boards (Greenhouse, Lever, Ashby, Workday) are read through their APIs instead.
  - **1.2b — Resolve careers pages** ✅ find each company's careers page from its domain, cheapest step first, with a confidence; low-confidence finds wait for a person. Measured by hiding the known pages of 71 labeled companies and finding them again: 87% found, none wrong at high or medium confidence.
  - **1.2c — Match and verdict** ✅ read each watched page in full (pagination, "load more", ATS APIs), match every tracked posting against it, and record verdicts that follow the evidence. Measured against the research labels on fresh reads: 98% agreement, and no closed role reported open.
  - **Cost pass** ✅ the LLM reads a page only when its role links changed (or every 14 days), and a company's own free ATS board is read in place of its page when it lists the same roles.
- 1.3 — Scoped writes and provenance: short-lived, per-run agent credentials, checked at the single path every agent write goes through
- 1.4 — Monitoring on demand, and what changed: re-verify one role, one company, or every watched company when the user asks — a re-run of 1.2 that catches both new roles and closures — then show what changed since the last check. A schedule the operator sets comes later, with a host.
- 1.5 — Capture and watched roles: the first web UI. A search profile suggests roles from the watched pages, the user picks which to track, and each tracked role gets a "check now" button that answers *still listed* or *no longer listed*. Paste a careers link, a posting link, or a company domain to resolve, verify, and add it to the watch list.

**Build order is 1.2 → 1.5 → 1.3 → 1.4.** Capture needs only 1.2, so it ships first to make the tool usable early; because every agent write goes through one path, 1.3's credential check covers it without rework. Monitoring is human-triggered first, so nothing waits on a host or a scheduler.

**Stage 2 — Pipeline system.** Applications/activities/drafts, CRUD and review UI, MCP server exposing scoped tools, additional agents.

**Stage 3 — Governance completion.** Full audit views, human review queue, analytics.

## Stack

- **Rails 8.1 / Ruby 3.4.8 / PostgreSQL** — core application and system of record
- **solid_queue** — for a schedule, once there is a host; until then the verifier runs on demand
- **Python + Playwright** — agent workers. Required rather than preferred: the verification step needs headless rendering plus LLM tooling, and both are strongest there.
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
bin/rails verifier:verify                        # shows the plan and its cost; GO=1 runs it
bin/rails verifier:find_boards                   # free boards listing the same roles as LLM-read pages (no API cost)
bin/rails "verifier:check[posting_id]"          # is this role still listed? its own page first, then its company's
bin/rails "verifier:track[posting_id]"          # or verifier:dismiss: your watch list, with NOTE="why"
bin/rails "verifier:hand_check[posting_id]"      # record a check you made yourself
```

The tests that decide whether a slice works run locally against the private target list: `verifier:test_a`, `verifier:test_resolution`, and `verifier:test_b` (`REPLAY=1` replays stored page reads at no API cost; `FRESH=1` reads the pages now).

Boot the server:

```bash
bin/rails server
```

It serves the operator's pages at `http://localhost:3000`: a dashboard (where the tracked roles stand, recent verdict changes, API credit spent), the roles (tracked, suggested, dismissed), each role's history and the checks behind it, and the companies watched. It is local and single-user, with no login, so it is never deployed as it is.

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path. The verifier's run directories (`tmp/verifier/`) and database backups (`~/.local/share/provenance-pipeline/backups/`) hold the same list, so they stay out of the repo too.
