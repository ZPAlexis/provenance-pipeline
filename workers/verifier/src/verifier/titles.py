"""Role titles: what a title is, word by word, wherever titles are compared.

One normalization and one vocabulary for every comparison of titles: matching a
posting to a listing (match.py), measuring how many of a page's roles a board
lists (boards.py), and telling whether a role's own page shows it (check.py).
A change here changes all of them at once, on purpose: "Sr." meaning "Senior"
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
