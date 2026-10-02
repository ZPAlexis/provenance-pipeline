"""Finding a free board that lists the same roles as a page the LLM has to read.

A careers page on no known ATS is rendered and read by the LLM at every run.
Many such companies also keep a Greenhouse, Lever, or Ashby board whose API
lists the same roles for free. This guesses boards from the company's name and
domain, as resolution does, and compares each one's roles with the roles the
page showed at its last full read. Nothing here is read by the LLM.

A board is adopted on the roles alone: it lists nearly every distinct role the
page showed, by the same title, so it is never much smaller. Who owns it (the
name the vendor records, or the site its page links to) is recorded as
evidence, not required. Both ways of being wrong were measured: a board with
the company's exact name can belong to another company and share none of its
roles, and a company's own board can link to a sister domain.
"""

import time
from collections.abc import Iterable, Iterator
from typing import Protocol

from verifier.contract import AtsBoard, BoardResult, BoardTarget, Listing, ResolveTarget
from verifier.match import title_words
from verifier.resolve import board_owner

ADOPT_OVERLAP = 0.9  # share of the page's distinct roles the board must also list
# Fewer roles than this are too few to tell two companies' boards apart, and cost little to read.
MIN_ROLES = 5


class BoardReader(Protocol):
    def guess_boards(self, target: ResolveTarget) -> Iterator[tuple[AtsBoard, list[Listing]]]: ...
    def board_confirms(self, board: AtsBoard, target: ResolveTarget) -> bool: ...
    def board_links(self, board: AtsBoard) -> list[str] | None: ...


def find_board(target: BoardTarget, reader: BoardReader) -> BoardResult:
    started = time.monotonic()
    page = _titles(target.titles)

    def finish(**fields) -> BoardResult:
        elapsed = int((time.monotonic() - started) * 1000)
        return BoardResult(target_id=target.id, page_roles=len(page), duration_ms=elapsed, **fields)

    if len(page) < MIN_ROLES:
        return finish(outcome="none", reason="too_few_roles")
    company = ResolveTarget(id=target.id, label=target.name, name=target.name, domain=target.domain)
    scored = []
    for board, listings in reader.guess_boards(company):
        on_board = _titles(listing.title for listing in listings)
        scored.append((board, len(page & on_board) / len(page), len(on_board)))
    if not scored:
        return finish(outcome="none", reason="no_board_found")

    board, overlap, size = max(scored, key=lambda found: (found[1], found[2]))
    if reader.board_confirms(board, company):
        owner, host = "confirmed", None
    else:
        owner, host = board_owner(reader.board_links(board), target.domain)

    outcome, reason = ("adopted", None) if overlap >= ADOPT_OVERLAP else ("rejected", "low_overlap")
    whose = {
        ("confirmed", False): "the vendor records the same company name",
        ("confirmed", True): f"its page links to {host}, the company's own site",
        ("elsewhere", True): f"its page links to {host}, not the company's site",
        (None, False): "nothing on it names the company",
    }[(owner, host is not None)]
    evidence = (
        f"{board.vendor}/{board.board} lists {overlap:.0%} of the {len(page)} roles the page showed, "
        f"by the same title ({size} roles on the board); {whose}."
    )
    return finish(
        outcome=outcome,
        reason=reason,
        board=board,
        board_roles=size,
        overlap=round(overlap, 3),
        owner=owner,
        owner_host=host,
        evidence=evidence,
    )


def _titles(titles: Iterable[str]) -> set[tuple[str, ...]]:
    """Distinct role titles, compared as their words (case, punctuation, accents, Sr./Jr. aside)."""
    return {words for words in (tuple(title_words(title)) for title in titles) if words}
