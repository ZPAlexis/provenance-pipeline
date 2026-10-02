"""Known applicant tracking systems: detection, and their public job-board APIs.

When a careers page is (or embeds) a Greenhouse, Lever, Ashby, or Workday
board, the vendor's API returns the listings directly: cheaper and more exact
than reading the rendered page, and for Workday the only way past its
20-per-page pagination. Measured against real data this covers a minority of
companies; the renderer carries the rest.
"""

import re
from collections.abc import Callable, Iterator
from urllib.parse import parse_qs, urlsplit

import httpx2

from verifier.config import USER_AGENT
from verifier.contract import AtsBoard, EmploymentType, Listing, WorkMode

# Each pattern captures the board name from a page, frame, or embed URL.
_PATTERNS: list[tuple[str, re.Pattern]] = [
    ("greenhouse", re.compile(r"^https?://(?:boards|job-boards)(?:\.eu)?\.greenhouse\.io/(?!embed/)([\w-]+)")),
    ("lever", re.compile(r"^https?://jobs(?:\.eu)?\.lever\.co/([\w.-]+)")),
    ("ashby", re.compile(r"^https?://jobs\.ashbyhq\.com/([\w.%-]+)")),
]

# Greenhouse's embed names the board in a query parameter: /embed/job_board?for=acme
_GREENHOUSE_EMBED = re.compile(r"^https?://(?:boards|job-boards)(?:\.eu)?\.greenhouse\.io/embed/job_board")

# https://{tenant}.{wdN}.myworkdayjobs.com/[{locale}/]{site}; /wday/... is its API, not a board.
_WORKDAY = re.compile(r"^https?://([\w-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Z]{2}/)?(?!wday/)([\w-]+)")

WORKDAY_PAGE_SIZE = 20  # the most its jobs API returns per request
WORKDAY_MAX_PAGES = 100  # a guard: 2,000 roles

# Vendors whose board names can be guessed from a company's name, for when the
# careers page itself cannot be read. Workday also needs a tenant and a site.
GUESSABLE_VENDORS = ("greenhouse", "lever", "ashby")

_CORPORATE_SUFFIXES = {"inc", "llc", "ltd", "ltda", "limited", "corp", "corporation", "co", "gmbh", "sa", "plc"}


def detect(urls: list[str]) -> AtsBoard | None:
    """The first known ATS board among a page's own, frame, and embed URLs."""
    for url in urls:
        if _GREENHOUSE_EMBED.match(url):
            board = parse_qs(urlsplit(url).query).get("for", [None])[0]
            if board:
                return AtsBoard(vendor="greenhouse", board=board)
            continue
        if match := _WORKDAY.match(url):
            tenant, instance, site = match.groups()
            return AtsBoard(vendor="workday", board=f"{tenant}.{instance}/{site}")
        for vendor, pattern in _PATTERNS:
            if match := pattern.match(url):
                return AtsBoard(vendor=vendor, board=match.group(1))
    return None


def api_url(board: AtsBoard) -> str:
    if board.vendor == "greenhouse":
        return f"https://boards-api.greenhouse.io/v1/boards/{board.board}/jobs"
    if board.vendor == "lever":
        return f"https://api.lever.co/v0/postings/{board.board}"
    if board.vendor == "ashby":
        return f"https://api.ashbyhq.com/posting-api/job-board/{board.board}"
    tenant_instance, site = board.board.split("/", 1)
    tenant = tenant_instance.split(".", 1)[0]
    return f"https://{tenant_instance}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/jobs"


def board_url(board: AtsBoard) -> str:
    """The board's public page: what a person would visit, and what the system watches."""
    if board.vendor == "greenhouse":
        return f"https://job-boards.greenhouse.io/{board.board}"
    if board.vendor == "lever":
        return f"https://jobs.lever.co/{board.board}"
    if board.vendor == "ashby":
        return f"https://jobs.ashbyhq.com/{board.board}"
    tenant_instance, site = board.board.split("/", 1)
    return f"https://{tenant_instance}.myworkdayjobs.com/{site}"


def board_name(board: AtsBoard, client: httpx2.Client) -> str | None:
    """The company name the vendor records for a board, where it records one.

    Only Greenhouse does (`/v1/boards/{token}` returns a `name`); Lever and Ashby
    have no such record. Used to confirm a board that was guessed by name.
    """
    if board.vendor != "greenhouse":
        return None
    try:
        return _get_json(client, f"https://boards-api.greenhouse.io/v1/boards/{board.board}").get("name")
    except (httpx2.HTTPError, ValueError, AttributeError):
        return None


def names_match(recorded: str | None, company: str | None) -> bool:
    """Whether two company names are the same, ignoring case, punctuation, and legal suffixes.

    Exact on purpose: this is what lets a guessed board be written without a
    human. "Goodwin" and "Goodwin Recruiting" are different companies as often
    as not; a board whose name only starts the same is left for a person.
    """
    a, b = _name_words(recorded), _name_words(company)
    return bool(a) and a == b


def _name_words(name: str | None) -> list[str]:
    return [word for word in re.findall(r"[a-z0-9]+", (name or "").lower()) if word not in _CORPORATE_SUFFIXES]


def api_host(board: AtsBoard) -> str:
    """The host the board's API lives on: the key for spacing requests politely."""
    return urlsplit(api_url(board)).netloc


def on_company_host(board: AtsBoard) -> bool:
    """Whether the API sits on the company's own careers host, and so answers to its robots.txt.

    Greenhouse, Lever, and Ashby publish documented job-board APIs on their own
    hosts for exactly this use; Workday's jobs endpoint is the one the company's
    careers site itself calls.
    """
    return board.vendor == "workday"


def fetch_listings(board: AtsBoard, client: httpx2.Client, pause: Callable[[], None] = lambda: None) -> list[Listing]:
    """Every open listing on the board. Raises on HTTP errors. `pause` spaces out paged requests."""
    if board.vendor == "workday":
        return _workday(board, client, pause)
    return {"greenhouse": _greenhouse, "lever": _lever, "ashby": _ashby}[board.vendor](board, client)


def board_candidates(domain: str | None, name: str | None) -> list[str]:
    """Likely board names for a company, from its domain's first label and its name."""
    candidates: list[str] = []
    if domain:
        label = domain.lower().removeprefix("www.").split(".")[0]
        candidates += [label, label.replace("-", "")]
    if name:
        words = [word for word in re.findall(r"[a-z0-9]+", name.lower()) if word not in _CORPORATE_SUFFIXES]
        if words:
            candidates += ["".join(words), "-".join(words), words[0]]
    return list(dict.fromkeys(candidate for candidate in candidates if candidate))


def find_board(
    candidates: list[str], client: httpx2.Client, wait: Callable[[str], None]
) -> tuple[AtsBoard, list[Listing]] | None:
    """The first guessed board that exists and lists at least one job.

    An empty board is passed over: a guess that happens to match an unused board
    would otherwise read as a company with no openings. `wait` is called with each
    API host before its request, to keep requests spaced.
    """
    return next(guessed_boards(candidates, client, wait), None)


def guessed_boards(
    candidates: list[str], client: httpx2.Client, wait: Callable[[str], None]
) -> Iterator[tuple[AtsBoard, list[Listing]]]:
    """Every guessed board that exists and lists at least one job, in the order tried."""
    for vendor in GUESSABLE_VENDORS:
        for candidate in candidates:
            board = AtsBoard(vendor=vendor, board=candidate)
            wait(api_host(board))
            try:
                listings = fetch_listings(board, client)
            except (httpx2.HTTPError, ValueError, KeyError, TypeError):
                continue
            if listings:
                yield board, listings


def _get_json(client: httpx2.Client, url: str, **params):
    response = client.get(url, params=params, headers={"User-Agent": USER_AGENT}, follow_redirects=True)
    response.raise_for_status()
    return response.json()


def _greenhouse(board: AtsBoard, client: httpx2.Client) -> list[Listing]:
    data = _get_json(client, api_url(board))
    return [
        Listing(
            title=job["title"],
            location=(job.get("location") or {}).get("name"),
            url=job.get("absolute_url"),
            work_mode=_mode_from_location((job.get("location") or {}).get("name")),
        )
        for job in data.get("jobs", [])
    ]


def _lever(board: AtsBoard, client: httpx2.Client) -> list[Listing]:
    data = _get_json(client, api_url(board), mode="json")
    return [
        Listing(
            title=posting["text"],
            location=(posting.get("categories") or {}).get("location"),
            url=posting.get("hostedUrl"),
            work_mode=_normalize_mode(posting.get("workplaceType")),
            department=(posting.get("categories") or {}).get("team")
            or (posting.get("categories") or {}).get("department"),
            employment_type=_employment_type((posting.get("categories") or {}).get("commitment")),
        )
        for posting in data
    ]


def _ashby(board: AtsBoard, client: httpx2.Client) -> list[Listing]:
    data = _get_json(client, api_url(board))
    listings = []
    for job in data.get("jobs", []):
        if job.get("isListed") is False:
            continue
        mode = _normalize_mode(job.get("workplaceType"))
        if mode == "unknown" and job.get("isRemote"):
            mode = "remote"
        listings.append(
            Listing(
                title=job["title"],
                location=job.get("location"),
                url=job.get("jobUrl"),
                work_mode=mode,
                department=job.get("department") or job.get("team"),
                employment_type=_employment_type(job.get("employmentType")),
            )
        )
    return listings


def _workday(board: AtsBoard, client: httpx2.Client, pause: Callable[[], None]) -> list[Listing]:
    url = api_url(board)
    site_root = url.split("/wday/", 1)[0] + "/" + board.board.split("/", 1)[1]
    listings: list[Listing] = []
    total = None
    for page in range(WORKDAY_MAX_PAGES):
        if page:
            pause()
        response = client.post(
            url,
            json={"appliedFacets": {}, "limit": WORKDAY_PAGE_SIZE, "offset": len(listings), "searchText": ""},
            headers={"User-Agent": USER_AGENT},
            follow_redirects=True,
        )
        response.raise_for_status()
        data = response.json()
        if total is None:
            total = data.get("total") or 0  # reported on the first page only
        postings = data.get("jobPostings") or []
        listings += [
            Listing(
                title=posting["title"],
                location=posting.get("locationsText"),
                url=site_root + posting["externalPath"] if posting.get("externalPath") else None,
                work_mode=_mode_from_location(posting.get("locationsText")),
            )
            for posting in postings
        ]
        if not postings or len(listings) >= total:
            break
    return listings


def _normalize_mode(value: str | None) -> WorkMode:
    key = re.sub(r"[^a-z]", "", (value or "").lower())
    return {"remote": "remote", "hybrid": "hybrid", "onsite": "onsite", "inoffice": "onsite"}.get(key, "unknown")


def _mode_from_location(location: str | None) -> WorkMode:
    return "remote" if location and "remote" in location.lower() else "unknown"


def _employment_type(value: str | None) -> EmploymentType:
    """Vendors' own words ("Full-time", "FullTime", "Contract") as the contract's, or unknown."""
    key = re.sub(r"[^a-z]", "", (value or "").lower())
    return {
        "fulltime": "full_time",
        "parttime": "part_time",
        "contract": "contract",
        "contractor": "contract",
        "intern": "internship",
        "internship": "internship",
        "temporary": "temporary",
        "temp": "temporary",
    }.get(key, "unknown")
