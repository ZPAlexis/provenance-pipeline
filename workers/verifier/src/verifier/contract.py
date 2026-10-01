"""The worker's input and output: the contract Rails reads and writes.

One target in, one PageResult out, as a line of JSONL. Rails is the only
consumer, and it validates every result before anything is written.
"""

from typing import Literal

from pydantic import BaseModel, Field

from verifier import RESULT_SCHEMA_VERSION

WorkMode = Literal["remote", "hybrid", "onsite", "unknown"]
EmploymentType = Literal["full_time", "part_time", "contract", "internship", "temporary", "unknown"]

# ok           the page was read and its listings extracted (possibly zero)
# blocked      we chose not to fetch it (robots.txt)
# inaccessible the site refused or failed us (HTTP error, bot challenge, timeout)
# error        our own failure (extraction or an unexpected exception)
Outcome = Literal["ok", "blocked", "inaccessible", "error"]

# Resolution: how a careers page was found, and the step a page was checked at.
# page_link: a link followed one level from a careers page that was found but did
# not list its jobs itself, or listed only some of them.
ResolutionMethod = Literal["imported", "path_probe", "homepage_link", "page_link", "ats_guess", "llm_link"]
ResolutionStep = Literal["imported", "path_probe", "homepage", "homepage_link", "page_link", "ats_guess", "llm_link"]


class Target(BaseModel):
    id: str
    url: str
    label: str | None = None  # for progress output only; never sent anywhere
    # The company's domain and name: used to find its board on a known ATS when
    # robots.txt keeps the verifier off the careers page itself.
    domain: str | None = None
    name: str | None = None


class Listing(BaseModel):
    title: str
    location: str | None = None
    url: str | None = None
    work_mode: WorkMode = "unknown"
    # Only as the page states them, for search profiles to filter on later.
    department: str | None = None
    employment_type: EmploymentType = "unknown"


class LlmUsage(BaseModel):
    model: str  # the model the API reports having served
    settings: dict = Field(default_factory=dict)  # request settings, e.g. effort
    purpose: Literal["extract", "resolve", "match"] = "extract"
    # A hash over the system prompt, output schema, and limits that produced this call.
    prompt_version: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0  # an estimate, from the published per-token prices


class AtsBoard(BaseModel):
    vendor: Literal["greenhouse", "lever", "ashby", "workday"]
    board: str  # the board's name; for Workday, "{tenant}.{wdN}/{site}"


class PageResult(BaseModel):
    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["page"] = "page"
    target_id: str
    url: str
    step: ResolutionStep | None = None  # set when the page was checked during resolution
    final_url: str | None = None
    checked_at: str  # ISO 8601, UTC
    outcome: Outcome
    reason: str | None = None  # why it is not "ok", or a note on a fallback
    method: str | None = None  # e.g. "ats_api:greenhouse", "render+llm"
    ats: AtsBoard | None = None
    listings: list[Listing] = Field(default_factory=list)
    listing_count: int | None = None  # None when nothing was extracted
    stated_total: int | None = None  # the total the page itself states, e.g. "208 jobs" on a paginated board
    explicit_no_openings: bool = False  # the page itself says there are no open roles
    listings_incomplete: bool = (
        False  # the page shows only some of its openings (pagination, "load more", a fuller board)
    )
    many_employers: bool = False  # the listings are many employers' (a job board or aggregator), not one company's
    single_job_posting: bool = False  # the page is one job's own posting, not a list of openings
    next_page_url: str | None = None  # where the list continues, when the page links to its next page
    input_truncated: bool = False  # the model saw less than the whole page
    notes: str | None = None  # the extractor's short account of what the page showed
    content_hash: str | None = None  # sha256 of the normalized page text
    http_status: int | None = None
    llm: LlmUsage | None = None
    duration_ms: int = 0


class ResolveTarget(BaseModel):
    """A company whose careers page is to be found."""

    id: str
    label: str | None = None
    domain: str | None = None
    name: str | None = None
    known_url: str | None = None  # a page already on record, tried first


class ResolutionResult(BaseModel):
    """How a company's careers page was found, or why it was not, with every check behind it.

    resolved   careers_page_url is the watch target, found at high or medium confidence.
    candidate  a low-confidence find, held for a human to confirm; never written as the watch target.
    failed     nothing usable; failure says why.
    error      an unexpected failure of our own; the company's resolution state is left alone.
    """

    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["resolution"] = "resolution"
    target_id: str
    outcome: Literal["resolved", "candidate", "failed", "error"]
    careers_page_url: str | None = None
    ats: AtsBoard | None = None
    method: ResolutionMethod | None = None
    confidence: Literal["high", "medium", "low"] | None = None
    failure: Literal["no_domain", "not_found", "blocked", "inaccessible"] | None = None
    evidence: str | None = None  # a sentence for the human reviewing a candidate
    reason: str | None = None  # for outcome "error"
    checks: list[PageResult] = Field(default_factory=list)
    duration_ms: int = 0


# --- Verification: matching tracked postings against a page's listings -------
#
# A verdict is written only from evidence that supports it: verified_live when a
# posting matches a listing; not_found only when the whole list was read; and
# None (inconclusive) when the list was partial and nothing matched, so the
# posting keeps its last verdict.
Verdict = Literal["verified_live", "not_found", "inaccessible"]
MatchMethod = Literal["exact", "variant", "llm", "none"]


class TrackedPosting(BaseModel):
    """A posting being verified: only what matching needs."""

    id: str
    title: str
    location: str | None = None


class MatchTarget(BaseModel):
    """A company's postings and a page's listings already read: matching without rendering.

    Used to replay stored page checks, so matching can be built and tuned at no
    API cost. `complete` says whether the whole list was read.
    """

    id: str  # the company
    label: str | None = None
    page_check_id: str | None = None  # the stored check the listings came from
    complete: bool
    listings: list[Listing]
    postings: list[TrackedPosting]


class PostingVerdict(BaseModel):
    posting_id: str
    verdict: Verdict | None  # None: inconclusive, no verdict written
    method: MatchMethod
    listing_index: int | None = None  # 0-based, into the page's listings
    listing: Listing | None = None
    location_note: str | None = None  # the matched listing is for a different location
    reasoning: str


class MatchResult(BaseModel):
    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["match"] = "match"
    target_id: str
    page_check_id: str | None = None
    complete: bool
    verdicts: list[PostingVerdict] = Field(default_factory=list)
    llm: LlmUsage | None = None  # the near-miss call, when one was needed
    outcome: Literal["ok", "error"] = "ok"
    reason: str | None = None
    duration_ms: int = 0


class VerifyTarget(BaseModel):
    """A company's watched page and the postings to verify against it."""

    id: str  # the company
    url: str
    label: str | None = None
    domain: str | None = None
    name: str | None = None
    postings: list[TrackedPosting]


class VerificationResult(BaseModel):
    """A company's page read in full (every page of it that could be), and a verdict per posting.

    ok           the page was read; verdicts follow the matching rules
    inaccessible the site refused or failed us, or robots.txt keeps us off: each
                 posting's verdict is inaccessible, with the reason
    error        our own failure (an extraction or an unexpected exception): no
                 verdicts, the postings keep their last ones
    """

    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["verification"] = "verification"
    target_id: str
    url: str
    outcome: Literal["ok", "inaccessible", "error"]
    reason: str | None = None
    complete: bool = False  # the whole list was read
    listing_count: int | None = None  # across every page read
    checks: list[PageResult] = Field(default_factory=list)  # one per page read
    verdicts: list[PostingVerdict] = Field(default_factory=list)
    match_llm: LlmUsage | None = None  # the near-miss call, when one was needed
    duration_ms: int = 0
