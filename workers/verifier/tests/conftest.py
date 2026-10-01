"""Shared fixtures: a local synthetic careers site, one browser, and a fake LLM.

Tests never reach the internet or the Anthropic API. The real validation set is
the private target list and is checked only by Test A, locally.
"""

from dataclasses import dataclass, field
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

import httpx2
import pytest
from playwright.sync_api import sync_playwright

from verifier.contract import LlmUsage
from verifier.extract import ExtractedListing, PageExtraction
from verifier.pipeline import Services
from verifier.politeness import HostThrottle
from verifier.render import RenderedPage
from verifier.robots import RobotsPolicy

SITE_DIR = Path(__file__).parent / "site"


@dataclass
class Site:
    base: str
    requested: list[str] = field(default_factory=list)

    def url(self, path: str) -> str:
        return f"{self.base}/{path.lstrip('/')}"


class _RecordingHandler(SimpleHTTPRequestHandler):
    requested: list[str]

    def do_GET(self):
        self.requested.append(self.path)
        super().do_GET()

    def log_message(self, *args):
        pass


@pytest.fixture(scope="session")
def site():
    requested: list[str] = []
    handler = type("Handler", (_RecordingHandler,), {"requested": requested})
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(handler, directory=str(SITE_DIR)))
    Thread(target=server.serve_forever, daemon=True).start()
    yield Site(base=f"http://127.0.0.1:{server.server_port}", requested=requested)
    server.shutdown()


@pytest.fixture(scope="session")
def browser():
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        yield browser
        browser.close()


class FakeExtractor:
    """Stands in for the LLM: every link under /jobs/ is a listing, named by its link text.

    A link reading "Next" is the list's next page; "Apply for this job" makes the
    page one job's posting; a visible "load more" makes the list incomplete.
    """

    def __init__(self):
        self.calls: list[RenderedPage] = []

    def extract(self, page: RenderedPage) -> tuple[PageExtraction, LlmUsage]:
        self.calls.append(page)
        listings = [
            ExtractedListing(
                title=text, location=None, link=number, work_mode="unknown", department=None, employment_type="unknown"
            )
            for number, (text, href) in enumerate(page.links, start=1)
            if "/jobs/" in href
        ]
        next_page = next((n for n, (text, _) in enumerate(page.links, start=1) if text.strip().lower() == "next"), None)
        extraction = PageExtraction(
            shows_job_listings=True,
            explicit_no_openings="no open positions" in page.text.lower(),
            listings_incomplete="load more" in page.text.lower() or next_page is not None,
            many_employers=False,
            single_job_posting="apply for this job" in page.text.lower(),
            stated_total=None,
            next_page=next_page,
            listings=listings,
            notes=f"fake extraction of {len(listings)} listings",
        )
        return extraction, LlmUsage(model="fake", input_tokens=100, output_tokens=20, cost_usd=0.0002)


@pytest.fixture
def services(browser):
    """Real browser, real robots handling, no delay, fake LLM."""
    with httpx2.Client(timeout=5.0) as http:
        yield Services(
            browser=browser,
            http=http,
            robots=RobotsPolicy(http),
            throttle=HostThrottle(0),
            extractor=FakeExtractor(),
        )
