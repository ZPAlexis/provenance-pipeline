"""The worker's input and output: the contract Rails reads and writes.

One target in, one PageResult out, as a line of JSONL. Rails is the only
consumer, and it validates every result before anything is written.
"""

from typing import Literal

from pydantic import BaseModel, Field

from verifier import RESULT_SCHEMA_VERSION

WorkMode = Literal["remote", "hybrid", "onsite", "unknown"]

# ok           the page was read and its listings extracted (possibly zero)
# blocked      we chose not to fetch it (robots.txt)
# inaccessible the site refused or failed us (HTTP error, bot challenge, timeout)
# error        our own failure (extraction or an unexpected exception)
Outcome = Literal["ok", "blocked", "inaccessible", "error"]


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


class LlmUsage(BaseModel):
    model: str  # the model the API reports having served
    settings: dict = Field(default_factory=dict)  # request settings, e.g. effort
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0  # an estimate, from the published per-token prices


class AtsBoard(BaseModel):
    vendor: Literal["greenhouse", "lever", "ashby", "workday"]
    board: str  # the board's name; for Workday, "{tenant}.{wdN}/{site}"


class PageResult(BaseModel):
    schema_version: int = RESULT_SCHEMA_VERSION
    target_id: str
    url: str
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
    input_truncated: bool = False  # the model saw less than the whole page
    notes: str | None = None  # the extractor's short account of what the page showed
    content_hash: str | None = None  # sha256 of the normalized page text
    http_status: int | None = None
    llm: LlmUsage | None = None
    duration_ms: int = 0
