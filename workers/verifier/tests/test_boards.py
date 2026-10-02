from verifier.boards import find_board
from verifier.contract import AtsBoard, BoardTarget, Listing

ROLES = [
    "Account Executive",
    "Solutions Engineer",
    "Data Engineer",
    "Product Designer",
    "Revenue Operations Manager",
    "Customer Success Manager",
    "Security Engineer",
    "Recruiter",
    "Staff Accountant",
    "Head of Marketing",
]


class FakeBoardReader:
    """Scripted boards: `boards` is every guessed board that lists jobs, in the order tried."""

    def __init__(self, boards=(), confirms=False, links=None):
        self.boards, self.confirms, self.links = list(boards), confirms, links
        self.searched = False

    def guess_boards(self, target):
        self.searched = True
        return iter(self.boards)

    def board_confirms(self, board, target):
        return self.confirms

    def board_links(self, board):
        return self.links


def board(vendor, name, titles):
    return AtsBoard(vendor=vendor, board=name), [Listing(title=title) for title in titles]


def company(titles=ROLES):
    return BoardTarget(id="c1", name="Acme", domain="acme.example", titles=titles)


def test_adopts_a_board_listing_the_same_roles_as_the_page():
    result = find_board(company(), FakeBoardReader([board("greenhouse", "acme", ROLES)], confirms=True))

    assert (result.outcome, result.overlap, result.board_roles, result.owner) == ("adopted", 1.0, 10, "confirmed")
    assert result.board == AtsBoard(vendor="greenhouse", board="acme")
    assert "lists 100% of the 10 roles" in result.evidence
    assert "the vendor records the same company name" in result.evidence


def test_adopts_a_board_with_nearly_every_role_and_more_besides():
    titles = ROLES[:9] + ["Sales Engineer", "Legal Counsel"]

    result = find_board(company(), FakeBoardReader([board("ashby", "acme", titles)]))

    assert (result.outcome, result.overlap, result.board_roles) == ("adopted", 0.9, 11)


def test_compares_titles_by_their_words_not_their_spelling():
    page = ["Sr. Account Executive", "Solutions Engineer", "Data Engineer", "Product Designer", "Recruiter"]
    titles = ["Senior Account Executive", "solutions engineer", "Data  Engineer", "Product Designer", "Recruiter"]

    result = find_board(company(page), FakeBoardReader([board("lever", "acme", titles)]))

    assert (result.outcome, result.overlap) == ("adopted", 1.0)


# Found in the board survey: Profound and Range each have a Greenhouse board with
# their exact name, belonging to another company and sharing none of their roles.
def test_rejects_a_board_of_the_same_name_that_lists_other_roles():
    result = find_board(company(), FakeBoardReader([board("greenhouse", "acme", ["Line Cook", "Bartender"])], True))

    assert (result.outcome, result.reason, result.overlap, result.owner) == (
        "rejected",
        "low_overlap",
        0.0,
        "confirmed",
    )


def test_rejects_a_board_missing_too_many_of_the_pages_roles():
    result = find_board(company(), FakeBoardReader([board("ashby", "acme", ROLES[:8])]))

    assert (result.outcome, result.overlap) == ("rejected", 0.8)


# Found in the board survey: LiveKit's own board links home to livekit.io, not
# the domain on record, yet lists every role its page does.
def test_adopts_a_board_that_links_to_another_domain_when_it_lists_the_same_roles():
    reader = FakeBoardReader([board("ashby", "acme", ROLES)], links=["https://acme-labs.example/"])

    result = find_board(company(), reader)

    assert (result.outcome, result.owner, result.owner_host) == ("adopted", "elsewhere", "acme-labs.example")
    assert "not the company's site" in result.evidence


def test_picks_the_board_that_lists_the_pages_roles_among_several():
    reader = FakeBoardReader([board("greenhouse", "acme", ["Line Cook"]), board("ashby", "acme", ROLES)])

    result = find_board(company(), reader)

    assert (result.outcome, result.board) == ("adopted", AtsBoard(vendor="ashby", board="acme"))


def test_records_no_owner_when_nothing_on_the_board_names_the_company():
    result = find_board(company(), FakeBoardReader([board("lever", "acme", ROLES)], links=None))

    assert (result.outcome, result.owner) == ("adopted", None)
    assert "nothing on it names the company" in result.evidence


def test_does_not_search_for_a_page_with_too_few_roles_to_tell_boards_apart():
    reader = FakeBoardReader([board("greenhouse", "acme", ROLES)])

    result = find_board(company(ROLES[:4]), reader)

    assert (result.outcome, result.reason, result.page_roles) == ("none", "too_few_roles", 4)
    assert not reader.searched


def test_counts_each_distinct_title_once():
    result = find_board(company(ROLES[:4] + ROLES[:4]), FakeBoardReader())

    assert (result.outcome, result.page_roles) == ("none", 4)


def test_reports_no_board_when_none_is_found():
    result = find_board(company(), FakeBoardReader())

    assert (result.outcome, result.reason) == ("none", "no_board_found")
