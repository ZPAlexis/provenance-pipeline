import httpx2

from verifier import pipeline
from verifier.contract import Target, TrackedPosting, VerifyTarget
from verifier.match import Matcher
from verifier.pipeline import read_all
from verifier.render import render
from verifier.verify import verify_company


def target(site, path):
    return Target(id="c1", url=site.url(path))


def test_clicks_load_more_until_the_list_stops_growing(browser, site):
    page = render(browser, site.url("loadmore.html"))

    assert page.load_more_clicks == 1
    assert [text for text, href in page.links if "/jobs/" in href] == [
        "RevOps Engineer",
        "GTM Analyst",
        "Solutions Engineer",
        "Data Engineer",
    ]


def test_reads_a_list_shown_behind_load_more_as_whole(services, site):
    checks, listings, complete = read_all(target(site, "loadmore.html"), services)

    assert (len(checks), len(listings), complete) == (1, 4, True)


def test_follows_a_list_to_its_next_page_and_reads_it_whole(services, site):
    checks, listings, complete = read_all(target(site, "paged/1.html"), services)

    assert [check.url for check in checks] == [site.url("paged/1.html"), site.url("paged/2.html")]
    assert [listing.title for listing in listings] == [
        "RevOps Engineer",
        "GTM Analyst",
        "Solutions Engineer",
        "Data Engineer",
    ]
    assert complete


def test_a_list_cut_short_by_the_page_cap_is_not_whole(services, site):
    checks, listings, complete = read_all(target(site, "paged/1.html"), services, max_pages=1)

    assert (len(checks), len(listings), complete) == (1, 2, False)


def test_a_next_link_that_leads_back_is_followed_once_and_never_called_whole(services, site):
    checks, _, complete = read_all(target(site, "loop/1.html"), services)

    assert len(checks) == 1
    assert not complete


def test_one_jobs_posting_is_never_a_whole_list(services, site):
    checks, _, complete = read_all(target(site, "jobpost.html"), services)

    assert checks[0].single_job_posting
    assert not complete


def test_reads_a_known_boards_address_through_its_api_without_rendering(services, monkeypatch):
    monkeypatch.setattr(pipeline, "render", lambda browser, url: (_ for _ in ()).throw(AssertionError("rendered")))
    monkeypatch.setattr(services.robots, "check", lambda url: "robots_unreachable")
    jobs = {"jobs": [{"title": "RevOps Engineer", "location": {"name": "Remote"}, "absolute_url": "https://x/1"}]}
    services.http = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(200, json=jobs)))

    checks, listings, complete = read_all(
        Target(id="c1", url="https://job-boards.greenhouse.io/acme/jobs/8054669"), services
    )

    assert (checks[0].method, len(listings), complete) == ("ats_api:greenhouse", 1, True)


def postings(*titles):
    return [TrackedPosting(id=f"p{n}", title=title) for n, title in enumerate(titles, start=1)]


def test_verifies_postings_against_every_page_of_the_list(services, site):
    company = VerifyTarget(id="c1", url=site.url("paged/1.html"), postings=postings("Data Engineer", "Designer"))

    result = verify_company(company, services, Matcher())

    assert (result.outcome, result.complete, result.listing_count, len(result.checks)) == ("ok", True, 4, 2)
    assert [v.verdict for v in result.verdicts] == ["verified_live", "not_found"]


# A role on a page we could not reach must never be marked closed.
def test_a_page_cut_short_leaves_unmatched_postings_without_a_verdict(services, site, monkeypatch):
    monkeypatch.setattr(pipeline, "MAX_PAGES", 1)
    company = VerifyTarget(id="c1", url=site.url("paged/1.html"), postings=postings("RevOps Engineer", "Data Engineer"))

    result = verify_company(company, services, Matcher())

    assert [v.verdict for v in result.verdicts] == ["verified_live", None]


def test_a_watched_page_robots_txt_keeps_us_off_makes_every_posting_inaccessible(services, site):
    company = VerifyTarget(id="c1", url=site.url("private/page.html"), postings=postings("RevOps Engineer"))

    result = verify_company(company, services, Matcher())

    assert (result.outcome, result.reason) == ("inaccessible", "robots_disallowed")
    assert [v.verdict for v in result.verdicts] == ["inaccessible"]
    assert services.extractor.calls == []


def test_a_watched_page_that_is_one_jobs_posting_proves_only_that_job(services, site):
    company = VerifyTarget(id="c1", url=site.url("jobpost.html"), postings=postings("GTM Analyst", "Designer"))

    result = verify_company(company, services, Matcher())

    assert result.reason == "single_job_posting"
    assert [v.verdict for v in result.verdicts] == ["verified_live", None]


# Found in the first real run: TCS's careers portal, down for maintenance, read as a whole list of none.
def test_a_rendered_page_that_showed_no_roles_and_did_not_say_so_is_never_a_whole_list(services, site):
    _, listings, complete = read_all(target(site, "maintenance.html"), services)

    assert listings == []
    assert not complete


def test_a_page_that_says_it_has_no_openings_is_a_whole_list_of_none(services, site):
    _, listings, complete = read_all(target(site, "empty.html"), services)

    assert (listings, complete) == ([], True)
