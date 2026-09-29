"""robots.txt, honored for every page the verifier renders.

Follows RFC 9309: a missing robots.txt (any 4xx) allows everything, while an
unreachable one (5xx or a network failure) means "assume complete disallow".
An unreachable robots.txt is retried once, and never remembered: many
companies share one job-board host, and a brief failure there must not block
all of them for the rest of the run. The documented public job-board APIs in
`ats` are not crawled pages and are not checked here.
"""

import time
from collections.abc import Callable
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser

import httpx2

from verifier.config import ROBOTS_AGENT, USER_AGENT

RETRY_DELAY_SECONDS = 2.0


class RobotsPolicy:
    def __init__(self, client: httpx2.Client, agent: str = ROBOTS_AGENT, sleep: Callable[[float], None] = time.sleep):
        self._client = client
        self._agent = agent
        self._sleep = sleep
        self._rules: dict[str, RobotFileParser] = {}  # origin -> parsed rules, for robots.txt that loaded

    def check(self, url: str) -> str | None:
        """None if `url` may be fetched; otherwise the reason it may not."""
        parts = urlsplit(url)
        origin = f"{parts.scheme}://{parts.netloc}"
        rules = self._rules.get(origin)
        if rules is None:
            rules = self._load(origin)
            if rules is None:
                return "robots_unreachable"
            self._rules[origin] = rules

        return None if rules.can_fetch(self._agent, url) else "robots_disallowed"

    def _load(self, origin: str) -> RobotFileParser | None:
        """The origin's rules, or None when robots.txt could not be reached, even on a retry."""
        for attempt in range(2):
            if attempt:
                self._sleep(RETRY_DELAY_SECONDS)
            try:
                response = self._client.get(
                    f"{origin}/robots.txt", headers={"User-Agent": USER_AGENT}, follow_redirects=True
                )
            except httpx2.HTTPError:
                continue
            if response.status_code < 500:
                parser = RobotFileParser()
                # A 4xx means there is no robots.txt: everything is allowed.
                parser.parse(response.text.splitlines() if response.status_code < 400 else [])
                return parser
        return None
