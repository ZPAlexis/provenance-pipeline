# verifier

The Python worker behind Stages 1.2 and 1.5. It never touches the database: Rails writes a targets file, runs the worker, validates every result against a fixed contract, and records it through one audited write path. One JSON result per target, appended as it goes, so a run that stops early keeps everything it finished.

```bash
uv run verifier extract --targets targets.json --out results.jsonl   # read careers pages, list their roles
uv run verifier resolve --targets companies.json --out results.jsonl # find each company's careers page
uv run verifier verify  --targets companies.json --out results.jsonl # read each watched page in full, match its postings
uv run verifier match   --targets snapshots.json --out results.jsonl # match against listings read before (nothing fetched)
uv run verifier check   --targets roles.json --out results.jsonl     # is one role still listed? its own page first
uv run verifier boards  --targets companies.json --out results.jsonl # find free boards listing the same roles (no LLM)
uv run verifier suggest --targets companies.json --out results.jsonl # weigh stored roles against a search profile (no fetch, no LLM)
```

Every command takes `--model` (default `claude-haiku-4-5`) and `--delay` (seconds between requests to one host, default 5). `verify`, `check`, and `match` take `--no-llm` to leave near-miss matches undecided, so a replay costs nothing; `boards` and `suggest` never call the LLM. The browser and the LLM client are imported only by the commands that use them: from a checkout under `/mnt` in WSL the LLM client alone takes about 15 seconds to import, and `suggest` starts in about one. In practice the worker is run from Rails (see the main README), which supplies the API credential to this process alone.

Exit codes: 0 finished; 2 bad input; 3 stopped, API credit exhausted; 4 stopped, credential missing or rejected; 5 stopped, the LLM service kept failing.

## How a page is read

1. **robots.txt is honored.** A disallowed page is never requested; an unreachable robots.txt counts as "disallow" and is retried once.
2. **A known board is read through its vendor's public API**: Greenhouse, Lever, Ashby, or Workday, whether the address is the board, one job on it, or a company page that embeds it. Exact, free, and complete. Workday's API sits on the company's own host, so its robots.txt decides. A board larger than the reader's limit (2,000 roles on Workday) is read as a part that says so, never as the whole list. A Workday board takes dozens of requests: a failed one is asked again once, and a board that keeps failing partway is kept as the part that was read.
3. **Otherwise the page is rendered in Chromium**: its JavaScript runs, it is scrolled for lazy loading, "load more" / "show more" buttons are clicked the way a person would (buttons only, never links, up to ten times), and every frame is read.
4. **Claude reads the rendered text** and returns structured output: each role with its title, location, link (by number, so URLs come back exactly as the page had them), work mode, department, and employment type when the page states them; plus what the page itself says about the list: a stated total, "no openings", only part of the list (paginated, filtered to one department), one job's own posting, or many employers' roles.
5. **Pagination is followed** through the "next page" link the extractor points to, up to ten pages per company.

The crawler names itself in its user agent, waits between requests to one host, and never tries to get past a bot challenge: a challenged or refused page is `inaccessible`, never "no openings".

## How a careers page is found

Cheapest, most certain step first. A page counts as found only when a check reads the company's own listings off it, or reads that it has none.

1. **The page already on record**, if it still lists jobs.
2. **Common paths** on the company's domain (`/careers`, `/jobs`, ...). A plain request goes first; only a path that answers is rendered.
3. **Homepage links** that say careers or jobs (English, Portuguese, Spanish), on the company's own site or into a known board.
4. **One link further** from a careers landing page that only links to its jobs, or a page showing only part of them: "All jobs" before a single department.
5. **A guessed board** on Greenhouse, Lever, or Ashby, from the domain and name, kept only if its vendor records the same company name or **its own page links home to the company's domain**. A guess that links to another company's site is discarded.
6. **Claude picks a link** from the homepage's numbered links, as a last resort.

Every result carries a confidence, so a person looks only where it matters. **High**: the company's own site, or a page it links to. **Medium**: a guessed board confirmed by its vendor's name record or its home link. **Low**: an unconfirmed guess, a link Claude picked, or a page that still shows only part of its list. A low-confidence find comes back as a *candidate* that Rails never watches until a person confirms it.

One job's own posting is never a careers page. A company's own page of many employers' roles comes back as a candidate with a *suggested kind*: a recruiter's client roles (its careers page, once the operator says so) or an aggregator's listings (never its careers page).

## How postings are verified

Each company's watched page is read in full, then every tracked posting (every one the operator has not dismissed) is matched against everything read. Matching knows nothing about what anyone is looking for:

1. **The posting's own link**: a listing at the role's own address at the employer is its role, whatever its title says now (a renamed title is noted). The link is learned from the listing a posting last matched.
2. **The same title**, ignoring case, punctuation, accents, and "Sr."/"Jr."
3. **A close variant**: one title's words all within the other's. The listing may add words that don't change the level ("Solutions Engineer" / "Senior Solutions Engineer, LATAM", but not "... Manager"); the posting may add only seniority or region, so a generic listing never stands in for a more specific posting ("Quality Engineer" is not "Quality Engineer – After Market Solutions").
4. **Near-misses only** (half the words shared) go to Claude, one call per page. A "same role" answer is not trusted when each title names something the other lacks.

The location picks which listing is the posting's and is noted when it differs; it never decides the verdict. The verdict follows the evidence:

| What was read | Matched | Not matched |
|---|---|---|
| The whole list (an ATS API, every page, or up to the stated total) | `verified_live` | `not_found` |
| Only part of it, or a page that showed no roles and didn't say it has none | `verified_live` | *inconclusive*: no verdict |
| Nothing: the site refused us, or robots.txt keeps us off | `inaccessible` | `inaccessible` |

Verification never guesses: it reads the watched page resolution decided, or the free board the board search confirmed lists the same roles (see below).

## Checking one role now

`check` answers one question for one tracked role: is it still listed? It matches as above, the role's own link first.

1. **The role's own page**, when it is known. On a known ATS, the board's API lists every role, free, so it settles the answer either way. On the company's own site, the page is loaded but never read by the LLM: when it loads, shows the role, and doesn't say it is closed ("no longer accepting applications", in English, Portuguese, or Spanish), the role is still listed. A redirect to an address that still carries the role's own id (Greenhouse's `gh_jid`, a requisition number, a UUID) is the same page.
2. **The company's careers page** otherwise: when the role's page is gone, leads elsewhere, says the role is closed, doesn't show it, or isn't known. The role or a close one is looked for there, and "no longer listed" needs the whole list, as for any verdict. A role found again under a new link is still listed, and the verdict carries the new link.

The answer is *still listed*, *no longer listed*, or *couldn't confirm*, with why. Whether a role was filled is never claimed: a page rarely says.

## Weighing roles against a search profile

`suggest` takes one company per target: the roles its watched page last listed (stored, never fetched again), the search profile, and the company's roles already on record. It never calls the LLM. Each role is weighed by these rules in order, and the first one it fails rules it out:

1. **Title**: it holds every word of one of the profile's titles, in any order, plurals folded and filler words aside ("Engineer, Solutions" holds "Solutions Engineer"). A one-word title is a keyword.
2. **Excluded words**: it holds every word of none of them.
3. **Level**: the level its title states (`titles.title_level`: entry, senior, lead, director, executive; the highest stated wins; "Manager" states none) is one sought.
4. **Place**: it is open to one of the places, which mean where someone can work (`places`). A country takes roles that name it by any name or code, or name a city or state in it, and roles open to a region containing it; a region takes roles open to it, never every role inside it; "Global", "Worldwide", or "Anywhere" opens a role to every place unless the location names something narrower. When the location names no place ("Remote"), a place the title names stands in. A place the vocabulary does not know is matched by its words.
5. **Work mode**: as the listing states it, or as its location says ("Remote").

What a role does not state is never held against it: it fits, with a note (`place_not_stated`, `work_mode_not_stated`, `level_not_stated`), noted only where the profile narrows. Every role holding a profile title comes back with its reasoning, fitting or ruled out; the rest are only counted. A fitting role that is already on record names the posting it is (`on_record`), matched by `match.Matcher` exactly as verification matches, without the LLM; `listed` says where every posting on record was found in the read.

## Paying for a read only when something may have changed

Claude's reading of rendered pages is nearly all of a run's cost, so verification avoids it in two ways, both decided by free signals:

- **Unchanged role links reuse the last read.** Each page is still rendered (free). When it links to exactly the role pages it did at the last run (role links under the same folders as before, none gone, none new), the listings read then are reused and the check says so, naming the read it reused. A role link is compared without tracking parameters or in-page anchors, but a route after the hash (`#/jobs/405`, as single-page job boards use) names the role and is kept. Roles without distinct links fall back to the page's whole text being identical. Every page of a list is judged on its own, so only the pages that changed are read. Whatever the links say, a page's listings are read again in full once they are 14 days old.
- **A free board read in place of the page.** `boards` looks for a Greenhouse, Lever, or Ashby board for each company whose page Claude had to read, and compares its roles with the roles the page showed. When no guessed board lists them, one of the company's own job pages is looked at for a board behind the site, such as an Apply button into Workday, whose boards can't be guessed by name. A board is adopted only on the roles themselves: it must list at least 90% of the page's distinct titles. Who owns it (the vendor's name record, or the site its page links to) is recorded as evidence, not required: a board with a company's exact name can belong to another company and share none of its roles, while a company's own board can link to a sister domain. Verification then reads the board's API; the page stays the one on record and is read instead if the board fails or lists nothing. A board's finding is trusted for 30 days, then the page is read again and the board checked against it.

## Code map

`cli` runs a command over its targets; the orchestrators do one job each: `resolve` (finding the careers page), `verify` (reading it in full and matching), `check` (one role now), `boards` (the board search), `match` (posting against listings), `profiles` (which stored roles fit a search profile, and why). Under them: `pipeline` (one page read: robots, render, ATS API, extraction, reuse), `render`, `extract` (the LLM steps), `ats` (vendors, their APIs, whose board a board is), `robots`, `politeness`. `contract` is the boundary with Rails; `config` holds the model, limits, and delays; `errors` holds why a whole run stops early.

**Helpers several modules share live in a neutral module, never inside an orchestrator:** `titles` (what a title is, word by word, and the level of experience it states: matching, board overlap, check now, and search profiles share one meaning of a title), `links` (whether two addresses name the same role or page), and `places` (what a location names, and whether a role there is open to where someone can work: a role in São Paulo, or open to Latin America, is open to Brazil). A change there changes every caller on purpose.

## Development

```bash
uv sync
uv run playwright install chromium
uv run ruff check . && uv run ruff format --check .
uv run pytest
```

Tests run against a local synthetic site (JavaScript-rendered lists, iframes, pagination, "load more", one job's posting, a maintenance page, job pages open, closed, and moved) with a fake LLM: no network, no API key, no cost.
