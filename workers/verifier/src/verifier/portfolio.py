"""What the operator's own links show (4d): their website, GitHub, or any other portfolio. Never read by the LLM.

A GitHub link is read through GitHub's public REST API, as the boards' job APIs are: the profile (its bio and its
README) and, for an account, each public repo of its own (forks left out, most recently pushed first), each with its
README. Any other site is rendered: the pages its sitemap lists (named in its robots.txt, or at /sitemap.xml), then
those its page links to on the same site, one level deep; robots.txt honored for each, the usual delay between requests
to the host, and caps on pages and on characters. A site whose pages aren't plain links (reached by script) is found
through its sitemap or not at all. Where the address names a language (`/en`, `/pt-br`), only the pages under it are
read, so a site in two languages isn't read twice.

Each page's main text is kept as it is, with a hash, as a role's description is: what applies to an application is
picked from them later, by the app.
"""

import hashlib
import html
import re
import time
from collections.abc import Callable
from datetime import UTC, datetime
from urllib.parse import urljoin, urlsplit, urlunsplit

import httpx2

from verifier.config import USER_AGENT
from verifier.contract import PortfolioPage, PortfolioResult, PortfolioTarget
from verifier.pipeline import Services
from verifier.render import RenderError, render

MAX_PAGES = 15  # the link's own page and up to 14 it links to
MAX_REPOS = 12  # an account's repos read, most recently pushed first
MAX_PAGE_CHARS = 20_000
MAX_TOTAL_CHARS = 150_000

_GITHUB = re.compile(r"^https?://(?:www\.)?github\.com/([A-Za-z0-9][A-Za-z0-9-]*)(?:/([\w.-]+))?/?(?:[?#].*)?$", re.I)
_GITHUB_API = "https://api.github.com"
# Path segments that name a language: a site in several keeps each under its own.
_LANGUAGES = {
    *("en", "pt", "es", "fr", "de", "it", "nl", "ja", "zh"),
    *("ko", "ru", "pl", "sv", "da", "no", "fi", "tr", "ar"),
}
_LOCALE = re.compile(r"([a-z]{2})(?:[-_][a-z]{2})?", re.I)
_FILES = re.compile(r"\.(pdf|png|jpe?g|gif|svg|webp|ico|zip|gz|mp4|mov|mp3|docx?|xlsx?|pptx?|csv|json|xml|txt)$", re.I)
_LOC = re.compile(r"<loc>\s*([^<\s]+)\s*</loc>", re.I)
MAX_SITEMAPS = 4  # the one named (or /sitemap.xml) and up to 3 an index points to
MAX_SITEMAP_BYTES = 2_000_000


class _Gone(Exception):
    """The site or the account isn't there."""


def read_link(target: PortfolioTarget, services: Services) -> PortfolioResult:
    checked_at = datetime.now(UTC).isoformat(timespec="seconds")
    started = time.monotonic()

    def result(outcome: str, **fields) -> PortfolioResult:
        return PortfolioResult(
            target_id=target.id,
            url=target.url,
            outcome=outcome,
            checked_at=checked_at,
            duration_ms=int((time.monotonic() - started) * 1000),
            **fields,
        )

    try:
        if match := _GITHUB.match(target.url):
            pages = _github(match.group(1), match.group(2), services)
            return result("ok", pages=pages)
    except _Gone:
        return result("gone", reason="not_found")
    except httpx2.HTTPStatusError as error:
        status = error.response.status_code
        if status in (403, 429):
            return result("inaccessible", reason="rate_limited")
        return result("gone" if status in (404, 410) else "inaccessible", reason=f"http_{status}")
    except (httpx2.HTTPError, ValueError, KeyError, TypeError):
        return result("inaccessible", reason="api_unreadable")
    return _site(target, services, result)


def _github(owner: str, repo: str | None, services: Services) -> list[PortfolioPage]:
    """A GitHub account (its profile, then its own repos) or one repo, through the public API."""

    def get(path: str, raw: bool = False):
        response = services.http.get(
            f"{_GITHUB_API}{path}",
            headers={
                "User-Agent": USER_AGENT,
                "Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            follow_redirects=True,
        )
        if raw and response.status_code == 404:
            return ""  # no README
        if response.status_code == 404:
            raise _Gone
        response.raise_for_status()
        return response.text if raw else response.json()

    if repo:
        return [_repo_page(get(f"/repos/{owner}/{repo}"), get(f"/repos/{owner}/{repo}/readme", raw=True))]

    user = get(f"/users/{owner}")
    profile = "\n\n".join(
        part
        for part in (user.get("name") or "", user.get("bio") or "", get(f"/repos/{owner}/{owner}/readme", raw=True))
        if part.strip()
    )
    home = user.get("html_url") or f"https://github.com/{owner}"
    pages = [_page(home, user.get("name") or owner, profile, "github_api")]
    repos = [
        found
        for found in get(f"/users/{owner}/repos?type=owner&sort=pushed&per_page=100")
        if not found.get("fork") and found.get("name", "").lower() != owner.lower()
    ]
    for found in repos[:MAX_REPOS]:
        pages.append(_repo_page(found, get(f"/repos/{owner}/{found['name']}/readme", raw=True)))
    return [page for page in pages if page.text]


def _repo_page(repo: dict, readme: str) -> PortfolioPage:
    facts = [
        repo.get("full_name") or repo.get("name") or "",
        repo.get("description") or "",
        f"Language: {repo['language']}" if repo.get("language") else "",
        f"Topics: {', '.join(repo['topics'])}" if repo.get("topics") else "",
    ]
    text = "\n".join(fact for fact in facts if fact) + (f"\n\n{readme}" if readme.strip() else "")
    return _page(repo.get("html_url") or "", repo.get("full_name") or repo.get("name"), text, "github_api")


def _site(target: PortfolioTarget, services: Services, result: Callable[..., PortfolioResult]) -> PortfolioResult:
    """The link's own page rendered, then the pages it links to on the same site, one level deep, within the caps."""
    if refusal := services.robots.check(target.url):
        return result("blocked", reason=refusal)
    page, reason = _render(target.url, services)
    if page is None:
        return result("gone" if reason in ("http_404", "http_410") else "inaccessible", reason=reason)

    first = _page(page.final_url, page.title or page.heading, page.main_text or page.text, "render")
    if not first.text:
        return result("inaccessible", reason="no_text")
    pages, seen, skipped = [first], {first.content_hash}, 0
    total = len(first.text)
    listed = _sitemap(page.final_url, services)
    linked = [url for url in _same_site(page.links, page.final_url) if url not in listed]
    for url in listed + linked:
        if len(pages) >= MAX_PAGES or total >= MAX_TOTAL_CHARS:
            skipped += 1
            continue
        if services.robots.check(url):
            skipped += 1
            continue
        linked, _ = _render(url, services)
        if linked is None or not _same_host(linked.final_url, page.final_url):
            skipped += 1
            continue
        read = _page(linked.final_url, linked.title or linked.heading, linked.main_text or linked.text, "render")
        if not read.text or read.content_hash in seen:
            continue  # nothing to read, or a page already read under another address
        seen.add(read.content_hash)
        pages.append(read)
        total += len(read.text)
    return result("ok", pages=pages, skipped=skipped)


def _sitemap(base: str, services: Services) -> list[str]:
    """The pages the site's sitemap lists, as `_same_site` keeps them (its host, its language, never a file): the
    sitemaps its robots.txt names, else /sitemap.xml; an index read one level, up to MAX_SITEMAPS in all. Read as
    text, never parsed as XML: only each <loc> is taken."""
    parts = urlsplit(base)
    queue = services.robots.sitemaps(base) or [f"{parts.scheme}://{parts.netloc}/sitemap.xml"]
    locs: list[str] = []
    read = 0
    while queue and read < MAX_SITEMAPS:
        sitemap = queue.pop(0)
        read += 1
        if not _same_host(sitemap, base) or services.robots.check(sitemap):
            continue
        services.throttle.wait(parts.netloc)
        try:
            response = services.http.get(sitemap, headers={"User-Agent": USER_AGENT}, follow_redirects=True)
        except httpx2.HTTPError:
            continue
        if response.status_code >= 400:
            continue
        text = response.text[:MAX_SITEMAP_BYTES]
        found = [html.unescape(loc) for loc in _LOC.findall(text)]
        if "<sitemapindex" in text:
            queue += found
        else:
            locs += found
    return _same_site([("", loc) for loc in locs], base)


def _render(url: str, services: Services):
    """The page rendered, or None and why not."""
    services.throttle.wait(urlsplit(url).netloc)
    try:
        page = render(services.browser, url)
    except RenderError as error:
        return None, error.reason
    if page.looks_like_challenge:
        return None, "bot_challenge"
    if page.status and page.status >= 400:
        return None, f"http_{page.status}"
    return page, None


def _same_site(links: list[tuple[str, str]], base: str) -> list[str]:
    """The pages `base` links to on its own site, under its language when its address names one: each once, in the
    order the page has them, never itself, a file, or another site."""
    scope = _language_scope(urlsplit(base).path)
    found: list[str] = []
    for _, href in links:
        parts = urlsplit(urljoin(base, href))
        if parts.scheme not in ("http", "https") or not _same_host(parts.geturl(), base):
            continue
        path = parts.path or "/"
        if _FILES.search(path) or not path.startswith(scope):
            continue
        url = urlunsplit((parts.scheme, parts.netloc.lower(), path.rstrip("/") or "/", "", ""))
        if url != _bare(base) and url not in found:
            found.append(url)
    return found


def _language_scope(path: str) -> str:
    """The part of a path up to its language segment ("/en/", "/site/pt-br/"), or "/" when it names none."""
    parts = path.split("/")
    for index, part in enumerate(parts):
        match = _LOCALE.fullmatch(part)
        if match and match.group(1).lower() in _LANGUAGES:
            return "/".join(parts[: index + 1]) + "/"
    return "/"


def _same_host(url: str, base: str) -> bool:
    def host(address: str) -> str:
        return urlsplit(address).netloc.lower().removeprefix("www.")

    return host(url) == host(base)


def _bare(url: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme, parts.netloc.lower(), parts.path.rstrip("/") or "/", "", ""))


def _page(url: str, title: str | None, text: str, via: str) -> PortfolioPage:
    tidy = _tidy(text)
    named = (title or "").strip() or None
    return PortfolioPage(url=url, title=named, text=tidy, content_hash=_hash(tidy), read_via=via)


def _tidy(text: str) -> str:
    """Spacing collapsed, blank runs to one, ends trimmed, cut at the page's limit."""
    lines = [re.sub(r"[ \t ]+", " ", line).strip() for line in (text or "").splitlines()]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()[:MAX_PAGE_CHARS]


def _hash(text: str) -> str:
    return "sha256:" + hashlib.sha256(re.sub(r"\s+", " ", text).strip().encode()).hexdigest()
