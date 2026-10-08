"""What goes wrong calling the LLM. Raised where it is called (extract.py), caught by its callers.

Apart from extract.py so the run loop and the matcher can catch them without
importing the LLM client, which commands that never call it (`suggest`) should
not wait for.
"""

from verifier.contract import LlmUsage


class CreditExhausted(Exception):
    """The API account is out of prepaid credit: the whole run stops, cleanly."""


class LlmConfigError(Exception):
    """The API credential is missing or rejected: the whole run stops."""


class ExtractionFailed(Exception):
    """This page could not be extracted; the run continues with the next one."""

    def __init__(self, reason: str, usage: LlmUsage | None = None):
        super().__init__(reason)
        self.reason = reason
        self.usage = usage  # tokens already billed, if a response came back
