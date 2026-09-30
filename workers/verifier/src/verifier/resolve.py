"""Finding a company's careers page: cheapest, most certain step first.

1. imported       the page already on record, if it still lists jobs
2. path_probe     common careers paths on the company's own domain
3. homepage_link  careers links on the homepage: same site, or a known ATS
4. ats_guess      a Greenhouse, Lever, or Ashby board guessed from the name
5. llm_link       the LLM picks the careers link from the homepage's links

A page counts as found only when a check reads listings off it, or reads that
it has none, and they are the company's own, not a job board's many employers.
A careers landing page that only links to its jobs, or a page that shows only
some of them, is followed one link further (page_link), to the jobs page or the
fuller board, at the confidence of the page that linked to it.

Confidence says how much a human needs to look: a page on the company's own
site, or one its own pages link to, is high; a guessed board whose vendor
records the same company name is medium; an unconfirmed guess or an LLM pick is
low, and comes back as a candidate for a human to confirm, never as the page to
watch. Every check made along the way comes back with the result, including
what it cost, whatever the outcome.
"""

import re
import time
from datetime import UTC, datetime
from typing import Protocol
from urllib.parse import urlsplit

import httpx2

from verifier import ats
from verifier.config import USER_AGENT
from verifier.contract import (
    AtsBoard,
    Listing,
    LlmUsage,
    PageResult,
    ResolutionResult,
    ResolutionStep,
    ResolveTarget,
    Target,
)
from verifier.extract import CreditExhausted, ExtractionFailed, LinkChoice, LlmConfigError, link_url
from verifier.pipeline import Services, check_page, read_homepage
from verifier.render import RenderedPage

COMMON_PATHS = ("/careers", "/jobs", "/about/careers", "/company/careers")

# Link text or URL that points at jobs, in English, Portuguese, and Spanish.
CAREERS_WORDS = re.compile(
    r"career|jobs?\b|join(?:us|\b)|hiring|open (?:roles|positions)|openings|work (?:with|for) us|"
    r"vagas|carreira|trabalhe|empleo|trabaja|[uú]nete",
    re.IGNORECASE,
)
MAX_HOMEPAGE_LINKS = 3

# One level beyond a careers page, the link text alone must say it leads to jobs:
# a careers page also links to every single role, and those URLs say "job" too.
LISTING_WORDS = re.compile(
    r"career|jobs?\b|positions|openings|opportunit|vacanc|roles\b|vagas|oportunidades|empleos?\b|hiring",
    re.IGNORECASE,
)
MAX_DEEPER_LINKS = 2
# Links on a careers page that say "jobs" but never lead to the list of them.
NOT_LISTINGS = re.compile(
    r"saved|alert|log ?in|sign ?(?:in|up)|talent (?:community|network|pool)|subscribe", re.IGNORECASE
)
# Sites a careers page links to that are never its own board.
NOT_A_BOARD = (
    "linkedin.com",
    "indeed.com",
    "glassdoor.com",
    "facebook.com",
    "instagram.com",
    "x.com",
    "twitter.com",
    "youtube.com",
    "wellfound.com",
    "angel.co",
    "builtin.com",
    "google.com",
)

# Pages checked for listings per company, beyond the homepage. Each check can
# cost an extraction, so this bounds what one company can cost.
MAX_CHECKS = 6


class PageReader(Protocol):
    """What resolution needs from the outside world; ServicesReader is the real one."""

    def answers(self, url: str) -> str | None: ...
    def check(
        self, target: ResolveTarget, url: str, step: ResolutionStep
    ) -> tuple[PageResult, RenderedPage | None]: ...
    def homepage(self, target: ResolveTarget, url: str) -> tuple[PageResult, RenderedPage | None]: ...
    def guess_board(self, target: ResolveTarget) -> tuple[AtsBoard, list[Listing]] | None: ...
    def board_confirms(self, board: AtsBoard, target: ResolveTarget) -> bool: ...


class LinkPicker(Protocol):
    def pick(self, page: RenderedPage) -> tuple[LinkChoice, LlmUsage]: ...


class Resolver:
    def __init__(
        self,
        reader: PageReader,
        link_picker: LinkPicker | None = None,
        scheme: str = "https",
        max_checks: int = MAX_CHECKS,
    ):
        self.reader = reader
        self.link_picker = link_picker
        self.scheme = scheme
        self.max_checks = max_checks

    def resolve(self, target: ResolveTarget) -> ResolutionResult:
        attempt = _Attempt(self, target)
        try:
            return attempt.run()
        except (CreditExhausted, LlmConfigError):
            raise  # the run stops; Rails records what finished
        except Exception as error:  # one company's surprise keeps the checks made, and their cost
            return attempt.finish(outcome="error", reason=f"unexpected:{type(error).__name__}")


class _Attempt:
    """One company's walk down the ladder. Each step returns a result when it ends the walk."""

    def __init__(self, resolver: Resolver, target: ResolveTarget):
        self.resolver = resolver
        self.reader = resolver.reader
        self.target = target
        self.checks: list[PageResult] = []
        self.pages_checked = 0
        self.seen: set[str] = set()
        self.started = time.monotonic()

    def run(self) -> ResolutionResult:
        target = self.target
        if target.known_url and (found := self.try_page(target.known_url, "imported", confidence="high")):
            return found
        if not target.domain:
            return self.finish(outcome="failed", failure="no_domain")

        root = f"{self.resolver.scheme}://{target.domain}"
        for path in COMMON_PATHS:
            url = self.reader.answers(root + path)
            if url and (found := self.try_page(url, "path_probe", confidence="high")):
                return found

        home, page = self.reader.homepage(target, root + "/")
        self.checks.append(home)
        home_index = len(self.checks) - 1
        for text, url in careers_links(page, target.domain, from_homepage=True) if page else []:
            evidence = f'The homepage links to it as "{text}".'
            if found := self.try_page(url, "homepage_link", confidence="high", evidence=evidence):
                return found

        if found := self.try_board_guess():
            return found
        if page and self.resolver.link_picker and (found := self.try_link_pick(page, home_index)):
            return found

        return self.finish(outcome="failed", failure=self.failure(home))

    def failure(self, home: PageResult) -> str:
        """Why nothing was found. A careers page whose jobs robots.txt keeps us off is blocked, not missing."""
        if home.outcome in ("blocked", "inaccessible"):
            return home.outcome
        if any(check.outcome == "blocked" for check in self.checks if check.step != "homepage"):
            return "blocked"
        return "not_found"

    def try_page(self, url, step, *, confidence, outcome="resolved", evidence=None, depth=0) -> ResolutionResult | None:
        checked = self.check(url, step)
        if not checked:
            return None
        result, page = checked
        yields = _yields(result)
        if (
            depth == 0
            and page
            and result.outcome == "ok"
            and not result.many_employers
            and (not yields or _partial(result))
        ):
            # A landing page, or a partial one: the jobs, or all of them, are one link further.
            for text, link in careers_links(page, self.target.domain, from_homepage=False)[:MAX_DEEPER_LINKS]:
                followed = f'Followed the link "{text}" from {result.final_url or url}.'
                found = self.try_page(
                    link,
                    "page_link",
                    confidence=confidence,
                    outcome=outcome,
                    evidence=" ".join(filter(None, [evidence, followed])),
                    depth=1,
                )
                if found and (not yields or _found_count(found) > (result.listing_count or 0)):
                    return found
        if not yields:
            return None
        if _partial(result):
            # We could not see the whole list: a person confirms it before it is watched.
            shown = f"{result.listing_count} of {result.stated_total}" if result.stated_total else "only some"
            partial = f"It shows {shown} of its openings, and no fuller page was found."
            outcome, confidence, evidence = "candidate", "low", " ".join(filter(None, [evidence, partial]))
        return self.finish(
            outcome=outcome,
            careers_page_url=result.final_url or result.url,
            ats=result.ats,
            method=step,
            confidence=confidence,
            evidence=evidence,
        )

    def check(self, url, step) -> tuple[PageResult, RenderedPage | None] | None:
        """One page checked for listings, within the per-company cap, never the same page twice."""
        if _key(url) in self.seen or self.pages_checked >= self.resolver.max_checks:
            return None
        self.pages_checked += 1
        result, page = self.reader.check(self.target, url, step)
        self.checks.append(result)
        self.seen |= {_key(url), _key(result.final_url or url)}
        return result, page

    def try_board_guess(self) -> ResolutionResult | None:
        found = self.reader.guess_board(self.target)
        if not found:
            return None
        board, listings = found
        url = ats.board_url(board)
        self.checks.append(
            PageResult(
                target_id=self.target.id,
                url=url,
                step="ats_guess",
                checked_at=datetime.now(UTC).isoformat(timespec="seconds"),
                outcome="ok",
                method=f"ats_api:{board.vendor}",
                ats=board,
                listings=listings,
                listing_count=len(listings),
            )
        )
        confirmed = self.reader.board_confirms(board, self.target)
        guessed = f"A {board.vendor} board named {board.board!r}, guessed from the company's name or domain"
        return self.finish(
            outcome="resolved" if confirmed else "candidate",
            careers_page_url=url,
            ats=board,
            method="ats_guess",
            confidence="medium" if confirmed else "low",
            evidence=f"{guessed}, records the same company name."
            if confirmed
            else f"{guessed}; nothing confirms it is this company's.",
        )

    def try_link_pick(self, page: RenderedPage, home_index: int) -> ResolutionResult | None:
        # The pick's usage goes on the homepage check: that is the page it read.
        home = self.checks[home_index]
        try:
            choice, usage = self.resolver.link_picker.pick(page)
        except ExtractionFailed as error:
            self.checks[home_index] = home.model_copy(
                update={"llm": error.usage, "notes": f"link pick: {error.reason}"}
            )
            return None
        self.checks[home_index] = home.model_copy(update={"llm": usage, "notes": f"link pick: {choice.reason}"})
        url = link_url(page, choice.link)
        if not url:
            return None
        text = page.links[choice.link - 1][0] or "(no text)"
        evidence = f'The LLM picked the homepage link "{text}": {choice.reason}'
        return self.try_page(url, "llm_link", confidence="low", outcome="candidate", evidence=evidence)

    def finish(self, **fields) -> ResolutionResult:
        return ResolutionResult(
            target_id=self.target.id,
            checks=self.checks,
            duration_ms=int((time.monotonic() - self.started) * 1000),
            **fields,
        )


def careers_links(page: RenderedPage, domain: str, *, from_homepage: bool) -> list[tuple[str, str]]:
    """Up to MAX_HOMEPAGE_LINKS links on a page that look like the way to jobs.

    A link into a known ATS board counts on its own, and leads to the board
    itself rather than to one role on it. From the homepage, anything else must
    be on the company's own site and say careers, jobs, or the like, in its text
    or its address. From a careers page, the link text must say so, and the
    link may lead off the company's site, to the board its jobs live on.
    """
    site = domain.lower().removeprefix("www.")
    chosen: dict[str, tuple[str, str]] = {}
    for text, url in page.links:
        parts = urlsplit(url)
        host = parts.netloc.lower()
        if parts.scheme not in ("http", "https") or (host.removeprefix("www.") == site and parts.path in ("", "/")):
            continue  # not a web page, or the company's homepage itself
        if board := ats.detect([url]):
            url = ats.board_url(board)
        elif from_homepage:
            own = host == site or host.endswith("." + site)
            if not (own and (CAREERS_WORDS.search(text or "") or CAREERS_WORDS.search(parts.path))):
                continue
        elif (
            not LISTING_WORDS.search(text or "")
            or NOT_LISTINGS.search(text or "")
            or any(host == other or host.endswith("." + other) for other in NOT_A_BOARD)
        ):
            continue
        chosen.setdefault(_key(url), (text, url))
        if len(chosen) == MAX_HOMEPAGE_LINKS:
            break
    return list(chosen.values())


def _yields(result: PageResult) -> bool:
    """A careers page: its own listings were read off it, or it says it has none."""
    return (
        result.outcome == "ok"
        and not result.many_employers
        and (bool(result.listing_count) or result.explicit_no_openings)
    )


def _partial(result: PageResult) -> bool:
    """Whether a page shows only some of its openings. A total the page itself states settles it."""
    if result.stated_total is not None:
        return (result.listing_count or 0) < result.stated_total
    return result.listings_incomplete


def _found_count(found: ResolutionResult) -> int:
    """How many listings the page a result settled on showed."""
    urls = (found.careers_page_url,)
    page = next((check for check in reversed(found.checks) if check.final_url in urls or check.url in urls), None)
    return (page.listing_count or 0) if page else 0


def _key(url: str) -> str:
    """URLs that differ only by a fragment or a trailing slash are one page."""
    return url.split("#", 1)[0].rstrip("/").lower()


class ServicesReader:
    """Resolution's reads, through the same robots, politeness, render, and extraction as verification."""

    def __init__(self, services: Services):
        self.services = services

    def answers(self, url: str) -> str | None:
        """Where a plain request for `url` ends up, if at a page. Never rendered, never read by the LLM."""
        if self.services.robots.check(url):
            return None
        self.services.throttle.wait(urlsplit(url).netloc)
        try:
            response = self.services.http.get(url, headers={"User-Agent": USER_AGENT}, follow_redirects=True)
        except httpx2.HTTPError:
            return None
        final = str(response.url)
        # A site that sends unknown paths to its homepage has no page there.
        if response.status_code >= 400 or urlsplit(final).path in ("", "/"):
            return None
        return final

    def check(self, target: ResolveTarget, url: str, step: ResolutionStep) -> tuple[PageResult, RenderedPage | None]:
        page_target = Target(id=target.id, url=url, label=target.label, domain=target.domain, name=target.name)
        result, page = check_page(page_target, self.services, ats_fallback=False)
        return result.model_copy(update={"step": step}), page

    def homepage(self, target: ResolveTarget, url: str) -> tuple[PageResult, RenderedPage | None]:
        return read_homepage(target.id, url, self.services)

    def guess_board(self, target: ResolveTarget) -> tuple[AtsBoard, list[Listing]] | None:
        candidates = ats.board_candidates(target.domain, target.name)
        return ats.find_board(candidates, self.services.http, wait=self.services.throttle.wait)

    def board_confirms(self, board: AtsBoard, target: ResolveTarget) -> bool:
        self.services.throttle.wait(ats.api_host(board))
        return ats.names_match(ats.board_name(board, self.services.http), target.name)
