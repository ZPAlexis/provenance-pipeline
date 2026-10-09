import json

import httpx2
import pytest

from verifier import ats
from verifier.contract import AtsBoard


@pytest.mark.parametrize(
    ("url", "vendor", "board"),
    [
        ("https://boards.greenhouse.io/acme", "greenhouse", "acme"),
        ("https://job-boards.greenhouse.io/acme/jobs/123", "greenhouse", "acme"),
        ("https://boards.greenhouse.io/embed/job_board?for=acme&b=https%3A%2F%2Facme.example", "greenhouse", "acme"),
        ("https://boards.greenhouse.io/embed/job_board/js?for=acme", "greenhouse", "acme"),
        ("https://jobs.lever.co/acme", "lever", "acme"),
        ("https://jobs.eu.lever.co/acme/abc-123", "lever", "acme"),
        ("https://jobs.ashbyhq.com/acme", "ashby", "acme"),
        ("https://jobs.ashbyhq.com/acme/embed?version=2", "ashby", "acme"),
        ("https://acme.wd3.myworkdayjobs.com/External", "workday", "acme.wd3/External"),
        ("https://acme.wd1.myworkdayjobs.com/en-US/Careers/job/Remote/Engineer_R1", "workday", "acme.wd1/Careers"),
    ],
)
def test_detects_known_boards(url, vendor, board):
    assert ats.detect(["https://acme.example/careers", url]) == AtsBoard(vendor=vendor, board=board)


def test_detects_nothing_on_an_own_domain_page():
    assert ats.detect(["https://acme.example/careers", "https://cdn.acme.example/app.js"]) is None


def test_ignores_a_greenhouse_embed_without_a_board_name():
    assert ats.detect(["https://boards.greenhouse.io/embed/job_board"]) is None


def test_does_not_mistake_workdays_own_api_for_a_board():
    assert ats.detect(["https://acme.wd1.myworkdayjobs.com/wday/cxs/acme/Careers/jobs"]) is None


def test_knows_where_each_vendor_api_lives():
    assert ats.api_url(AtsBoard(vendor="greenhouse", board="acme")) == (
        "https://boards-api.greenhouse.io/v1/boards/acme/jobs"
    )
    assert ats.api_url(AtsBoard(vendor="workday", board="acme.wd1/Careers")) == (
        "https://acme.wd1.myworkdayjobs.com/wday/cxs/acme/Careers/jobs"
    )
    assert ats.api_host(AtsBoard(vendor="lever", board="acme")) == "api.lever.co"


# Workday's jobs endpoint sits on the company's own careers host, so it answers to
# that host's robots.txt; the vendors' documented public APIs are not crawled pages.
def test_only_workday_is_on_the_companys_own_host():
    assert ats.on_company_host(AtsBoard(vendor="workday", board="acme.wd1/Careers"))
    assert not ats.on_company_host(AtsBoard(vendor="greenhouse", board="acme"))


def client_returning(payload, seen=None):
    def handler(request):
        if seen is not None:
            seen.append(str(request.url))
        return httpx2.Response(200, json=payload)

    return httpx2.Client(transport=httpx2.MockTransport(handler))


def test_reads_a_greenhouse_board():
    seen = []
    payload = {
        "jobs": [
            {
                "title": "RevOps Engineer",
                "absolute_url": "https://boards.greenhouse.io/acme/jobs/1",
                "location": {"name": "Remote - Americas"},
            },
            {
                "title": "Office Manager",
                "absolute_url": "https://boards.greenhouse.io/acme/jobs/2",
                "location": {"name": "Testville"},
            },
        ],
        "meta": {"total": 2},
    }

    listings = ats.fetch_listings(AtsBoard(vendor="greenhouse", board="acme"), client_returning(payload, seen))

    assert seen == ["https://boards-api.greenhouse.io/v1/boards/acme/jobs"]
    assert [(listing.title, listing.work_mode) for listing in listings] == [
        ("RevOps Engineer", "remote"),
        ("Office Manager", "unknown"),
    ]


def test_reads_an_ashby_board_and_skips_unlisted_jobs():
    payload = {
        "jobs": [
            {
                "title": "GTM Engineer",
                "jobUrl": "https://jobs.ashbyhq.com/acme/1",
                "location": "Remote",
                "isListed": True,
                "isRemote": True,
                "workplaceType": None,
            },
            {
                "title": "Hidden Role",
                "jobUrl": "https://jobs.ashbyhq.com/acme/2",
                "location": "Remote",
                "isListed": False,
                "isRemote": True,
                "workplaceType": "Remote",
            },
            {
                "title": "Field Engineer",
                "jobUrl": "https://jobs.ashbyhq.com/acme/3",
                "location": "Testville",
                "isListed": True,
                "isRemote": False,
                "workplaceType": "OnSite",
            },
        ]
    }

    listings = ats.fetch_listings(AtsBoard(vendor="ashby", board="acme"), client_returning(payload))

    assert [(listing.title, listing.work_mode) for listing in listings] == [
        ("GTM Engineer", "remote"),
        ("Field Engineer", "onsite"),
    ]


def test_reads_a_lever_board():
    seen = []
    payload = [
        {
            "text": "Sales Engineer",
            "hostedUrl": "https://jobs.lever.co/acme/1",
            "workplaceType": "unspecified",
            "categories": {"location": "Testville"},
        }
    ]

    listings = ats.fetch_listings(AtsBoard(vendor="lever", board="acme"), client_returning(payload, seen))

    assert seen == ["https://api.lever.co/v0/postings/acme?mode=json"]
    assert [(listing.title, listing.location, listing.work_mode) for listing in listings] == [
        ("Sales Engineer", "Testville", "unknown")
    ]


def test_raises_on_a_vendor_api_error():
    client = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(404)))

    with pytest.raises(httpx2.HTTPStatusError):
        ats.fetch_listings(AtsBoard(vendor="greenhouse", board="gone"), client)


def workday_handler(total, offsets=None):
    def handler(request):
        offset = json.loads(request.content)["offset"]
        if offsets is not None:
            offsets.append(offset)
        postings = [
            {
                "title": f"Role {offset + i}",
                "externalPath": f"/job/Remote/Role_R{offset + i}",
                "locationsText": "Testville",
            }
            for i in range(min(20, total - offset))
        ]
        return httpx2.Response(200, json={"total": total if offset == 0 else 0, "jobPostings": postings})

    return handler


# A board larger than the reader's guard is never passed off as the whole list.
def test_a_workday_board_larger_than_the_guard_comes_back_as_a_part(monkeypatch):
    monkeypatch.setattr(ats, "WORKDAY_MAX_PAGES", 2)
    client = httpx2.Client(transport=httpx2.MockTransport(workday_handler(45)))

    with pytest.raises(ats.IncompleteBoard) as cut:
        ats.fetch_listings(AtsBoard(vendor="workday", board="acme.wd1/Careers"), client)

    assert (len(cut.value.listings), cut.value.total) == (40, 45)


def test_reads_every_page_of_a_workday_board():
    offsets, pauses = [], []

    def handler(request):
        offset = json.loads(request.content)["offset"]
        offsets.append(offset)
        count = min(20, 45 - offset)
        postings = [
            {
                "title": f"Role {offset + i}",
                "externalPath": f"/job/Remote/Role_R{offset + i}",
                "locationsText": "Remote" if offset + i == 0 else "Testville",
            }
            for i in range(count)
        ]
        # Like the real API, the total arrives on the first page only.
        return httpx2.Response(200, json={"total": 45 if offset == 0 else 0, "jobPostings": postings})

    client = httpx2.Client(transport=httpx2.MockTransport(handler))
    board = AtsBoard(vendor="workday", board="acme.wd1/Careers")

    listings = ats.fetch_listings(board, client, pause=lambda: pauses.append(1))

    assert offsets == [0, 20, 40]
    assert len(listings) == 45
    assert len(pauses) == 2  # spaced between pages, not before the first
    assert listings[0].url == "https://acme.wd1.myworkdayjobs.com/Careers/job/Remote/Role_R0"
    assert (listings[0].work_mode, listings[1].work_mode) == ("remote", "unknown")


def test_derives_board_name_candidates_from_domain_and_name():
    assert ats.board_candidates("www.acme-robotics.example", "Acme Robotics, Inc.") == [
        "acme-robotics",
        "acmerobotics",
        "acme",
    ]
    assert ats.board_candidates(None, None) == []


def test_finds_the_first_guessed_board_that_actually_lists_jobs():
    waited = []

    def handler(request):
        url = str(request.url)
        if url == "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs":
            return httpx2.Response(200, json={"jobs": []})  # exists, but lists nothing
        if url == "https://api.lever.co/v0/postings/acme?mode=json":
            return httpx2.Response(200, json=[{"text": "Sales Engineer", "hostedUrl": "https://jobs.lever.co/acme/1"}])
        return httpx2.Response(404)

    client = httpx2.Client(transport=httpx2.MockTransport(handler))

    board, listings = ats.find_board(["acme", "acmerobotics"], client, wait=waited.append)

    assert board == AtsBoard(vendor="lever", board="acme")
    assert [listing.title for listing in listings] == ["Sales Engineer"]
    assert waited == ["boards-api.greenhouse.io", "boards-api.greenhouse.io", "api.lever.co"]


def test_finds_no_board_when_none_lists_jobs():
    client = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(404)))

    assert ats.find_board(["acme"], client, wait=lambda host: None) is None


def test_gives_each_board_the_public_url_a_person_would_visit():
    assert ats.board_url(AtsBoard(vendor="greenhouse", board="acme")) == "https://job-boards.greenhouse.io/acme"
    assert ats.board_url(AtsBoard(vendor="lever", board="acme")) == "https://jobs.lever.co/acme"
    assert ats.board_url(AtsBoard(vendor="ashby", board="acme")) == "https://jobs.ashbyhq.com/acme"
    assert ats.board_url(AtsBoard(vendor="workday", board="acme.wd1/Careers")) == (
        "https://acme.wd1.myworkdayjobs.com/Careers"
    )


# Greenhouse's board record carries the company's name, which confirms a guess.
def test_reads_the_company_name_greenhouse_records_for_a_board():
    client = client_returning({"name": "Acme Robotics", "content": "<p>Hi</p>"})

    assert ats.board_name(AtsBoard(vendor="greenhouse", board="acme"), client) == "Acme Robotics"
    assert ats.board_name(AtsBoard(vendor="lever", board="acme"), client) is None  # Lever has no such record


def test_board_name_is_none_when_the_record_cannot_be_read():
    client = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(404)))

    assert ats.board_name(AtsBoard(vendor="greenhouse", board="acme"), client) is None


def test_matches_company_names_ignoring_case_punctuation_and_legal_suffixes_only():
    assert ats.names_match("Acme Robotics", "Acme Robotics, Inc.")
    assert ats.names_match("ACME ROBOTICS LLC", "acme robotics")
    # Found in the resolution test: a board recording "Goodwin" was another company than "Goodwin Recruiting".
    assert not ats.names_match("Goodwin", "Goodwin Recruiting")
    assert not ats.names_match("Acme Robotics", "Apex Robotics")
    assert not ats.names_match(None, "Acme")


def test_keeps_department_and_employment_type_where_the_vendor_records_them():
    lever = [{"text": "RevOps Engineer", "categories": {"team": "Revenue", "commitment": "Full-time"}}]
    ashby = {"jobs": [{"title": "GTM Analyst", "department": "Sales", "employmentType": "Contract"}]}

    def handler(request):
        return httpx2.Response(200, json=lever if "lever" in request.url.host else ashby)

    client = httpx2.Client(transport=httpx2.MockTransport(handler))
    (from_lever,) = ats.fetch_listings(AtsBoard(vendor="lever", board="acme"), client)
    (from_ashby,) = ats.fetch_listings(AtsBoard(vendor="ashby", board="acme"), client)

    assert (from_lever.department, from_lever.employment_type) == ("Revenue", "full_time")
    assert (from_ashby.department, from_ashby.employment_type) == ("Sales", "contract")


def test_finds_every_guessed_board_that_lists_jobs():
    def handler(request):
        url = str(request.url)
        if url == "https://boards-api.greenhouse.io/v1/boards/acme/jobs":
            return httpx2.Response(200, json={"jobs": [{"title": "Line Cook", "absolute_url": "https://x/1"}]})
        if url == "https://api.ashbyhq.com/posting-api/job-board/acme":
            return httpx2.Response(200, json={"jobs": [{"title": "Sales Engineer", "jobUrl": "https://x/2"}]})
        return httpx2.Response(404)

    client = httpx2.Client(transport=httpx2.MockTransport(handler))

    found = list(ats.guessed_boards(["acme"], client, wait=lambda host: None))

    assert [board for board, _ in found] == [
        AtsBoard(vendor="greenhouse", board="acme"),
        AtsBoard(vendor="ashby", board="acme"),
    ]


def test_a_workday_request_that_fails_once_is_asked_again(monkeypatch):
    calls = []
    handler = workday_handler(45)

    def flaky(request):
        calls.append(json.loads(request.content)["offset"])
        return httpx2.Response(503) if len(calls) == 2 else handler(request)

    client = httpx2.Client(transport=httpx2.MockTransport(flaky))

    listings = ats.fetch_listings(AtsBoard(vendor="workday", board="acme.wd1/Careers"), client)

    assert (len(listings), calls) == (45, [0, 20, 20, 40])


# Found with Baker Hughes: one failed request among dozens threw the whole board away.
def test_a_workday_board_that_keeps_failing_partway_keeps_what_was_read():
    handler = workday_handler(45)

    def failing_after_first(request):
        offset = json.loads(request.content)["offset"]
        return handler(request) if offset == 0 else httpx2.Response(503)

    client = httpx2.Client(transport=httpx2.MockTransport(failing_after_first))

    with pytest.raises(ats.IncompleteBoard) as cut:
        ats.fetch_listings(AtsBoard(vendor="workday", board="acme.wd1/Careers"), client)

    assert (len(cut.value.listings), cut.value.total) == (20, 45)


def test_a_workday_board_that_fails_on_its_first_page_fails():
    client = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(503)))

    with pytest.raises(httpx2.HTTPError):
        ats.fetch_listings(AtsBoard(vendor="workday", board="acme.wd1/Careers"), client)


# --- Oracle Cloud HCM ----------------------------------------------------------------

ORACLE_PAGE = (
    "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/pt-BR/sites/CX_4001/jobs"
    "?location=Brasil&locationId=300000000314829&locationLevel=country&mode=job-location"
)


def test_detects_an_oracle_cloud_site_with_the_place_its_page_is_filtered_to():
    assert ats.detect([ORACLE_PAGE]) == AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001/300000000314829")
    # A role's own page names the site alone: its whole list.
    job = "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/pt-BR/sites/CX_4001/job/41966"
    assert ats.detect([job]) == AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001")
    assert ats.on_company_host(AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001"))
    assert ats.board_url(AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001/300000000314829")) == (
        "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_4001/jobs?locationId=300000000314829"
    )


def oracle_handler(total, finders, roles=None):
    def handler(request):
        finder = request.url.params["finder"]
        finders.append(finder)
        offset = int(next(part for part in finder.split(",") if part.startswith("offset=")).split("=")[1])
        jobs = roles or [
            {"Id": str(40000 + offset + i), "Title": f"Role {offset + i}", "PrimaryLocation": "Contagem, MG, Brazil",
             "WorkplaceType": "", "secondaryLocations": []}
            for i in range(min(ats.ORACLE_PAGE_SIZE, total - offset))
        ]  # fmt: skip
        return httpx2.Response(200, json={"items": [{"TotalJobsCount": total, "requisitionList": jobs}]})

    return handler


def test_reads_every_page_of_an_oracle_site_with_its_pages_filter():
    finders, pauses = [], []
    client = httpx2.Client(transport=httpx2.MockTransport(oracle_handler(115, finders)))
    board = AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001/300000000314829")

    listings = ats.fetch_listings(board, client, pause=lambda: pauses.append(1))

    assert len(listings) == 115 and len(pauses) == 1
    assert finders[0] == (
        "findReqs;siteNumber=CX_4001,limit=100,offset=0,sortBy=POSTING_DATES_DESC,locationId=300000000314829"
    )
    assert "offset=100" in finders[1]
    assert listings[0].url == "https://emfg.fa.em4.oraclecloud.com/hcmUI/CandidateExperience/en/sites/CX_4001/job/40000"


def test_an_oracle_role_keeps_every_place_it_is_listed_for_and_its_stated_work_mode():
    role = {
        "Id": "41712",
        "Title": "Arquiteto de Soluções Especialista",
        "PrimaryLocation": "Belo Horizonte, MG, Brazil",
        "WorkplaceType": "Hybrid",
        "JobSchedule": "Full time",
        "secondaryLocations": [{"Name": "Barra Mansa, RJ, Brazil"}, {"Name": "Belo Horizonte, MG, Brazil"}],
    }
    client = httpx2.Client(transport=httpx2.MockTransport(oracle_handler(1, [], roles=[role])))

    (listing,) = ats.fetch_listings(AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001"), client)

    assert listing.location == "Belo Horizonte, MG, Brazil; Barra Mansa, RJ, Brazil"
    assert (listing.work_mode, listing.employment_type) == ("hybrid", "full_time")


def test_an_oracle_site_larger_than_the_guard_comes_back_as_a_part(monkeypatch):
    monkeypatch.setattr(ats, "ORACLE_MAX_PAGES", 1)
    client = httpx2.Client(transport=httpx2.MockTransport(oracle_handler(115, [])))

    with pytest.raises(ats.IncompleteBoard) as cut:
        ats.fetch_listings(AtsBoard(vendor="oracle", board="emfg.fa.em4/CX_4001"), client)

    assert (len(cut.value.listings), cut.value.total) == (100, 115)
