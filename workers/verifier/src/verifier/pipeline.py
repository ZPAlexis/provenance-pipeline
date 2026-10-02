"""Checking one careers page, end to end: robots.txt, render, known ATS, extraction.

Cheapest path first. A page on (or embedding) a known ATS is read through the
vendor's public API; everything else is rendered and read by the LLM. Every
outcome, including refusals and failures, comes back as a PageResult, so a
page that could not be read is never mistaken for one with no openings.
"""

import time
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import urlsplit

import httpx2
from playwright.sync_api import Browser

from verifier import ats
from verifier.config import MAX_PAGES
from verifier.contract import Listing, PageResult, Target
from verifier.extract import ExtractionFailed, Extractor, input_truncated, link_url
from verifier.politeness import HostThrottle
from verifier.render import RenderedPage, RenderError, render
from verifier.robots import RobotsPolicy


@dataclass
class Services:
    browser: Browser
    http: httpx2.Client
    robots: RobotsPolicy
    throttle: HostThrottle
    extractor: Extractor


def read_homepage(target_id: str, url: str, services: Services) -> tuple[PageResult, RenderedPage | None]:
    """Render a homepage for its links, without extracting listings. The same robots and politeness rules apply."""
    started = time.monotonic()
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")

    def finish(page: RenderedPage | None = None, **fields) -> tuple[PageResult, RenderedPage | None]:
        elapsed = int((time.monotonic() - started) * 1000)
        result = PageResult(
            target_id=target_id, url=url, checked_at=checked_at, step="homepage", duration_ms=elapsed, **fields
        )
        return result, page

    refusal = services.robots.check(url)
    if refusal:
        return finish(outcome="blocked", reason=refusal)
    services.throttle.wait(urlsplit(url).netloc)
    try:
        page = render(services.browser, url)
    except RenderError as error:
        return finish(outcome="inaccessible", reason=error.reason)

    seen = {"final_url": page.final_url, "http_status": page.status, "content_hash": page.content_hash}
    if page.looks_like_challenge:
        return finish(outcome="inaccessible", reason="bot_challenge", **seen)
    if page.status and page.status >= 400:
        return finish(outcome="inaccessible", reason=f"http_{page.status}", **seen)
    return finish(page, outcome="ok", method="render", **seen)


def verify_page(target: Target, services: Services) -> PageResult:
    """Check one page and extract its listings."""
    return check_page(target, services)[0]


def check_page(
    target: Target, services: Services, *, ats_fallback: bool = True
) -> tuple[PageResult, RenderedPage | None]:
    """Check one page, returning the rendered page too when there is one, for its links.

    `ats_fallback=False` during resolution, which guesses boards as its own step.
    """
    started = time.monotonic()
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    page: RenderedPage | None = None

    def finish(**fields) -> tuple[PageResult, RenderedPage | None]:
        elapsed = int((time.monotonic() - started) * 1000)
        result = PageResult(target_id=target.id, url=target.url, checked_at=checked_at, duration_ms=elapsed, **fields)
        return result, page

    # An address on a known ATS board (the board, or one job on it) is read
    # through the vendor's public API: exact, free, and not a crawled page.
    board = ats.detect([target.url])
    if board and not (ats.on_company_host(board) and services.robots.check(ats.api_url(board))):
        try:
            listings = _fetch_board(board, services)
            return finish(
                outcome="ok",
                method=f"ats_api:{board.vendor}",
                ats=board,
                listings=listings,
                listing_count=len(listings),
            )
        except (httpx2.HTTPError, ValueError, KeyError, TypeError):
            pass  # read the page itself instead

    refusal = services.robots.check(target.url)
    if refusal and not ats_fallback:
        return finish(outcome="blocked", reason=refusal)
    if refusal:
        # The page itself is never fetched. Where the company has a board on a
        # known ATS, its listings are read there instead, and the result says so.
        found = ats.find_board(
            ats.board_candidates(target.domain, target.name), services.http, wait=services.throttle.wait
        )
        if not found:
            return finish(outcome="blocked", reason=refusal)
        board, listings = found
        return finish(
            outcome="ok",
            reason=f"{refusal}_ats_fallback",
            method=f"ats_api:{board.vendor}",
            ats=board,
            listings=listings,
            listing_count=len(listings),
        )

    services.throttle.wait(urlsplit(target.url).netloc)
    try:
        page = render(services.browser, target.url)
    except RenderError as error:
        return finish(outcome="inaccessible", reason=error.reason)

    seen = {"final_url": page.final_url, "http_status": page.status, "content_hash": page.content_hash}
    if page.looks_like_challenge:
        return finish(outcome="inaccessible", reason="bot_challenge", **seen)
    if page.status and page.status >= 400:
        return finish(outcome="inaccessible", reason=f"http_{page.status}", **seen)

    board = ats.detect(page.urls)
    fallback = None
    if board and ats.on_company_host(board) and services.robots.check(ats.api_url(board)):
        fallback = f"ats_api_blocked:{board.vendor}"
    elif board:
        try:
            listings = _fetch_board(board, services)
            return finish(
                outcome="ok",
                method=f"ats_api:{board.vendor}",
                ats=board,
                listings=listings,
                listing_count=len(listings),
                **seen,
            )
        except (httpx2.HTTPError, ValueError, KeyError, TypeError):
            fallback = f"ats_api_failed:{board.vendor}"

    try:
        extraction, usage = services.extractor.extract(page)
    except ExtractionFailed as error:
        return finish(outcome="error", reason=error.reason, method="render+llm", ats=board, llm=error.usage, **seen)

    listings = [
        Listing(
            title=item.title,
            location=item.location,
            url=link_url(page, item.link),
            work_mode=item.work_mode,
            department=item.department,
            employment_type=item.employment_type,
        )
        for item in extraction.listings
    ]
    return finish(
        outcome="ok",
        reason=fallback or (None if extraction.shows_job_listings else "not_a_listings_page"),
        method="render+llm",
        ats=board,
        listings=listings,
        listing_count=len(listings),
        stated_total=extraction.stated_total,
        explicit_no_openings=extraction.explicit_no_openings,
        listings_incomplete=extraction.listings_incomplete,
        many_employers=extraction.many_employers,
        many_employers_kind=extraction.many_employers_kind if extraction.many_employers else None,
        single_job_posting=extraction.single_job_posting,
        next_page_url=link_url(page, extraction.next_page),
        input_truncated=input_truncated(page),
        notes=extraction.notes,
        llm=usage,
        **seen,
    )


def _fetch_board(board, services: Services) -> list[Listing]:
    """Every listing on a known board, through its API, with requests spaced like any other."""

    def space_out() -> None:
        services.throttle.wait(ats.api_host(board))

    space_out()
    return ats.fetch_listings(board, services.http, pause=space_out)


def read_all(
    target: Target, services: Services, *, ats_fallback: bool = True, max_pages: int | None = None
) -> tuple[list[PageResult], list[Listing], bool]:
    """Read a page and every next page of its list, up to `max_pages`.

    Returns a check per page read, the listings across them, and whether the
    whole list was read: through an ATS API; up to the total the page states;
    or to a last page that neither links further nor says it shows only part.
    One job's own posting is never a whole list.
    """
    max_pages = max_pages or MAX_PAGES
    result, _ = check_page(target, services, ats_fallback=ats_fallback)
    checks = [result]
    if result.outcome != "ok":
        return checks, [], False

    listings = list(result.listings)
    seen = {_listing_key(listing) for listing in listings}
    visited = {_url_key(result.final_url or result.url)}
    while (next_url := checks[-1].next_page_url) and len(checks) < max_pages:
        if _url_key(next_url) in visited:
            break
        visited.add(_url_key(next_url))
        page_result, _ = check_page(target.model_copy(update={"url": next_url}), services, ats_fallback=False)
        checks.append(page_result)
        if page_result.outcome != "ok":
            break
        fresh = [listing for listing in page_result.listings if _listing_key(listing) not in seen]
        if not fresh:
            break  # a "next" page with nothing new: stop rather than go round
        listings += fresh
        seen |= {_listing_key(listing) for listing in fresh}
    return checks, listings, _whole_list(checks, listings)


def _whole_list(checks: list[PageResult], listings: list[Listing]) -> bool:
    first, last = checks[0], checks[-1]
    if last.outcome != "ok" or any(check.single_job_posting for check in checks):
        return False
    if (first.method or "").startswith("ats_api"):
        return True
    if first.stated_total is not None:
        return len(listings) >= first.stated_total
    return not last.listings_incomplete and not last.next_page_url


def _listing_key(listing: Listing) -> tuple:
    return (listing.url,) if listing.url else (listing.title.strip().lower(), (listing.location or "").strip().lower())


def _url_key(url: str) -> str:
    return url.split("#", 1)[0].rstrip("/").lower()
