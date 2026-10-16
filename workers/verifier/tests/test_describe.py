import json
from dataclasses import replace

import httpx2

from verifier.contract import DescribeTarget
from verifier.describe import MAX_CHARS, describe_role


def role(url):
    return DescribeTarget(id="p1", url=url, label="Acme / Sales Engineer")


def through(services, handler):
    """The services with every HTTP request answered by `handler`; the browser is never used."""
    return replace(services, http=httpx2.Client(transport=httpx2.MockTransport(handler)))


def answering(routes):
    def handler(request):
        for prefix, payload in routes.items():
            if str(request.url).startswith(prefix):
                return httpx2.Response(200, json=payload) if payload is not None else httpx2.Response(404)
        if request.url.path == "/robots.txt":
            return httpx2.Response(404)  # no robots.txt: everything allowed
        raise AssertionError(f"unexpected request {request.url}")

    return handler


def test_reads_a_greenhouse_role_through_its_job_api_as_plain_text(services):
    api = "https://boards-api.greenhouse.io/v1/boards/acme/jobs/4012345"
    content = "&lt;p&gt;You will run technical discovery.&lt;/p&gt;&lt;ul&gt;&lt;li&gt;Five years&lt;/li&gt;&lt;/ul&gt;"
    result = describe_role(
        role("https://job-boards.greenhouse.io/acme/jobs/4012345?gh_src=x"),
        through(services, answering({api: {"content": content}})),
    )

    assert (result.outcome, result.read_via) == ("ok", "ats_api:greenhouse")
    assert result.text == "You will run technical discovery.\n\n- Five years"
    assert result.content_hash.startswith("sha256:")


def test_reads_lever_and_ashby_roles_through_their_apis(services):
    lever_id, ashby_id = "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b", "11111111-2222-3333-4444-555555555555"
    routes = {
        f"https://api.lever.co/v0/postings/acme/{lever_id}": {
            "descriptionPlain": "About the role.",
            "lists": [{"text": "You will", "content": "<li>Demo the product</li>"}],
            "additionalPlain": "Remote in Brazil.",
        },
        "https://api.ashbyhq.com/posting-api/job-board/acme": {
            "jobs": [
                {"id": "other", "descriptionPlain": "Not this one."},
                {"id": ashby_id, "descriptionPlain": "Ashby text."},
            ]
        },
    }
    lever = describe_role(role(f"https://jobs.lever.co/acme/{lever_id}"), through(services, answering(routes)))
    ashby = describe_role(role(f"https://jobs.ashbyhq.com/acme/{ashby_id}"), through(services, answering(routes)))

    assert (lever.read_via, lever.text) == (
        "ats_api:lever",
        "About the role.\n\nYou will\n\n- Demo the product\n\nRemote in Brazil.",
    )
    assert (ashby.read_via, ashby.text) == ("ats_api:ashby", "Ashby text.")


def test_reads_workday_and_oracle_roles_through_the_endpoints_their_sites_call(services):
    routes = {
        "https://acme.wd1.myworkdayjobs.com/wday/cxs/acme/External/job/Sao-Paulo/Sales-Engineer_R1": {
            "jobPostingInfo": {"jobDescription": "<p>Workday text.</p>"}
        },
        "https://emfg.fa.em4.oraclecloud.com/hcmRestApi/resources/latest/recruitingCEJobRequisitionDetails": {
            "items": [
                {"ExternalDescriptionStr": "<p>Oracle text.</p>", "ExternalQualificationsStr": "<p>Engineering.</p>"}
            ]
        },
    }
    workday = describe_role(
        role("https://acme.wd1.myworkdayjobs.com/en-US/External/job/Sao-Paulo/Sales-Engineer_R1"),
        through(services, answering(routes)),
    )
    oracle = describe_role(
        role("https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/pt-BR/sites/CX_4001/job/41966"),
        through(services, answering(routes)),
    )

    assert (workday.read_via, workday.text) == ("ats_api:workday", "Workday text.")
    assert (oracle.read_via, oracle.text) == ("ats_api:oracle", "Oracle text.\n\nEngineering.")


def test_a_role_its_board_no_longer_has_is_gone(services):
    routes = {
        "https://boards-api.greenhouse.io/v1/boards/acme/jobs/1": None,
        "https://api.ashbyhq.com/posting-api/job-board/acme": {"jobs": []},
    }

    greenhouse = describe_role(
        role("https://job-boards.greenhouse.io/acme/jobs/1"), through(services, answering(routes))
    )
    ashby = describe_role(
        role("https://jobs.ashbyhq.com/acme/11111111-2222-3333-4444-555555555555"), through(services, answering(routes))
    )

    assert (greenhouse.outcome, greenhouse.reason) == ("gone", "http_404")
    assert (ashby.outcome, ashby.reason) == ("gone", "not_on_its_board")
    assert greenhouse.text is None


def test_renders_a_role_on_its_own_site_and_keeps_its_main_text(services, site):
    result = describe_role(role(site.url("jobs/described-role.html")), services)

    assert (result.outcome, result.read_via) == ("ok", "render")
    assert result.text == (
        "Sales Engineer\n\nYou will run technical discovery with prospects.\n\n"
        "Five years in pre-sales\nPortuguese and English"
    )
    assert "Privacy" not in result.text  # the footer is not the description


def test_keeps_all_of_a_page_that_marks_no_main_content(services, site):
    result = describe_role(role(site.url("jobs/open-role.html")), services)

    assert result.text.startswith("Solutions Engineer\n\nTestville")


def test_never_reads_a_page_robots_txt_keeps_us_off_and_says_when_there_is_none(services, site):
    blocked = describe_role(role(site.url("private/role.html")), services)
    none = describe_role(DescribeTarget(id="p1", url=None), services)

    assert blocked.outcome == "blocked"
    assert (none.outcome, none.reason) == ("no_page", "no_page_on_record")


def test_a_gone_page_is_said_so(services, site):
    assert describe_role(role(site.url("jobs/gone.html")), services).outcome == "gone"


def test_cuts_a_text_longer_than_any_description_and_says_so(services):
    api = "https://boards-api.greenhouse.io/v1/boards/acme/jobs/2"
    long_text = "&lt;p&gt;" + ("word " * (MAX_CHARS // 4)) + "&lt;/p&gt;"
    result = describe_role(
        role("https://job-boards.greenhouse.io/acme/jobs/2"),
        through(services, answering({api: {"content": long_text}})),
    )

    assert (len(result.text), result.reason) == (MAX_CHARS, "cut_at_limit")
    assert json.loads(result.model_dump_json())["kind"] == "description"
