"""Which stored roles fit a search profile, and why.

A role fits when each of these holds, weighed in this order:

- its title holds every word of one of the profile's titles, in any order: "Engineer,
  Solutions" holds "Solutions Engineer", and a one-word title is a keyword. Words are
  compared as titles are everywhere (titles.title_words: "Sr." is "Senior"), with
  plurals folded ("Solution" holds "Solutions") and filler words ("of", "de") aside;
- it holds every word of none of the excluded ones;
- the level its title states is one sought;
- it is open to one of the places, which mean where the operator can work
  (places.py): a role in São Paulo, BRA, or open to Latin America, is open to Brazil.
  Remote roles too: a remote role is open to some places, not all. When the location
  names no place ("Remote"), a place its title names stands in: "Sales Engineer, North
  America" is not open to Brazil. A place the vocabulary does not know is matched by
  its words, every one of them;
- its work mode is one sought. A mode the listing left unknown is read from its
  location ("Remote", "Hybrid") when that says.

What a role does not state is never held against it: no location, one naming no place
("Remote" alone) with none in its title either, no work mode, or a title stating no
level fits, marked for the operator to weigh. It is marked only where the profile
narrows: with every work mode sought, an unstated one changes nothing.

Every role holding a profile title comes back, suggested or ruled out by the first
rule it fails, so a profile can be tuned against what it leaves out. The rest are
only counted.
"""

import time

from verifier import places
from verifier.contract import FitNote, Listing, RoleFit, RuledOut, SearchProfile, SuggestionResult, SuggestTarget
from verifier.places import Place, Reading
from verifier.titles import FILLER_WORDS, LEVELS, title_level, title_words

WORK_MODES = ("remote", "hybrid", "onsite")
MODE_LABELS = {"remote": "remote", "hybrid": "hybrid", "onsite": "on-site"}
MODE_WORDS = {"remote": "remote", "remotely": "remote", "hybrid": "hybrid"}


def suggest(target: SuggestTarget) -> SuggestionResult:
    """One company's stored roles weighed against the profile."""
    started = time.monotonic()
    profile = Profile(target.profile)
    roles = [fit for index, listing in enumerate(target.listings) if (fit := profile.fit(index, listing))]
    return SuggestionResult(
        target_id=target.id,
        page_check_id=target.page_check_id,
        weighed=len(target.listings),
        roles=roles,
        duration_ms=int((time.monotonic() - started) * 1000),
    )


class Profile:
    """A search profile with its words and places worked out once, to weigh many roles."""

    def __init__(self, profile: SearchProfile):
        self.titles = [(title, words) for title in profile.titles if (words := _title_words(title))]
        self.excluded = [(phrase, words) for phrase in profile.excluded if (words := _title_words(phrase))]
        # Each place as entered, the known place it is (if it is one), and its words.
        self.places = [
            (entry, places.resolve(entry), words) for entry in profile.places if (words := _place_words(entry))
        ]
        self.work_modes = set(profile.work_modes) or set(WORK_MODES)
        self.levels = set(profile.levels) or set(LEVELS)

    def fit(self, index: int, listing: Listing) -> RoleFit | None:
        """The role weighed against the profile; None when its title holds none of the profile's titles."""
        words = _title_words(listing.title)
        title = next((title for title, needed in self.titles if needed <= words), None)
        if title is None:
            return None

        level, mode = title_level(listing.title), _work_mode(listing)
        found = RoleFit(
            listing_index=index, listing=listing, title=title, level=level, work_mode=mode, suggested=True, reasoning=""
        )
        said = [f'Its title holds every word of "{title}"']

        def ruled_out(rule: RuledOut, why: str) -> RoleFit:
            reasoning = f"{'; '.join(said)}, but {why}."
            return found.model_copy(update={"suggested": False, "ruled_out": rule, "reasoning": reasoning})

        def unstated(note: FitNote, why: str) -> None:
            found.notes.append(note)
            said.append(why)

        if excluded := next((phrase for phrase, needed in self.excluded if needed <= words), None):
            return ruled_out("excluded", f'it also holds every word of "{excluded}", which is excluded')

        if self.levels != set(LEVELS):
            if level is None:
                unstated("level_not_stated", "its title states no level")
            elif level not in self.levels:
                return ruled_out("level", f"it is {level} level, which is not sought")
            else:
                said.append(f"it is {level} level")

        if self.places:
            location = (listing.location or "").strip()
            reading = places.read(location)
            if reading.states_a_place:
                if not (match := self._open_to(reading, _place_words(location))):
                    return ruled_out("place", f'its location "{location}" names none of the places sought')
                found.place, how = match
                said.append(f'its location "{location}" {how}')
            else:
                nowhere = f'its location "{location}" names no place' if location else "it states no location"
                in_title = places.read(listing.title, title=True)
                if not in_title.places:
                    unstated("place_not_stated", nowhere)
                elif match := self._open_to(in_title):
                    found.place, how = match
                    said.append(f"{nowhere}, but its title {how}")
                else:
                    named = ", ".join(dict.fromkeys(place.name for place in in_title.places))
                    return ruled_out("place", f"{nowhere}, and its title names {named}, none of the places sought")

        if self.work_modes != set(WORK_MODES):
            if mode == "unknown":
                unstated("work_mode_not_stated", "its work mode is not stated")
            elif mode not in self.work_modes:
                return ruled_out("work_mode", f"it is {MODE_LABELS[mode]}, which is not sought")
            else:
                said.append(f"it is {MODE_LABELS[mode]}")

        found.reasoning = f"{'; '.join(said)}."
        return found

    def _open_to(self, reading: Reading, words: set[str] | None = None) -> tuple[str, str] | None:
        """The first profile place a role read so is open to, as entered, and how; None when none.

        `words` are the location's own, for places the vocabulary does not know.
        """
        for entry, sought, needed in self.places:
            if sought is None:
                if words is not None and needed <= words:
                    return entry, f"names {entry}"
                continue
            if open_places := [found for found in reading.narrower if places.open_to(found, sought)]:
                # Said most directly: the place itself, then a city or state in it, then a region containing it.
                found = min(open_places, key=lambda found: (found.name != sought.name, found.kind != "within"))
                return entry, _how(found, sought)
        if reading.everywhere:
            return self.places[0][0], "is open anywhere"
        return None


def _how(found: Place, sought: Place) -> str:
    """Why a role at `found` is open to someone at `sought`, for the reasoning."""
    if found.name == sought.name:
        return f"names {found.name}"
    if found.kind == "within" and found.country == sought.name:
        return f"names {found.name}, in {sought.name}"
    return f"names {found.name}, which includes {sought.name}"


def _title_words(text: str | None) -> set[str]:
    """A title's words as a profile weighs them: plurals folded, filler aside (unless it is all filler)."""
    words = {_singular(word) for word in title_words(text)}
    return words - FILLER_WORDS or words


def _place_words(text: str | None) -> set[str]:
    """A place's words: as titles are normalized, but never folded ("Americas" is not "America")."""
    words = set(title_words(text))
    return words - FILLER_WORDS or words


def _singular(word: str) -> str:
    return word[:-1] if len(word) > 3 and word.endswith("s") and not word.endswith("ss") else word


def _work_mode(listing: Listing) -> str:
    """The listing's work mode; when it left that unknown, the one its location names, if just one."""
    if listing.work_mode != "unknown":
        return listing.work_mode
    named = {MODE_WORDS[word] for word in title_words(listing.location) if word in MODE_WORDS}
    return named.pop() if len(named) == 1 else "unknown"
