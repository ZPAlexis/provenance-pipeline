"""The worker's input and output: the contract Rails reads and writes.

One target in, one PageResult out, as a line of JSONL. Rails is the only
consumer, and it validates every result before anything is written.
"""

from typing import Literal

from pydantic import BaseModel, Field

from verifier import RESULT_SCHEMA_VERSION

WorkMode = Literal["remote", "hybrid", "onsite", "unknown"]
EmploymentType = Literal["full_time", "part_time", "contract", "internship", "temporary", "unknown"]
# What kind of company a page's roles say it is. A recruiter's own board lists its
# clients' roles, and those are its openings; an aggregator's lists other companies' own.
CompanyKind = Literal["employer", "recruiter", "aggregator"]

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
    purpose: Literal["extract", "resolve", "match", "relate"] = "extract"
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
    # When many_employers: a recruiter's client roles, or a job board's other companies' postings.
    many_employers_kind: Literal["recruiter", "job_board"] | None = None
    single_job_posting: bool = False  # the page is one job's own posting, not a list of openings
    next_page_url: str | None = None  # where the list continues, when the page links to its next page
    # When the listings were last actually read by the LLM. A check that reused them
    # (its role links unchanged) carries the original read's time, and the check reused.
    listings_read_at: str | None = None
    reused_from: str | None = None  # the stored page check whose listings were reused
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
    kind: CompanyKind | None = None  # as the operator confirmed it; None while unconfirmed


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
    # The kind the pages read suggest, held for the operator to confirm; with its evidence.
    kind_suggestion: Literal["recruiter", "aggregator"] | None = None
    kind_evidence: str | None = None
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
# link: the listing is at the posting's own address; posting_page: the role's own page shows it.
MatchMethod = Literal["link", "exact", "variant", "llm", "posting_page", "none"]


class TrackedPosting(BaseModel):
    """A posting being verified: only what matching needs."""

    id: str
    title: str
    location: str | None = None
    url: str | None = None  # the role's own page at the employer, when known: matched before any title
    # Added without a title (its `title` a placeholder): its own page names it, the first time it is read.
    title_from_page: bool = False


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


class PreviousRead(BaseModel):
    """What a page showed when it was last read: reused when its role links are unchanged."""

    page_check_id: str
    url: str
    final_url: str | None = None
    listings: list[Listing] = Field(default_factory=list)
    listing_count: int | None = None
    stated_total: int | None = None
    explicit_no_openings: bool = False
    listings_incomplete: bool = False
    many_employers: bool = False
    many_employers_kind: Literal["recruiter", "job_board"] | None = None
    single_job_posting: bool = False
    next_page_url: str | None = None
    content_hash: str | None = None
    listings_read_at: str  # ISO 8601: when the LLM last actually read these listings


class VerifyTarget(BaseModel):
    """A company's watched page and the postings to verify against it."""

    id: str  # the company
    url: str
    label: str | None = None
    domain: str | None = None
    name: str | None = None
    postings: list[TrackedPosting]
    # The company's own ATS board, confirmed to list the same roles: read through its
    # API instead of rendering the page.
    board: AtsBoard | None = None
    previous: list[PreviousRead] = Field(default_factory=list)  # one per page of the list, from the last run


class BoardTarget(BaseModel):
    """A company whose watched page the LLM had to read: does a free board list the same roles?"""

    id: str
    name: str | None = None
    domain: str | None = None
    titles: list[str]  # the distinct role titles the page showed at its last full read
    # A few of the page's role links: a board behind the company's own site shows only on its job pages.
    job_urls: list[str] = Field(default_factory=list)


class BoardResult(BaseModel):
    """Whether a free board lists the same roles as a company's page: adopted only on the roles themselves."""

    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["board"] = "board"
    target_id: str
    # adopted: read through it from now on; rejected: a board, but not the same roles;
    # none: no board found; error: the search itself failed.
    outcome: Literal["adopted", "rejected", "none", "error"]
    reason: str | None = None  # why rejected or not searched: "low_overlap", "too_few_roles", "no_board_found"
    board: AtsBoard | None = None  # the best board found, adopted or not
    page_roles: int = 0  # distinct titles the page showed
    board_roles: int = 0  # distinct titles on the board
    overlap: float = 0.0  # share of the page's titles the board also lists
    owner: Literal["confirmed", "elsewhere"] | None = None  # from its name record or where it links; evidence only
    owner_host: str | None = None
    evidence: str | None = None
    duration_ms: int = 0


# --- Search profiles: which stored roles fit what the operator is looking for ---
#
# Nothing is fetched and the LLM is never called: the roles were read before, and
# stored. What a role does not state is never held against it: it fits, marked.
Level = Literal["entry", "senior", "lead", "director", "executive"]  # titles.LEVELS
SoughtWorkMode = Literal["remote", "hybrid", "onsite"]


class SearchProfile(BaseModel):
    """What the operator is looking for.

    A role fits when its title holds every word of one of `titles`, in any order,
    and every word of none of `excluded`; it is open to one of `places`, where the
    operator can work (places.py); and its work mode and level are among those
    sought. An empty `places`, `work_modes`, or `levels` accepts any.
    """

    titles: list[str]
    excluded: list[str] = Field(default_factory=list)
    places: list[str] = Field(default_factory=list)  # where the operator can work: countries, regions, cities
    work_modes: list[SoughtWorkMode] = Field(default_factory=list)
    levels: list[Level] = Field(default_factory=list)


class SuggestTarget(BaseModel):
    """A company's roles as its watched page last listed them, weighed against a profile."""

    id: str  # the company
    label: str | None = None
    page_check_id: str | None = None  # the stored read the listings came from
    listings: list[Listing]
    profile: SearchProfile
    # The company's roles already on record, whatever the operator made of them (tracked,
    # suggested, dismissed): a listing that is one of them is never suggested anew.
    postings: list[TrackedPosting] = Field(default_factory=list)


# excluded: its title holds an excluded word; level, place, work_mode: one it states is not sought.
RuledOut = Literal["excluded", "level", "place", "work_mode"]
# What the role does not state, so could not be weighed: it fits, marked.
FitNote = Literal["work_mode_not_stated", "place_not_stated", "level_not_stated"]


class RoleFit(BaseModel):
    """A role whose title holds a profile title: suggested, or ruled out and why."""

    listing_index: int  # 0-based, into the target's listings
    listing: Listing
    title: str  # the profile title it holds every word of
    level: Level | None = None  # as its title states it
    place: str | None = None  # the profile place, as entered, that its location (or else its title) is open to
    work_mode: WorkMode = "unknown"  # as the listing states it, or else as its location does
    suggested: bool
    ruled_out: RuledOut | None = None
    notes: list[FitNote] = Field(default_factory=list)
    reasoning: str
    on_record: str | None = None  # the posting this listing already is, matched as verification matches


class SuggestionResult(BaseModel):
    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["suggestion"] = "suggestion"
    target_id: str
    page_check_id: str | None = None
    outcome: Literal["ok", "error"] = "ok"
    reason: str | None = None
    weighed: int = 0  # roles weighed
    roles: list[RoleFit] = Field(default_factory=list)  # every role holding a profile title; the rest are not listed
    # Each posting on record found among the listings, fitting or not: posting id -> listing index.
    # A posting missing here was not in this read, which may be only part of the list.
    listed: dict[str, int] = Field(default_factory=dict)
    duration_ms: int = 0


class RelateTarget(BaseModel):
    """A search profile's titles, for titles in the same area to be proposed."""

    id: str  # the profile
    titles: list[str]
    excluded: list[str] = Field(default_factory=list)
    places: list[str] = Field(default_factory=list)  # their languages are the languages proposed in


class ProposedTitle(BaseModel):
    title: str
    language: str
    reason: str


class RelatedResult(BaseModel):
    """Titles the LLM proposes in the same area as a profile's: for the operator to pick, never added on their own."""

    schema_version: int = RESULT_SCHEMA_VERSION
    kind: Literal["related"] = "related"
    target_id: str
    outcome: Literal["ok", "error"] = "ok"
    reason: str | None = None
    proposals: list[ProposedTitle] = Field(default_factory=list)
    llm: LlmUsage | None = None
    duration_ms: int = 0


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
