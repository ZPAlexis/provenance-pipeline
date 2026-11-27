"""A careers page opened for another reader (4f): the operator's own AI assistant, through MCP. Never the LLM."""

from verifier import reading
from verifier.contract import Target
from verifier.extract import build_prompt, link_url
from verifier.reading import read_page
from verifier.render import render


def target(site, path):
    return Target(id="c1", url=site.url(path), label="Example Co")


def test_hands_back_the_page_as_the_extractor_would_see_it_and_never_calls_the_llm(services, browser, site):
    result = read_page(target(site, "dynamic.html"), services)

    page = render(browser, site.url("dynamic.html"))
    assert (result.outcome, result.final_url, result.content_hash) == ("ok", page.final_url, page.content_hash)
    assert (result.text, result.title) == (page.text, page.title)
    assert result.links == page.links
    # Link n is the extractor's link n: the same number names the same address for either reader.
    for number, (label, href) in enumerate(result.links, start=1):
        assert link_url(page, number) == href
        assert f"[{number}] {label or '(no text)'} -> {href}" in build_prompt(page)
    assert (result.text_truncated, result.links_truncated) == (False, False)
    assert services.extractor.calls == []


def test_cuts_the_page_where_the_extractor_does_and_says_so(services, site, monkeypatch):
    monkeypatch.setattr(reading, "MAX_TEXT_CHARS", 20)
    monkeypatch.setattr(reading, "MAX_LINKS", 1)

    result = read_page(target(site, "dynamic.html"), services)

    assert (len(result.text), len(result.links)) == (20, 1)
    assert (result.text_truncated, result.links_truncated) == (True, True)


def test_never_opens_a_page_robots_txt_keeps_us_off_nor_takes_a_refusal_for_a_page(services, site):
    blocked = read_page(target(site, "private/page.html"), services)
    missing = read_page(target(site, "no-such-page.html"), services)
    challenge = read_page(target(site, "challenge.html"), services)

    assert (blocked.outcome, blocked.reason, blocked.text) == ("blocked", "robots_disallowed", None)
    assert "/private/page.html" not in site.requested
    assert (missing.outcome, missing.reason) == ("inaccessible", "http_404")
    assert (challenge.outcome, challenge.reason, challenge.links) == ("inaccessible", "bot_challenge", [])
