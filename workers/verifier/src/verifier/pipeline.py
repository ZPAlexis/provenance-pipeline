"""Checking one careers page, end to end: robots.txt, render, known ATS, extraction.

Cheapest path first. A page on (or embedding) a known ATS is read through the
vendor's public API; everything else is rendered and read by the LLM. Every
outcome, including refusals and failures, comes back as a PageResult, so a
page that could not be read is never mistaken for one with no openings.
"""

import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx2
from playwright.sync_api import Browser

from verifier import ats
from verifier.config import LISTINGS_MAX_AGE_DAYS, MAX_PAGES
from verifier.contract import AtsBoard, Listing, PageResult, PreviousRead, Target
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
    target: Target, services: Services, *, ats_fallback: bool = True, previous: PreviousRead | None = None
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

    # The page links to exactly the role pages it did last time: the same roles, so the
    # listings read then are reused and the LLM is not paid to read them again.
    if previous and (reused := _reused(previous, page)):
        return finish(**reused, **seen)

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
        listings_read_at=checked_at,
        notes=extraction.notes,
        llm=usage,
        **seen,
    )


def read_board(target: Target, board: AtsBoard, services: Services) -> PageResult:
    """A company's confirmed board, read through its API in place of its watched page.

    Comes back ok only with listings: a board that cannot be read, or that lists
    nothing, is a reason to read the page itself, never evidence that every role closed.
    """
    started = time.monotonic()
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")

    def finish(**fields) -> PageResult:
        elapsed = int((time.monotonic() - started) * 1000)
        return PageResult(
            target_id=target.id,
            url=ats.board_url(board),
            checked_at=checked_at,
            ats=board,
            duration_ms=elapsed,
            **fields,
        )

    if ats.on_company_host(board) and (refusal := services.robots.check(ats.api_url(board))):
        return finish(outcome="blocked", reason=refusal)
    try:
        listings = _fetch_board(board, services)
    except (httpx2.HTTPError, ValueError, KeyError, TypeError):
        return finish(outcome="error", reason="board_unreadable")
    if not listings:
        return finish(outcome="error", reason="board_empty")
    return finish(
        outcome="ok",
        method=f"ats_api:{board.vendor}",
        listings=listings,
        listing_count=len(listings),
        notes=f"Read through the company's confirmed {board.vendor} board, in place of {target.url}.",
    )


def _fetch_board(board, services: Services) -> list[Listing]:
    """Every listing on a known board, through its API, with requests spaced like any other."""

    def space_out() -> None:
        services.throttle.wait(ats.api_host(board))

    space_out()
    return ats.fetch_listings(board, services.http, pause=space_out)


def read_all(
    target: Target,
    services: Services,
    *,
    ats_fallback: bool = True,
    max_pages: int | None = None,
    previous: list[PreviousRead] | None = None,
) -> tuple[list[PageResult], list[Listing], bool]:
    """Read a page and every next page of its list, up to `max_pages`.

    Returns a check per page read, the listings across them, and whether the
    whole list was read: through an ATS API; up to the total the page states;
    or to a last page that neither links further nor says it shows only part.
    One job's own posting is never a whole list.

    `previous` holds what each page showed at the last run. Every page is judged
    on its own: one whose role links are unchanged reuses its listings.
    """
    max_pages = max_pages or MAX_PAGES
    previous = _by_url(previous or [])
    result, _ = check_page(target, services, ats_fallback=ats_fallback, previous=previous.get(_url_key(target.url)))
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
        page_result, _ = check_page(
            target.model_copy(update={"url": next_url}),
            services,
            ats_fallback=False,
            previous=previous.get(_url_key(next_url)),
        )
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
        return True  # the vendor's own list, empty or not
    if not listings and not any(check.explicit_no_openings for check in checks):
        # A rendered page that showed no roles and did not say it has none (a
        # maintenance screen, an app that never loaded, a landing page) is not
        # evidence that any role is closed.
        return False
    if first.stated_total is not None:
        return len(listings) >= first.stated_total
    return not last.listings_incomplete and not last.next_page_url


def _listing_key(listing: Listing) -> tuple:
    return (listing.url,) if listing.url else (listing.title.strip().lower(), (listing.location or "").strip().lower())


def _url_key(url: str) -> str:
    return url.split("#", 1)[0].rstrip("/").lower()


def _by_url(reads: list[PreviousRead]) -> dict[str, PreviousRead]:
    """Previous reads by the address asked for and the one it ended at."""
    by_url: dict[str, PreviousRead] = {}
    for read in reads:
        for url in (read.url, read.final_url):
            if url:
                by_url.setdefault(_url_key(url), read)
    return by_url


# Query parameters that track a visit rather than name a role.
_TRACKING = ("utm_", "gh_src", "trk")


def _reused(previous: PreviousRead, page: RenderedPage) -> dict | None:
    """The previous read's listings, when the page still shows the same roles and they are fresh enough."""
    read_at = datetime.fromisoformat(previous.listings_read_at)
    if read_at.tzinfo is None:
        read_at = read_at.replace(tzinfo=UTC)
    if datetime.now(UTC) - read_at > timedelta(days=LISTINGS_MAX_AGE_DAYS) or not _same_roles(previous, page):
        return None
    return {
        "outcome": "ok",
        "method": "reused",
        "listings": previous.listings,
        "listing_count": previous.listing_count,
        "stated_total": previous.stated_total,
        "explicit_no_openings": previous.explicit_no_openings,
        "listings_incomplete": previous.listings_incomplete,
        "many_employers": previous.many_employers,
        "many_employers_kind": previous.many_employers_kind,
        "single_job_posting": previous.single_job_posting,
        "next_page_url": previous.next_page_url,
        "listings_read_at": previous.listings_read_at,
        "reused_from": previous.page_check_id,
        "notes": f"The page links to the same role pages as when it was read on {read_at.date()}: "
        "its listings were reused, not read again.",
    }


def _same_roles(previous: PreviousRead, page: RenderedPage) -> bool:
    """The page links to exactly the role pages it did before: none gone, none new of the same kind.

    "Of the same kind" means under the same folder as the earlier role links
    (/jobs/123 and /jobs/456). Links that do not tell the roles apart (a role
    without one, or roles sharing one) fall back to the page's whole text being
    identical.
    """
    role_links = {_link_key(listing.url) for listing in previous.listings if listing.url}
    if previous.listings and len(role_links) == len(previous.listings):
        prefixes = {_link_prefix(url) for url in role_links}
        return {_link_key(href) for _, href in page.links if _link_prefix(href) in prefixes} == role_links
    return previous.content_hash is not None and previous.content_hash == page.content_hash


def _link_prefix(url: str) -> tuple[str, str]:
    parts = urlsplit(url)
    return parts.netloc.lower().removeprefix("www."), parts.path.rstrip("/").rsplit("/", 1)[0]


def _link_key(url: str) -> str:
    parts = urlsplit(url)
    query = urlencode([(k, v) for k, v in parse_qsl(parts.query) if not k.lower().startswith(_TRACKING)])
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower().removeprefix("www."), parts.path.rstrip("/"), query, "")
    )
