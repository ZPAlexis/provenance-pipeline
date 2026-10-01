"""Matching tracked postings against the listings a careers page shows.

Field-neutral: it only asks whether a posting is among a page's listings, never
what kind of role anyone wants. Cheapest first:

1. exact    the same title, ignoring case, punctuation, accents, and "Sr."/"Jr."
2. variant  one title's words all within the other's ("Solutions Engineer" /
            "Senior Solutions Engineer"), when the shorter has two words or more
            and the longer adds no level of responsibility (manager, director,
            lead...): "Solutions Engineer Manager" is a different job
3. llm      for near-misses only (half the words shared or more), the LLM
            decides whether a candidate is the same opening. A "same" is not
            trusted when each title names something the other lacks ("GTM" /
            "Foundry"): that check is inconclusive instead

A title match means the role is live; the location only picks which listing is
the posting's, and a different location is noted, never held against it. A
verdict follows from the evidence: verified_live on a match; not_found only when
the whole list was read; otherwise inconclusive (no verdict), so a role on page
two is never marked closed.
"""

import re
import time
import unicodedata
from collections.abc import Callable
from typing import Protocol

from verifier.contract import Listing, LlmUsage, MatchResult, MatchTarget, PostingVerdict, TrackedPosting
from verifier.extract import ExtractionFailed, MatchDecisions

ABBREVIATIONS = {"sr": "senior", "jr": "junior"}
# Words that tell two near-miss titles apart without making them different jobs.
SENIORITY_WORDS = {"senior", "junior", "staff", "i", "ii", "iii", "iv", "1", "2", "3"}
REGION_WORDS = {
    "latam", "latin", "america", "americas", "north", "south", "emea", "apac", "amer", "europe", "eu", "uk",
    "us", "usa", "na", "global", "remote", "brazil", "brasil", "mexico", "canada", "argentina", "colombia",
}  # fmt: skip
FILLER_WORDS = {"and", "of", "the", "for", "de", "da", "do", "e", "y", "en", "to", "a", "an"}

# Words that make a title a different level of responsibility, not a variant.
LEVEL_WORDS = {
    "manager",
    "management",
    "director",
    "head",
    "vp",
    "vice",
    "president",
    "chief",
    "officer",
    "lead",
    "leader",
    "principal",
    "intern",
    "internship",
    "apprentice",
    "trainee",
    "assistant",
}
NEAR_MISS = 0.5  # share of words in common, out of the longer title's
MAX_CANDIDATES = 8  # near-miss listings shown to the LLM per posting


class Adjudicator(Protocol):
    def decide(self, cases: list["Case"], listings: list[Listing]) -> tuple[MatchDecisions, LlmUsage]: ...


def title_words(title: str | None) -> list[str]:
    text = unicodedata.normalize("NFKD", title or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    return [ABBREVIATIONS.get(word, word) for word in re.findall(r"[a-z0-9]+", text)]


def same_title(a: str, b: str) -> bool:
    return bool(title_words(a)) and title_words(a) == title_words(b)


def variant(a: str, b: str) -> bool:
    """One title's words all within the other's, when what the longer adds does not change the job's level.

    "Solutions Engineer" / "Senior Solutions Engineer, LATAM" is a variant; "Solutions
    Engineer" / "Solutions Engineer Manager" is a different job, so it goes to the LLM.
    """
    shorter, longer = sorted((set(title_words(a)), set(title_words(b))), key=len)
    return len(shorter) >= 2 and shorter <= longer and not (longer - shorter) & LEVEL_WORDS


def overlap(a: str, b: str) -> float:
    wa, wb = set(title_words(a)), set(title_words(b))
    return len(wa & wb) / max(len(wa), len(wb), 1)


class Case:
    """A posting whose title only nearly matches some listings: for the LLM to decide."""

    def __init__(self, number: int, posting: TrackedPosting, candidates: list[int]):
        self.number = number  # 1-based, as the prompt shows it
        self.posting = posting
        self.candidates = candidates  # 0-based listing indexes


class Matcher:
    def __init__(self, adjudicator: Adjudicator | None = None, clock: Callable[[], float] = time.monotonic):
        self.adjudicator = adjudicator
        self.clock = clock

    def match(self, target: MatchTarget) -> MatchResult:
        started = self.clock()
        listings = target.listings
        verdicts: dict[str, PostingVerdict] = {}
        cases: list[Case] = []

        for posting in target.postings:
            exact = [i for i, listing in enumerate(listings) if same_title(posting.title, listing.title)]
            if exact:
                verdicts[posting.id] = _live(posting, listings, exact, "exact")
                continue
            variants = [i for i, listing in enumerate(listings) if variant(posting.title, listing.title)]
            if variants:
                verdicts[posting.id] = _live(posting, listings, variants, "variant")
                continue
            near = sorted(
                (i for i, listing in enumerate(listings) if overlap(posting.title, listing.title) >= NEAR_MISS),
                key=lambda i: -overlap(posting.title, listings[i].title),
            )[:MAX_CANDIDATES]
            if near:
                cases.append(Case(len(cases) + 1, posting, near))
            else:
                verdicts[posting.id] = _unmatched(posting, target)

        usage, reason = None, None
        if cases:
            decisions, usage, reason = self._adjudicate(cases, listings)
            for case in cases:
                verdicts[case.posting.id] = _judged(case, decisions.get(case.number), listings, target, reason)

        return MatchResult(
            target_id=target.id,
            page_check_id=target.page_check_id,
            complete=target.complete,
            verdicts=[verdicts[posting.id] for posting in target.postings],
            llm=usage,
            reason=reason,
            duration_ms=int((self.clock() - started) * 1000),
        )

    def _adjudicate(
        self, cases: list[Case], listings: list[Listing]
    ) -> tuple[dict[int, tuple[int | None, str]], LlmUsage | None, str | None]:
        """Decisions by case number: (listing index or None, reason). Failures leave every case undecided."""
        if self.adjudicator is None:
            return {}, None, "near_misses_not_judged"
        try:
            result, usage = self.adjudicator.decide(cases, listings)
        except ExtractionFailed as error:
            return {}, error.usage, error.reason
        decisions = {}
        for decision in result.decisions:
            case = next((c for c in cases if c.number == decision.posting), None)
            if case is None:
                continue
            index = decision.listing - 1 if decision.listing is not None else None
            # Only one of the posting's own candidates can be its match.
            decisions[case.number] = (index if index in case.candidates else None, decision.reason)
        return decisions, usage, None


def _live(posting: TrackedPosting, listings: list[Listing], indexes: list[int], method: str) -> PostingVerdict:
    index = max(indexes, key=lambda i: _location_score(posting.location, listings[i].location))
    listing = listings[index]
    shown = f'"{listing.title}"' + (f" ({listing.location})" if listing.location else "")
    how = f', a variant of the posting\'s "{posting.title}"' if method == "variant" else ""
    return PostingVerdict(
        posting_id=posting.id,
        verdict="verified_live",
        method=method,
        listing_index=index,
        listing=listing,
        location_note=_location_note(posting, listing),
        reasoning=f"The page lists {shown}{how}.",
    )


def _unmatched(posting: TrackedPosting, target: MatchTarget, why: str | None = None) -> PostingVerdict:
    count = len(target.listings)
    if target.complete:
        verdict, text = "not_found", f'None of the {count} roles on the page is "{posting.title}".'
    else:
        verdict = None
        text = (
            f'"{posting.title}" is not among the {count} roles read, but the page shows only part of its list, '
            "so this check is inconclusive."
        )
    return PostingVerdict(
        posting_id=posting.id, verdict=verdict, method="none", reasoning=" ".join(filter(None, [text, why]))
    )


def _judged(case: Case, decision, listings: list[Listing], target: MatchTarget, failure: str | None) -> PostingVerdict:
    posting = case.posting
    closest = listings[case.candidates[0]].title
    if decision is None:
        # Never judged: no LLM in this run, or the call failed. Close is not the same, and not different either.
        return PostingVerdict(
            posting_id=posting.id,
            verdict=None,
            method="none",
            reasoning=f'"{closest}" on the page is close to "{posting.title}" but was not judged ({failure}); '
            "inconclusive.",
        )
    index, reason = decision
    if index is None:
        return _unmatched(posting, target, f'The closest, "{closest}", was judged a different role: {reason}')
    ours, theirs = (
        _distinctive(posting.title, listings[index].title),
        _distinctive(listings[index].title, posting.title),
    )
    if ours and theirs:
        # Each title names something the other doesn't ("GTM" / "Foundry"): two
        # specialties, whatever the LLM says. Not trusted either way: no verdict.
        return PostingVerdict(
            posting_id=posting.id,
            verdict=None,
            method="none",
            reasoning=f'The LLM judged "{listings[index].title}" the same role, but each title names something the '
            f"other does not ({', '.join(sorted(ours))} / {', '.join(sorted(theirs))}), so this check is "
            "inconclusive.",
        )
    verdict = _live(posting, listings, [index], "llm")
    return verdict.model_copy(update={"reasoning": f"{verdict.reasoning[:-1]}, judged the same role: {reason}"})


def _distinctive(title: str, other: str) -> set[str]:
    """Words in `title` that `other` lacks, beyond seniority, regions, and filler: what makes it a different job."""
    return set(title_words(title)) - set(title_words(other)) - SENIORITY_WORDS - REGION_WORDS - FILLER_WORDS


def _location_words(location: str | None) -> set[str]:
    return set(title_words(location)) - {"remote", "hybrid", "onsite", "office", "and", "or"}


def _location_score(posting_location: str | None, listing_location: str | None) -> float:
    a, b = _location_words(posting_location), _location_words(listing_location)
    return len(a & b) / max(len(a | b), 1)


def _location_note(posting: TrackedPosting, listing: Listing) -> str | None:
    a, b = _location_words(posting.location), _location_words(listing.location)
    if not a or not b or a & b:
        return None  # nothing to compare (e.g. only "Remote"), or they share a place
    return f"Listed for {listing.location}; the posting says {posting.location}."
