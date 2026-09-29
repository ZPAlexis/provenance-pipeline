"""Per-host spacing between requests: one page at a time, never hammering a site."""

import time
from collections.abc import Callable


class HostThrottle:
    def __init__(
        self,
        delay_seconds: float,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ):
        self.delay_seconds = delay_seconds
        self._clock = clock
        self._sleep = sleep
        self._last_request: dict[str, float] = {}

    def wait(self, host: str) -> None:
        """Block until `host` may be requested again, then record the request."""
        last = self._last_request.get(host)
        if last is not None:
            remaining = self.delay_seconds - (self._clock() - last)
            if remaining > 0:
                self._sleep(remaining)
        self._last_request[host] = self._clock()
