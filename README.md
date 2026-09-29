# Provenance Pipeline

**An agent-governed pipeline system.** AI agents are first-class users, operating under scoped permissions with full provenance on every write.

The CRM half is deliberately minimal. The point of this system is the governance layer around what agents are allowed to do — the data model exists to make that layer meaningful.

> **Status: Stage 1.2 in progress.** The verification worker renders careers pages and extracts their listings (1.2a); careers-page resolution (1.2b) is next. See [Build stages](#build-stages).

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

1. **An imported base of companies.** The seed data came from job-listing exports, and many of those listings turned out to be stale. That matters less than it sounds: postings are perishable, but the companies behind them are durable, and every posting is re-verified at the source, so a stale listing corrects itself on its first check. The listings were just how the companies were found.
2. **Manual capture.** Paste a posting URL or a company domain; the system resolves the company's careers page and ATS, verifies, and adds the company to the watch list for good. Job boards and ordinary browsing keep feeding the system — a find gets captured instead of living in a notes file.

**The tradeoff, stated plainly: roles at companies outside the list are missed.** There is no crawl, so the list only grows by judgment. That is deliberate. Search-then-filter optimizes for recall; watching a curated list optimizes for precision and fit, which is what this system is for.

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
              enrichment (jsonb), notes

postings      company_id, role_title, location, posting_url, posted_on,
              source_slice, verification_state, roles_listed_count,
              work_mode, last_checked_at, enrichment (jsonb)

audit_events  actor, action, target (polymorphic), changes_made (jsonb),
              model_version, reasoning, occurred_at
```

Notes on a few choices:

- **UUID primary keys** throughout (via `pgcrypto`).
- **JSONB `enrichment`** on both core tables. Upstream sources vary in shape — one export carries 7 columns, another 28. Structured core plus JSONB avoids a migration every time a source adds a field. Promote a key to a real column once it's filtered or sorted on regularly.
- **`source_slice` lives on postings, not companies**, because one company can surface in several geographic pulls — the slice describes where the posting was found.
- **`changes_made`, not `changes`** — the latter collides with `ActiveModel::Dirty#changes`.

### Verification fields

A **check** is an observation at the employer's own careers page that produced a verdict: `verified_live`, `not_found`, or `inaccessible`. An upstream answer that maps to none of these is not a check: the posting stays `pending`, and the raw answer is kept in `enrichment`.

- **`verification_state`** — the last check's verdict, or `pending` while there is no usable one.
- **`last_checked_at`** — when that verdict was observed. It is present exactly when a posting has a verdict (enforced by validation), so `nil` means one thing: never checked.
- **`roles_listed_count`** — roles visible on the page at that check, matched or not. This is the corroborating observable; `nil` means unknown, never a sentinel value.
- **`work_mode`** — as observed at that check.

Imported verdicts carry an operator-supplied check date. A bare date is day precision (stored at 12:00 UTC so the calendar day never shifts), and the posting's create event records where the date came from. The Stage 1.2 verifier becomes the main writer and records the exact time it looked; how it records a check that changes nothing is defined in Stage 1.2.

## Build stages

**Stage 1 — Job Finder.** A thin vertical slice through the whole stack rather than a horizontal layer, so something useful ships before the CRUD work and the governance model is proven on real data early.

- **1.1 — Schema and ingest** ✅
- **1.2 — Verification agent** (Playwright + LLM, Python worker) ← *current*, in three slices:
  - **1.2a — Render and extract** ✅ read a careers page in a real browser and extract its listings; known job boards (Greenhouse, Lever, Ashby, Workday) are read through their APIs instead. See [`workers/verifier`](workers/verifier).
  - 1.2b — Resolve careers pages from a company's domain
  - 1.2c — Match postings against listings and record verdicts
- 1.3 — Scoped writes and provenance: short-lived, per-run agent credentials, checked at the single path every agent write goes through
- 1.4 — Scheduled monitoring and digest: re-verify every watched company on a cadence — the sourcing mechanism, a scheduled re-run of 1.2 that catches both new roles and closures — then report what changed
- 1.5 — Manual capture ("add by URL"): paste an employer careers link or a company domain to resolve, verify, and add it to the watch list

**Build order is 1.2 → 1.5 → 1.3 → 1.4.** Manual capture needs only 1.2, so it ships first to make the tool usable early; because every agent write goes through one path, 1.3's credential check covers it without rework.

**Stage 2 — Pipeline system.** Applications/activities/drafts, CRUD and review UI, MCP server exposing scoped tools, additional agents.

**Stage 3 — Governance completion.** Full audit views, human review queue, analytics.

## Stack

- **Rails 8.1 / Ruby 3.4.8 / PostgreSQL** — core application and system of record
- **solid_queue** — scheduled re-verification in Stage 1.4; until then the verifier runs on demand
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

`clay:summary` breaks down postings by slice, verification state, and work mode, and lists **suspect negatives** — `not_found` verdicts with zero roles listed. Those are the renderer's first targets in Stage 1.2.

Boot the server:

```bash
bin/rails server
```

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path.
