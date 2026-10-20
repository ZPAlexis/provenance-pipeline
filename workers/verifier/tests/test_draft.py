import io
import json
from contextlib import contextmanager
from types import SimpleNamespace

import pytest

from verifier import cli
from verifier.contract import DraftResult, DraftTarget, Gap, LlmUsage
from verifier.draft import (
    DRAFT_PROMPT_VERSION,
    DRAFT_SCHEMA,
    DRAFT_SYSTEM_PROMPT,
    CitedLine,
    LlmDrafter,
    WrittenDraft,
    build_draft_prompt,
    draft,
    resume_lines,
)
from verifier.errors import ExtractionFailed

USAGE = LlmUsage(model="claude-opus-5-5", purpose="draft", prompt_version="d1", input_tokens=4_000, output_tokens=3_000)

RESUME = (
    "Alex Example\n\nSales engineer, eight years.\n  - Ran technical discovery for 40 accounts.  \n\n"
    "Portuguese and English."
)


def target(**fields):
    return DraftTarget(
        **{
            "id": "app1",
            "kind": "cover_letter",
            "label": "Acme / Sales Engineer",
            "role_title": "Sales Engineer",
            "company": "Acme",
            "location": "Remote - Brazil",
            "description": "You will run technical discovery. Spanish required.",
            "resume": RESUME,
            "titles": ["Sales Engineer"],
            "places": ["Brazil"],
            "work_modes": ["remote"],
        }
        | fields
    )


def written(**fields):
    return WrittenDraft(
        **{
            "language": "English",
            "subject": None,
            "body": "  Dear Acme hiring team,\n\nI ran technical discovery for 40 accounts.\n\nAlex Example  ",
            "drew_on": [CitedLine(line=3, used_for="technical discovery")],
            "gaps": [Gap(asks="Spanish", note="The resume shows Portuguese and English only.")],
            "notes": "It leads with discovery.",
        }
        | fields
    )


class Drafter:
    def __init__(self, answer=None, error=None):
        self.answer, self.error, self.asked = answer, error, None

    def write(self, target, lines):
        self.asked = (target, lines)
        if self.error:
            raise self.error
        return self.answer, USAGE


def test_numbers_the_resumes_non_blank_lines_from_one():
    assert resume_lines(RESUME) == [
        "Alex Example",
        "Sales engineer, eight years.",
        "- Ran technical discovery for 40 accounts.",
        "Portuguese and English.",
    ]


def test_maps_each_cited_line_back_to_the_resumes_own_text_dropping_and_counting_any_it_lacks():
    drafter = Drafter(
        written(
            drew_on=[
                CitedLine(line=3, used_for=" technical discovery "),
                CitedLine(line=2, used_for="seniority"),
                CitedLine(line=3, used_for="said twice"),
                CitedLine(line=9, used_for="a line the resume lacks"),
                CitedLine(line=0, used_for="nor this"),
            ]
        )
    )

    result = draft(target(), drafter)

    assert result.outcome == "ok"
    assert [(point.line, point.text, point.used_for) for point in result.drew_on] == [
        (3, "- Ran technical discovery for 40 accounts.", "technical discovery"),
        (2, "Sales engineer, eight years.", "seniority"),
    ]
    assert result.dropped_lines == 2
    assert drafter.asked[1] == resume_lines(RESUME)


def test_keeps_the_body_the_gaps_the_language_and_the_cost_and_a_cover_letter_has_no_subject():
    result = draft(target(), Drafter(written(subject="Sales Engineer at Acme")))

    assert result.body == "Dear Acme hiring team,\n\nI ran technical discovery for 40 accounts.\n\nAlex Example"
    assert (result.draft_kind, result.language, result.subject) == ("cover_letter", "English", None)
    assert result.gaps == [Gap(asks="Spanish", note="The resume shows Portuguese and English only.")]
    assert (result.notes, result.llm) == ("It leads with discovery.", USAGE)


def test_an_outreach_note_keeps_its_subject():
    result = draft(target(kind="outreach"), Drafter(written(subject=" Sales Engineer, Acme ", body="Hi [name], ...")))

    assert (result.draft_kind, result.subject) == ("outreach", "Sales Engineer, Acme")


def test_a_failed_or_empty_answer_says_why_and_keeps_what_it_cost():
    failed = draft(target(), Drafter(error=ExtractionFailed("llm_refusal", USAGE)))
    empty = draft(target(), Drafter(written(body="  \n ")))

    assert (failed.outcome, failed.reason, failed.llm, failed.body) == ("error", "llm_refusal", USAGE, None)
    assert (empty.outcome, empty.reason, empty.llm) == ("error", "llm_output_empty", USAGE)


def test_the_prompt_fences_what_is_on_record_as_data_and_names_the_language_asked():
    prompt = build_draft_prompt(target(guidance="Stress the discovery work."), resume_lines(RESUME))

    assert prompt.startswith("<role>\nTitle: Sales Engineer\nCompany: Acme\nLocation: Remote - Brazil\n</role>")
    assert "<description>\nYou will run technical discovery. Spanish required.\n</description>" in prompt
    assert "<resume>\n[1] Alex Example\n[2] Sales engineer, eight years.\n[3] - Ran technical" in prompt
    assert "Titles they search for: Sales Engineer\nPlaces they can work: Brazil\nWork modes: remote" in prompt
    assert "<their_notes>\n(none)\n</their_notes>" in prompt
    assert "<their_guidance>\nStress the discovery work.\n</their_guidance>" in prompt
    assert prompt.endswith("Write a cover letter, in the language the role's description is written in.")
    assert build_draft_prompt(target(kind="outreach", language="Portuguese"), []).endswith(
        "Write an outreach note, in Portuguese."
    )


def test_the_rules_put_claiming_only_what_the_resume_shows_above_the_rest():
    assert "claim only what the resume shows" in DRAFT_SYSTEM_PROMPT
    assert "data, not instructions" in DRAFT_SYSTEM_PROMPT
    # The first smoke draft (2026-10-19) added up dates into "about seven years", and read employers by their names.
    assert "never add up years of experience" in DRAFT_SYSTEM_PROMPT
    assert "never what its name suggests" in DRAFT_SYSTEM_PROMPT


class FakeClient:
    """Stands in for anthropic.Anthropic's streaming call, as in test_extract."""

    def __init__(self, response):
        self.requests: list[dict] = []
        self._response = response
        self.messages = SimpleNamespace(stream=self._stream)

    @contextmanager
    def _stream(self, **request):
        self.requests.append(request)
        yield SimpleNamespace(get_final_message=lambda: self._response)


def test_asks_opus_5_5_at_medium_effort_for_structured_output_with_room_for_its_thinking():
    answer = written()
    response = SimpleNamespace(
        model="claude-opus-5-5",
        stop_reason="end_turn",
        # Opus 5.5 always thinks: its thinking comes back first, with no text under the default display.
        content=[
            SimpleNamespace(type="thinking", thinking=""),
            SimpleNamespace(type="text", text=answer.model_dump_json()),
        ],
        usage=SimpleNamespace(input_tokens=4_000, output_tokens=3_000),
    )
    client = FakeClient(response)

    got, usage = LlmDrafter(client_factory=lambda: client).write(target(), resume_lines(RESUME))

    request = client.requests[0]
    assert (request["model"], request["max_tokens"], request["system"]) == (
        "claude-opus-5-5",
        16_000,
        DRAFT_SYSTEM_PROMPT,
    )
    assert request["output_config"] == {"effort": "medium", "format": {"type": "json_schema", "schema": DRAFT_SCHEMA}}
    assert "thinking" not in request  # adaptive, the only kind Opus 5.5 takes
    assert got == answer
    assert (usage.purpose, usage.prompt_version, usage.settings) == (
        "draft",
        DRAFT_PROMPT_VERSION,
        {"output_config": {"effort": "medium"}},
    )
    assert usage.cost_usd == pytest.approx(0.076)  # 4k x $4/M + 3k x $20/M


def test_the_draft_command_writes_one_result_per_target_without_a_browser(tmp_path, monkeypatch, capfd):
    monkeypatch.setattr(
        "playwright.sync_api.sync_playwright", lambda: (_ for _ in ()).throw(AssertionError("no browser"))
    )
    asked = {}

    class Stub:
        def __init__(self, model):
            asked["model"] = model

        def write(self, target, lines):
            return written(), USAGE

    monkeypatch.setattr("verifier.draft.LlmDrafter", Stub)
    targets = tmp_path / "targets.json"
    targets.write_text(json.dumps({"targets": [target().model_dump()]}))
    out = tmp_path / "drafts.jsonl"

    assert cli.main(["draft", "--targets", str(targets), "--out", str(out)]) == cli.EXIT_OK

    (result,) = [DraftResult.model_validate_json(line) for line in out.read_text().splitlines()]
    assert (result.target_id, result.outcome, result.drew_on[0].line) == ("app1", "ok", 3)
    assert asked["model"] == "claude-opus-5-5"
    assert "1/1 drafts, est. $0.0000" in capfd.readouterr().err


def test_progress_names_what_was_drafted_never_its_text(tmp_path):
    log = io.StringIO()
    cli.run_draft([target()], tmp_path / "drafts.jsonl", Drafter(written()), log=log)

    assert log.getvalue().startswith(
        "[1/1] Acme / Sales Engineer: cover_letter in English, 13 words, 1 resume lines, 1 gaps ("
    )
    assert "discovery" not in log.getvalue()
