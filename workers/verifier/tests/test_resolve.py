from verifier.contract import AtsBoard, Listing, LlmUsage, PageResult, ResolveTarget
from verifier.extract import ExtractionFailed, LinkChoice
from verifier.render import RenderedPage
from verifier.resolve import Resolver, ServicesReader, careers_links

ACME = ResolveTarget(id="c1", label="Acme", domain="acme.example", name="Acme Robotics")


def page(links):
    return RenderedPage(final_url="https://acme.example/", status=200, title="Acme", text="Welcome", links=links)


class FakeReader:
    """Scripted pages. `pages` maps a URL to how many listings it shows, `links` to the links it renders.

    A URL in `partial` shows only some of its listings; one in `aggregator`
    lists many employers' jobs.
    """

    def __init__(
        self,
        *,
        answering=(),
        pages=None,
        links=None,
        partial=(),
        stated=None,
        aggregator=(),
        home=None,
        home_outcome=None,
        board=None,
        confirms=False,
    ):
        self.answering = set(answering)
        self.pages = pages or {}
        self.links = links or {}
        self.partial, self.aggregator = set(partial), set(aggregator)
        self.stated = stated or {}
        self.home = home
        self.home_outcome = home_outcome or ("ok" if home is not None else "inaccessible")
        self.board = board
        self.confirms = confirms
        self.checked: list[tuple[str, str]] = []

    def answers(self, url):
        return url if url in self.answering else None

    def check(self, target, url, step):
        self.checked.append((url, step))
        count = self.pages.get(url)
        result = PageResult(
            target_id=target.id,
            url=url,
            final_url=url,
            checked_at="2026-09-30T12:00:00+00:00",
            outcome="ok" if count is not None else "inaccessible",
            method="render+llm",
            step=step,
            listing_count=count,
            listings=[Listing(title=f"Role {n}") for n in range(count or 0)],
            listings_incomplete=url in self.partial,
            many_employers=url in self.aggregator,
            stated_total=self.stated.get(url),
        )
        rendered = RenderedPage(final_url=url, status=200, title="", text="", links=self.links.get(url, []))
        return result, (rendered if count is not None else None)

    def homepage(self, target, url):
        result = PageResult(
            target_id=target.id,
            url=url,
            checked_at="2026-09-30T12:00:00+00:00",
            outcome=self.home_outcome,
            method="render",
            step="homepage",
        )
        return result, (self.home if self.home_outcome == "ok" else None)

    def guess_board(self, target):
        return self.board

    def board_confirms(self, board, target):
        return self.confirms


class FakePicker:
    def __init__(self, link=None, fail=False):
        self.link, self.fail, self.calls = link, fail, 0

    def pick(self, page):
        self.calls += 1
        usage = LlmUsage(model="fake", purpose="resolve", prompt_version="v1", input_tokens=500, cost_usd=0.0005)
        if self.fail:
            raise ExtractionFailed("llm_refusal", usage)
        return LinkChoice(link=self.link, reason="It says Careers."), usage


def resolve(reader, target=ACME, picker=None):
    return Resolver(reader, link_picker=picker).resolve(target)


def test_keeps_the_imported_page_when_it_still_lists_jobs():
    known = ACME.model_copy(update={"known_url": "https://acme.example/jobs-board"})
    reader = FakeReader(pages={"https://acme.example/jobs-board": 5})

    result = resolve(reader, known)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "imported", "high")
    assert result.careers_page_url == "https://acme.example/jobs-board"
    assert reader.checked == [("https://acme.example/jobs-board", "imported")]


def test_fails_without_a_domain_or_a_known_page():
    result = resolve(FakeReader(), ACME.model_copy(update={"domain": None}))

    assert (result.outcome, result.failure) == ("failed", "no_domain")
    assert result.checks == []


def test_finds_a_common_careers_path_on_the_companys_own_domain():
    reader = FakeReader(answering={"https://acme.example/jobs"}, pages={"https://acme.example/jobs": 4})

    result = resolve(reader)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "path_probe", "high")
    # /careers did not answer the cheap probe, so it was never rendered.
    assert reader.checked == [("https://acme.example/jobs", "path_probe")]


def test_passes_over_a_path_that_answers_but_lists_nothing():
    reader = FakeReader(
        answering={"https://acme.example/careers"},
        pages={"https://acme.example/careers": 0, "https://acme.example/join": 3},
        home=page([("Join our team", "https://acme.example/join")]),
    )

    result = resolve(reader)

    assert (result.method, result.careers_page_url) == ("homepage_link", "https://acme.example/join")


def test_follows_a_homepage_link_to_the_companys_job_board_at_high_confidence():
    reader = FakeReader(
        home=page([("Open roles", "https://jobs.lever.co/acme")]),
        pages={"https://jobs.lever.co/acme": 6},
    )

    result = resolve(reader)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "homepage_link", "high")


def test_ignores_homepage_links_to_other_sites_and_links_that_are_not_about_jobs():
    reader = FakeReader(
        home=page(
            [("Careers at our partner", "https://partner.example/careers"), ("Blog", "https://acme.example/blog")]
        )
    )

    result = resolve(reader)

    assert reader.checked == []
    assert (result.outcome, result.failure) == ("failed", "not_found")


def test_a_guessed_board_the_vendor_confirms_is_resolved_at_medium_confidence():
    board = AtsBoard(vendor="greenhouse", board="acmerobotics")
    reader = FakeReader(home=page([]), board=(board, [Listing(title="GTM Engineer")]), confirms=True)

    result = resolve(reader)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "ats_guess", "medium")
    assert result.careers_page_url == "https://job-boards.greenhouse.io/acmerobotics"
    assert result.checks[-1].step == "ats_guess"


# A guess nothing confirms could be another company's board: it waits for a human.
def test_an_unconfirmed_guessed_board_is_only_a_candidate():
    board = AtsBoard(vendor="lever", board="acme")
    reader = FakeReader(home=page([]), board=(board, [Listing(title="GTM Engineer")]), confirms=False)

    result = resolve(reader)

    assert (result.outcome, result.confidence) == ("candidate", "low")
    assert result.careers_page_url == "https://jobs.lever.co/acme"


def test_a_link_the_llm_picks_is_only_a_candidate_and_its_cost_is_kept():
    reader = FakeReader(
        home=page([("Life at Acme", "https://acme.example/life")]), pages={"https://acme.example/life": 3}
    )

    result = resolve(reader, picker=FakePicker(link=1))

    assert (result.outcome, result.method, result.confidence) == ("candidate", "llm_link", "low")
    homepage = next(check for check in result.checks if check.step == "homepage")
    assert homepage.llm.purpose == "resolve"
    assert "Life at Acme" in result.evidence


def test_keeps_going_when_the_link_pick_fails_and_keeps_what_it_cost():
    reader = FakeReader(home=page([("Life at Acme", "https://acme.example/life")]))

    result = resolve(reader, picker=FakePicker(fail=True))

    assert (result.outcome, result.failure) == ("failed", "not_found")
    homepage = next(check for check in result.checks if check.step == "homepage")
    assert homepage.llm.input_tokens == 500


def test_names_why_nothing_was_found():
    assert resolve(FakeReader(home_outcome="inaccessible")).failure == "inaccessible"
    assert resolve(FakeReader(home_outcome="blocked")).failure == "blocked"


def test_caps_how_many_pages_it_checks_for_one_company():
    paths = ["/careers", "/jobs", "/about/careers", "/company/careers"]
    links = [(f"Careers {n}", f"https://acme.example/careers-{n}") for n in range(10)]
    reader = FakeReader(
        answering={f"https://acme.example{path}" for path in paths},
        pages={f"https://acme.example{path}": 0 for path in paths} | {href: 0 for _, href in links},
        home=page(links),
    )

    Resolver(reader, max_checks=6).resolve(ACME)

    assert len(reader.checked) == 6


def test_resolves_a_real_careers_path_end_to_end(services, site):
    host = site.base.removeprefix("http://")
    target = ResolveTarget(id="c1", label="Example", domain=host, name="Example Co")

    result = Resolver(ServicesReader(services), scheme="http").resolve(target)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "path_probe", "high")
    assert result.careers_page_url.endswith("/careers/")
    assert result.checks[0].listing_count == 3


def test_an_unexpected_failure_keeps_the_checks_already_made():
    class BreaksOnGuess(FakeReader):
        def guess_board(self, target):
            raise RuntimeError("boom")

    result = resolve(BreaksOnGuess(home=page([])))

    assert (result.outcome, result.reason) == ("error", "unexpected:RuntimeError")
    assert [check.step for check in result.checks] == ["homepage"]


def test_reads_careers_links_in_portuguese_and_spanish_but_not_lookalikes():
    links = [
        ("Trabalhe conosco", "https://acme.example/trabalhe-conosco"),
        ("Únete al equipo", "https://acme.example/equipo"),
        ("Joint ventures", "https://acme.example/partners"),
        ("Vagas", "https://www.acme.example/vagas"),
    ]

    assert [url for _, url in careers_links(page(links), "acme.example", from_homepage=True)] == [
        "https://acme.example/trabalhe-conosco",
        "https://acme.example/equipo",
        "https://www.acme.example/vagas",
    ]


# Found in the first resolution test: careers pages that only link to their jobs.
def test_follows_a_careers_landing_page_to_the_jobs_it_links_to():
    landing = "https://acme.example/careers"
    reader = FakeReader(
        answering={landing},
        pages={landing: 0, "https://acme.example/careers/positions": 12},
        links={
            landing: [
                ("Life at Acme", "https://acme.example/careers/life"),
                ("See all open positions", "https://acme.example/careers/positions"),
            ]
        },
    )

    result = resolve(reader)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "page_link", "high")
    assert result.careers_page_url == "https://acme.example/careers/positions"
    assert 'Followed the link "See all open positions"' in result.evidence
    assert [step for _, step in reader.checked] == ["path_probe", "page_link"]


def test_follows_a_landing_page_to_the_ats_board_it_links_to():
    landing = "https://acme.example/careers"
    reader = FakeReader(
        answering={landing},
        pages={landing: 0, "https://acme.wd3.myworkdayjobs.com/External": 208},
        links={landing: [("Search jobs", "https://acme.wd3.myworkdayjobs.com/en-US/External/job/Remote/Engineer_R1")]},
    )

    result = resolve(reader)

    # The board itself, not the one role the link pointed at.
    assert result.careers_page_url == "https://acme.wd3.myworkdayjobs.com/External"


def test_from_a_careers_page_follows_only_links_whose_text_says_jobs():
    landing = "https://acme.example/careers"
    reader = FakeReader(
        answering={landing},
        pages={landing: 0},
        links={
            landing: [
                ("Senior Engineer", "https://acme.example/jobs/123-senior-engineer"),
                ("Jobs", "https://www.linkedin.com/company/acme/jobs"),
            ]
        },
    )

    resolve(reader)

    assert reader.checked == [(landing, "path_probe")]


def test_prefers_the_fuller_board_a_partial_page_links_to():
    partial = "https://acme.example/careers"
    board = "https://acme.applytojob.example/apply"
    reader = FakeReader(
        answering={partial},
        pages={partial: 3, board: 54},
        partial={partial},
        links={partial: [("View all jobs", board)]},
    )

    result = resolve(reader)

    assert (result.method, result.careers_page_url) == ("page_link", board)


def test_keeps_a_partial_page_when_nothing_further_shows_more():
    partial = "https://acme.example/careers"
    reader = FakeReader(
        answering={partial},
        pages={partial: 3, "https://acme.example/careers/all": 2},
        partial={partial},
        links={partial: [("All jobs", "https://acme.example/careers/all")]},
    )

    result = resolve(reader)

    # We could not see the whole list, so a person confirms it before it is watched.
    assert (result.outcome, result.method, result.confidence) == ("candidate", "path_probe", "low")
    assert result.careers_page_url == partial
    assert "only some of its openings" in result.evidence


# A job board's own /jobs page lists other companies' openings.
def test_an_aggregators_listings_are_not_the_companys_careers_page():
    jobs = "https://acme.example/jobs"
    reader = FakeReader(
        answering={jobs},
        pages={jobs: 18},
        aggregator={jobs},
        links={jobs: [("More jobs", "https://acme.example/jobs/more")]},
    )

    result = resolve(reader)

    assert result.outcome == "failed"
    assert reader.checked == [(jobs, "path_probe")]


def test_a_link_followed_from_an_llm_pick_is_still_only_a_candidate():
    picked = "https://acme.example/life"
    reader = FakeReader(
        home=page([("Life at Acme", picked)]),
        pages={picked: 0, "https://acme.example/life/openings": 4},
        links={picked: [("Current openings", "https://acme.example/life/openings")]},
    )

    result = resolve(reader, picker=FakePicker(link=1))

    assert (result.outcome, result.method, result.confidence) == ("candidate", "page_link", "low")


def test_follows_a_homepage_link_to_a_careers_subdomain():
    reader = FakeReader(
        home=page([("Careers", "https://careers.acme.example/")]),
        pages={"https://careers.acme.example/": 110},
    )

    result = resolve(reader)

    assert (result.outcome, result.method, result.confidence) == ("resolved", "homepage_link", "high")


def test_a_careers_page_whose_jobs_robots_txt_keeps_us_off_is_blocked_not_missing():
    class RobotsOnJobs(FakeReader):
        def check(self, target, url, step):
            if "/vagas" not in url:
                return super().check(target, url, step)
            self.checked.append((url, step))
            result = PageResult(
                target_id=target.id,
                url=url,
                checked_at="2026-09-30T12:00:00+00:00",
                outcome="blocked",
                reason="robots_disallowed",
                step=step,
            )
            return result, None

    hub = "https://acme.example/carreiras"
    reader = RobotsOnJobs(
        home=page([("Carreiras", hub)]),
        pages={hub: 0},
        links={hub: [("Ver vagas", "https://acme.example/carreiras/vagas")]},
    )

    assert resolve(reader).failure == "blocked"


def test_a_total_the_page_states_settles_whether_it_is_partial():
    careers = "https://acme.example/careers"
    complete = FakeReader(answering={careers}, pages={careers: 181}, partial={careers}, stated={careers: 181})
    partial = FakeReader(answering={careers}, pages={careers: 10}, stated={careers: 83})

    assert (resolve(complete).outcome, resolve(complete).confidence) == ("resolved", "high")
    result = resolve(partial)
    assert (result.outcome, result.confidence) == ("candidate", "low")
    assert "10 of 83" in result.evidence


def test_never_follows_links_that_say_jobs_but_lead_elsewhere():
    landing = "https://acme.example/careers"
    reader = FakeReader(
        answering={landing},
        pages={landing: 0},
        links={
            landing: [
                ("Saved jobs (0)", "https://acme.example/careers/saved-jobs"),
                ("Job alerts", "https://acme.example/careers/alerts"),
                ("Join our talent community", "https://acme.example/careers/community"),
            ]
        },
    )

    resolve(reader)

    assert reader.checked == [(landing, "path_probe")]
