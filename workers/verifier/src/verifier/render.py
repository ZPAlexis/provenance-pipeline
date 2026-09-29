"""Rendering a careers page in a real browser.

Most job boards load their listings client-side, so an HTTP fetch sees an empty
shell and a parse failure looks like a confident "not found". Chromium runs the
page's JavaScript, waits for it to go quiet, scrolls to trigger lazy loading,
and then reads every frame, because many company pages embed their job board
in an iframe.
"""

import contextlib
import hashlib
import re
from dataclasses import dataclass, field

from playwright.sync_api import Browser, Page
from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeout

from verifier.config import NAVIGATION_TIMEOUT_MS, SCROLL_PASSES, SETTLE_TIMEOUT_MS, USER_AGENT

_LINKS_JS = """() => Array.from(document.querySelectorAll('a[href]'))
  .map(a => [(a.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 200), a.href])"""
_EMBED_SRCS_JS = """() => Array.from(document.querySelectorAll('iframe[src], script[src]')).map(e => e.src)"""

# Text a bot challenge interstitial shows instead of the page.
_CHALLENGE_MARKERS = (
    "verify you are human",
    "just a moment",
    "checking your browser",
    "attention required",
    "are you a robot",
    "complete the security check",
)


class RenderError(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass
class RenderedPage:
    final_url: str
    status: int | None
    title: str
    text: str
    links: list[tuple[str, str]] = field(default_factory=list)  # (link text, absolute URL)
    urls: list[str] = field(default_factory=list)  # final, frame, and embed URLs: where a known ATS shows up

    @property
    def content_hash(self) -> str:
        normalized = re.sub(r"\s+", " ", self.text).strip()
        return "sha256:" + hashlib.sha256(normalized.encode()).hexdigest()

    @property
    def looks_like_challenge(self) -> bool:
        """A bot-challenge interstitial rather than the page. We never try to get past one."""
        head = self.text[:3000].lower()
        return len(self.text) < 3000 and any(marker in head for marker in _CHALLENGE_MARKERS)


def render(browser: Browser, url: str) -> RenderedPage:
    context = browser.new_context(user_agent=USER_AGENT)
    try:
        page = context.new_page()
        page.set_default_navigation_timeout(NAVIGATION_TIMEOUT_MS)
        try:
            response = page.goto(url, wait_until="domcontentloaded")
        except PlaywrightTimeout as error:
            raise RenderError("timeout") from error
        except PlaywrightError as error:
            raise RenderError("navigation_error") from error

        _settle(page)
        return _read(page, response.status if response else None)
    finally:
        context.close()


def _settle(page: Page) -> None:
    """Let client-side rendering finish. Some pages never go fully quiet; read what rendered."""
    _wait_for_quiet(page, SETTLE_TIMEOUT_MS)
    for _ in range(SCROLL_PASSES):
        page.evaluate("() => window.scrollTo(0, document.body ? document.body.scrollHeight : 0)")
        page.wait_for_timeout(400)
    _wait_for_quiet(page, 3_000)


def _wait_for_quiet(page: Page, timeout_ms: int) -> None:
    with contextlib.suppress(PlaywrightTimeout):
        page.wait_for_load_state("networkidle", timeout=timeout_ms)


def _read(page: Page, status: int | None) -> RenderedPage:
    texts: list[str] = []
    links: list[tuple[str, str]] = []
    urls: list[str] = [page.url]

    for frame in page.frames:
        urls.append(frame.url)
        try:
            texts.append(frame.locator("body").inner_text(timeout=5_000))
            links.extend(tuple(link) for link in frame.evaluate(_LINKS_JS))
            urls.extend(frame.evaluate(_EMBED_SRCS_JS))
        except PlaywrightError:
            continue  # a frame detached or never finished loading; read the rest

    return RenderedPage(
        final_url=page.url,
        status=status,
        title=page.title(),
        text="\n\n".join(text for text in texts if text.strip()),
        links=_dedupe_links(links),  # all of them; the prompt decides how many the model sees
        urls=[url for url in dict.fromkeys(urls) if url and not url.startswith(("about:", "javascript:"))],
    )


def _dedupe_links(links: list[tuple[str, str]]) -> list[tuple[str, str]]:
    seen: set[tuple[str, str]] = set()
    kept = []
    for text, href in links:
        if not href or href.startswith(("javascript:", "mailto:", "tel:")) or (text, href) in seen:
            continue
        seen.add((text, href))
        kept.append((text, href))
    return kept
