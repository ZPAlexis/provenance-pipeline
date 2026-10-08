"""Why a whole run stops early. Raised where the LLM is called, caught by the CLI's run loop.

Apart from extract.py so the loop can catch them without importing the LLM client,
which commands that never call it (`suggest`) should not wait for.
"""


class CreditExhausted(Exception):
    """The API account is out of prepaid credit: the whole run stops, cleanly."""


class LlmConfigError(Exception):
    """The API credential is missing or rejected: the whole run stops."""
