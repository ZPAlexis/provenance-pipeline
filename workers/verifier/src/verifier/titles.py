"""Role titles: what a title is, word by word, wherever titles are compared.

One normalization and one vocabulary for every comparison of titles: matching a
posting to a listing (match.py), measuring how many of a page's roles a board
lists (boards.py), telling whether a role's own page shows it or naming the role
from it (check.py), and fitting a role to a search profile (profiles.py). A
change here changes all of them at once, on purpose: "Sr." meaning "Senior"
cannot be true for matching and false for board adoption.
"""

import re
import unicodedata

ABBREVIATIONS = {"sr": "senior", "jr": "junior"}

# Words that tell two titles apart without making them different jobs.
SENIORITY_WORDS = {"senior", "junior", "staff", "i", "ii", "iii", "iv", "1", "2", "3"}
REGION_WORDS = {
    "latam", "latin", "america", "americas", "north", "south", "emea", "apac", "amer", "europe", "eu", "uk",
    "us", "usa", "na", "global", "remote", "brazil", "brasil", "mexico", "canada", "argentina", "colombia",
}  # fmt: skip
FILLER_WORDS = {"and", "of", "the", "for", "de", "da", "do", "e", "y", "en", "to", "a", "an"}

# Words that make a title a different level of responsibility, not a variant.
LEVEL_WORDS = {
    "manager",
    "management",
    "director",
    "head",
    "vp",
    "vice",
    "president",
    "chief",
    "officer",
    "lead",
    "leader",
    "principal",
    "intern",
    "internship",
    "apprentice",
    "trainee",
    "assistant",
}


def title_words(title: str | None) -> list[str]:
    """A title's words: lowercase, accents and punctuation aside, abbreviations spelled out."""
    text = unicodedata.normalize("NFKD", title or "")
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).lower()
    return [ABBREVIATIONS.get(word, word) for word in re.findall(r"[a-z0-9]+", text)]


# A role's level of experience, as its title states it, lowest to highest. The
# highest stated wins: a "Senior Director" is a director. "Manager" states none,
# naming a kind of role as often as a level ("Product Manager", "Account Manager");
# neither do numerals, nor "Associate", which opens entry titles and director ones.
LEVELS = ("entry", "senior", "lead", "director", "executive")
LEVEL_OF = {
    "intern": "entry", "internship": "entry", "apprentice": "entry", "trainee": "entry",
    "junior": "entry", "graduate": "entry", "grad": "entry", "entry": "entry",
    "senior": "senior", "staff": "senior", "principal": "senior",
    "lead": "lead", "leader": "lead",
    "director": "director", "head": "director",
    "vp": "executive", "svp": "executive", "evp": "executive", "president": "executive", "chief": "executive",
    "ceo": "executive", "cto": "executive", "cfo": "executive", "coo": "executive", "cro": "executive",
    "cmo": "executive", "cio": "executive", "ciso": "executive", "cpo": "executive",
}  # fmt: skip
# "Lead" before these names sales work, not a level: "Lead Generation Specialist".
_LEAD_AS_NOUN = {"generation", "gen"}


def title_level(title: str | None) -> str | None:
    """The level a title states, or None when it states none (most titles: "Solutions Engineer")."""
    words = title_words(title)
    stated = [
        LEVEL_OF[word]
        for word, following in zip(words, [*words[1:], None], strict=True)
        if word in LEVEL_OF and not (word == "lead" and following in _LEAD_AS_NOUN)
    ]
    return max(stated, key=LEVELS.index, default=None)


# Words a heading uses when it names the page or the company, not a role: "Careers", "Join us", "Vagas".
PAGE_WORDS = {
    "careers", "career", "jobs", "job", "openings", "opening", "opportunities", "opportunity", "positions",
    "position", "vacancies", "vacancy", "join", "us", "our", "team", "work", "with", "apply", "now", "details",
    "description", "home", "page", "welcome", "not", "found", "error", "404", "vagas", "vaga", "trabalhe",
    "conosco", "carreiras", "oportunidades", "empleos", "empleo", "trabaja", "nosotros", "detalhes", "detalles",
}  # fmt: skip
# Where a page's title runs its parts together: "Sales Engineer | Acme Careers", "Sales Engineer – Acme".
_HEADING_PARTS = re.compile(r"\s+[|–—·•@-]\s+|\s*\|\s*")
MAX_TITLE_CHARS = 100


def heading_title(headings: list[str | None], company: str | None = None) -> str | None:
    """A role's title from its own page's headings (its h1, then its <title>), when one plainly names it.

    Parts naming only the company or the page ("Acme Careers", "Join us") are dropped, the rest kept in order:
    "Sales Engineer - LATAM | Acme Careers" is "Sales Engineer - LATAM". None when no heading names a role
    plainly: the caller reads the page another way.
    """
    named = set(title_words(company))
    beside = named | PAGE_WORDS | FILLER_WORDS
    for heading in headings:
        parts = [_without_company(part.strip(), named) for part in _HEADING_PARTS.split(heading or "")]
        kept = [part for part in parts if not set(title_words(part)) <= beside]
        title = " - ".join(kept)
        if kept and len(title) <= MAX_TITLE_CHARS:
            return title
    return None


def _without_company(part: str, company: set[str]) -> str:
    """A part without its trailing "at Acme" ("em", "en", "na" Acme): the company, not the role."""
    match = re.search(r"\s+(?:at|em|en|na|no|bei|chez)\s+(.+)$", part, re.IGNORECASE)
    if company and match and set(title_words(match.group(1))) <= company | FILLER_WORDS:
        return part[: match.start()]
    return part
