import httpx2
import pytest

from verifier import pipeline
from verifier.contract import LlmUsage, Target
from verifier.extract import ExtractionFailed
from verifier.pipeline import verify_page
from verifier.render import RenderedPage


def target(site, path):
    return Target(id="t1", url=site.url(path))


def test_extracts_listings_from_a_javascript_rendered_page(services, site):
    result = verify_page(target(site, "dynamic.html"), services)

    assert result.outcome == "ok"
    assert result.method == "render+llm"
    assert result.listing_count == 4
    assert result.llm.model == "fake"
    assert result.content_hash.startswith("sha256:")
    assert result.input_truncated is False
    # Link numbers from the model come back as the page's exact URLs.
    assert {listing.url for listing in result.listings} == {
        site.url(f"jobs/{slug}")
        for slug in ("edge-platform-engineer", "revops-lead", "solutions-architect", "data-engineer")
    }


def test_never_requests_a_page_robots_txt_disallows(services, site):
    result = verify_page(target(site, "private/page.html"), services)

    assert (result.outcome, result.reason) == ("blocked", "robots_disallowed")
    assert "/private/page.html" not in site.requested
    assert services.extractor.calls == []


def test_reports_an_http_error_as_inaccessible(services, site):
    result = verify_page(target(site, "no-such-page.html"), services)

    assert (result.outcome, result.reason) == ("inaccessible", "http_404")
    assert result.listing_count is None


def test_reports_a_bot_challenge_as_inaccessible_without_reading_it(services, site):
    result = verify_page(target(site, "challenge.html"), services)

    assert (result.outcome, result.reason) == ("inaccessible", "bot_challenge")
    assert services.extractor.calls == []


# "No openings" must be something the page says, not an absence of evidence.
def test_distinguishes_a_page_that_says_it_has_no_openings(services, site):
    result = verify_page(target(site, "empty.html"), services)

    assert result.outcome == "ok"
    assert result.listing_count == 0
    assert result.explicit_no_openings is True


def test_records_a_failed_extraction_as_an_error_with_what_it_cost(services, site):
    class FailingExtractor:
        def extract(self, page):
            raise ExtractionFailed("llm_refusal", LlmUsage(model="fake", input_tokens=50, cost_usd=0.0001))

    services.extractor = FailingExtractor()
    result = verify_page(target(site, "static.html"), services)

    assert (result.outcome, result.reason) == ("error", "llm_refusal")
    assert result.listing_count is None
    assert result.llm.input_tokens == 50


class TestKnownAtsFastPath:
    LEVER_PAYLOAD = [
        {
            "text": "Account Executive",
            "hostedUrl": "https://jobs.lever.co/acme/1",
            "workplaceType": "remote",
            "categories": {"location": "Remote"},
        },
        {
            "text": "Sales Engineer",
            "hostedUrl": "https://jobs.lever.co/acme/2",
            "workplaceType": "hybrid",
            "categories": {"location": "Testville"},
        },
    ]

    @pytest.fixture
    def lever_page(self, monkeypatch):
        page = RenderedPage(
            final_url="https://careers.acme.example/",
            status=200,
            title="Acme careers",
            text="Open roles",
            urls=["https://careers.acme.example/", "https://jobs.lever.co/acme"],
        )
        monkeypatch.setattr(pipeline, "render", lambda browser, url: page)

    @pytest.fixture
    def no_robots(self, services, monkeypatch):
        monkeypatch.setattr(services.robots, "check", lambda url: None)

    def with_api(self, services, handler):
        services.http = httpx2.Client(transport=httpx2.MockTransport(handler))

    def test_reads_listings_from_the_vendor_api_without_the_llm(self, services, lever_page, no_robots):
        self.with_api(services, lambda request: httpx2.Response(200, json=self.LEVER_PAYLOAD))

        result = verify_page(Target(id="t1", url="https://careers.acme.example/"), services)

        assert result.outcome == "ok"
        assert result.method == "ats_api:lever"
        assert (result.ats.vendor, result.ats.board) == ("lever", "acme")
        assert [listing.work_mode for listing in result.listings] == ["remote", "hybrid"]
        assert result.llm is None
        assert services.extractor.calls == []

    def test_falls_back_to_the_llm_when_the_vendor_api_fails(self, services, lever_page, no_robots):
        self.with_api(services, lambda request: httpx2.Response(503))

        result = verify_page(Target(id="t1", url="https://careers.acme.example/"), services)

        assert result.outcome == "ok"
        assert result.method == "render+llm"
        assert result.reason == "ats_api_failed:lever"
        assert len(services.extractor.calls) == 1

    def workday_page(self, monkeypatch):
        page = RenderedPage(
            final_url="https://acme.wd1.myworkdayjobs.com/Careers",
            status=200,
            title="Careers",
            text="Showing 20 of 2 jobs",
            urls=["https://acme.wd1.myworkdayjobs.com/Careers"],
        )
        monkeypatch.setattr(pipeline, "render", lambda browser, url: page)

    WORKDAY_PAYLOAD = {
        "total": 2,
        "jobPostings": [
            {"title": "RevOps Analyst", "externalPath": "/job/Remote/RevOps-Analyst_R1", "locationsText": "Remote"},
            {
                "title": "Field Engineer",
                "externalPath": "/job/Testville/Field-Engineer_R2",
                "locationsText": "Testville",
            },
        ],
    }

    def test_reads_a_workday_board_through_its_jobs_api(self, services, monkeypatch, no_robots):
        self.workday_page(monkeypatch)
        self.with_api(services, lambda request: httpx2.Response(200, json=self.WORKDAY_PAYLOAD))

        result = verify_page(Target(id="t1", url="https://acme.wd1.myworkdayjobs.com/Careers"), services)

        assert (result.outcome, result.method, result.listing_count) == ("ok", "ats_api:workday", 2)
        assert services.extractor.calls == []

    # The jobs endpoint is on the company's own host, so its robots.txt decides.
    def test_reads_the_rendered_page_when_robots_txt_disallows_the_workday_api(self, services, monkeypatch):
        self.workday_page(monkeypatch)
        monkeypatch.setattr(services.robots, "check", lambda url: "robots_disallowed" if "/wday/" in url else None)
        self.with_api(services, lambda request: pytest.fail("the disallowed API must not be called"))

        result = verify_page(Target(id="t1", url="https://acme.wd1.myworkdayjobs.com/Careers"), services)

        assert (result.outcome, result.method, result.reason) == ("ok", "render+llm", "ats_api_blocked:workday")
        assert len(services.extractor.calls) == 1


class TestRobotsBlockedPages:
    """When robots.txt keeps us off a careers page, look for the company's board on a
    known ATS instead, and say so in the result."""

    def target(self, site):
        return Target(id="t1", url=site.url("private/page.html"), domain="acme.example", name="Acme")

    def test_reads_the_companys_ats_board_instead_and_records_why(self, services, site):
        def handler(request):
            if str(request.url) == "https://api.lever.co/v0/postings/acme?mode=json":
                return httpx2.Response(
                    200, json=[{"text": "Sales Engineer", "hostedUrl": "https://jobs.lever.co/acme/1"}]
                )
            return httpx2.Response(404)

        services.http = httpx2.Client(transport=httpx2.MockTransport(handler))

        result = verify_page(self.target(site), services)

        assert (result.outcome, result.reason) == ("ok", "robots_disallowed_ats_fallback")
        assert (result.method, result.ats.board, result.listing_count) == ("ats_api:lever", "acme", 1)
        assert result.final_url is None  # the page itself was never fetched
        assert "/private/page.html" not in site.requested

    def test_stays_blocked_when_no_board_is_found(self, services, site):
        services.http = httpx2.Client(transport=httpx2.MockTransport(lambda request: httpx2.Response(404)))

        result = verify_page(self.target(site), services)

        assert (result.outcome, result.reason) == ("blocked", "robots_disallowed")
        assert "/private/page.html" not in site.requested


def test_hands_back_the_rendered_page_for_its_links(services, site):
    result, page = pipeline.check_page(target(site, "static.html"), services, ats_fallback=False)

    assert result.outcome == "ok"
    assert page is not None and page.links
    assert (result.listings_incomplete, result.many_employers) == (False, False)


def test_hands_back_no_page_when_robots_keeps_it_out(services, site):
    result, page = pipeline.check_page(target(site, "private/page.html"), services, ats_fallback=False)

    assert (result.outcome, page) == ("blocked", None)
