"""A careers page opened for another reader (4f): the operator's own AI assistant, through MCP. Never the LLM here.

The page is opened as a check opens it (robots.txt, the wait between requests to one host, the browser, a bot
challenge or an error status never taken for a page), and handed back as the extractor would see it: its text, cut
where the extractor's is, and its links in the page's order, cut where the extractor's are. A role named by its link's
number then means the same link to either reader.
"""

import time
from datetime import UTC, datetime
from urllib.parse import urlsplit

from verifier.config import MAX_LINKS, MAX_TEXT_CHARS
from verifier.contract import RenderResult, Target
from verifier.pipeline import Services
from verifier.render import RenderError, render


def read_page(target: Target, services: Services) -> RenderResult:
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    started = time.monotonic()

    def finish(outcome: str, **fields) -> RenderResult:
        elapsed = int((time.monotonic() - started) * 1000)
        return RenderResult(
            target_id=target.id, url=target.url, outcome=outcome, checked_at=checked_at, duration_ms=elapsed, **fields
        )

    if refusal := services.robots.check(target.url):
        return finish("blocked", reason=refusal)
    services.throttle.wait(urlsplit(target.url).netloc)
    try:
        page = render(services.browser, target.url)
    except RenderError as error:
        return finish("inaccessible", reason=error.reason)

    seen = {"final_url": page.final_url, "http_status": page.status}
    if page.looks_like_challenge:
        return finish("inaccessible", reason="bot_challenge", **seen)
    if page.status and page.status >= 400:
        return finish("inaccessible", reason=f"http_{page.status}", **seen)
    return finish(
        "ok",
        title=page.title,
        text=page.text[:MAX_TEXT_CHARS],
        text_truncated=len(page.text) > MAX_TEXT_CHARS,
        links=page.links[:MAX_LINKS],
        links_truncated=len(page.links) > MAX_LINKS,
        content_hash=page.content_hash,
        **seen,
    )
