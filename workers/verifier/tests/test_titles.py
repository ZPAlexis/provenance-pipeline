from typing import get_args

import pytest

from verifier.contract import Level
from verifier.titles import LEVELS, heading_title, title_level, title_words


def test_title_words_spell_out_abbreviations_and_drop_accents():
    assert title_words("Sr. Engenheiro de Soluções") == ["senior", "engenheiro", "de", "solucoes"]


@pytest.mark.parametrize(
    ("title", "level"),
    [
        ("Solutions Engineer", None),
        ("Product Manager", None),  # "Manager" names the kind of role as often as a level
        ("Software Engineer II", None),
        ("Associate Account Executive", None),
        ("Jr. Data Analyst", "entry"),
        ("Sales Intern", "entry"),
        ("Sr. Solutions Engineer", "senior"),
        ("Staff Engineer", "senior"),
        ("Principal Engineer", "senior"),
        ("Team Lead, Support", "lead"),
        ("Lead Generation Specialist", None),  # sales work, not a level
        ("Head of Revenue Operations", "director"),
        ("Senior Director, Sales", "director"),  # the highest stated wins
        ("Senior Vice President, Marketing", "executive"),
        ("VP Sales", "executive"),
        ("Chief Revenue Officer", "executive"),
    ],
)
def test_title_level_is_the_highest_its_title_states(title, level):
    assert title_level(title) == level


def test_the_contract_names_the_same_levels():
    assert get_args(Level) == LEVELS


@pytest.mark.parametrize(
    ("headings", "title"),
    [
        (["Solutions Engineer", "Solutions Engineer — Example Co"], "Solutions Engineer"),
        (["", "Sales Engineer | Acme Careers"], "Sales Engineer"),
        (["Sales Engineer - LATAM | Acme"], "Sales Engineer - LATAM"),  # its own qualifier kept
        (["", "RevOps Engineer at Acme"], "RevOps Engineer"),
        (["Engenheiro de Vendas na Acme"], "Engenheiro de Vendas"),
        (["Pre-Sales Engineer"], "Pre-Sales Engineer"),  # a hyphen inside a word joins it
        (["Join Acme", "Careers | Acme"], None),  # only the company and the page: unclear
        (["Vagas", "Trabalhe conosco - Acme"], None),
        (["x" * 120], None),  # longer than any title
    ],
)
def test_heading_title_names_a_role_only_when_a_heading_plainly_does(headings, title):
    assert heading_title(headings, "Acme") == title
