"""Places: what a location names, and whether a role there is open to where someone can work.

A place on a search profile means where the operator can work. A role is open to a
country when its location names the country (by any of its names or codes: Brazil,
Brasil, BR, BRA), a city or state in it (São Paulo, Minas Gerais), or a region that
contains it (South America, Latin America, Americas). A role is open to a region
when its location names that region or one containing it, never merely a place
inside it: "Americas" on a profile catches "Americas Remote", not every office in
New York. "Global", "Worldwide", or "Anywhere" opens a role to every place, but only
when its location names nothing narrower ("U.S. Anywhere" is the US).

Phrases are matched word by word in order (titles.title_words: accents and
punctuation aside), the longest first: "New Mexico" is a state, not Mexico. Codes
that are also common words (CA, DE, IN, IT, CAN, PER) are left out, as are cities
sharing a name with a place elsewhere (Salvador, Valencia, Cambridge).
"""

from dataclasses import dataclass, field
from typing import Literal

from verifier.titles import FILLER_WORDS, title_words

# Words a location uses that name no place: "Remote", "Fully remote", "Multiple locations", "HQ".
NO_PLACE_WORDS = {
    "remote", "remotely", "fully", "full", "part", "time", "home", "work", "from", "wfh", "virtual", "distributed",
    "flexible", "flex", "first", "friendly", "optional", "hybrid", "onsite", "on", "site", "office", "offices", "in",
    "or", "location", "locations", "multiple", "various", "based", "hq", "headquarters", "area", "greater", "metro",
    "metropolitan", "region", "only", "field", "territory", "travel", "nationwide", "tbd", "n",
}  # fmt: skip

Kind = Literal["everywhere", "region", "country", "within"]


@dataclass(frozen=True)
class Place:
    name: str
    kind: Kind
    country: str | None = None  # for a city or state: the country it is in
    within: frozenset[str] = field(default_factory=frozenset)  # every place containing it, by name


EVERYWHERE = Place("anywhere", "everywhere")
EVERYWHERE_PHRASES = ("global", "globally", "worldwide", "world wide", "anywhere", "world")

# name: (other names, regions it is part of)
REGIONS = {
    "Americas": ("The Americas, AMER", ()),
    "North America": ("NAMER, NORAM", ("Americas",)),
    "Latin America": ("LATAM, Lat Am, Latinoamérica, América Latina", ("Americas",)),
    "South America": ("Sudamérica, América do Sul, América del Sur", ("Americas",)),
    "Central America": ("", ("Latin America", "Americas")),
    "EMEA": ("", ()),
    "Europe": ("EU, European Union", ("EMEA",)),
    "DACH": ("", ("Europe", "EMEA")),
    "Nordics": ("Nordic, Nordic countries, Scandinavia", ("Europe", "EMEA")),
    "Benelux": ("", ("Europe", "EMEA")),
    "CEE": ("Central and Eastern Europe, Eastern Europe", ("Europe", "EMEA")),
    "Middle East": ("MENA", ("EMEA",)),
    "Africa": ("", ("EMEA",)),
    "APAC": ("Asia Pacific, Asia-Pacific, APJ", ()),
    "Asia": ("", ("APAC",)),
    "Southeast Asia": ("South East Asia, SEA region", ("Asia", "APAC")),
    "ANZ": ("", ("APAC",)),
}

_US_STATES = (
    "Alabama, Alaska, Arizona, Arkansas, California, Colorado, Connecticut, Delaware, Florida, Hawaii, Idaho, "
    "Illinois, Indiana, Iowa, Kansas, Kentucky, Louisiana, Maine, Maryland, Massachusetts, Michigan, Minnesota, "
    "Mississippi, Missouri, Montana, Nebraska, Nevada, New Hampshire, New Jersey, New Mexico, New York, "
    "North Carolina, North Dakota, Ohio, Oklahoma, Oregon, Pennsylvania, Rhode Island, South Carolina, South Dakota, "
    "Tennessee, Texas, Utah, Vermont, Virginia, Washington, West Virginia, Wisconsin, Wyoming, District of Columbia"
)
_US_CITIES = (
    "New York City, NYC, San Francisco, Bay Area, SF Bay Area, Los Angeles, Seattle, Boston, Chicago, Austin, Denver, "
    "Atlanta, Miami, Dallas, Houston, San Diego, Palo Alto, Mountain View, Menlo Park, Redwood City, Sunnyvale, "
    "Santa Clara, San Mateo, Oakland, Pittsburgh, Philadelphia, Salt Lake City, Lehi, Raleigh, Nashville, Minneapolis, "
    "Detroit, Portland, Brooklyn, Boulder, Las Vegas, Kansas City, Baltimore, Arlington, Reston, Irvine, Scottsdale, "
    "Tampa, Orlando, Cincinnati, Cleveland, Indianapolis, Milwaukee, Sacramento, Washington DC"
)
_BRAZIL_STATES = (
    "Minas Gerais, Paraná, Santa Catarina, Rio Grande do Sul, Rio Grande do Norte, Bahia, Pernambuco, Ceará, Goiás, "
    "Espírito Santo, Maranhão, Paraíba, Alagoas, Sergipe, Piauí, Mato Grosso, Mato Grosso do Sul, Rondônia, "
    "Tocantins, Amapá, Roraima, Distrito Federal"
)
_BRAZIL_CITIES = (
    "São Paulo, Rio de Janeiro, Belo Horizonte, Curitiba, Porto Alegre, Brasília, Campinas, Fortaleza, Recife, "
    "Florianópolis, Niterói, Macaé, Goiânia, Manaus, Belém, Joinville, São José dos Campos, Uberlândia, "
    "Ribeirão Preto, Sorocaba, Londrina, Blumenau, Barueri, Osasco, Taubaté, Juiz de Fora, João Pessoa, Maceió, "
    "Aracaju, Teresina, Cuiabá, Campo Grande, Santo André, São Bernardo do Campo, Guarulhos, Jundiaí"
)

# name: (other names, codes, regions it is part of, cities and states in it)
COUNTRIES = {
    # The Americas
    "United States": (
        "United States of America, USA, U.S., U.S.A.",
        "US, USA",
        ("North America",),
        f"{_US_STATES}, {_US_CITIES}",
    ),
    "Canada": (
        "",
        "",
        ("North America",),
        "Ontario, Quebec, British Columbia, Alberta, Manitoba, Nova Scotia, Toronto, Vancouver, Montreal, Montréal, "
        "Ottawa, Calgary, Edmonton, Waterloo, Kitchener",
    ),
    "Mexico": (
        "México",
        "MX, MEX",
        ("North America", "Latin America"),
        "Mexico City, Ciudad de México, CDMX, Guadalajara, Monterrey, Querétaro, Puebla, Tijuana",
    ),
    "Brazil": ("Brasil", "BR, BRA", ("South America", "Latin America"), f"{_BRAZIL_STATES}, {_BRAZIL_CITIES}"),
    "Argentina": ("", "ARG", ("South America", "Latin America"), "Buenos Aires, Rosario, Mendoza, La Plata"),
    "Chile": ("", "CL, CHL", ("South America", "Latin America"), "Santiago de Chile, Valparaíso"),
    "Colombia": ("", "COL", ("South America", "Latin America"), "Bogotá, Medellín, Cali, Barranquilla"),
    "Peru": ("Perú", "", ("South America", "Latin America"), "Lima, Arequipa"),
    "Uruguay": ("", "UY, URY", ("South America", "Latin America"), "Montevideo"),
    "Paraguay": ("", "PRY", ("South America", "Latin America"), "Asunción"),
    "Bolivia": ("", "BOL", ("South America", "Latin America"), "La Paz"),
    "Ecuador": ("", "ECU", ("South America", "Latin America"), "Quito, Guayaquil"),
    "Venezuela": ("", "VEN", ("South America", "Latin America"), "Caracas"),
    "Costa Rica": ("", "CRI", ("Central America",), "Heredia"),
    "Panama": ("Panamá", "", ("Central America",), ""),
    "Guatemala": ("", "", ("Central America",), ""),  # GTM is as likely go-to-market
    "Dominican Republic": ("República Dominicana", "", ("Latin America",), "Santo Domingo"),
    # Europe
    "United Kingdom": (
        "UK, U.K., Great Britain, Britain, England, Scotland, Wales, Northern Ireland",
        "GB, GBR",
        ("Europe",),
        "London, Manchester, Edinburgh, Glasgow, Bristol, Leeds, Oxford, Belfast, Brighton, Liverpool",
    ),
    "Ireland": ("Republic of Ireland, Éire", "IRL", ("Europe",), "Dublin, Cork, Galway, Limerick"),
    "Germany": (
        "Deutschland",
        "DEU, GER",
        ("DACH",),
        "Berlin, Munich, München, Hamburg, Frankfurt, Cologne, Köln, Stuttgart, Düsseldorf, Leipzig, Dresden, "
        "Nuremberg, Nürnberg",
    ),
    "Austria": ("Österreich", "AUT", ("DACH",), "Vienna, Wien, Graz, Linz, Salzburg"),
    "Switzerland": (
        "Schweiz, Suisse, Svizzera",
        "CH, CHE",
        ("DACH",),
        "Zurich, Zürich, Geneva, Genève, Basel, Lausanne, Bern, Zug",
    ),
    "France": ("", "FR, FRA", ("Europe",), "Paris, Lyon, Marseille, Toulouse, Lille, Nantes, Bordeaux"),
    "Spain": ("España", "ESP", ("Europe",), "Madrid, Barcelona, Seville, Sevilla, Málaga, Bilbao"),
    "Portugal": ("", "PT, PRT", ("Europe",), "Lisbon, Lisboa, Braga, Coimbra"),
    "Italy": ("Italia", "ITA", ("Europe",), "Milan, Milano, Rome, Roma, Turin, Torino, Bologna, Florence, Firenze"),
    "Netherlands": (
        "The Netherlands, Holland, Nederland",
        "NL, NLD",
        ("Benelux",),
        "Amsterdam, Rotterdam, Utrecht, Eindhoven, The Hague, Den Haag",
    ),
    "Belgium": ("Belgique, België", "BEL", ("Benelux",), "Brussels, Bruxelles, Antwerp, Ghent"),
    "Luxembourg": ("", "LUX", ("Benelux",), ""),
    "Denmark": ("Danmark", "DK, DNK", ("Nordics",), "Copenhagen, København, Aarhus"),
    "Sweden": ("Sverige", "SWE", ("Nordics",), "Stockholm, Gothenburg, Göteborg, Malmö"),
    "Norway": ("Norge", "", ("Nordics",), "Oslo, Bergen"),
    "Finland": ("Suomi", "", ("Nordics",), "Helsinki, Espoo, Tampere"),
    "Iceland": ("", "", ("Nordics",), "Reykjavík"),
    "Poland": ("Polska", "PL, POL", ("CEE",), "Warsaw, Warszawa, Kraków, Wrocław, Gdańsk, Poznań, Łódź"),
    "Czechia": ("Czech Republic", "CZE", ("CEE",), "Prague, Praha, Brno"),
    "Romania": ("", "ROU", ("CEE",), "Bucharest, Cluj-Napoca, Iași"),
    "Hungary": ("", "HUN", ("CEE",), "Budapest"),
    "Ukraine": ("", "UKR", ("CEE",), "Kyiv, Kiev, Lviv, Kharkiv"),
    "Estonia": ("", "", ("CEE",), "Tallinn"),
    "Latvia": ("", "", ("CEE",), "Riga"),
    "Lithuania": ("", "", ("CEE",), "Vilnius"),
    "Bulgaria": ("", "", ("CEE",), ""),
    "Serbia": ("", "", ("CEE",), "Belgrade"),
    "Croatia": ("", "", ("CEE",), "Zagreb"),
    "Greece": ("", "GRC", ("Europe",), ""),
    "Turkey": ("Türkiye", "TUR", ("Europe", "Middle East"), "Istanbul, Ankara"),
    # Middle East and Africa
    "Israel": ("", "ISR", ("Middle East",), "Tel Aviv, Jerusalem, Haifa"),
    "United Arab Emirates": ("UAE", "", ("Middle East",), "Dubai, Abu Dhabi"),
    "Saudi Arabia": ("KSA", "", ("Middle East",), "Riyadh, Jeddah"),
    "Qatar": ("", "", ("Middle East",), "Doha"),
    "Egypt": ("", "EGY", ("Africa", "Middle East"), "Cairo"),
    "South Africa": ("", "ZAF", ("Africa",), "Cape Town, Johannesburg, Durban, Pretoria"),
    "Nigeria": ("", "NGA", ("Africa",), "Abuja"),
    "Kenya": ("", "KEN", ("Africa",), "Nairobi"),
    "Ghana": ("", "", ("Africa",), "Accra"),
    "Morocco": ("", "", ("Africa",), "Casablanca"),
    # Asia-Pacific
    "India": (
        "",
        "IND",
        ("Asia",),
        "Bengaluru, Bangalore, Mumbai, Delhi, New Delhi, Hyderabad, Pune, Chennai, Gurgaon, Gurugram, Noida, "
        "Kolkata, Ahmedabad, Kochi",
    ),
    "Singapore": ("", "SG, SGP", ("Southeast Asia",), ""),
    "Japan": ("", "JP, JPN", ("Asia",), "Tokyo, Osaka, Kyoto"),
    "South Korea": ("Korea, Republic of Korea", "KR, KOR", ("Asia",), "Seoul"),
    "China": ("", "CN, CHN", ("Asia",), "Beijing, Shanghai, Shenzhen, Guangzhou, Hangzhou"),
    "Hong Kong": ("", "HK, HKG", ("Asia",), ""),
    "Taiwan": ("", "TW, TWN", ("Asia",), "Taipei"),
    "Philippines": ("", "PH, PHL", ("Southeast Asia",), "Manila, Cebu, Makati, Taguig"),
    "Vietnam": ("Viet Nam", "VN, VNM", ("Southeast Asia",), "Hanoi, Ho Chi Minh City, Ho Chi Minh, Saigon, Da Nang"),
    "Thailand": ("", "THA", ("Southeast Asia",), "Bangkok"),
    "Indonesia": ("", "IDN", ("Southeast Asia",), "Jakarta, Bali"),
    "Malaysia": ("", "MYS", ("Southeast Asia",), "Kuala Lumpur"),
    "Pakistan": ("", "PK, PAK", ("Asia",), "Karachi, Lahore, Islamabad"),
    "Australia": (
        "",
        "AU, AUS",
        ("ANZ",),
        "Sydney, Melbourne, Brisbane, Perth, Adelaide, Canberra, New South Wales, Queensland",
    ),
    "New Zealand": ("", "NZ, NZL", ("ANZ",), "Auckland, Wellington, Christchurch"),
}  # fmt: skip

# A title's codes are only these: in a title "PL" is as likely PL/SQL as Poland, and "PT" part-time.
TITLE_CODES = {("us",), ("usa",), ("uk",), ("uae",)}


def _phrases(text: str) -> list[str]:
    return [phrase.strip() for phrase in text.split(",") if phrase.strip()]


def _region_within(name: str) -> frozenset[str]:
    parents = REGIONS[name][1]
    return frozenset(parents).union(*(_region_within(parent) for parent in parents))


def _build() -> tuple[dict[tuple[str, ...], Place], set[tuple[str, ...]]]:
    index: dict[tuple[str, ...], Place] = {}
    codes: set[tuple[str, ...]] = set()

    def add(phrase: str, place: Place) -> None:
        index.setdefault(tuple(title_words(phrase)), place)

    for phrase in EVERYWHERE_PHRASES:
        add(phrase, EVERYWHERE)
    for name, (aliases, _parents) in REGIONS.items():
        region = Place(name, "region", within=_region_within(name))
        for phrase in [name, *_phrases(aliases)]:
            add(phrase, region)
    for name, (aliases, country_codes, regions, inside) in COUNTRIES.items():
        within = frozenset(regions).union(*(_region_within(region) for region in regions))
        country = Place(name, "country", within=within)
        for phrase in [name, *_phrases(aliases), *_phrases(country_codes)]:
            add(phrase, country)
        codes.update(tuple(title_words(code)) for code in _phrases(country_codes))
        for phrase in _phrases(inside):
            add(phrase, Place(phrase, "within", country=name, within=within | {name}))
    return index, codes


PLACES, CODES = _build()
_LONGEST = max(len(phrase) for phrase in PLACES)


@dataclass(frozen=True)
class Reading:
    """What a location (or a title) says about where a role is."""

    places: tuple[Place, ...]  # the known places it names, in order
    others: frozenset[str]  # words left over that may name a place this vocabulary does not know

    @property
    def everywhere(self) -> bool:
        """Open anywhere: it names "Global", "Worldwide", or "Anywhere", and nothing narrower."""
        return bool(self.places) and all(place is EVERYWHERE for place in self.places) and not self.others

    @property
    def narrower(self) -> tuple[Place, ...]:
        return tuple(place for place in self.places if place is not EVERYWHERE)

    @property
    def states_a_place(self) -> bool:
        return bool(self.places or self.others)


def read(text: str | None, *, title: bool = False) -> Reading:
    """The places a location names. In a title, only names and the few safe codes count, and never "Global"."""
    words = title_words(text)
    found: list[Place] = []
    others: set[str] = set()
    index = 0
    while index < len(words):
        for size in range(min(_LONGEST, len(words) - index), 0, -1):
            phrase = tuple(words[index : index + size])
            place = PLACES.get(phrase)
            if place and not (title and (place is EVERYWHERE or (phrase in CODES and phrase not in TITLE_CODES))):
                found.append(place)
                index += size
                break
        else:
            word = words[index]
            if word not in NO_PLACE_WORDS and word not in FILLER_WORDS and not word.isdigit():
                others.add(word)
            index += 1
    return Reading(tuple(found), frozenset() if title else frozenset(others))


def resolve(text: str) -> Place | None:
    """The known place a profile entry is, if it is one: "Brasil" is Brazil, "LATAM" is Latin America."""
    return PLACES.get(tuple(title_words(text)))


def open_to(found: Place, sought: Place) -> bool:
    """Whether a role at `found` is open to someone who can work at `sought`.

    The same place, or one containing it (Latin America for Brazil); for a country,
    also a city or state in it. Never a place merely inside a region or city sought.
    """
    if found.name == sought.name or found.name in sought.within:
        return True
    return sought.kind == "country" and found.kind == "within" and found.country == sought.name
