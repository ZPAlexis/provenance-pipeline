"""Verifying a company's tracked postings against its watched careers page.

The page is read in full where it can be (every next page of its list, "load
more" clicked, a known board through its API), then each posting is matched
against everything read. Verdicts follow the evidence (see match.py): a page
the site refuses us, or that robots.txt keeps us off, makes every posting
inaccessible; a failure of our own writes no verdicts at all.

No guessing here: a watched page robots.txt keeps us off is not swapped for a
board guessed from the company's name. Resolution decides the page; this only
reads it.

Two ways a run pays less. A company whose own board was confirmed to list the
same roles as its page (see boards.py) is read through that board's API; the
page stays the one on record, and is read again if the board fails or lists
nothing. And a page whose role links are unchanged since the last run reuses the
listings read then (see pipeline.py), up to a full read every 14 days.
"""

import time

from verifier.contract import MatchTarget, PostingVerdict, Target, VerificationResult, VerifyTarget
from verifier.match import Matcher
from verifier.pipeline import Services, read_all, read_board


def verify_company(target: VerifyTarget, services: Services, matcher: Matcher) -> VerificationResult:
    started = time.monotonic()
    page_target = Target(id=target.id, url=target.url, label=target.label, domain=target.domain, name=target.name)
    checks, listings, complete = _read(page_target, target, services)
    first = checks[0]

    def finish(**fields) -> VerificationResult:
        elapsed = int((time.monotonic() - started) * 1000)
        return VerificationResult(target_id=target.id, url=target.url, checks=checks, duration_ms=elapsed, **fields)

    if first.outcome in ("blocked", "inaccessible"):
        why = f"The watched page could not be read ({first.reason})."
        verdicts = [
            PostingVerdict(posting_id=posting.id, verdict="inaccessible", method="none", reasoning=why)
            for posting in target.postings
        ]
        return finish(outcome="inaccessible", reason=first.reason, verdicts=verdicts)
    if first.outcome == "error":
        return finish(outcome="error", reason=first.reason)

    match = matcher.match(
        MatchTarget(id=target.id, label=target.label, complete=complete, listings=listings, postings=target.postings)
    )
    reason = "single_job_posting" if any(check.single_job_posting for check in checks) else match.reason
    return finish(
        outcome="ok",
        reason=reason,
        complete=complete,
        listing_count=len(listings),
        verdicts=match.verdicts,
        match_llm=match.llm,
    )


def _read(page_target: Target, target: VerifyTarget, services: Services):
    if target.board:
        via_board = read_board(page_target, target.board, services)
        if via_board.outcome == "ok":
            return [via_board], via_board.listings, not via_board.listings_incomplete  # the vendor's own list
    checks, listings, complete = read_all(page_target, services, ats_fallback=False, previous=target.previous)
    if target.board:
        why = (
            f"The company's confirmed board ({target.board.vendor}/{target.board.board}) could not be used "
            f"({via_board.reason}), so the page was read instead."
        )
        checks[0] = checks[0].model_copy(update={"notes": " ".join(filter(None, [why, checks[0].notes]))})
    return checks, listings, complete
