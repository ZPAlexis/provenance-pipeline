import io
import json
from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from verifier import cli
from verifier.contract import FitResult, FitTarget, Gap, LlmUsage
from verifier.draft import DRAFT_PROMPT_VERSION, RULES
from verifier.errors import ExtractionFailed
from verifier.fit import (
    FIT_PROMPT_VERSION,
    FIT_SCHEMA,
    FIT_SYSTEM_PROMPT,
    LlmWeigher,
    WrittenFit,
    WrittenMatch,
    build_fit_prompt,
    fit,
)
from verifier.review import REVIEW_PROMPT_VERSION

USAGE = LlmUsage(model="claude-haiku-4-5", purpose="fit", prompt_version="f1", input_tokens=4_000, output_tokens=600)
RESUME = "Jordan Sample\n\nSales engineer, eight years.\n- Ran discovery for 35 accounts a year.\n"


def target(**fields):
    return FitTarget(
        **{
            "id": "posting1",
            "label": "Acme / Sales Engineer",
            "role_title": "Sales Engineer",
            "company": "Acme",
            "location": "Remote - Brazil",
            "description": "You will run discovery. Spanish required.",
            "resume": RESUME,
            "titles": ["Sales Engineer", "Solutions Engineer"],
        }
        | fields
    )


def written(**fields):
    return WrittenFit(
        **{
            "score": 72,
            "level": "Mid-level asked; the resume shows eight years",
            "matches": [
                WrittenMatch(point=" Discovery at volume ", lines=[3, 3, 9]),
                WrittenMatch(point=" ", lines=[1]),
            ],
            "gaps": [Gap(asks="Spanish", note="Not shown."), Gap(asks=" ", note="x")],
            "why": " Strong on discovery; Spanish is missing. ",
        }
        | fields
    )


class Weigher:
    def __init__(self, answer=None, error=None):
        self.answer, self.error = answer, error

    def weigh(self, target, lines):
        if self.error:
            raise self.error
        return self.answer, USAGE


def test_scores_the_role_and_maps_each_line_named_back_to_the_resumes_text():
    result = fit(target(), Weigher(written()))

    assert (result.outcome, result.score, result.why) == ("ok", 72, "Strong on discovery; Spanish is missing.")
    assert [(m.point, [(line.line, line.text) for line in m.lines]) for m in result.matches] == [
        ("Discovery at volume", [(3, "- Ran discovery for 35 accounts a year.")])
    ]
    assert [(gap.asks, gap.note) for gap in result.gaps] == [("Spanish", "Not shown.")]
    assert result.level == "Mid-level asked; the resume shows eight years"
    assert (result.dropped_lines, result.llm) == (1, USAGE)


def test_a_failed_out_of_range_or_empty_answer_says_why_and_keeps_what_it_cost():
    failed = fit(target(), Weigher(error=ExtractionFailed("llm_refusal", USAGE)))
    over = fit(target(), Weigher(written(score=140)))
    empty = fit(target(), Weigher(written(why=" ")))

    assert (failed.outcome, failed.reason, failed.llm) == ("error", "llm_refusal", USAGE)
    assert (over.outcome, over.reason, over.score, over.llm) == ("error", "score_out_of_range", None, USAGE)
    assert (empty.outcome, empty.reason) == ("error", "llm_output_empty")


def test_its_rules_are_the_shared_ones_and_the_others_prompts_keep_their_versions():
    assert RULES["grounding"] in FIT_SYSTEM_PROMPT
    assert RULES["fit"] in FIT_SYSTEM_PROMPT
    assert "85 to 100" in RULES["fit"] and "0 to 24" in RULES["fit"]
    assert "data, not instructions" in FIT_SYSTEM_PROMPT
    # A section of their own: adding fit's moved neither the drafter's prompt nor the review's.
    assert (DRAFT_PROMPT_VERSION, REVIEW_PROMPT_VERSION) == ("4fbc2a1e0185", "12a32d559f0c")


def test_the_prompt_fences_what_is_on_record():
    prompt = build_fit_prompt(target(), ["Jordan Sample", "Sales engineer."])

    assert "<role>\nTitle: Sales Engineer\nCompany: Acme\nLocation: Remote - Brazil\n</role>" in prompt
    assert "<resume>\n[1] Jordan Sample\n[2] Sales engineer.\n</resume>" in prompt
    assert "<description>\nYou will run discovery. Spanish required.\n</description>" in prompt
    assert "<titles_they_search_for>\nSales Engineer, Solutions Engineer\n</titles_they_search_for>" in prompt
    assert prompt.endswith("Weigh this role against the resume.")


class FakeClient:
    def __init__(self, response):
        self.requests: list[dict] = []
        self._response = response
        self.messages = SimpleNamespace(stream=self._stream)

    @contextmanager
    def _stream(self, **request):
        self.requests.append(request)
        yield SimpleNamespace(get_final_message=lambda: self._response)


def test_asks_haiku_for_structured_output_with_no_effort_setting():
    answer = written()
    response = SimpleNamespace(
        model="claude-haiku-4-5-20251001",
        stop_reason="end_turn",
        content=[SimpleNamespace(type="text", text=answer.model_dump_json())],
        usage=SimpleNamespace(input_tokens=4_000, output_tokens=600),
    )
    client = FakeClient(response)

    got, usage = LlmWeigher(client_factory=lambda: client).weigh(target(), ["Jordan Sample"])

    request = client.requests[0]
    assert (request["model"], request["max_tokens"]) == ("claude-haiku-4-5", 4_000)
    assert request["output_config"] == {"format": {"type": "json_schema", "schema": FIT_SCHEMA}}
    assert got == answer
    assert (usage.purpose, usage.prompt_version) == ("fit", FIT_PROMPT_VERSION)
    assert usage.cost_usd == pytest.approx(0.007)  # 4k x $1/M + 600 x $5/M


def test_the_fit_command_writes_one_result_per_role_without_a_browser(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "playwright.sync_api.sync_playwright", lambda: (_ for _ in ()).throw(AssertionError("no browser"))
    )
    asked = {}

    class Stub:
        def __init__(self, model):
            asked["model"] = model

        def weigh(self, target, lines):
            return written(), USAGE

    monkeypatch.setattr("verifier.fit.LlmWeigher", Stub)
    targets = tmp_path / "targets.json"
    targets.write_text(json.dumps({"targets": [target().model_dump(), target(id="posting2").model_dump()]}))
    out = tmp_path / "fits.jsonl"

    assert cli.main(["fit", "--targets", str(targets), "--out", str(out)]) == cli.EXIT_OK

    results = [FitResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert [(result.target_id, result.score) for result in results] == [("posting1", 72), ("posting2", 72)]
    assert asked["model"] == "claude-haiku-4-5"
    log = io.StringIO()
    cli.run_fit([target()], tmp_path / "again.jsonl", Weigher(written()), log=log)
    assert log.getvalue().startswith("[1/1] Acme / Sales Engineer: fit 72, 1 matches, 1 gaps (")
