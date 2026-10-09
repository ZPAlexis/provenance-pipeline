"""Checking one tracked role now: its own page first, then the company's watched page.

The role's own page at the employer answers fastest. On a known ATS the board's
API says whether the role is listed (free, and the whole list, so it settles the
answer either way). On the company's own site, a page that is clearly up (it
loads, shows the role, and does not say it is closed) is enough to call the role
still listed; nothing is read by the LLM.

A page that is gone, moved, closed, or unclear is never the last word: the
company's watched page is read for that role or a close one, and "no longer
listed" still needs the whole list there. A role found again under a new link is
still listed, and the verdict carries the new link.

A role added without a title (`title_from_page`) is named by what is read: on an
ATS, the board's own listing for its link, free; on the company's own site, the
page's heading when it plainly names a role (titles.heading_title), and only
when it does not, one read by the LLM. The verdict's listing carries the name.
"""

import re
import time
from datetime import UTC, datetime
from urllib.parse import urlsplit

import httpx2

from verifier import ats
from verifier.contract import (
    AtsBoard,
    Listing,
    LlmUsage,
    MatchTarget,
    PageResult,
    PostingVerdict,
    VerificationResult,
    VerifyTarget,
)
from verifier.errors import ExtractionFailed
from verifier.links import same_job
from verifier.match import Matcher
from verifier.pipeline import Services, board_read
from verifier.render import RenderedPage, RenderError, render
from verifier.titles import FILLER_WORDS, REGION_WORDS, SENIORITY_WORDS, heading_title, title_words
from verifier.verify import verify_company

# Wording a job page uses once a role is closed: English, Portuguese, Spanish.
CLOSED = re.compile(
    r"no longer (accepting applications|available|open)"
    # "has been filled", never "is filled": open roles say they run "until the position is filled".
    r"|(position|job|role|vacancy|opening|posting) (has been (filled|closed)|is (now )?closed|has expired)"
    r"|(job|posting|listing) (has )?expired"
    r"|(vaga|oportunidade|posi[cç][aã]o) (foi )?(encerrada|fechada|preenchida|expirada)"
    r"|vaga (indispon[ií]vel|n[aã]o est[aá] mais dispon[ií]vel)"
    r"|inscri[cç][oõ]es encerradas"
    r"|(vacante|oferta|puesto|empleo) (cerrad[ao]|expirad[ao]|ya no est[aá] disponible|ha (expirado|caducado))",
    re.IGNORECASE,
)


def check_posting(target: VerifyTarget, services: Services, matcher: Matcher) -> VerificationResult:
    """One tracked role: `target` is its company's watched page with that posting alone."""
    if len(target.postings) != 1:
        raise ValueError("a check is of exactly one posting")
    started = time.monotonic()
    posting = target.postings[0]
    evidence: list[PageResult] = []

    def elapsed() -> int:
        return int((time.monotonic() - started) * 1000)

    if not posting.url:
        why = "is not on record"
    elif board := ats.detect([posting.url]):
        settled, check, why = _on_board(target, board, services, matcher)
        if settled:
            return settled.model_copy(update={"duration_ms": elapsed()})
        evidence.append(check)
    else:
        check, why, named = _own_page(target, services)
        evidence.append(check)
        if why is None:
            shown = f'names the role "{named[0].title}", {named[1]}' if named else "shows the role"
            verdict = PostingVerdict(
                posting_id=posting.id,
                verdict="verified_live",
                method="posting_page",
                listing=named[0] if named else Listing(title=posting.title, url=posting.url),
                reasoning=f"Its own page is up and {shown} ({posting.url}).",
            )
            return VerificationResult(
                target_id=target.id,
                url=target.url,
                outcome="ok",
                checks=evidence,
                verdicts=[verdict],
                duration_ms=elapsed(),
            )

    # The company's watched page decides, the role's own page kept as evidence.
    result = verify_company(target, services, matcher)
    lead = f"The role's own page {why}, so its company's careers page was checked."
    verdicts = [verdict.model_copy(update={"reasoning": f"{lead} {verdict.reasoning}"}) for verdict in result.verdicts]
    return result.model_copy(
        update={"checks": result.checks + evidence, "verdicts": verdicts, "duration_ms": elapsed()}
    )


def _on_board(
    target: VerifyTarget, board: AtsBoard, services: Services, matcher: Matcher
) -> tuple[VerificationResult | None, PageResult, str]:
    """The role's own address is on a known board: its whole list, through the API, settles the answer.

    Returns the result when it does; otherwise the board's check, kept as evidence, and why it did not.
    """
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    started = time.monotonic()

    def check(**fields) -> PageResult:
        return PageResult(
            target_id=target.id,
            url=ats.board_url(board),
            checked_at=checked_at,
            duration_ms=int((time.monotonic() - started) * 1000),
            **({"ats": board} | fields),
        )

    if ats.on_company_host(board) and (refusal := services.robots.check(ats.api_url(board))):
        return None, check(outcome="blocked", reason=refusal), f"is on a {board.vendor} board robots.txt keeps us off"
    try:
        read = check(**board_read(board, services))
    except (httpx2.HTTPError, ValueError, KeyError, TypeError):
        return (
            None,
            check(outcome="error", reason="board_unreadable"),
            f"is on a {board.vendor} board that could not be read",
        )
    if not read.listings:
        return None, read, f"is on a {board.vendor} board that lists nothing"

    whole = not read.listings_incomplete
    match = matcher.match(
        MatchTarget(id=target.id, label=target.label, complete=whole, listings=read.listings, postings=target.postings)
    )
    if match.verdicts[0].verdict is None:
        return None, read, f"is on a {board.vendor} board read only in part, which does not list it"
    result = VerificationResult(
        target_id=target.id,
        url=target.url,
        outcome="ok",
        complete=whole,
        listing_count=len(read.listings),
        checks=[read],
        verdicts=match.verdicts,
        match_llm=match.llm,
    )
    return result, read, ""


def _own_page(target: VerifyTarget, services: Services) -> tuple[PageResult, str | None, tuple[Listing, str] | None]:
    """The role's own page on the company's site, loaded; read by the LLM only to name a role added without a title.

    Returns the check, why the page is not clearly up (None when it is), and, for a role added
    without a title, the listing its page names and how it was named.
    """
    posting = target.postings[0]
    url = posting.url
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    started = time.monotonic()

    def finish(why: str | None, named: tuple[Listing, str] | None = None, **fields):
        up = f'is up and names the role "{named[0].title}", {named[1]}' if named else "is up and shows the role"
        result = PageResult(
            target_id=target.id,
            url=url,
            checked_at=checked_at,
            duration_ms=int((time.monotonic() - started) * 1000),
            notes=f"The role's own page {why or up}.",
            **fields,
        )
        return result, why, named

    if refusal := services.robots.check(url):
        return finish("is off limits by robots.txt", outcome="blocked", reason=refusal)
    services.throttle.wait(urlsplit(url).netloc)
    try:
        page = render(services.browser, url)
    except RenderError as error:
        return finish(f"could not be loaded ({error.reason})", outcome="inaccessible", reason=error.reason)

    seen = {"final_url": page.final_url, "http_status": page.status, "content_hash": page.content_hash}
    if page.looks_like_challenge:
        return finish("showed a bot challenge", outcome="inaccessible", reason="bot_challenge", **seen)
    if page.status and page.status >= 400:
        return finish(f"is gone (HTTP {page.status})", outcome="inaccessible", reason=f"http_{page.status}", **seen)
    if not same_job(url, page.final_url):
        return finish(f"now leads to {page.final_url}", outcome="ok", method="render", reason="redirected", **seen)
    if CLOSED.search(page.text):
        return finish("says the role is closed", outcome="ok", method="render", reason="says_closed", **seen)
    if posting.title_from_page:
        listing, how, usage = _name(page, target, services)
        method = "render+llm" if usage else "render"
        if listing is None:
            why = f"names no role plainly ({how})"
            return finish(why, outcome="ok", method=method, reason="role_not_named", llm=usage, **seen)
        return finish(None, (listing, how), outcome="ok", method=method, llm=usage, **seen)
    if not _shows(posting.title, page.text):
        return finish("does not show the role", outcome="ok", method="render", reason="role_not_shown", **seen)
    return finish(None, outcome="ok", method="render", **seen)


def _name(page: RenderedPage, target: VerifyTarget, services: Services) -> tuple[Listing | None, str, LlmUsage | None]:
    """What a role's own page names it: its heading, when that plainly names a role; else the LLM's read of the page."""
    url = target.postings[0].url
    if title := heading_title([page.heading, page.title], target.name or target.label):
        return Listing(title=title, url=url), "as its heading names it", None
    try:
        extraction, usage = services.extractor.extract(page)
    except ExtractionFailed as error:
        return None, f"the LLM could not read it: {error.reason}", error.usage
    if not extraction.listings:
        return None, "its heading is unclear, and the LLM found no role on it", usage
    found = extraction.listings[0]
    listing = Listing(
        title=found.title,
        location=found.location,
        url=url,
        work_mode=found.work_mode,
        department=found.department,
        employment_type=found.employment_type,
    )
    return listing, "as the LLM read it, its heading being unclear", usage


def _shows(title: str, text: str) -> bool:
    """Whether a page's text names the role: every word of its title but seniority, region, and filler."""
    wanted = set(title_words(title)) - SENIORITY_WORDS - REGION_WORDS - FILLER_WORDS
    return bool(wanted) and wanted <= set(title_words(text))
