import io
import json

from verifier import cli, pipeline
from verifier.cli import run, run_boards, run_resolve
from verifier.contract import (
    AtsBoard,
    BoardResult,
    BoardTarget,
    Listing,
    MatchResult,
    PageResult,
    ResolutionResult,
    ResolveTarget,
    SuggestionResult,
    Target,
)
from verifier.errors import CreditExhausted
from verifier.extract import ExtractionFailed
from verifier.resolve import Resolver, ServicesReader


def targets(site, *paths):
    return [Target(id=f"t{index}", url=site.url(path), label=path) for index, path in enumerate(paths, start=1)]


def read_results(path):
    return [PageResult.model_validate_json(line) for line in path.read_text().splitlines()]


def test_writes_one_result_per_target_and_summarizes_the_run(services, site, tmp_path):
    out = tmp_path / "results.jsonl"

    summary = run(targets(site, "dynamic.html", "private/page.html"), out, services, log=io.StringIO())

    results = read_results(out)
    assert [result.target_id for result in results] == ["t1", "t2"]
    assert [result.outcome for result in results] == ["ok", "blocked"]
    assert (summary.pages, summary.listings, summary.stopped) == (2, 4, None)
    assert summary.outcomes == {"ok": 1, "blocked": 1}
    assert summary.cost_usd == 0.0002


def test_stops_cleanly_when_credit_runs_out_keeping_finished_results(services, site, tmp_path):
    class CreditRunsOut:
        def __init__(self, inner):
            self.inner, self.calls = inner, 0

        def extract(self, page):
            self.calls += 1
            if self.calls > 1:
                raise CreditExhausted("Your credit balance is too low")
            return self.inner.extract(page)

    services.extractor = CreditRunsOut(services.extractor)
    out = tmp_path / "results.jsonl"
    log = io.StringIO()

    summary = run(targets(site, "static.html", "dynamic.html", "framed.html"), out, services, log=log)

    assert summary.stopped == "credit_exhausted"
    assert [result.target_id for result in read_results(out)] == ["t1"]
    assert "API credit is exhausted" in log.getvalue()


class LlmDown:
    def __init__(self, reason):
        self.reason, self.calls = reason, 0

    def extract(self, page):
        self.calls += 1
        raise ExtractionFailed(self.reason)


# An outage is not five separate page failures: stop instead of rendering the rest.
def test_stops_when_the_llm_is_unavailable_three_pages_running(services, site, tmp_path):
    services.extractor = LlmDown("llm_http_529")
    out = tmp_path / "results.jsonl"
    log = io.StringIO()

    summary = run(targets(site, "static.html", "dynamic.html", "framed.html", "empty.html"), out, services, log=log)

    assert summary.stopped == "llm_unavailable"
    assert services.extractor.calls == 3
    assert len(read_results(out)) == 3
    assert "the LLM service is failing" in log.getvalue()


def test_keeps_going_through_page_specific_llm_failures(services, site, tmp_path):
    services.extractor = LlmDown("llm_refusal")

    summary = run(
        targets(site, "static.html", "dynamic.html", "framed.html", "empty.html"),
        tmp_path / "r.jsonl",
        services,
        log=io.StringIO(),
    )

    assert summary.stopped is None
    assert summary.outcomes == {"error": 4}


def test_one_unexpected_failure_does_not_lose_the_run(services, site, tmp_path, monkeypatch):
    real = pipeline.verify_page

    def flaky(target, services):
        if target.id == "t1":
            raise RuntimeError("boom")
        return real(target, services)

    monkeypatch.setattr(pipeline, "verify_page", flaky)
    out = tmp_path / "results.jsonl"

    run(targets(site, "static.html", "empty.html"), out, services, log=io.StringIO())

    results = read_results(out)
    assert [(result.outcome, result.reason) for result in results] == [
        ("error", "unexpected:RuntimeError"),
        ("ok", None),
    ]
    assert results[0].checked_at


def test_a_check_target_carries_exactly_one_posting(tmp_path):
    bad = tmp_path / "targets.json"
    postings = [{"id": "p1", "title": "A"}, {"id": "p2", "title": "B"}]
    bad.write_text(json.dumps({"targets": [{"id": "c1", "url": "https://acme.example/careers", "postings": postings}]}))

    assert cli.main(["check", "--targets", str(bad), "--out", str(tmp_path / "out.jsonl")]) == cli.EXIT_BAD_INPUT


def test_rejects_an_unreadable_targets_file(tmp_path):
    bad = tmp_path / "targets.json"
    bad.write_text(json.dumps({"not_targets": []}))

    assert cli.main(["extract", "--targets", str(bad), "--out", str(tmp_path / "out.jsonl")]) == cli.EXIT_BAD_INPUT


def test_resolve_writes_one_result_per_company_counting_every_page_it_checked(services, site, tmp_path):
    host = site.base.removeprefix("http://")
    companies = [
        ResolveTarget(id="c1", label="Example", domain=host, name="Example Co"),
        ResolveTarget(id="c2", label="Nameless", name="Nameless Co"),
    ]
    out = tmp_path / "resolutions.jsonl"

    summary = run_resolve(companies, out, Resolver(ServicesReader(services), scheme="http"), log=io.StringIO())

    results = [ResolutionResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [(result.target_id, result.outcome) for result in results] == [("c1", "resolved"), ("c2", "failed")]
    assert summary.outcomes == {"resolved": 1, "failed": 1}
    assert (summary.targets, summary.pages, summary.listings) == (2, 1, 3)


def test_resolve_stops_cleanly_when_credit_runs_out(tmp_path):
    class NoCredit:
        def resolve(self, target):
            raise CreditExhausted("Your credit balance is too low")

    summary = run_resolve([ResolveTarget(id="c1")], tmp_path / "r.jsonl", NoCredit(), log=io.StringIO())

    assert summary.stopped == "credit_exhausted"
    assert (tmp_path / "r.jsonl").read_text() == ""


def test_match_replays_stored_listings_without_a_browser_and_counts_verdicts(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "playwright.sync_api.sync_playwright", lambda: (_ for _ in ()).throw(AssertionError("no browser"))
    )
    targets = tmp_path / "targets.json"
    targets.write_text(
        json.dumps(
            {
                "targets": [
                    {
                        "id": "c1",
                        "label": "Acme",
                        "complete": True,
                        "listings": [{"title": "RevOps Engineer"}],
                        "postings": [{"id": "p1", "title": "RevOps Engineer"}, {"id": "p2", "title": "Designer"}],
                    },
                    {
                        "id": "c2",
                        "complete": False,
                        "listings": [{"title": "Recruiter"}],
                        "postings": [{"id": "p3", "title": "Sales Engineer LATAM"}],
                    },
                ]
            }
        )
    )
    out = tmp_path / "matches.jsonl"

    assert cli.main(["match", "--no-llm", "--targets", str(targets), "--out", str(out)]) == cli.EXIT_OK

    results = [MatchResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [[v.verdict for v in r.verdicts] for r in results] == [["verified_live", "not_found"], [None]]


def test_verify_writes_one_result_per_company_with_its_verdicts(services, site, tmp_path):
    from verifier.cli import run_verify
    from verifier.contract import TrackedPosting, VerificationResult, VerifyTarget
    from verifier.match import Matcher

    companies = [
        VerifyTarget(id="c1", url=site.url("paged/1.html"), postings=[TrackedPosting(id="p1", title="Data Engineer")])
    ]
    out = tmp_path / "verifications.jsonl"

    summary = run_verify(companies, out, services, Matcher(), log=io.StringIO())

    (result,) = [VerificationResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [v.verdict for v in result.verdicts] == ["verified_live"]
    assert (summary.pages, summary.verdicts) == (2, {"verified_live": 1})


def test_boards_writes_one_result_per_company_and_tallies_what_was_adopted(tmp_path):
    roles = ["Account Executive", "Solutions Engineer", "Data Engineer", "Product Designer", "Recruiter"]

    class Reader:
        def guess_boards(self, target):
            if target.name == "Acme":
                return iter([(AtsBoard(vendor="ashby", board="acme"), [Listing(title=title) for title in roles])])
            return iter([])

        def board_confirms(self, board, target):
            return True

        def board_links(self, board):
            return None

    out = tmp_path / "results.jsonl"
    companies = [BoardTarget(id="c1", name="Acme", titles=roles), BoardTarget(id="c2", name="Other", titles=roles)]

    summary = run_boards(companies, out, Reader(), log=io.StringIO())

    results = [BoardResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [(result.target_id, result.outcome) for result in results] == [("c1", "adopted"), ("c2", "none")]
    assert (summary.outcomes, summary.pages, summary.cost_usd) == ({"adopted": 1, "none": 1}, 0, 0.0)


def test_suggest_weighs_stored_roles_without_a_browser_and_counts_what_fits(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(
        "playwright.sync_api.sync_playwright", lambda: (_ for _ in ()).throw(AssertionError("no browser"))
    )
    profile = {"titles": ["Solutions Engineer"], "places": ["Brazil"], "work_modes": ["remote"]}
    targets = tmp_path / "targets.json"
    targets.write_text(
        json.dumps(
            {
                "targets": [
                    {
                        "id": "c1",
                        "label": "Acme",
                        "page_check_id": "pc1",
                        "listings": [
                            {"title": "Solutions Engineer", "location": "Remote - Brazil", "work_mode": "remote"},
                            {"title": "Solutions Engineer", "location": "New York", "work_mode": "onsite"},
                            {"title": "Recruiter", "location": "Remote - Brazil"},
                        ],
                        "profile": profile,
                    },
                    {"id": "c2", "listings": [], "profile": profile},
                ]
            }
        )
    )
    out = tmp_path / "suggestions.jsonl"

    assert cli.main(["suggest", "--targets", str(targets), "--out", str(out)]) == cli.EXIT_OK

    results = [SuggestionResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [(r.target_id, r.weighed, [fit.suggested for fit in r.roles]) for r in results] == [
        ("c1", 3, [True, False]),
        ("c2", 0, []),
    ]
    assert "2/2 companies, 1 suggested" in capfd.readouterr().err
