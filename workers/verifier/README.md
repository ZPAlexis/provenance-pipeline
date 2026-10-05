# verifier

The Python worker behind Stage 1.2. It never touches the database: Rails writes a targets file, runs the worker, validates every result against a fixed contract, and records it through one audited write path. One JSON result per target, appended as it goes, so a run that stops early keeps everything it finished.

```bash
uv run verifier extract --targets targets.json --out results.jsonl   # read careers pages, list their roles
uv run verifier resolve --targets companies.json --out results.jsonl # find each company's careers page
uv run verifier verify  --targets companies.json --out results.jsonl # read each watched page in full, match its postings
uv run verifier match   --targets snapshots.json --out results.jsonl # match against listings read before (nothing fetched)
uv run verifier boards  --targets companies.json --out results.jsonl # find free boards listing the same roles (no LLM)
```

Every command takes `--model` (default `claude-haiku-4-5`) and `--delay` (seconds between requests to one host, default 5). `verify` and `match` take `--no-llm` to leave near-miss matches undecided, so a replay costs nothing; `boards` never calls the LLM. In practice the worker is run from Rails (see the main README), which supplies the API credential to this process alone.

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

Each company's watched page is read in full, then every tracked posting is matched against everything read. Matching knows nothing about what anyone is looking for:

1. **The same title**, ignoring case, punctuation, accents, and "Sr."/"Jr."
2. **A close variant**: one title's words all within the other's. The listing may add words that don't change the level ("Solutions Engineer" / "Senior Solutions Engineer, LATAM", but not "... Manager"); the posting may add only seniority or region, so a generic listing never stands in for a more specific posting ("Quality Engineer" is not "Quality Engineer – After Market Solutions").
3. **Near-misses only** (half the words shared) go to Claude, one call per page. A "same role" answer is not trusted when each title names something the other lacks.

The location picks which listing is the posting's and is noted when it differs; it never decides the verdict. The verdict follows the evidence:

| What was read | Matched | Not matched |
|---|---|---|
| The whole list (an ATS API, every page, or up to the stated total) | `verified_live` | `not_found` |
| Only part of it, or a page that showed no roles and didn't say it has none | `verified_live` | *inconclusive*: no verdict |
| Nothing: the site refused us, or robots.txt keeps us off | `inaccessible` | `inaccessible` |

A watched page is never swapped for a guessed board during verification: resolution decides the page, verification only reads it.

## Paying for a read only when something may have changed

Claude's reading of rendered pages is nearly all of a run's cost, so verification avoids it in two ways, both decided by free signals:

- **Unchanged role links reuse the last read.** Each page is still rendered (free). When it links to exactly the role pages it did at the last run (role links under the same folders as before, none gone, none new), the listings read then are reused and the check says so, naming the read it reused. A role link is compared without tracking parameters or in-page anchors, but a route after the hash (`#/jobs/405`, as single-page job boards use) names the role and is kept. Roles without distinct links fall back to the page's whole text being identical. Every page of a list is judged on its own, so only the pages that changed are read. Whatever the links say, a page's listings are read again in full once they are 14 days old.
- **A free board read in place of the page.** `boards` looks for a Greenhouse, Lever, or Ashby board for each company whose page Claude had to read, and compares its roles with the roles the page showed. When no guessed board lists them, one of the company's own job pages is looked at for a board behind the site, such as an Apply button into Workday, whose boards can't be guessed by name. A board is adopted only on the roles themselves: it must list at least 90% of the page's distinct titles. Who owns it (the vendor's name record, or the site its page links to) is recorded as evidence, not required: a board with a company's exact name can belong to another company and share none of its roles, while a company's own board can link to a sister domain. Verification then reads the board's API; the page stays the one on record and is read instead if the board fails or lists nothing. A board's finding is trusted for 30 days, then the page is read again and the board checked against it.

## Development

```bash
uv sync
uv run playwright install chromium
uv run ruff check . && uv run ruff format --check .
uv run pytest
```

Tests run against a local synthetic site (JavaScript-rendered lists, iframes, pagination, "load more", one job's posting, a maintenance page) with a fake LLM: no network, no API key, no cost.
