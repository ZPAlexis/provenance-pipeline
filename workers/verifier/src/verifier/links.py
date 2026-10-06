"""Role links: telling whether two addresses name the same role.

A role is known by its link from one check to the next (a listing's address on
the careers page, or a posting's own page at the employer), so links are
compared as the role they name: tracking parameters, "www.", a trailing slash,
and in-page anchors aside.
"""

import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# Query parameters that track a visit rather than name a role.
TRACKING = ("utm_", "gh_src", "trk")


def link_key(url: str) -> str:
    """A role link compared as the role it names.

    A fragment that is a route (#/jobs/405, #!/jobs/405), as single-page job boards use, names
    the role and is kept.
    """
    parts = urlsplit(url)
    query = urlencode([(k, v) for k, v in parse_qsl(parts.query) if not k.lower().startswith(TRACKING)])
    route = parts.fragment.rstrip("/") if parts.fragment.startswith(("/", "!/")) else ""
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower().removeprefix("www."), parts.path.rstrip("/"), query, route)
    )


def link_prefix(url: str) -> tuple[str, str]:
    """The host and folder a link sits in: role links of one list share it (/jobs/123, /jobs/456)."""
    parts = urlsplit(url)
    return parts.netloc.lower().removeprefix("www."), parts.path.rstrip("/").rsplit("/", 1)[0]


# A role's own id in its address: a long number (Greenhouse's gh_jid, a requisition) or a UUID.
_JOB_ID = re.compile(r"\d{6,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def same_job(url: str, final_url: str) -> bool:
    """Whether a redirect kept the role: the same page, or an address that still carries the role's own id."""
    if same_page(url, final_url):
        return True
    ids = set(_JOB_ID.findall(url.lower()))
    return any(job_id in final_url.lower() for job_id in ids)


def same_page(a: str, b: str) -> bool:
    """Whether two addresses are one page: scheme, "www.", case, a trailing slash, and the query aside."""
    first, second = urlsplit(a), urlsplit(b)
    return (first.netloc.lower().removeprefix("www."), first.path.rstrip("/").lower()) == (
        second.netloc.lower().removeprefix("www."),
        second.path.rstrip("/").lower(),
    )
