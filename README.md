# Provenance Pipeline

**An agent-governed pipeline system.** AI agents are first-class users, operating under scoped permissions with full provenance on every write.

The CRM half is deliberately minimal. The point of this system is the governance layer around what agents are allowed to do — the data model exists to make that layer meaningful.

> **Status: Stage 1.1** — schema and CSV ingest. See [Build stages](#build-stages).

---

## The problem it solves

The first agent in the system is a **job finder**: it sources postings, then verifies at the employer's own applicant tracking system whether they are actually still open.

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

## Build stages

**Stage 1 — Job Finder.** A thin vertical slice through the whole stack rather than a horizontal layer, so something useful ships before the CRUD work and the governance model is proven on real data early.

- **1.1 — Schema and ingest** ← *current*
- 1.2 — Verification agent (Playwright + LLM, Python worker)
- 1.3 — Scoped writes and provenance
- 1.4 — Weekly digest

**Stage 2 — Pipeline system.** Applications/activities/drafts, CRUD and review UI, MCP server exposing scoped tools, additional agents.

**Stage 3 — Governance completion.** Full audit views, human review queue, analytics.

## Stack

- **Rails 8.1 / Ruby 3.4.8 / PostgreSQL** — core application and system of record
- **solid_queue** — async verification across many postings
- **Python + Playwright** — agent workers. Required rather than preferred: the verification step needs headless rendering plus LLM tooling, and both are strongest there.
- **RSpec, Rubocop, Brakeman, bundler-audit**

## Setup

```bash
bundle install
bin/rails db:create db:migrate
```

Import Clay CSV exports (a directory or a single file):

```bash
bin/rails "clay:import[/path/to/clay-exports]"
bin/rails clay:summary
```

`clay:summary` breaks down postings by slice, verification state, and work mode, and lists **suspect negatives** — `not_found` verdicts with zero roles listed. Those are the renderer's first targets in Stage 1.2.

Boot the server:

```bash
bin/rails server
```

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path.
