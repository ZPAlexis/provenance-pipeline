from verifier.contract import LlmUsage, RelateTarget
from verifier.errors import ExtractionFailed
from verifier.extract import RelatedTitle, RelatedTitles, build_related_prompt
from verifier.related import related

USAGE = LlmUsage(model="claude-haiku-4-5", purpose="relate", prompt_version="r1", input_tokens=400, output_tokens=300)


class Proposer:
    def __init__(self, titles, error=None):
        self.titles, self.error, self.asked = titles, error, None

    def propose(self, titles, excluded, places):
        self.asked = (titles, excluded, places)
        if self.error:
            raise self.error
        return RelatedTitles(
            proposals=[
                RelatedTitle(title=title, language=language, reason="Same work.") for title, language in self.titles
            ]
        ), USAGE


def target(**fields):
    return RelateTarget(**{"id": "profile", "titles": ["Solutions Engineer"], "places": ["Brazil"]} | fields)


def test_proposes_titles_never_one_of_the_profiles_own_nor_twice():
    proposer = Proposer(
        [
            ("Sales Engineer", "English"),
            ("Arquiteto de Soluções", "Portuguese"),
            ("solutions engineer", "English"),  # one of its own
            ("Sales  Engineer", "English"),  # twice
            ("", "English"),
        ]
    )

    result = related(target(excluded=["Intern"]), proposer)

    assert [(p.title, p.language) for p in result.proposals] == [
        ("Sales Engineer", "English"),
        ("Arquiteto de Soluções", "Portuguese"),
    ]
    assert proposer.asked == (["Solutions Engineer"], ["Intern"], ["Brazil"])
    assert (result.outcome, result.llm) == ("ok", USAGE)


def test_a_failed_call_says_why_and_keeps_what_it_cost():
    result = related(target(), Proposer([], error=ExtractionFailed("llm_output_invalid", USAGE)))

    assert (result.outcome, result.reason, result.proposals, result.llm) == ("error", "llm_output_invalid", [], USAGE)


def test_the_prompt_names_titles_ruled_out_words_and_places_as_data():
    prompt = build_related_prompt(["Solutions Engineer"], [], ["Brazil", "LATAM"])

    assert prompt == (
        "<their_titles>\nSolutions Engineer\n</their_titles>\n<ruled_out_words>\n(none)\n</ruled_out_words>\n"
        "<places>\nBrazil\nLATAM\n</places>"
    )
