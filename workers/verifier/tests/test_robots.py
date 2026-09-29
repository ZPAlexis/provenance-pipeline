import httpx2

from verifier.robots import RobotsPolicy


def policy(handler, fetched=None, slept=None):
    def recording(request):
        if fetched is not None:
            fetched.append(str(request.url))
        return handler(request)

    sleep = slept.append if slept is not None else (lambda seconds: None)
    return RobotsPolicy(httpx2.Client(transport=httpx2.MockTransport(recording)), sleep=sleep)


def responses(*statuses):
    """A handler answering with each status in turn."""
    remaining = list(statuses)
    return lambda request: httpx2.Response(remaining.pop(0), text="")


def test_honors_disallow_rules():
    robots = policy(lambda request: httpx2.Response(200, text="User-agent: *\nDisallow: /internal/\n"))

    assert robots.check("https://acme.example/careers") is None
    assert robots.check("https://acme.example/internal/jobs") == "robots_disallowed"


def test_honors_rules_addressed_to_the_verifier_by_name():
    rules = "User-agent: ProvenancePipelineVerifier\nDisallow: /\n\nUser-agent: *\nAllow: /\n"
    robots = policy(lambda request: httpx2.Response(200, text=rules))

    assert robots.check("https://acme.example/careers") == "robots_disallowed"


def test_allows_everything_when_there_is_no_robots_txt():
    robots = policy(lambda request: httpx2.Response(404))

    assert robots.check("https://acme.example/careers") is None


# RFC 9309: an unreachable robots.txt means assume complete disallow.
def test_refuses_when_robots_txt_is_unreachable():
    assert policy(lambda request: httpx2.Response(503)).check("https://acme.example/careers") == "robots_unreachable"


# Seen for real on 2026-09-29: one brief failure on a shared job-board host
# blocked every company on it for the whole run.
def test_retries_once_before_concluding_robots_txt_is_unreachable():
    fetched, slept = [], []
    robots = policy(responses(503, 200), fetched, slept)

    assert robots.check("https://acme.example/careers") is None
    assert len(fetched) == 2
    assert len(slept) == 1


def test_does_not_remember_that_robots_txt_was_unreachable():
    robots = policy(responses(503, 503, 200))

    assert robots.check("https://acme.example/careers") == "robots_unreachable"
    assert robots.check("https://acme.example/jobs") is None


def test_refuses_when_the_site_cannot_be_reached():
    def unreachable(request):
        raise httpx2.ConnectError("no route", request=request)

    assert policy(unreachable).check("https://acme.example/careers") == "robots_unreachable"


def test_fetches_robots_txt_once_per_origin():
    fetched = []
    robots = policy(lambda request: httpx2.Response(200, text=""), fetched)

    robots.check("https://acme.example/careers")
    robots.check("https://acme.example/jobs")
    robots.check("https://other.example/careers")

    assert fetched == ["https://acme.example/robots.txt", "https://other.example/robots.txt"]
