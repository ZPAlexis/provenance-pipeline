"""A role's description, read from its own page (Stage 2b). Never by the LLM.

Where the role is on a board the worker reads through its API (Greenhouse,
Lever, Ashby, Workday, Oracle Cloud), the board's job endpoint returns its
description: free, exact, and nothing rendered. Anywhere else the role's own
page is rendered and its main text kept as it is: the page's <main> or
<article> when it marks one, else all its text. Only text is kept; the
drafting and scoring agents to come read it, and the hash says when it changed.
"""

import hashlib
import html
import re
import time
from datetime import UTC, datetime
from html.parser import HTMLParser
from urllib.parse import urlsplit

import httpx2

from verifier import ats
from verifier.config import USER_AGENT
from verifier.contract import AtsBoard, DescribeTarget, DescriptionResult
from verifier.links import same_job
from verifier.pipeline import Services
from verifier.render import RenderError, render

MAX_CHARS = 60_000  # a description longer than this is a page, not a description: kept cut, and said

_GREENHOUSE_JOB = re.compile(r"^https?://(?:boards|job-boards)(?:\.eu)?\.greenhouse\.io/([\w-]+)/jobs/(\d+)")
_LEVER_JOB = re.compile(r"^https?://jobs(\.eu)?\.lever\.co/([\w.-]+)/([0-9a-f-]{36})")
_ASHBY_JOB = re.compile(r"^https?://jobs\.ashbyhq\.com/([\w.%-]+)/([0-9a-f-]{36})")
_WORKDAY_JOB = re.compile(
    r"^https?://([\w-]+)\.(wd\d+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Z]{2}/)?([\w-]+)/job/([^?#]+)"
)
_ORACLE_JOB = re.compile(
    r"^https?://([\w-]+\.fa\.[\w-]+\.oraclecloud\.com)/hcmUI/CandidateExperience/[\w-]+/sites/([\w-]+)/job/(\d+)"
)


class _Gone(Exception):
    """The board no longer has the job."""


class _Blocked(Exception):
    """robots.txt keeps us off the endpoint the company's own site calls."""


def describe_role(target: DescribeTarget, services: Services) -> DescriptionResult:
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    started = time.monotonic()

    def result(outcome: str, **fields) -> DescriptionResult:
        text = fields.pop("text", None)
        if text is not None:
            text, cut = _tidy(text)
            if not text:
                outcome, fields["reason"] = "inaccessible", "no_text"
            elif cut:
                fields["reason"] = "cut_at_limit"
        return DescriptionResult(
            target_id=target.id,
            url=target.url,
            outcome=outcome,
            text=text or None,
            content_hash=_hash(text) if text else None,
            checked_at=checked_at,
            duration_ms=int((time.monotonic() - started) * 1000),
            **fields,
        )

    if not target.url:
        return result("no_page", reason="no_page_on_record")
    try:
        if via := _from_board(target.url, services):
            vendor, text = via
            return result("ok", read_via=f"ats_api:{vendor}", text=text)
    except _Gone:
        return result("gone", reason="not_on_its_board")
    except _Blocked as refusal:
        return result("blocked", reason=str(refusal))
    except httpx2.HTTPStatusError as error:
        status = error.response.status_code
        return result("gone" if status in (404, 410) else "inaccessible", reason=f"http_{status}")
    except (httpx2.HTTPError, ValueError, KeyError, TypeError):
        return result("inaccessible", reason="board_unreadable")
    return _from_page(target, services, result)


def _from_board(url: str, services: Services) -> tuple[str, str] | None:
    """The description from the board's own job API, when the role's address is on a board the worker reads."""
    get = _getter(services)
    if match := _GREENHOUSE_JOB.match(url):
        board, job = match.groups()
        data = get(f"https://boards-api.greenhouse.io/v1/boards/{board}/jobs/{job}")
        return "greenhouse", _html_text(html.unescape(data.get("content") or ""))
    if match := _LEVER_JOB.match(url):
        eu, site, job = match.groups()
        data = get(f"https://api{eu or ''}.lever.co/v0/postings/{site}/{job}")
        parts = [data.get("descriptionPlain") or _html_text(data.get("description") or "")]
        for section in data.get("lists") or []:
            parts += [section.get("text") or "", _html_text(section.get("content") or "")]
        parts.append(data.get("additionalPlain") or _html_text(data.get("additional") or ""))
        return "lever", "\n\n".join(part for part in parts if part)
    if match := _ASHBY_JOB.match(url):
        board, job = match.groups()
        data = get(ats.api_url(AtsBoard(vendor="ashby", board=board)))
        found = next((posting for posting in data.get("jobs") or [] if posting.get("id") == job), None)
        if found is None:
            raise _Gone
        return "ashby", found.get("descriptionPlain") or _html_text(found.get("descriptionHtml") or "")
    if match := _WORKDAY_JOB.match(url):
        tenant, instance, site, path = match.groups()
        api = f"https://{tenant}.{instance}.myworkdayjobs.com/wday/cxs/{tenant}/{site}/job/{path}"
        _polite(services, api)
        data = get(api)
        return "workday", _html_text((data.get("jobPostingInfo") or {}).get("jobDescription") or "")
    if match := _ORACLE_JOB.match(url):
        host, site, job = match.groups()
        # Built by hand, as the list's finder is: its ; , and = are its own syntax.
        api = (
            f"https://{host}/hcmRestApi/resources/latest/recruitingCEJobRequisitionDetails"
            f'?expand=all&onlyData=true&finder=ById;Id="{job}",siteNumber={site}'
        )
        _polite(services, api)
        items = get(api).get("items") or []
        if not items:
            raise _Gone
        item = items[0]
        parts = [
            item.get(field) or ""
            for field in ("ExternalDescriptionStr", "ExternalResponsibilitiesStr", "ExternalQualificationsStr")
        ]
        return "oracle", "\n\n".join(_html_text(part) for part in parts if part)
    return None


def _polite(services: Services, url: str) -> None:
    """Workday's and Oracle's endpoints are the ones the company's own site calls: they answer to its robots.txt."""
    if refusal := services.robots.check(url):
        raise _Blocked(refusal)
    services.throttle.wait(urlsplit(url).netloc)


def _getter(services: Services):
    def get(url: str) -> dict:
        response = services.http.get(
            url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"}, follow_redirects=True
        )
        response.raise_for_status()
        return response.json()

    return get


def _from_page(target: DescribeTarget, services: Services, result) -> DescriptionResult:
    """The role's own page rendered, and its main text kept as it is."""
    url = target.url
    if refusal := services.robots.check(url):
        return result("blocked", reason=refusal)
    services.throttle.wait(urlsplit(url).netloc)
    try:
        page = render(services.browser, url)
    except RenderError as error:
        return result("inaccessible", reason=error.reason)
    if page.looks_like_challenge:
        return result("inaccessible", reason="bot_challenge")
    if page.status in (404, 410):
        return result("gone", reason=f"http_{page.status}")
    if page.status and page.status >= 400:
        return result("inaccessible", reason=f"http_{page.status}")
    if not same_job(url, page.final_url):
        return result("gone", reason="redirected")
    return result("ok", read_via="render", text=page.main_text or page.text)


class _TextOfHtml(HTMLParser):
    """An HTML description as text: a line per block, lists as dashes, scripts and styles left out."""

    BLOCKS = {"p", "div", "br", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "section", "table"}

    def __init__(self):
        super().__init__()
        self.parts: list[str] = []
        self._skipping = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skipping += 1
        elif tag in self.BLOCKS:
            self.parts.append("\n- " if tag == "li" else "\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skipping = max(0, self._skipping - 1)
        elif tag in self.BLOCKS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skipping:
            self.parts.append(data)


def _html_text(markup: str) -> str:
    parser = _TextOfHtml()
    parser.feed(markup)
    parser.close()
    return "".join(parser.parts)


def _tidy(text: str) -> tuple[str, bool]:
    """Spacing collapsed, blank runs to one, ends trimmed, cut at the limit: the text, and whether it was cut."""
    lines = [re.sub(r"[ \t\u00a0]+", " ", line).strip() for line in text.splitlines()]
    tidy = re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()
    return tidy[:MAX_CHARS], len(tidy) > MAX_CHARS


def _hash(text: str) -> str:
    return "sha256:" + hashlib.sha256(re.sub(r"\s+", " ", text).strip().encode()).hexdigest()
