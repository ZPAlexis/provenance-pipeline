# verifier

The Python worker behind Stage 1.2. Given a list of careers pages, it renders each one in a real browser, extracts the job listings it shows, and writes one JSON result per page. It never touches the database: Rails writes the targets file, runs the worker, and reads the results back.

```bash
uv run verifier extract --targets targets.json --out results.jsonl [--model claude-haiku-4-5]
```

In practice it is run from Rails, which supplies the API credential:

```bash
bin/rails "verifier:extract[https://example.com/careers]"   # one page
bin/rails verifier:test_a                                    # Test A over every page with ground truth
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
