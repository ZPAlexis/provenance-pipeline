# Sourcing: a watch list, not a search

[← README](../README.md)

The system does not search the job market. **It watches a chosen set of companies and reports what changed.**

That separates two jobs that browsing job sites does at once, badly:

| Job | How often | Who does it |
|---|---|---|
| Deciding which companies are worth watching | Rarely | A human — it's a judgment call (their own AI assistant may propose; they decide) |
| Checking whether those companies opened or closed a role | Constantly | The system — it's mechanical |

**Three inputs feed the watch list:**

1. **An imported base of companies.** The seed data came from job-board exports, and many of those postings turned out to be stale. That matters less than it sounds: postings are perishable, but the companies behind them are durable, and every posting is re-verified at the source, so a stale listing corrects itself on its first check. The listings were just how the companies were found.
2. **Manual capture.** Paste a company's domain, careers page, or ATS board, or a role's own page; the system finds the company's careers page and ATS, reads it, and adds the company to the watch list for good, and a pasted role is tracked. Job boards and ordinary browsing keep feeding the system — a find gets captured instead of living in a notes file. A job board's own link (LinkedIn, Indeed) is never read: it is kept beside the role as where it was found, and finds the role again if it is already on record.
3. **Proposals from the operator's own AI assistant** (4b; Claude or another, through MCP). Asked to, it searches the open web for companies that fit what the operator wants of one (kept on the profile), checks each against the record and its job board, and proposes it with a review: a score from 0 to 100, point by point, with its sources. A proposal is watched only once the operator tracks it, and one they decline is never proposed again.

**The tradeoff, stated plainly: roles at companies outside the list are missed.** There is no crawl, so the list only grows by judgment. That is deliberate. Search-then-filter optimizes for recall; watching a curated list optimizes for precision and fit, which is what this system is for.

**Nothing in the code is specific to one kind of role.** Verification reads every role a careers page shows (a *listing*) and checks whether a tracked *posting* is among them, without knowing what anyone is looking for. The only place a target field enters is a search profile stored as data — titles and keywords, exclusions, the places the user can work, work modes, and seniority as a title states it — which decides which roles are suggested; the user picks the ones to track. Another field, or another person, is another profile.

Two consequences shape the build. A company's careers page becomes a **watch target**, re-checked for months — a higher bar than resolving a page once for a single check. And re-verification makes postings **stateful**: `verified_live` → `not_found` is a lifecycle transition, not a correction, and the audit log is what makes "when did this role close?" answerable.
