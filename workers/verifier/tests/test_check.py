import httpx2
import pytest

from verifier import check as check_module
from verifier.check import CLOSED, check_posting
from verifier.contract import TrackedPosting, VerifyTarget
from verifier.match import Matcher


def role(site, title, page=None, **fields):
    """A company watching static.html, with one tracked role whose own page is `page` (a path, or a full URL)."""
    url = page if page is None or page.startswith("http") else site.url(page)
    return VerifyTarget(
        id="c1", url=site.url("static.html"), postings=[TrackedPosting(id="p1", title=title, url=url, **fields)]
    )


def only(result):
    assert len(result.verdicts) == 1
    return result.verdicts[0]


def test_a_role_whose_own_page_is_clearly_up_is_still_listed_without_reading_the_careers_page(services, site):
    result = check_posting(role(site, "Solutions Engineer", "jobs/open-role.html"), services, Matcher())

    verdict = only(result)
    assert (verdict.verdict, verdict.method) == ("verified_live", "posting_page")
    assert verdict.reasoning == f"Its own page is up and shows the role ({site.url('jobs/open-role.html')})."
    assert [check.url for check in result.checks] == [site.url("jobs/open-role.html")]
    assert services.extractor.calls == []  # nothing read by the LLM
    assert result.complete is False


@pytest.mark.parametrize(
    ("page", "why", "reason"),
    [
        ("jobs/closed-role.html", "says the role is closed", "says_closed"),
        ("jobs/gone.html", "is gone (HTTP 404)", "http_404"),
        ("jobs/other-role.html", "does not show the role", "role_not_shown"),
    ],
)
def test_a_role_whose_own_page_is_not_clearly_up_is_looked_for_on_the_careers_page(services, site, page, why, reason):
    result = check_posting(role(site, "Solutions Engineer", page), services, Matcher())

    verdict = only(result)
    assert verdict.verdict == "verified_live"  # static.html still lists "Solutions Engineer"
    assert verdict.listing.url == site.url("jobs/solutions-engineer")  # found again under its listed link
    assert verdict.reasoning.startswith(f"The role's own page {why}, so its company's careers page was checked.")
    assert [check.url for check in result.checks] == [site.url("static.html"), site.url(page)]
    assert result.checks[-1].reason == reason


def test_a_role_whose_address_now_leads_elsewhere_is_looked_for_on_the_careers_page(services, site):
    result = check_posting(role(site, "Solutions Engineer", "jobs/moved.html"), services, Matcher())

    assert result.checks[-1].reason == "redirected"
    assert only(result).reasoning.startswith(f"The role's own page now leads to {site.url('static.html')}")


# A gone page alone never says a role is no longer listed: the careers page's whole list does.
def test_a_role_gone_from_its_own_page_and_from_the_whole_list_is_no_longer_listed(services, site):
    result = check_posting(role(site, "Designer", "jobs/gone.html"), services, Matcher())

    assert (only(result).verdict, result.complete) == ("not_found", True)


def test_a_role_with_no_page_of_its_own_on_record_is_looked_for_on_the_careers_page(services, site):
    result = check_posting(role(site, "GTM Systems Analyst"), services, Matcher())

    assert only(result).verdict == "verified_live"
    assert only(result).reasoning.startswith("The role's own page is not on record")


def greenhouse(*jobs):
    payload = {"jobs": [{"title": title, "absolute_url": url, "location": {"name": "Remote"}} for title, url in jobs]}
    return httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(200, json=payload)))


@pytest.fixture
def never_rendered(monkeypatch):
    monkeypatch.setattr(check_module, "render", lambda *args: (_ for _ in ()).throw(AssertionError("rendered")))
    monkeypatch.setattr("verifier.pipeline.render", lambda *args: (_ for _ in ()).throw(AssertionError("rendered")))


# A role on a known ATS is settled by its board's whole list, free, either way.
@pytest.mark.parametrize(
    ("jobs", "expected", "method"),
    [
        ([("Account Executive", "https://job-boards.greenhouse.io/acme/jobs/7")], "verified_live", "link"),
        ([("Office Manager", "https://job-boards.greenhouse.io/acme/jobs/8")], "not_found", "none"),
    ],
)
def test_a_role_on_a_known_board_is_settled_by_the_boards_whole_list(
    services, site, never_rendered, jobs, expected, method
):
    services.http = greenhouse(*jobs)
    target = role(site, "Senior Account Executive", "https://job-boards.greenhouse.io/acme/jobs/7")

    result = check_posting(target, services, Matcher())

    assert (only(result).verdict, only(result).method, result.complete) == (expected, method, True)
    assert [check.url for check in result.checks] == ["https://job-boards.greenhouse.io/acme"]


def test_a_known_board_that_cannot_be_read_hands_over_to_the_careers_page(services, site):
    services.http = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(500)))
    target = role(site, "Solutions Engineer", "https://job-boards.greenhouse.io/acme/jobs/7")

    result = check_posting(target, services, Matcher())

    assert only(result).verdict == "verified_live"
    assert only(result).reasoning.startswith("The role's own page is on a greenhouse board that could not be read")
    assert (result.checks[-1].outcome, result.checks[-1].reason) == ("error", "board_unreadable")


def test_a_check_is_of_exactly_one_posting(services, site):
    target = role(site, "Solutions Engineer").model_copy(
        update={"postings": [TrackedPosting(id="p1", title="A"), TrackedPosting(id="p2", title="B")]}
    )

    with pytest.raises(ValueError, match="exactly one posting"):
        check_posting(target, services, Matcher())


@pytest.mark.parametrize(
    "text",
    [
        "This job is no longer accepting applications.",
        "The position has been filled.",
        "Esta vaga foi encerrada.",
        "Vaga não está mais disponível",
        "Esta oferta ha expirado.",
        "La vacante ya no está disponible.",
    ],
)
def test_knows_how_a_closed_role_is_worded(text):
    assert CLOSED.search(text)


def test_does_not_mistake_an_open_role_for_a_closed_one():
    assert not CLOSED.search("We are hiring! Applications are open until the role is filled by the right person.")


# Found with Databricks: its job address redirects to a canonical one carrying the same gh_jid.
def test_a_role_whose_address_redirects_but_keeps_its_id_is_answered_by_its_own_page(services, site):
    result = check_posting(role(site, "Solutions Engineer", "jobs/role-8747434.html"), services, Matcher())

    assert (only(result).verdict, only(result).method) == ("verified_live", "posting_page")
    assert services.extractor.calls == []


# A role added without a title: its own page names it, and the verdict carries the name.
def test_a_role_added_without_a_title_is_named_by_its_pages_heading_for_free(services, site):
    target = role(site, "(title pending)", "jobs/open-role.html", title_from_page=True)

    result = check_posting(target, services, Matcher())

    verdict = only(result)
    assert (verdict.verdict, verdict.listing.title) == ("verified_live", "Solutions Engineer")
    assert verdict.reasoning.startswith('Its own page is up and names the role "Solutions Engineer", as its heading')
    assert services.extractor.calls == []  # nothing read by the LLM


def test_a_role_whose_heading_names_only_the_company_is_named_by_one_llm_read(services, site):
    target = role(site, "(title pending)", "jobs/untitled-role.html", title_from_page=True)
    target = target.model_copy(update={"name": "Example Co"})

    result = check_posting(target, services, Matcher())

    verdict = only(result)
    assert (verdict.verdict, verdict.listing.title) == ("verified_live", "Data Analyst")
    assert "as the LLM read it" in verdict.reasoning
    assert len(services.extractor.calls) == 1
    assert result.checks[0].method == "render+llm" and result.checks[0].llm is not None
