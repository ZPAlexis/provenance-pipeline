import io
import json
from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from verifier import cli
from verifier.contract import BackgroundLine, FitResult, FitTarget, Gap, LlmUsage
from verifier.draft import DRAFT_PROMPT_VERSION, RULES
from verifier.errors import ExtractionFailed
from verifier.fit import (
    FIT_PROMPT_VERSION,
    FIT_SCHEMA,
    FIT_SYSTEM_PROMPT,
    LlmWeigher,
    WrittenCovered,
    WrittenFit,
    WrittenMatch,
    WrittenMustHave,
    WrittenPreference,
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
            "places": ["Brazil", "LATAM"],
            "work_modes": ["remote"],
        }
        | fields
    )


def written(**fields):
    return WrittenFit(
        **{
            "must_haves": [],
            "score": 72,
            "level": "Mid-level asked; the resume shows eight years",
            "matches": [
                WrittenMatch(point=" Discovery at volume ", lines=[3, 3, 9]),
                WrittenMatch(point=" ", lines=[1]),
            ],
            "gaps": [Gap(asks="Spanish", note="Not shown."), Gap(asks=" ", note="x")],
            "why": " Strong on discovery; Spanish is missing. ",
            "background_score": None,
            "background_why": None,
            "covered": [],
            "preferences": [],
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
    # A section of their own: adding fit's moved neither the drafter's prompt nor the review's. 4c step 5 moved both on
    # purpose (the background: what they're looking for for the drafter, background not on the resume for the review).
    # 4d step 4 moved the review's on purpose: background_resume now says what the operator's links add.
    assert (DRAFT_PROMPT_VERSION, REVIEW_PROMPT_VERSION) == ("bb4cf0750d48", "60123e844791")


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


# 4c step 5: the Background fit beside the ATS fit, when the operator's background is given.
BACKGROUND = [
    BackgroundLine(line=1, text="A long-term role building revenue systems.", part="looking_for"),
    BackgroundLine(line=2, text="Internal-facing work first.", part="role_preferences"),
    BackgroundLine(line=3, text="Portuguese, native; Spanish, conversational.", part="not_on_resume"),
]


def test_reads_the_background_too_mapping_its_lines_back_and_keeping_the_ats_fit_as_it_was():
    answer = written(
        background_score=80,
        background_why=" The background covers Spanish. ",
        covered=[
            WrittenCovered(asks="Spanish", background_lines=[3, 3, 9], address_in="resume", note=" Add it. "),
            WrittenCovered(asks=" ", background_lines=[], address_in="both", note=""),
        ],
        preferences=[
            WrittenPreference(preference="Internal-facing work", verdict="miss", why="Outward.", preference_line=2),
            # B3 is background not on the resume, so it states no preference: dropped and counted.
            WrittenPreference(preference="Spanish", verdict="match", why="Asked for.", preference_line=3),
        ],
    )

    result = fit(target(background=BACKGROUND), Weigher(answer))

    assert (result.score, result.background_score, result.background_why) == (72, 80, "The background covers Spanish.")
    assert [(gap.asks, [line.line for line in gap.lines], gap.address_in, gap.note) for gap in result.covered] == [
        ("Spanish", [3], "resume", "Add it.")
    ]
    assert [(point.verdict, [line.part for line in point.lines]) for point in result.preferences] == [
        ("miss", ["role_preferences"]),
        ("match", []),
    ]
    assert result.background_dropped_lines == 2  # B9 isn't in the background; B3 states no preference


def test_without_a_background_no_background_fit_is_kept_and_one_out_of_range_is_refused():
    assert fit(target(), Weigher(written(background_score=90, background_why="x"))).background_score is None
    assert fit(target(background=BACKGROUND), Weigher(written())).background_score is None
    refused = fit(target(background=BACKGROUND), Weigher(written(background_score=140, background_why="x")))
    assert (refused.outcome, refused.reason) == ("error", "background_score_out_of_range")


def test_the_prompt_gives_the_background_under_each_parts_label_and_the_rules_for_both_readings():
    prompt = build_fit_prompt(target(background=BACKGROUND), [])

    assert (
        "<background>\nWhat I'm looking for:\n[B1] A long-term role building revenue systems.\nRole preferences:\n"
        "[B2] Internal-facing work first.\nBackground not on the resume:\n[B3] Portuguese" in prompt
    )
    assert prompt.endswith("Weigh this role against the resume, then again with the background.")
    assert build_fit_prompt(target(), []).endswith("Weigh this role against the resume.")
    assert RULES["background_fit"] in FIT_SYSTEM_PROMPT
    assert "background_score" in FIT_SCHEMA["properties"]


# 4d step 2: the role's must-haves, read one by one before the score; the app caps the score, the worker never does.
def test_reads_each_must_have_with_its_lines_and_one_whose_lines_dont_hold_up_as_not_shown():
    def must(asks, shown_in, lines=(), background_lines=(), note=""):
        return WrittenMustHave(
            asks=asks, shown_in=shown_in, lines=list(lines), background_lines=list(background_lines), note=note
        )

    answer = written(
        background_score=80,
        background_why="The background covers Spanish.",
        must_haves=[
            must(" Discovery ", "resume", lines=[3, 9], note=" "),
            must("Spanish", "background", background_lines=[3, 7], note="Conversational."),
            must("5+ years of AI", "resume", lines=[9]),
            must("A degree", "none", note="Not shown."),
            must(" ", "none"),
        ],
    )

    result = fit(target(background=BACKGROUND), Weigher(answer))

    def read(m):
        return (m.asks, m.shown_in, [line.line for line in m.lines], [line.line for line in m.background_lines], m.note)

    assert [read(m) for m in result.must_haves] == [
        ("Discovery", "resume", [3], [], None),
        ("Spanish", "background", [], [3], "Conversational."),
        ("5+ years of AI", "none", [], [], None),  # line 9 isn't in the resume: a screener wouldn't find it either
        ("A degree", "none", [], [], "Not shown."),
    ]
    assert result.score == 72  # as weighed: the app caps it
    assert (result.dropped_lines, result.background_dropped_lines) == (3, 1)


def test_a_must_have_said_to_be_in_a_background_never_given_is_read_as_not_shown():
    said = WrittenMustHave(asks="Spanish", shown_in="background", lines=[], background_lines=[1], note="")
    answer = written(must_haves=[said])

    result = fit(target(), Weigher(answer))

    assert [(must.shown_in, must.background_lines) for must in result.must_haves] == [("none", [])]
    assert result.background_score is None


def test_the_prompt_says_where_they_can_work_and_the_rules_read_the_must_haves():
    prompt = build_fit_prompt(target(), [])

    assert "<where_they_can_work>\nPlaces: Brazil, LATAM\nHow: remote\n</where_they_can_work>" in prompt
    assert "Places: (not said)\nHow: (not said)" in build_fit_prompt(target(places=[], work_modes=[]), [])
    assert RULES["must_haves"] in FIT_SYSTEM_PROMPT
    assert "a minimum stated in years is a must-have, never a level" in RULES["fit"]
    assert "must_haves" in FIT_SCHEMA["properties"]


# 4d step 4: the lines of the operator's links that apply to the role, numbered on after the background's.
LINKED = [
    *BACKGROUND,
    BackgroundLine(line=4, text="Project Alpha: an append-only audit log.", part="links", source="Project Alpha"),
    BackgroundLine(line=5, text="Built with Rails and Playwright.", part="links", source="Project Alpha"),
    BackgroundLine(line=6, text="Governed AI agents.", part="links", source="GitHub"),
]


def test_the_prompt_gives_the_links_lines_under_the_page_each_is_from():
    block = build_fit_prompt(target(background=LINKED), [])

    assert (
        "What their own links show that applies to this role:\nFrom Project Alpha:\n"
        "[B4] Project Alpha: an append-only audit log.\n[B5] Built with Rails and Playwright.\n"
        "From GitHub:\n[B6] Governed AI agents." in block
    )
    assert "their own links (their website, GitHub or a portfolio)" in RULES["background_fit"]


def test_a_covered_gap_or_a_must_have_may_rest_on_a_line_of_the_links_but_never_a_preference():
    answer = written(
        background_score=80,
        background_why="The links show the audit log.",
        covered=[WrittenCovered(asks="Audit trails", background_lines=[4], address_in="resume", note="Add it.")],
        preferences=[WrittenPreference(preference="Internal-facing work", verdict="match", why="x", preference_line=6)],
        must_haves=[WrittenMustHave(asks="Rails", shown_in="background", lines=[], background_lines=[5], note="")],
    )

    result = fit(target(background=LINKED), Weigher(answer))

    assert [(line.part, line.source) for line in result.covered[0].lines] == [("links", "Project Alpha")]
    assert [(line.part, line.source) for line in result.must_haves[0].background_lines] == [("links", "Project Alpha")]
    assert result.preferences[0].lines == []  # B6 is a page's line, never a preference of theirs
