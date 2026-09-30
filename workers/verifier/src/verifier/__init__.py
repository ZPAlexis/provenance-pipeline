"""Verification worker for Provenance Pipeline.

Renders a company's careers page, extracts its job listings, and returns them
as JSON. It never touches the database: Rails hands it a targets file, reads
its results file, and records everything through one audited write path.
"""

RESULT_SCHEMA_VERSION = 2  # 2: resolution results; purpose and prompt_version on LLM usage
