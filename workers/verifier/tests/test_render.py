from verifier.render import render


def titles(page):
    return {text for text, href in page.links if "/jobs/" in href}


def test_reads_a_static_page(browser, site):
    page = render(browser, site.url("static.html"))

    assert page.status == 200
    assert page.title == "Careers at Example Co"
    assert titles(page) == {"Revenue Operations Engineer", "GTM Systems Analyst", "Solutions Engineer"}


# The headline capability: listings that exist only after JavaScript runs.
def test_reads_listings_rendered_by_javascript(browser, site):
    page = render(browser, site.url("dynamic.html"))

    assert titles(page) == {"Edge Platform Engineer", "RevOps Lead", "Solutions Architect", "Data Engineer"}
    assert "Loading open positions" not in page.text


def test_reads_a_job_board_embedded_in_an_iframe(browser, site):
    page = render(browser, site.url("framed.html"))

    assert titles(page) == {"Customer Success Manager", "Pricing Analyst"}
    assert site.url("board.html") in page.urls


def test_hashes_the_page_text_ignoring_whitespace(browser, site):
    first = render(browser, site.url("static.html"))
    second = render(browser, site.url("static.html"))

    assert first.content_hash.startswith("sha256:")
    assert first.content_hash == second.content_hash


def test_recognizes_a_bot_challenge(browser, site):
    assert render(browser, site.url("challenge.html")).looks_like_challenge
    assert not render(browser, site.url("static.html")).looks_like_challenge
