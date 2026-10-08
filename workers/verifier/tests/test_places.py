import pytest

from verifier.places import EVERYWHERE, open_to, read, resolve


def names(text, **kwargs):
    return [place.name for place in read(text, **kwargs).places]


def test_a_profile_entry_resolves_to_the_place_it_names_by_any_name_or_code():
    assert {resolve(entry).name for entry in ("Brazil", "Brasil", "BR", "BRA")} == {"Brazil"}
    assert resolve("LATAM").name == resolve("Latin America").name == "Latin America"
    assert (resolve("São Paulo").kind, resolve("Sao Paulo").country) == ("within", "Brazil")
    assert resolve("Global") is EVERYWHERE
    assert resolve("Almaty") is None


@pytest.mark.parametrize(
    ("location", "named"),
    [
        ("São Paulo, BRA", ["São Paulo", "Brazil"]),
        ("BR-RJ-NITEROI-PRACA ALCIDES PEREIRA", ["Brazil", "Niterói"]),
        ("Remote - Canada, USA, or Latin America", ["Canada", "United States", "Latin America"]),
        ("U.S. Anywhere", ["United States", "anywhere"]),
        ("Albuquerque, New Mexico", ["New Mexico"]),  # the longest phrase first: a state, not Mexico
        ("Mexico City, Mexico", ["Mexico City", "Mexico"]),
        ("Remote", []),
    ],
)
def test_read_names_the_places_a_location_names_in_order(location, named):
    assert names(location) == named


def test_words_naming_no_known_place_are_kept_and_words_naming_none_are_not():
    assert read("Albuquerque, New Mexico").others == {"albuquerque"}
    assert read("Fully Remote (2 Locations), HQ").states_a_place is False
    assert read("Remote - Global").everywhere
    assert not read("U.S. Anywhere").everywhere


def test_a_title_names_places_by_name_and_only_the_safe_codes():
    assert names("Account Executive - UK", title=True) == ["United Kingdom"]
    assert names("PL/SQL Developer (PT)", title=True) == []  # not Poland, not Portugal
    assert names("GTM Engineer, Global Accounts", title=True) == []  # not Guatemala, and "Global" is accounts
    assert read("Sales Engineer, Kazakhstan", title=True).others == frozenset()


def test_a_role_is_open_to_a_country_in_it_or_in_a_region_containing_it():
    brazil = resolve("Brazil")
    assert all(open_to(resolve(found), brazil) for found in ("Brasil", "Curitiba", "Minas Gerais", "LATAM", "Americas"))
    assert not any(open_to(resolve(found), brazil) for found in ("Mexico", "North America", "EMEA"))


def test_a_role_is_open_to_a_region_only_in_it_or_in_one_containing_it():
    latam = resolve("LATAM")
    assert open_to(resolve("Latin America"), latam) and open_to(resolve("Americas"), latam)
    assert not open_to(resolve("Brazil"), latam)  # a role in Brazil is not open to all of Latin America
    assert not open_to(resolve("South America"), latam)  # nor one open to South America
