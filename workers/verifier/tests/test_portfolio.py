import io
from dataclasses import replace

import httpx2

from verifier import cli
from verifier.contract import PortfolioTarget
from verifier.portfolio import _sitemap, read_link


def link(url, label="Website"):
    return PortfolioTarget(id="l1", url=url, label=label)


def through(services, handler):
    """The services with every HTTP request answered by `handler`; the browser is never used."""
    return replace(services, http=httpx2.Client(transport=httpx2.MockTransport(handler)))


def github(routes):
    """GitHub's API as `routes` answers it: JSON, a README as raw text, or a status (404, 403)."""

    def handler(request):
        key = request.url.path + (f"?{request.url.query.decode()}" if request.url.query else "")
        if key not in routes:
            raise AssertionError(f"unexpected request {request.url}")
        answer = routes[key]
        if isinstance(answer, int):
            return httpx2.Response(answer)
        if isinstance(answer, str):
            assert request.headers["Accept"] == "application/vnd.github.raw"
            return httpx2.Response(200, text=answer)
        return httpx2.Response(200, json=answer)

    return handler


ACCOUNT = {
    "/users/jsample": {"name": "Jordan Sample", "bio": "Governed AI agents.", "html_url": "https://github.com/jsample"},
    "/repos/jsample/jsample/readme": "# Hi\nI build agents under permission sets.",
    "/users/jsample/repos?type=owner&sort=pushed&per_page=100": [
        {"name": "jsample", "full_name": "jsample/jsample", "fork": False},
        {"name": "forked", "full_name": "jsample/forked", "fork": True},
        {
            "name": "alpha",
            "full_name": "jsample/alpha",
            "fork": False,
            "description": "Verifies roles at the source.",
            "language": "Ruby",
            "topics": ["ai-agents", "mcp"],
            "html_url": "https://github.com/jsample/alpha",
        },
        {"name": "beta", "full_name": "jsample/beta", "fork": False, "html_url": "https://github.com/jsample/beta"},
    ],
    "/repos/jsample/alpha/readme": "# Alpha\nAn append-only audit log.",
    "/repos/jsample/beta/readme": 404,
}


def test_reads_a_github_account_through_its_api_its_profile_then_its_own_repos(services):
    result = read_link(link("https://github.com/jsample", "GitHub"), through(services, github(ACCOUNT)))

    assert result.outcome == "ok"
    assert [(page.url, page.title, page.read_via) for page in result.pages] == [
        ("https://github.com/jsample", "Jordan Sample", "github_api"),
        ("https://github.com/jsample/alpha", "jsample/alpha", "github_api"),
        ("https://github.com/jsample/beta", "jsample/beta", "github_api"),
    ]
    assert result.pages[0].text == "Jordan Sample\n\nGoverned AI agents.\n\n# Hi\nI build agents under permission sets."
    assert result.pages[1].text == (
        "jsample/alpha\nVerifies roles at the source.\nLanguage: Ruby\nTopics: ai-agents, mcp\n\n"
        "# Alpha\nAn append-only audit log."
    )
    assert result.pages[2].text == "jsample/beta"  # no README: what the repo says of itself
    assert all(page.content_hash.startswith("sha256:") for page in result.pages)


def test_reads_one_repo_and_says_when_github_has_no_such_account_or_refuses(services):
    repo = {
        "/repos/jsample/alpha": {
            "name": "alpha",
            "full_name": "jsample/alpha",
            "html_url": "https://github.com/jsample/alpha",
        },
        "/repos/jsample/alpha/readme": "# Alpha",
    }
    one = read_link(link("https://github.com/jsample/alpha/"), through(services, github(repo)))
    gone = read_link(link("https://github.com/nobody"), through(services, github({"/users/nobody": 404})))
    limited = read_link(link("https://github.com/jsample"), through(services, github({"/users/jsample": 403})))

    assert [(page.title, page.text) for page in one.pages] == [("jsample/alpha", "jsample/alpha\n\n# Alpha")]
    assert (gone.outcome, gone.reason) == ("gone", "not_found")
    assert (limited.outcome, limited.reason) == ("inaccessible", "rate_limited")


def test_reads_a_site_with_its_sitemaps_pages_and_those_it_links_to_under_its_language(services, site):
    result = read_link(link(site.url("portfolio/en/index.html")), services)

    assert result.outcome == "ok"
    assert [page.title for page in result.pages] == [
        "Jordan Sample · Portfolio",
        "Hidden project",  # listed only in the sitemap
        "About · Jordan Sample",
        "Project Alpha",
        "Project Beta",
    ]
    assert result.pages[0].text == (
        "Jordan Sample\n\nSolutions engineer building governed AI agents.\n\n"
        "About\nProject Alpha\nAlpha's demo\nProject Beta\nResume\nEmail\nElsewhere"
    )
    assert "Salesforce rollouts" in result.pages[2].text
    # Never the other language, a file, an email address or another site; the home page linked again is read once.
    assert not any("/portfolio/pt/" in path or path.endswith(".pdf") for path in site.requested)
    assert result.skipped == 0


def test_leaves_a_page_robots_txt_refuses_unread_and_refuses_a_site_it_keeps_us_off(services, site):
    result = read_link(link(site.url("portfolio/home.html")), services)
    refused = read_link(link(site.url("private/page.html")), services)

    # A site that names no language reads its whole sitemap: the English pages here.
    assert [page.title for page in result.pages] == [
        "Jordan Sample",
        "Jordan Sample · Portfolio",
        "Hidden project",
        "About · Jordan Sample",
    ]
    assert result.skipped == 1  # /private/ is disallowed
    assert "/private/notes.html" not in site.requested
    assert refused.outcome == "blocked"


def test_the_command_reads_each_link_and_counts_what_it_read_never_what_it_says(services, tmp_path):
    out = tmp_path / "links.jsonl"
    log = io.StringIO()

    cli.run_portfolio([link("https://github.com/jsample", "GitHub")], out, through(services, github(ACCOUNT)), log=log)

    assert out.read_text().count('"kind":"portfolio"') == 1
    assert log.getvalue().startswith("[1/1] GitHub: ok, 3 pages, ")
    assert "permission sets" not in log.getvalue()


def test_reads_a_sitemap_index_one_level_keeping_the_sites_pages_under_its_language(services):
    index = (
        "<sitemapindex><sitemap><loc>https://jordan.example/pages.xml</loc></sitemap>"
        "<sitemap><loc>https://other.example/pages.xml</loc></sitemap></sitemapindex>"
    )
    pages = (
        "<urlset><url><loc>https://jordan.example/en/about</loc></url>"
        "<url><loc>https://www.jordan.example/en/projects/alpha?ref=x&amp;y=1</loc></url>"
        "<url><loc>https://jordan.example/pt/sobre</loc></url>"
        "<url><loc>https://jordan.example/en/resume.pdf</loc></url></urlset>"
    )

    def handler(request):
        answers = {
            "/robots.txt": "Sitemap: https://jordan.example/index.xml",
            "/index.xml": index,
            "/pages.xml": pages,
        }
        assert request.url.host == "jordan.example", request.url  # another site's sitemap is never read
        return httpx2.Response(200, text=answers[request.url.path])

    services = through(services, handler)
    services = replace(services, robots=type(services.robots)(services.http))

    assert services.robots.check("https://jordan.example/en") is None
    assert _sitemap("https://jordan.example/en", services) == [
        "https://jordan.example/en/about",
        "https://www.jordan.example/en/projects/alpha",
    ]
