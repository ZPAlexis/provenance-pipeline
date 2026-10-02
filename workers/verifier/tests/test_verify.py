from datetime import UTC, datetime, timedelta

import httpx2
import pytest

from verifier import pipeline
from verifier.contract import AtsBoard, Listing, PreviousRead, Target, TrackedPosting, VerifyTarget
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


# Reusing what a page showed last time, when its role links are unchanged.


def previous(check, **changes):
    """What a check would be sent back as at the next run."""
    read = PreviousRead.model_validate(check.model_dump() | {"page_check_id": f"pc:{check.url.rsplit('/', 1)[-1]}"})
    return read.model_copy(update=changes)


def test_a_page_whose_role_links_are_unchanged_reuses_its_listings_without_the_llm(services, site):
    (first,), _, _ = read_all(target(site, "static.html"), services)

    checks, listings, complete = read_all(target(site, "static.html"), services, previous=[previous(first)])

    assert len(services.extractor.calls) == 1
    assert (checks[0].method, checks[0].reused_from) == ("reused", "pc:static.html")
    assert checks[0].listings_read_at == first.listings_read_at
    assert "reused, not read again" in checks[0].notes
    assert (listings, complete) == (first.listings, True)


@pytest.mark.parametrize("change", ["a role gone", "a role added", "a role replaced"])
def test_a_page_whose_role_links_changed_is_read_again(services, site, change):
    (first,), _, _ = read_all(target(site, "static.html"), services)
    old = Listing(title="Office Manager", url=site.url("jobs/office-manager"))
    listings = {
        "a role gone": first.listings + [old],  # was on the page last time, not now
        "a role added": first.listings[1:],  # on the page now, not last time
        "a role replaced": first.listings[1:] + [old],
    }[change]

    checks, _, _ = read_all(target(site, "static.html"), services, previous=[previous(first, listings=listings)])

    assert len(services.extractor.calls) == 2
    assert checks[0].method == "render+llm"


def test_roles_without_links_are_reused_only_while_the_pages_text_is_unchanged(services, site):
    (first,), _, _ = read_all(target(site, "static.html"), services)
    unlinked = [listing.model_copy(update={"url": None}) for listing in first.listings]

    same, _, _ = read_all(target(site, "static.html"), services, previous=[previous(first, listings=unlinked)])
    changed = previous(first, listings=unlinked, content_hash="sha256:other")
    other, _, _ = read_all(target(site, "static.html"), services, previous=[changed])

    assert (same[0].method, other[0].method) == ("reused", "render+llm")


def test_listings_are_read_again_once_they_are_two_weeks_old(services, site):
    (first,), _, _ = read_all(target(site, "static.html"), services)
    stale = (datetime.now(UTC) - timedelta(days=15)).isoformat(timespec="seconds")

    checks, _, _ = read_all(target(site, "static.html"), services, previous=[previous(first, listings_read_at=stale)])

    assert checks[0].method == "render+llm"


def test_each_page_of_a_list_is_judged_on_its_own(services, site):
    first_run, first_listings, _ = read_all(target(site, "paged/1.html"), services)

    # Page 2 is as it was; page 1 has no read on record.
    checks, listings, complete = read_all(target(site, "paged/1.html"), services, previous=[previous(first_run[1])])

    assert [check.method for check in checks] == ["render+llm", "reused"]
    assert len(services.extractor.calls) == 3
    assert (listings, complete) == (first_listings, True)


# Reading a confirmed board in place of the page.

GREENHOUSE_JOBS = {
    "jobs": [{"title": "RevOps Engineer", "location": {"name": "Remote"}, "absolute_url": "https://x/1"}]
}


def test_reads_a_confirmed_board_in_place_of_the_page_without_rendering(services, monkeypatch):
    monkeypatch.setattr(pipeline, "render", lambda browser, url: (_ for _ in ()).throw(AssertionError("rendered")))
    services.http = httpx2.Client(
        transport=httpx2.MockTransport(lambda request: httpx2.Response(200, json=GREENHOUSE_JOBS))
    )
    company = VerifyTarget(
        id="c1",
        url="https://acme.example/careers",
        board=AtsBoard(vendor="greenhouse", board="acme"),
        postings=postings("RevOps Engineer", "Designer"),
    )

    result = verify_company(company, services, Matcher())

    assert (result.complete, result.checks[0].method) == (True, "ats_api:greenhouse")
    assert result.checks[0].url == "https://job-boards.greenhouse.io/acme"
    assert "in place of https://acme.example/careers" in result.checks[0].notes
    assert [v.verdict for v in result.verdicts] == ["verified_live", "not_found"]


@pytest.mark.parametrize(
    ("status", "body", "reason"), [(200, {"jobs": []}, "board_empty"), (500, {}, "board_unreadable")]
)
def test_reads_the_page_when_its_confirmed_board_lists_nothing_or_fails(services, site, status, body, reason):
    services.http = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(status, json=body)))
    company = VerifyTarget(
        id="c1",
        url=site.url("static.html"),
        board=AtsBoard(vendor="greenhouse", board="acme"),
        postings=postings("Solutions Engineer"),
    )

    result = verify_company(company, services, Matcher())

    assert (result.checks[0].method, result.checks[0].url) == ("render+llm", site.url("static.html"))
    assert result.checks[0].notes.startswith(
        f"The company's confirmed board (greenhouse/acme) could not be used ({reason})"
    )
    assert [v.verdict for v in result.verdicts] == ["verified_live"]
