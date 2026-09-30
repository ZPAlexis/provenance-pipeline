# verifier

The Python worker behind Stage 1.2. It has two commands. `extract` renders careers pages in a real browser and writes the job listings each one shows. `resolve` finds a company's careers page from its domain and name. Either way it writes one JSON result per target and never touches the database: Rails writes the targets file, runs the worker, validates every result against a fixed contract, and records it through one audited write path.

```bash
uv run verifier extract --targets targets.json --out results.jsonl [--model claude-haiku-4-5]
uv run verifier resolve --targets companies.json --out resolutions.jsonl [--model claude-haiku-4-5]
```

In practice it is run from Rails, which supplies the API credential:

```bash
bin/rails "verifier:extract[https://example.com/careers]"   # one page
bin/rails verifier:test_a                                    # Test A over every page with ground truth
bin/rails verifier:resolve                                   # find and record careers pages (backs up first)
bin/rails verifier:candidates                                # low-confidence finds waiting for a human
bin/rails verifier:test_resolution                           # hide known pages, find them again
```

## How a page is checked

1. **robots.txt** is honored. A disallowed page is never requested, and an unreachable robots.txt counts as "disallow". When the company has a board on Greenhouse, Lever, or Ashby, found by its domain and name, the listings are read from that vendor's public API instead, and the result is marked `robots_disallowed_ats_fallback`, so the data's source stays visible.
2. The page is **rendered in Chromium**, which runs its JavaScript, waits for it to settle, scrolls to trigger lazy loading, and reads every frame, since many job boards are embedded in iframes.
3. If the page is, or embeds, a **Greenhouse, Lever, Ashby, or Workday** board, the listings come from that vendor's API: exact, free, and for Workday every page of its paginated results. Workday's API is on the company's own careers host, so it is checked against that host's robots.txt too.
4. Otherwise **Claude** reads the rendered text and returns the listings as structured output. The page's links are numbered and the model answers with a link's number, so URLs come back exactly as the page had them. Calls stream, which leaves room for boards with hundreds of roles.

The crawler identifies itself in its user agent, waits between requests to the same host, and never tries to get past a bot challenge. A challenged or blocked page is reported as `inaccessible`, never as "no openings".

## Development

```bash
uv sync
uv run playwright install chromium
uv run ruff check . && uv run ruff format --check .
uv run pytest
```

Tests run against a local synthetic site with a fake LLM: no network, no API key, no cost.

## How a careers page is found

Cheapest, most certain step first. A page counts as found only when a check reads listings off it, or reads that it has none.

1. **The page already on record**, if there is one and it still lists jobs.
2. **Common paths** on the company's domain (`/careers`, `/jobs`, `/about/careers`, `/company/careers`). A plain request goes first, and only a path that answers is rendered.
3. **Homepage links** that say careers or jobs (in English, Portuguese, or Spanish) on the company's own site, or that lead to a known ATS board.
4. **A guessed ATS board** on Greenhouse, Lever, or Ashby, from the domain and name.
5. **Claude picks a link** from the homepage's numbered links, as a last resort.

Every result carries a confidence, so a human looks only where it matters. **High**: a page on the company's own site, or a board its own homepage links to. **Medium**: a guessed Greenhouse board whose recorded company name matches. **Low**: an unconfirmed guess or a link Claude picked. A low-confidence find comes back as a *candidate*: Rails holds it apart from the watched page until a person confirms or rejects it, and that decision is audited as theirs. Every page checked along the way, and what each LLM call cost, is kept as evidence, whatever the outcome.
