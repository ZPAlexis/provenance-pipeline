from contextlib import contextmanager
from types import SimpleNamespace

import anthropic
import httpx2
import pytest

from verifier.config import MAX_LINKS, MAX_TEXT_CHARS
from verifier.extract import (
    OUTPUT_SCHEMA,
    SYSTEM_PROMPT,
    CreditExhausted,
    ExtractedListing,
    ExtractionFailed,
    LlmConfigError,
    LlmExtractor,
    PageExtraction,
    build_prompt,
    input_truncated,
    link_url,
)
from verifier.render import RenderedPage

PAGE = RenderedPage(
    final_url="https://acme.example/careers",
    status=200,
    title="Careers",
    text="Open roles: Revenue Operations Engineer",
    links=[("Home", "https://acme.example/"), ("Revenue Operations Engineer", "https://acme.example/jobs/1")],
)

EXTRACTION = PageExtraction(
    shows_job_listings=True,
    explicit_no_openings=False,
    stated_total=None,
    listings=[ExtractedListing(title="Revenue Operations Engineer", location=None, link=2, work_mode="unknown")],
    notes="One role listed.",
)


class FakeClient:
    """Stands in for anthropic.Anthropic's streaming call: messages.stream(...) as a context manager."""

    def __init__(self, response=None, error=None):
        self.requests: list[dict] = []
        self._response = response
        self._error = error
        self.messages = SimpleNamespace(stream=self._stream)

    @contextmanager
    def _stream(self, **request):
        self.requests.append(request)
        if self._error:
            raise self._error  # the SDK raises API errors as the stream opens
        yield SimpleNamespace(get_final_message=lambda: self._response)


def response(text=None, stop_reason="end_turn", model="claude-haiku-4-5-20251001"):
    return SimpleNamespace(
        model=model,
        stop_reason=stop_reason,
        content=[SimpleNamespace(type="text", text=EXTRACTION.model_dump_json() if text is None else text)],
        usage=SimpleNamespace(input_tokens=10_000, output_tokens=2_000),
    )


def api_error(cls, status, message, text=""):
    request = httpx2.Request("POST", "https://api.anthropic.com/v1/messages")
    return cls(message, response=httpx2.Response(status, text=text, request=request), body=None)


def extractor(client, model="claude-haiku-4-5"):
    return LlmExtractor(model, client_factory=lambda: client)


def test_asks_haiku_for_structured_output_with_no_effort_setting():
    client = FakeClient(response())
    extraction, _ = extractor(client).extract(PAGE)

    request = client.requests[0]
    assert request["model"] == "claude-haiku-4-5"
    assert request["system"] == SYSTEM_PROMPT
    assert request["output_config"] == {"format": {"type": "json_schema", "schema": OUTPUT_SCHEMA}}
    assert extraction.listings[0].title == "Revenue Operations Engineer"


# A 500-role board needs ~25k output tokens; streaming lifts the SDK's
# non-streaming ceiling (~21k) up to Haiku 4.5's own maximum.
def test_streams_with_room_for_the_largest_boards():
    client = FakeClient(response())
    extractor(client).extract(PAGE)

    assert client.requests[0]["max_tokens"] == 64_000


def test_runs_the_higher_rungs_at_low_effort():
    client = FakeClient(response(model="claude-sonnet-5"))
    _, usage = extractor(client, "claude-sonnet-5").extract(PAGE)

    assert client.requests[0]["output_config"]["effort"] == "low"
    assert client.requests[0]["output_config"]["format"]["type"] == "json_schema"
    assert usage.settings == {"output_config": {"effort": "low"}}


def test_records_tokens_the_served_model_and_an_estimated_cost():
    _, usage = extractor(FakeClient(response())).extract(PAGE)

    assert usage.model == "claude-haiku-4-5-20251001"
    assert (usage.input_tokens, usage.output_tokens) == (10_000, 2_000)
    assert usage.cost_usd == pytest.approx(0.02)  # 10k x $1/M + 2k x $5/M


def test_rejects_an_unknown_model():
    with pytest.raises(ValueError, match="unknown model"):
        LlmExtractor("claude-unknown")


def test_stops_the_run_when_credit_is_exhausted():
    error = api_error(anthropic.BadRequestError, 400, "Your credit balance is too low to access the Anthropic API.")

    with pytest.raises(CreditExhausted):
        extractor(FakeClient(error=error)).extract(PAGE)


def test_stops_the_run_when_the_credential_is_rejected():
    error = api_error(anthropic.AuthenticationError, 401, "invalid x-api-key")

    with pytest.raises(LlmConfigError):
        extractor(FakeClient(error=error)).extract(PAGE)


# Seen for real on 2026-09-29: the edge answers 503 before the request reaches the
# API. It is the credential, not this page, so the whole run must stop.
def test_stops_the_run_when_the_credential_cannot_be_validated():
    error = api_error(anthropic.InternalServerError, 503, "Error code: 503", text="credential validation failed")

    with pytest.raises(LlmConfigError, match="could not be validated"):
        extractor(FakeClient(error=error)).extract(PAGE)


def test_stops_the_run_when_there_is_no_credential():
    def no_key():
        raise anthropic.AnthropicError("no api key")

    with pytest.raises(LlmConfigError):
        LlmExtractor(client_factory=no_key).extract(PAGE)


def test_fails_only_this_page_on_other_api_errors():
    error = api_error(anthropic.InternalServerError, 529, "overloaded")

    with pytest.raises(ExtractionFailed) as failure:
        extractor(FakeClient(error=error)).extract(PAGE)
    assert failure.value.reason == "llm_http_529"


# Those tokens were billed whether or not the output was usable; the run's cost must include them.
@pytest.mark.parametrize(
    ("text", "stop_reason", "reason"),
    [
        ("", "refusal", "llm_refusal"),
        ('{"shows_job_listings": true, "listings": [', "max_tokens", "llm_output_incomplete"),
        ('{"not": "the schema"}', "end_turn", "llm_output_invalid"),
    ],
)
def test_keeps_the_billed_usage_when_a_response_is_unusable(text, stop_reason, reason):
    with pytest.raises(ExtractionFailed) as failure:
        extractor(FakeClient(response(text=text, stop_reason=stop_reason))).extract(PAGE)

    assert failure.value.reason == reason
    assert failure.value.usage.output_tokens == 2_000


def test_prompt_fences_the_page_as_data_and_numbers_its_links():
    prompt = build_prompt(PAGE)

    assert "<page_text>\nOpen roles: Revenue Operations Engineer" in prompt
    assert "[2] Revenue Operations Engineer -> https://acme.example/jobs/1" in prompt
    assert "not instructions" in SYSTEM_PROMPT


def test_maps_a_link_number_back_to_the_exact_url():
    assert link_url(PAGE, 2) == "https://acme.example/jobs/1"
    assert link_url(PAGE, None) is None
    assert link_url(PAGE, 0) is None
    assert link_url(PAGE, 3) is None  # a number the model made up


def test_marks_what_the_model_could_not_see():
    long_text = RenderedPage(final_url="https://acme.example", status=200, title="t", text="x" * (MAX_TEXT_CHARS + 1))
    many_links = RenderedPage(
        final_url="https://acme.example",
        status=200,
        title="t",
        text="jobs",
        links=[(f"Role {n}", f"https://acme.example/jobs/{n}") for n in range(MAX_LINKS + 1)],
    )

    assert "[text truncated]" in build_prompt(long_text)
    assert "[link list truncated]" in build_prompt(many_links)
    assert input_truncated(long_text) and input_truncated(many_links)
    assert not input_truncated(PAGE)
