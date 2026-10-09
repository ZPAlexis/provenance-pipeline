"""Titles in the same area as a search profile's, proposed by the LLM for the operator to pick from.

The profile's titles are matched word by word (profiles.py), so a role in the same
area under another name, or in another language ("Arquiteto de Soluções" for
"Solutions Architect"), never fits until its title is on the profile. One LLM call
proposes such titles, in the languages of the profile's places; the operator picks
which to add. Nothing is added on its own, and matching stays word by word.
"""

import time
from typing import Protocol

from verifier.contract import LlmUsage, ProposedTitle, RelatedResult, RelateTarget
from verifier.errors import ExtractionFailed
from verifier.extract import MAX_RELATED, RelatedTitles
from verifier.titles import title_words


class Proposer(Protocol):
    def propose(self, titles: list[str], excluded: list[str], places: list[str]) -> tuple[RelatedTitles, LlmUsage]: ...


def related(target: RelateTarget, proposer: Proposer) -> RelatedResult:
    """The titles proposed for one profile: never one of its own, never twice, at most MAX_RELATED."""
    started = time.monotonic()
    try:
        answer, usage = proposer.propose(target.titles, target.excluded, target.places)
    except ExtractionFailed as error:
        return RelatedResult(target_id=target.id, outcome="error", reason=error.reason, llm=error.usage)

    seen = {tuple(title_words(title)) for title in target.titles}
    proposals = []
    for proposal in answer.proposals:
        key = tuple(title_words(proposal.title))
        if not key or key in seen:
            continue
        seen.add(key)
        proposals.append(
            ProposedTitle(title=proposal.title.strip(), language=proposal.language, reason=proposal.reason)
        )
    return RelatedResult(
        target_id=target.id,
        proposals=proposals[:MAX_RELATED],
        llm=usage,
        duration_ms=int((time.monotonic() - started) * 1000),
    )
