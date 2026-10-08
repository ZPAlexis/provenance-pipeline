import pytest

from verifier.contract import Listing, SearchProfile, SuggestTarget, TrackedPosting
from verifier.profiles import Profile, suggest

EVERY_MODE = ["remote", "hybrid", "onsite"]


def weigh(listing: Listing, **profile):
    return Profile(SearchProfile(**{"titles": ["Solutions Engineer"]} | profile)).fit(0, listing)


def role(title="Solutions Engineer", location="Remote - Brazil", work_mode="remote"):
    return Listing(title=title, location=location, work_mode=work_mode)


def test_a_title_fits_when_it_holds_every_word_of_a_profile_title_in_any_order():
    assert weigh(role("Engineer, Solutions")).title == "Solutions Engineer"
    assert weigh(role("Senior Solutions Engineer, LATAM")).suggested
    assert weigh(role("Solution Engineer")).suggested  # plurals folded
    assert weigh(role("Sales Engineer")) is None


def test_a_one_word_title_is_a_keyword_and_filler_words_are_aside():
    assert weigh(role("Revenue Operations Analyst"), titles=["RevOps", "Revenue"]).title == "Revenue"
    assert weigh(role("Revenue Operations Director"), titles=["Director of Revenue Operations"]).suggested
    assert weigh(role("Sr. Engineer, Solutions"), titles=["Senior Solutions Engineer"]).suggested


def test_the_first_profile_title_it_holds_is_the_one_named():
    fit = weigh(role("Senior Solutions Engineer"), titles=["Senior Solutions Engineer", "Solutions Engineer"])
    assert fit.title == "Senior Solutions Engineer"


def test_an_excluded_word_rules_a_title_out():
    fit = weigh(role("Solutions Engineer Intern"), excluded=["Intern", "Vice President"])
    assert (fit.suggested, fit.ruled_out) == (False, "excluded")
    assert fit.reasoning == (
        'Its title holds every word of "Solutions Engineer", '
        'but it also holds every word of "Intern", which is excluded.'
    )
    assert weigh(role("Solutions Engineer, Internal Tools"), excluded=["Intern"]).suggested  # words, not letters


def test_the_level_a_title_states_must_be_sought():
    assert weigh(role("Senior Solutions Engineer"), levels=["senior", "lead"]).suggested
    fit = weigh(role("Junior Solutions Engineer"), levels=["senior", "lead"])
    assert (fit.suggested, fit.ruled_out, fit.level) == (False, "level", "entry")


def test_a_title_stating_no_level_fits_marked_but_only_when_levels_narrow():
    fit = weigh(role(), levels=["senior"])
    assert (fit.suggested, fit.notes) == (True, ["level_not_stated"])
    assert weigh(role()).notes == []


def test_a_role_must_be_open_to_one_of_the_places_remote_roles_too():
    places = ["Brazil", "LATAM"]
    fit = weigh(role(location="Sao Paulo, SP"), places=places)
    assert (fit.suggested, fit.place) == (True, "Brazil")
    assert fit.reasoning.endswith('its location "Sao Paulo, SP" names São Paulo, in Brazil.')

    fit = weigh(role(location="Remote - US"), places=places)
    assert (fit.suggested, fit.ruled_out) == (False, "place")
    assert fit.reasoning.endswith('but its location "Remote - US" names none of the places sought.')


@pytest.mark.parametrize(
    "location",
    [
        "São Paulo, BRA", "BR-RJ-NITEROI-PRACA ALCIDES PEREIRA", "Belo Horizonte, MG, BR", "Brasil",
        "Latin America | Remote", "Americas Remote", "Remote - Canada, USA, or Latin America", "Remote - Global",
        "Worldwide",
    ],
)  # fmt: skip
def test_a_country_takes_roles_in_it_by_any_name_code_city_or_state_or_open_to_a_region_containing_it(location):
    assert weigh(role(location=location), places=["Brazil"]).suggested


@pytest.mark.parametrize(
    "location", ["North America", "United States - Remote", "EMEA", "Remote (United States | Canada)", "U.S. Anywhere"]
)
def test_a_country_leaves_out_roles_elsewhere_and_anywhere_narrowed_to_elsewhere(location):
    assert weigh(role(location=location), places=["Brazil"]).ruled_out == "place"


def test_the_reasoning_says_how_the_role_is_open_to_the_place():
    def why(location):
        return weigh(role(location=location), places=["Brasil"]).reasoning

    assert why("Brazil").endswith('its location "Brazil" names Brazil.')
    assert why("Latin America | Remote").endswith("names Latin America, which includes Brazil.")
    assert why("Remote - Global").endswith('its location "Remote - Global" is open anywhere.')


def test_a_region_takes_roles_open_to_it_never_every_role_inside_it():
    assert weigh(role(location="Americas Remote"), places=["LATAM"]).suggested
    assert weigh(role(location="São Paulo, Brazil"), places=["LATAM"]).ruled_out == "place"
    # The Americas take a role open to the Americas, not one in New York, nor one open to North America.
    assert weigh(role(location="New York, NY"), places=["Americas"]).ruled_out == "place"
    assert weigh(role(location="Remote, North America"), places=["Americas"]).ruled_out == "place"


def test_a_place_the_vocabulary_does_not_know_is_matched_by_its_words():
    assert weigh(role(location="Almaty, Kazakhstan"), places=["Kazakhstan"]).place == "Kazakhstan"
    assert weigh(role(location="Remote - Global"), places=["Kazakhstan"]).suggested
    assert weigh(role(location="Lehi, Utah"), places=["Kazakhstan"]).ruled_out == "place"


def test_a_location_naming_no_place_fits_marked():
    for location in ("Remote", "Fully Remote", "2 Locations", "", None):
        fit = weigh(role(location=location), places=["Brazil"])
        assert (fit.suggested, fit.notes, fit.place) == (True, ["place_not_stated"], None)
    assert weigh(role(location="Remote")).notes == []  # no places: nothing to weigh


def test_when_the_location_names_no_place_a_place_in_the_title_stands_in():
    places = ["Brazil", "LATAM"]
    fit = weigh(role("Solutions Engineer, LATAM", location="Remote"), places=places)
    assert (fit.suggested, fit.place, fit.notes) == (True, "Brazil", [])
    assert fit.reasoning.endswith(
        'its location "Remote" names no place, but its title names Latin America, which includes Brazil.'
    )

    fit = weigh(role("Senior Solutions Engineer - North America", location="Remote"), places=places)
    assert (fit.suggested, fit.ruled_out) == (False, "place")
    assert fit.reasoning.endswith("its title names North America, none of the places sought.")

    # "Global" in a title names accounts or teams, not where the role is.
    assert weigh(role("Global Solutions Engineer", location="Remote"), places=places).notes == ["place_not_stated"]
    # A location naming a place decides alone.
    assert weigh(role("Solutions Engineer, LATAM", location="Remote - US"), places=places).ruled_out == "place"


def test_the_work_mode_must_be_sought_and_an_unstated_one_fits_marked():
    assert weigh(role(work_mode="onsite", location="Brazil"), work_modes=["remote"]).ruled_out == "work_mode"

    fit = weigh(role(work_mode="unknown", location="Brazil"), work_modes=["remote", "hybrid"])
    assert (fit.suggested, fit.notes) == (True, ["work_mode_not_stated"])
    assert fit.reasoning.endswith("its work mode is not stated.")

    # Every mode sought: an unstated one changes nothing.
    assert weigh(role(work_mode="unknown"), work_modes=EVERY_MODE).notes == []


def test_an_unknown_work_mode_is_read_from_a_location_that_says():
    fit = weigh(role(work_mode="unknown", location="Remote - Brazil"), work_modes=["remote"])
    assert (fit.notes, fit.work_mode) == ([], "remote")
    assert weigh(role(work_mode="unknown", location="Remote or Hybrid")).work_mode == "unknown"
    assert weigh(role(work_mode="unknown", location="Hybrid - Brazil"), work_modes=["remote"]).ruled_out == "work_mode"


def test_the_reasoning_says_why_it_fits():
    fit = weigh(role(location="São Paulo, Brazil"), places=["Brazil"], work_modes=["remote"], levels=["senior"])
    assert fit.reasoning == (
        'Its title holds every word of "Solutions Engineer"; its title states no level; '
        'its location "São Paulo, Brazil" names Brazil; it is remote.'
    )


def test_suggest_returns_every_role_holding_a_title_and_counts_the_rest():
    target = SuggestTarget(
        id="c1",
        page_check_id="pc1",
        listings=[role(), role("Account Executive"), role(location="Remote - US")],
        profile=SearchProfile(titles=["Solutions Engineer"], places=["Brazil"]),
    )

    result = suggest(target)

    assert (result.target_id, result.page_check_id, result.weighed) == ("c1", "pc1", 3)
    assert [(fit.listing_index, fit.suggested) for fit in result.roles] == [(0, True), (2, False)]


def test_a_role_already_on_record_says_which_posting_it_is_matched_as_verification_matches():
    listings = [
        Listing(title="Solutions Engineer", location="São Paulo, Brazil", url="https://acme.example/jobs/1"),
        Listing(title="Senior Solutions Engineer", location="Remote - Brazil", url="https://acme.example/jobs/2"),
        Listing(title="Account Executive", location="Brazil", url="https://acme.example/jobs/3"),
        Listing(title="Solutions Engineer, LATAM", location="Latin America", url="https://acme.example/jobs/4"),
    ]
    postings = [
        TrackedPosting(id="by-link", title="SE (renamed since)", url="https://acme.example/jobs/1?utm_source=x"),
        TrackedPosting(id="by-title", title="Sr. Solutions Engineer"),
        TrackedPosting(id="not-a-fit", title="Account Executive"),
        TrackedPosting(id="gone", title="Data Engineer"),
    ]
    target = SuggestTarget(
        id="c1", listings=listings, postings=postings, profile=SearchProfile(titles=["Solutions Engineer"])
    )

    result = suggest(target)

    assert [(fit.listing_index, fit.on_record) for fit in result.roles] == [(0, "by-link"), (1, "by-title"), (3, None)]
    # Every posting found, fitting or not; one not in this read is missing, never guessed.
    assert result.listed == {"by-link": 0, "by-title": 1, "not-a-fit": 2}
