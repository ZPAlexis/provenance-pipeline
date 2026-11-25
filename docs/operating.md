# Running it

[← README](../README.md)

Setup in full, every command, backups, and the pages. The README has the quickstart and the tests.

## Setup

It needs Ruby 3.4.13 and PostgreSQL 16; it was built in WSL (Ubuntu), with the Ruby from mise.

```bash
bundle install
bin/rails db:create db:migrate
```

Import Clay CSV exports (a directory or a single file). Clay carries no per-row check date, so an export that includes verdicts needs `VERIFIED_AT`, the date the verdicts were reached (ISO 8601). Without it, the import refuses to run and writes nothing; exports without verdicts don't need it. See [Verification fields](schema.md#verification-fields).

```bash
VERIFIED_AT=2026-09-22 bin/rails "clay:import[/path/to/clay-exports]"
bin/rails clay:summary
```

Every write the importer makes is recorded in `audit_events` as a create or an update, with `changes_made` holding `{ attribute => [before, after] }` (JSONB enrichment is diffed key by key). Rows are atomic, and re-importing a file writes nothing.

`clay:summary` breaks down postings by slice, verification state, and work mode, and lists **suspect negatives** — `not_found` verdicts with zero roles listed.

## The verifier

The worker lives in [`workers/verifier`](../workers/verifier) (Python, managed with [uv](https://docs.astral.sh/uv/)):

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
bin/rails verifier:verify                        # check all tracked companies: the plan and its cost; GO=1 runs it
bin/rails verifier:changes                       # what changed since the check before the latest (FROM=)
bin/rails "verifier:describe[posting_id]"        # read a role's description (ROLES=applications|tracked for many); free
bin/rails verifier:find_boards                   # free boards listing the same roles as LLM-read pages (no API cost)
bin/rails "verifier:check[posting_id]"           # is this role still listed? its own page first, then its company's
bin/rails "verifier:track[posting_id]"           # or verifier:dismiss (archive it): your watch list, with NOTE="why"
bin/rails "verifier:dismiss_company[company_id]" # archive a company and its roles in play (NOTE=); verifier:track_company undoes it (ROLES=0 leaves its roles)
bin/rails verifier:proposals                     # the companies your own AI assistant proposed (4b): track one (verifier:track_company reads its board then, free) or decline it (verifier:dismiss_company)
bin/rails companies:preferences                  # what you want of a company (4b); WANTS=, AVOIDS=, STAGES=, SIZES=, MODELS=, INDUSTRIES=, EXCLUDED= save them
bin/rails companies:reviews                      # companies by their newest review, best first, stale ones marked (MIN=, LIMIT=); DUE=1 lists those due one
bin/rails "companies:review[company id or name]" # one company's newest review in full: its points, facts with sources, concerns and questions
bin/rails verifier:suggest                       # suggestions from the search profile (no API cost); PREVIEW=1 writes nothing
URL="acme.com" bin/rails verifier:add            # add a company by its domain, careers page, or ATS board (COMPANY_NAME, PAGE=its careers page, watched as given; CHECK=1 reads it)
URL="https://..." bin/rails verifier:add_role    # add a role by its own page, tracked (TITLE, needed without CHECK=1; SOURCE; COMPANY_ID at a company on record; WEBSITE for an ATS link's new company)
URL="https://..." bin/rails "verifier:own_page[posting_id]"  # change a role's own page at the employer (NOTE optional)
bin/rails "verifier:hand_check[posting_id]"      # record a check you made yourself
REASON="why" bin/rails "verifier:undo_verdict[posting_id]"  # undo the verifier's latest verdict on a role, restoring what it replaced
REASON="why" bin/rails "postings:move[posting_id,Company Name,domain.com]"  # move a role to the company really hiring (one an aggregator listed)
bin/rails verifier:backfill_job_urls             # each role's own page, from the listing it already matched (no API cost)
bin/rails profile:links                          # your own links (4d) and what each read found; READ=1 reads them now, free
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
bin/rails fit:list                               # roles by fit, best first, stale scores and screen risks marked (MIN=70, LIMIT=)
bin/rails "fit:show[posting_id]"                 # its score, why, the level, its must-haves, matches by resume line, gaps
bin/rails reviews:list                           # reviews, newest first, who wrote each and its cost (APPLICATION=)
bin/rails "reviews:show[id]"                     # its strengths, gaps and suggestions with their lines, and its note
```

The commands run most have specs of their own (`spec/tasks/`), run as the operator runs them: what each prints, that its writes are audited as theirs and backed up first, and that a command given something wrong is refused before any backup. A name is given in `COMPANY_NAME` or `CONTACT_NAME`, never `NAME`, which shells set already (WSL sets it to the machine's name).

## Backups

Every verifier batch that writes backs up first: `bin/rails db:backup` does the same by hand (checks started from the pages, at most once a day). Dumps go to `~/.local/share/provenance-pipeline/backups/` (owner-only), named with their UTC time. Each new dump prunes the folder to the 10 newest plus the newest of each week for a year. The test environment backs up into `tmp/backups/` instead, never beside the real dumps. To keep a copy on another disk as well, name a folder in `~/.config/provenance-pipeline/backup_mirror` (one line); each new dump is copied and pruned there the same way, and a failed copy is reported without stopping the batch.

A backup is proven by restoring it. Into a scratch database, then compare and drop it:

```bash
createdb provenance_pipeline_restore_check
pg_restore --no-owner --exit-on-error --dbname=provenance_pipeline_restore_check ~/.local/share/provenance-pipeline/backups/<newest>.dump
psql -d provenance_pipeline_restore_check -c "select count(*) from postings"
dropdb provenance_pipeline_restore_check
```

## The pages

Boot the server:

```bash
bin/rails server
```

It serves the operator's pages at `http://localhost:3000`: the pipeline (applications by stage, each with a page to move it, log what happened and with whom, keep its contacts, write and approve its drafts, and read its timeline), a dashboard (where applications and the tracked roles stand, how old the tracked companies' lists are, recent checks and verdict changes, API credit spent), "Check all tracked companies" on the Roles page (its plan and what it could cost: "at most" what the pages cost when last read in full, "about" when some were never read, priced at an average list; then its progress), what changed since a check of everything, the audit log (every write on record, narrowed by who made it, the kind of record, the action, the days, one record or credential, and an attribute it changed), the analytics (the pipeline: how far applications get, how long they sit in each stage, how they end, what is open now; the watch: how long roles stay listed, answers week by week, how fresh they are; the agents: AI cost, agreement on the review queue, writes and refusals), the roles (tracked, suggested with why, archived, filtered by answer and by fit, sorted by fit, the unscored or those weighed before the background weighed from there), each role's history, its description (read again from its own page, free, when a check moves that page), its fit (the ATS fit and the Background fit) and the checks behind it, the companies (tracked or archived, narrowed to those with no careers page yet, a page to confirm, no role tracked, or roles tracked none of which is still listed; each with its domain, careers page, roles and application, and a page of its own with its contacts), the search profile with a preview of what it would suggest, the company preferences, the operator's resume and their background in three parts, and the Review page: the questions waiting for the operator, by kind, each naming its company (its domain linked) and role and decided with a button; a check asked from one is followed on the item until it says whether it settled it; and the Agents page: each agent's scopes, the credentials its runs held, with what each wrote, and every refused write. From them the operator adds a company or a role by its link (a role also from its company's page; since 4e a role's ATS board is watched at once and the role checked right after when that costs nothing, never a check that could spend unasked), confirms or sets a company's careers page, changes a role's own page, tracks or archives a role or a company with a note on the record (several at once from the lists; archiving a company archives its roles in play), finds suggestions, and checks a role or a company now: the check runs in the background, one at a time, and a check that could spend says its ceiling and asks first. It is local and single-user, with no login, so it is never deployed as it is.

## Note on data

Source CSVs are **not committed** — they contain a live job-search target list. Keep exports outside the repo or in an ignored path. The verifier's run directories (`tmp/verifier/`) and database backups (`~/.local/share/provenance-pipeline/backups/`) hold the same list, so they stay out of the repo too. A draft's, a resume review's or a fit's run files quote the resume (and the part of the background they were given), so they are removed as soon as the run's results are read. The logs keep the record's private text out too: the resume and the background, what is written for an application, notes, pay, what happened, and the people (a contact's name, role, link and notes) are filtered from a request's parameters, from the values in logged SQL, and from a record printed in a console.

**No company on the record is named in the repo either,** in code, specs, docs or a commit message: examples name made-up ones (Acme, Contoso). `bin/rails privacy:names` checks the repo's files (tracked, and new ones not ignored) and the commits not yet pushed against every company name and domain on the record, and local CI runs it before anything is pushed. It runs only where the record is, so GitHub's CI can't. A name the repo may carry anyway (a tool the project uses that is also a company, a name that is also a word, checked then only as written) is allowed in `~/.config/provenance-pipeline/names_allowed.yml`, which names companies on the record too, so it stays outside the repo.
