"""`verifier extract --targets targets.json --out results.jsonl`

Reads the targets Rails wrote, checks each careers page one at a time, and
appends one JSON result per page as it goes, so a run that stops early still
leaves every finished result behind. Progress goes to stderr.

Exit codes: 0 finished; 2 bad input; 3 stopped, API credit exhausted;
4 stopped, API credential missing or rejected; 5 stopped, LLM service failing.
"""

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import httpx2
from playwright.sync_api import sync_playwright

from verifier.config import DEFAULT_MODEL, DOMAIN_DELAY_SECONDS, MODEL_SETTINGS
from verifier.contract import PageResult, Target
from verifier.extract import CreditExhausted, LlmConfigError, LlmExtractor
from verifier.pipeline import Services, verify_page
from verifier.politeness import HostThrottle
from verifier.robots import RobotsPolicy

EXIT_OK, EXIT_BAD_INPUT, EXIT_CREDIT, EXIT_CREDENTIAL, EXIT_LLM_UNAVAILABLE = 0, 2, 3, 4, 5

# Failures that mean the LLM service itself is down, not that one page was hard.
# This many in a row stops the run rather than rendering every remaining page.
_OUTAGE = re.compile(r"^llm_(http_5\d\d|connection_error|rate_limited)$")
OUTAGE_LIMIT = 3


@dataclass
class RunSummary:
    pages: int = 0
    outcomes: dict[str, int] = field(default_factory=dict)
    listings: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    stopped: str | None = None  # why the run ended early, if it did

    def add(self, result: PageResult) -> None:
        self.pages += 1
        self.outcomes[result.outcome] = self.outcomes.get(result.outcome, 0) + 1
        self.listings += result.listing_count or 0
        if result.llm:
            self.input_tokens += result.llm.input_tokens
            self.output_tokens += result.llm.output_tokens
            self.cost_usd = round(self.cost_usd + result.llm.cost_usd, 6)


def run(targets: list[Target], out_path: Path, services: Services, log=sys.stderr) -> RunSummary:
    summary = RunSummary()
    outage_streak = 0
    with out_path.open("a", encoding="utf-8") as out:
        for index, target in enumerate(targets, start=1):
            try:
                result = verify_page(target, services)
            except CreditExhausted:
                summary.stopped = "credit_exhausted"
                print(f"[{index}/{len(targets)}] stopped: API credit is exhausted", file=log)
                break
            except LlmConfigError as error:
                summary.stopped = "credential"
                print(f"[{index}/{len(targets)}] stopped: {error}", file=log)
                break
            except Exception as error:  # one page's surprise must not lose the rest of the run
                result = PageResult(
                    target_id=target.id,
                    url=target.url,
                    checked_at=datetime.now(UTC).isoformat(timespec="seconds"),
                    outcome="error",
                    reason=f"unexpected:{type(error).__name__}",
                )

            out.write(result.model_dump_json() + "\n")
            out.flush()
            summary.add(result)
            print(f"[{index}/{len(targets)}] {_describe(target, result)}", file=log)

            outage_streak = outage_streak + 1 if _OUTAGE.match(result.reason or "") else 0
            if outage_streak >= OUTAGE_LIMIT:
                summary.stopped = "llm_unavailable"
                print(
                    f"stopped: the LLM service is failing ({result.reason}) on {OUTAGE_LIMIT} pages running", file=log
                )
                break
    return summary


def _describe(target: Target, result: PageResult) -> str:
    label = target.label or target.url
    detail = f"{result.listing_count} listings via {result.method}" if result.outcome == "ok" else result.reason
    cost = f", ${result.llm.cost_usd:.4f}" if result.llm else ""
    return f"{label}: {result.outcome}, {detail} ({result.duration_ms / 1000:.1f}s{cost})"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="verifier")
    commands = parser.add_subparsers(dest="command", required=True)
    extract = commands.add_parser("extract", help="check careers pages and extract their listings")
    extract.add_argument("--targets", type=Path, required=True, help='JSON file: {"targets": [{"id", "url"}]}')
    extract.add_argument("--out", type=Path, required=True, help="JSONL file to append results to")
    extract.add_argument("--model", default=DEFAULT_MODEL, choices=sorted(MODEL_SETTINGS))
    extract.add_argument("--delay", type=float, default=DOMAIN_DELAY_SECONDS, help="seconds between requests to a host")
    args = parser.parse_args(argv)

    try:
        payload = json.loads(args.targets.read_text(encoding="utf-8"))
        targets = [Target.model_validate(item) for item in payload["targets"]]
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"could not read targets from {args.targets}: {error}", file=sys.stderr)
        return EXIT_BAD_INPUT

    with sync_playwright() as playwright, httpx2.Client(timeout=20.0) as http:
        browser = playwright.chromium.launch()
        try:
            services = Services(
                browser=browser,
                http=http,
                robots=RobotsPolicy(http),
                throttle=HostThrottle(args.delay),
                extractor=LlmExtractor(model=args.model),
            )
            summary = run(targets, args.out, services)
        finally:
            browser.close()

    print(
        f"\n{summary.pages}/{len(targets)} pages, outcomes {summary.outcomes}, {summary.listings} listings, "
        f"{summary.input_tokens} in / {summary.output_tokens} out tokens, est. ${summary.cost_usd:.4f}",
        file=sys.stderr,
    )
    return {
        "credit_exhausted": EXIT_CREDIT,
        "credential": EXIT_CREDENTIAL,
        "llm_unavailable": EXIT_LLM_UNAVAILABLE,
    }.get(summary.stopped, EXIT_OK)


if __name__ == "__main__":
    sys.exit(main())
