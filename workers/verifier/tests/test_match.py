from verifier.contract import Listing, LlmUsage, MatchTarget, TrackedPosting
from verifier.extract import ExtractionFailed, MatchDecision, MatchDecisions
from verifier.match import Matcher, same_title, variant


def target(postings, listings, complete=True):
    return MatchTarget(
        id="c1",
        page_check_id="pc1",
        complete=complete,
        listings=[Listing(title=t, location=loc) for t, loc in listings],
        postings=[TrackedPosting(id=f"p{n}", title=t, location=loc) for n, (t, loc) in enumerate(postings, 1)],
    )


class FakeAdjudicator:
    """Answers with scripted decisions: {posting number: listing number or None}."""

    def __init__(self, answers=None, fail=None):
        self.answers, self.fail, self.calls = answers or {}, fail, []

    def decide(self, cases, listings):
        self.calls.append([(case.posting.title, [listings[i].title for i in case.candidates]) for case in cases])
        usage = LlmUsage(model="fake", purpose="match", prompt_version="m1", input_tokens=300, cost_usd=0.0003)
        if self.fail:
            raise ExtractionFailed(self.fail, usage)
        decisions = [
            MatchDecision(posting=n, listing=listing, reason="same job") for n, listing in self.answers.items()
        ]
        return MatchDecisions(decisions=decisions), usage


def only(result):
    assert len(result.verdicts) == 1
    return result.verdicts[0]


def test_titles_match_ignoring_case_punctuation_accents_and_seniority_abbreviations():
    assert same_title("Sr. Solutions Engineer", "senior solutions engineer")
    assert same_title("Engenheiro de Soluções", "ENGENHEIRO DE SOLUCOES")
    assert not same_title("Solutions Engineer", "Solutions Engineering")


def test_a_variant_needs_two_words_in_common_at_least():
    assert variant("Solutions Engineer", "Senior Solutions Engineer, LATAM")
    assert not variant("Engineer", "Senior Solutions Engineer")


# A title that adds a level of responsibility is a different job: the LLM decides, never the rule.
def test_a_title_that_adds_a_level_is_not_a_variant():
    assert not variant("Solutions Engineer", "Solutions Engineer Manager")
    assert not variant("RevOps Engineer", "Lead RevOps Engineer")


def test_an_exact_title_is_live():
    verdict = only(
        Matcher().match(target([("RevOps Engineer", None)], [("Designer", None), ("RevOps Engineer", None)]))
    )

    assert (verdict.verdict, verdict.method, verdict.listing_index) == ("verified_live", "exact", 1)
    assert verdict.reasoning == 'The page lists "RevOps Engineer".'


def test_a_close_variant_is_live_and_says_so():
    verdict = only(Matcher().match(target([("Solutions Engineer", None)], [("Senior Solutions Engineer", None)])))

    assert (verdict.verdict, verdict.method) == ("verified_live", "variant")
    assert "a variant of" in verdict.reasoning


def test_location_picks_the_listing_among_several_and_never_decides_the_verdict():
    listings = [("DevOps Engineer", "Poland"), ("DevOps Engineer", "Brazil"), ("DevOps Engineer", "Argentina")]

    verdict = only(Matcher().match(target([("DevOps Engineer", "São Paulo, Brazil")], listings)))
    assert (verdict.listing_index, verdict.location_note) == (1, None)

    elsewhere = only(Matcher().match(target([("DevOps Engineer", "Mexico City, Mexico")], listings)))
    assert elsewhere.verdict == "verified_live"
    assert elsewhere.location_note == "Listed for Poland; the posting says Mexico City, Mexico."


def test_remote_alone_is_not_a_location_to_disagree_with():
    verdict = only(Matcher().match(target([("RevOps Engineer", "Remote, Brazil")], [("RevOps Engineer", "Remote")])))

    assert verdict.location_note is None


def test_no_match_on_the_whole_list_is_not_found():
    verdict = only(Matcher().match(target([("RevOps Engineer", None)], [("Designer", None), ("Recruiter", None)])))

    assert (verdict.verdict, verdict.method) == ("not_found", "none")
    assert "None of the 2 roles" in verdict.reasoning


# A role on page two must never be marked closed.
def test_no_match_on_part_of_the_list_is_inconclusive():
    verdict = only(Matcher().match(target([("RevOps Engineer", None)], [("Designer", None)], complete=False)))

    assert verdict.verdict is None
    assert "inconclusive" in verdict.reasoning


def test_a_page_that_says_it_has_no_openings_makes_every_posting_not_found():
    result = Matcher().match(target([("RevOps Engineer", None), ("GTM Analyst", None)], []))

    assert [v.verdict for v in result.verdicts] == ["not_found", "not_found"]


def test_the_llm_decides_near_misses_and_its_cost_is_kept():
    judge = FakeAdjudicator({1: 1})
    result = Matcher(judge).match(target([("Sales Engineer LATAM", None)], [("Sales Engineer, Latin America", None)]))

    verdict = only(result)
    assert (verdict.verdict, verdict.method, verdict.listing_index) == ("verified_live", "llm", 0)
    assert verdict.reasoning == 'The page lists "Sales Engineer, Latin America", judged the same role: same job'
    assert result.llm.purpose == "match"


def test_a_near_miss_the_llm_rejects_is_not_found_on_the_whole_list():
    judge = FakeAdjudicator({1: None})
    verdict = only(Matcher(judge).match(target([("Solutions Engineer", None)], [("Solutions Engineer Manager", None)])))

    assert verdict.verdict == "not_found"
    assert "judged a different role" in verdict.reasoning


def test_all_near_misses_on_a_page_go_in_one_call_and_obvious_matches_never_do():
    judge = FakeAdjudicator({1: 2, 2: None})
    postings = [("Sales Engineer LATAM", None), ("Account Manager Brazil", None), ("Designer", None)]
    listings = [("Designer", None), ("Sales Engineer, Latin America", None), ("Account Executive Brazil", None)]

    Matcher(judge).match(target(postings, listings))

    assert len(judge.calls) == 1
    assert [title for title, _ in judge.calls[0]] == ["Sales Engineer LATAM", "Account Manager Brazil"]


def test_an_answer_outside_a_postings_own_candidates_is_ignored():
    judge = FakeAdjudicator({1: 1})  # listing 1 is not among its candidates
    verdict = only(
        Matcher(judge).match(
            target([("Sales Engineer LATAM", None)], [("Designer", None), ("Sales Engineer, Brazil", None)])
        )
    )

    assert verdict.verdict == "not_found"


def test_without_an_llm_near_misses_are_left_undecided_at_no_cost():
    result = Matcher(None).match(target([("Sales Engineer LATAM", None)], [("Sales Engineer, Latin America", None)]))

    assert only(result).verdict is None
    assert (result.reason, result.llm) == ("near_misses_not_judged", None)


def test_a_failed_llm_call_leaves_near_misses_undecided_and_keeps_what_it_cost():
    result = Matcher(FakeAdjudicator(fail="llm_refusal")).match(
        target([("Sales Engineer LATAM", None)], [("Sales Engineer, Latin America", None)])
    )

    assert only(result).verdict is None
    assert result.reason == "llm_refusal"
    assert result.llm.input_tokens == 300


# Found replaying Test B: the LLM matched "Data Engineer (GTM)" to "Data Foundry Engineer".
def test_a_same_judgement_is_not_trusted_when_each_title_names_something_the_other_lacks():
    judge = FakeAdjudicator({1: 1})
    verdict = only(Matcher(judge).match(target([("Data Engineer (GTM)", None)], [("Data Foundry Engineer", None)])))

    assert (verdict.verdict, verdict.method) == (None, "none")
    assert "(gtm / foundry)" in verdict.reasoning


def test_regions_and_seniority_do_not_count_as_naming_something_else():
    judge = FakeAdjudicator({1: 1})
    verdict = only(
        Matcher(judge).match(target([("Senior Sales Engineer LATAM", None)], [("Sales Engineer, Brazil", None)]))
    )

    assert verdict.verdict == "verified_live"
