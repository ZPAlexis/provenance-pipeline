# Schema

[← README](../README.md)

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
              comp_expectation, notes (the operator's alone to start or move;
              since 4f their AI assistant adds dated notes on their word)

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

profile_links search_profile_id, label, url, position, read_at, read_outcome
              (ok | gone | blocked | inaccessible | error), read_reason,
              read_skipped (4d: the operator's own website, GitHub or other
              portfolio, at most 5, never LinkedIn; the operator's alone to
              edit, audited by the label's and address's hashes; the verifier
              records only what a read found)

link_pages    profile_link_id, url, title, text, content_hash, read_via
              (render | github_api), run_id, first_read_at, last_read_at
              (4d: each page a link showed, one row per distinct text, read
              free and never by the LLM; a read's pages share its read_at)

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
              background_id, background_hash; since 4d must_haves (jsonb:
              each must-have the role states, shown on the resume, only in the
              background, or not shown, with its lines; null before the
              check), score_before_cap and background_score_before_cap (the
              score as weighed, when a must-have capped it at 69)

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

agent_credentials  actor, scopes, token_digest, purpose, issued_by (who asked
                   for the run: the operator, or their AI assistant),
                   expires_at, revoked_at (one per agent run)

check_runs    kind (role | company | all | describe | draft | review | fit |
              links), company_id, posting_id, request (jsonb: what a draft,
              review or fit was asked for; mode free for a free check, 4f), status (queued | running | done |
              failed), requested_by (the operator, or their AI assistant: the
              dashboard's "Asked by"), ceiling_usd, answer, summary, tally (jsonb),
              cost_usd, run_id, total, error, started_at, finished_at
              (a check asked for from the pages, run in the background,
              which the page polls)

page_renders  company_id, page_check_id (the check that left it unread), run_id,
              url, final_url, http_status, title, text, text_truncated,
              links (jsonb: [link text, address] pairs in page order),
              links_truncated, content_hash, rendered_at (4f: a careers page a
              free check left unread, opened for the operator's AI assistant to
              read, as the extractor would see it, never by the AI here)

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

- **An application's history is its audit log.** Each stage change records the stage and the date it happened (the operator's, not when it was typed), so velocity and conversion are measured from the record, not a copy of it. Moved to the stage it is at, on another day, a stage is re-dated in place: its new date is recorded, and its timeline and its days in the stage go by it.
- **A credential is never deleted,** so every agent write can be traced to the run behind it. A refused write is an audit event too (`denied`), with what it tried.
- **Page checks are evidence, not changes.** Every page read, whatever its outcome, is a `page_checks` row with a snapshot of every listing it saw, unfiltered, so a later search profile can be applied to past checks. Changes to companies and postings go through `audit_events`.
- **`llm_calls` answers "what did this cost, and what produced it"** without the run directory: one row per model call, with the model the API reports having served, its settings, and a `prompt_version` hash over the prompt, output schema, and limits.
- **A repeat read is paid for only when the roles may have changed.** A page that links to exactly the role pages it did last time reuses that read's listings, and its check names the read it reused (`reused_from_id`); listings are read in full again once 14 days old (`listings_read_at`). A company whose free ATS board lists at least 90% of its page's roles has that board recorded beside the page (`board_*`, with the evidence) and read in its place for 30 days; the page stays the one on record.
- **A contact is someone else's personal data.** Its name, email, link and notes are audited as hashes, never the values, so deleting a contact takes them off the record; its activities and outreach notes stay as they were written, naming no one.
- **Only the operator tracks a company or a role,** by hand or through their own AI assistant on their word (4a: the assistant's `watchlist:curate`, with their reason on the record); no agent does on its own judgment. A company can also be `suggested` (4b): proposed by the operator's own client (`companies:suggest`), with why in `proposal`, and not watched, checked, suggested from or reviewed until tracked. Tracking one reads the board it was proposed with at once, always free (the worker is started with no API key at all): kept as its careers page, by the verifier, only when the board's vendor records the same company or its page links home; held for the operator to confirm when nothing ties it to the company. Archiving one declines it, and it is never proposed again. Why it may fit is the operator's business: the audit log holds it by a hash alone. A company is `tracked` or `dismissed` (archived, 4a): it is watched only while tracked and its careers page is found, and archiving it archives its tracked and suggested roles too, each on the record with the operator's note; it is refused while an application there is open, and tracking the company again brings those roles back as they were. A posting is `suggested` (proposed by the suggester, with why in `fit`), `tracked` (on the operator's watch list), or `dismissed` (archived: never checked or suggested again); the suggester may suggest, never track. A suggestion the operator never acted on is withdrawn when it no longer fits the profile or its check found it gone: deleted, with its whole record kept in its last audit event. `job_url` is the role's own page at the employer, learned from the listing it matched, so the next check finds the role by its link before its title; `posting_url` stays where it was found.
- **The review queue is worked out from the record.** Each open item is a question the record asks now (one per question about one company or role), raised by the agent whose read led to it and closed by the operator's decision or when its evidence resolves, all audited. `evidence_key` fingerprints what was seen: an item left as is is raised again only when it changes.
- **Careers-page resolution is recorded beside the page:** how it was found, how sure we are (`high`, `medium`, `low`, or `confirmed` by a person), a held candidate, or why it failed. A low-confidence find waits in `resolution_candidate_url` and is never watched until a person confirms it.
- **JSONB `enrichment`** on both core tables. Upstream sources vary in shape — one export carries 7 columns, another 28. Structured core plus JSONB avoids a migration every time a source adds a field. Promote a key to a real column once it's filtered or sorted on regularly.
- **A draft keeps what it was written from.** The resume and description versions it read are linked and hashed (a hash outlives a deleted resume), its LLM call names the model, settings, prompt version and cost, and the text as the drafter wrote it stays beside the operator's edits. Its audit events name its size and hash, never its text: a draft is the resume paraphrased.
- **Whether a list was read whole is the worker's own answer,** kept on each verification run's first check (`complete`): a role missing from part of a list has not closed, so what changed and the accuracy test's replays (`verifier:test_b`, see [Tests](../README.md#tests)) read it rather than guess.
- **UUID primary keys** throughout (via `pgcrypto`).
- **`source_slice` lives on postings, not companies**, because one company can surface in several geographic pulls — the slice describes where the posting was found.
- **`changes_made`, not `changes`** — the latter collides with `ActiveModel::Dirty#changes`.

## Verification fields

A **check** is an observation at the employer's own careers page that produced a verdict: `verified_live`, `not_found`, or `inaccessible`. An upstream answer that maps to none of these is not a check: the posting stays `pending`, and the raw answer is kept in `enrichment`.

- **`verification_state`** — the last check's verdict, or `pending` while there is no usable one.
- **`last_checked_at`** — when that verdict was observed. It is present exactly when a posting has a verdict (enforced by validation), so `nil` means one thing: no check has produced a verdict yet (it may have been checked and found inconclusive).
- **`roles_listed_count`** — roles visible on the page at that check, matched or not. This is the corroborating observable; `nil` means unknown, never a sentinel value.
- **`work_mode`** — as observed at that check.

Imported verdicts carry an operator-supplied check date. A bare date is day precision (stored at 12:00 UTC so the calendar day never shifts), and the posting's create event records where the date came from. The verifier (1.2) is the main writer now, and records the exact time it looked. A verdict that changes is an audited update; a check that confirms the verdict only refreshes `last_checked_at` and what it observed, with the check's own record as its provenance (a role found at a new address is the exception: its `job_url` changes, audited); and a check that couldn't decide (it read only part of a list and found nothing) writes no verdict at all, so a role on page two is never marked closed.
