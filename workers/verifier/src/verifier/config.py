"""Settings that shape how the worker behaves on other people's sites and on the API."""

# Names the crawler and links to the project, per the etiquette decision: the
# verifier says what it is rather than posing as an ordinary browser.
USER_AGENT = (
    "Mozilla/5.0 (compatible; ProvenancePipelineVerifier/0.1; +https://github.com/ZPAlexis/provenance-pipeline)"
)
ROBOTS_AGENT = "ProvenancePipelineVerifier"

# Politeness. One page at a time, and at least this long between two requests
# to the same host. Provisional numbers; they are settled in 1.2b.
DOMAIN_DELAY_SECONDS = 5.0

NAVIGATION_TIMEOUT_MS = 30_000
SETTLE_TIMEOUT_MS = 10_000  # waiting for client-side rendering to go quiet
SCROLL_PASSES = 4  # to trigger lazy-loaded listings
LOAD_MORE_CLICKS = 10  # "load more" / "show more" buttons clicked per page, as a person would
LOAD_MORE_PAUSE_MS = 1_000  # between clicks: each one asks the site for more
MAX_PAGES = 10  # pages of one list followed through its "next" links, per company

# What the LLM is shown of a page.
MAX_TEXT_CHARS = 150_000  # ~40k tokens; the largest board seen so far renders ~63k chars
MAX_LINKS = 1_500

DEFAULT_MODEL = "claude-haiku-4-5"
# Haiku 4.5's own ceiling (Sonnet 5 and Opus 5 allow 128k), reachable because
# calls stream. A 500-role board needs roughly 25k; listings name links by number,
# not URL, which keeps even that affordable.
MAX_OUTPUT_TOKENS = 64_000

# Request settings per model. Haiku 4.5 rejects `effort`, so it gets none; the
# rungs above it run at low effort. Recorded on every result.
MODEL_SETTINGS: dict[str, dict] = {
    "claude-haiku-4-5": {},
    "claude-sonnet-5": {"output_config": {"effort": "low"}},
    "claude-opus-5": {"output_config": {"effort": "low"}},
}

# USD per million tokens (input, output), from the API reference as cached
# 2026-06-24. Used only to estimate what a run cost.
PRICES_PER_MTOK: dict[str, tuple[float, float]] = {
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-sonnet-5": (2.00, 10.00),
    "claude-opus-5": (5.00, 25.00),
}


def estimate_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    input_price, output_price = PRICES_PER_MTOK.get(model, (0.0, 0.0))
    return round((input_tokens * input_price + output_tokens * output_price) / 1_000_000, 6)
