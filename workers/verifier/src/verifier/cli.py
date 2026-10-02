"""`verifier extract|resolve|match|verify|boards --targets targets.json --out results.jsonl`

extract  checks each careers page and extracts its listings: one PageResult per target.
resolve  finds each company's careers page: one ResolutionResult per target,
         carrying every page it checked on the way.
match    matches a company's tracked postings against listings already read (a
         stored page check): one MatchResult per target, nothing rendered.
verify   reads each company's watched page in full and matches its postings
         against it: one VerificationResult per company.
         For match and verify, `--no-llm` leaves near-misses undecided.
boards   looks for a free board listing the same roles as a page the LLM had to
         read: one BoardResult per company. Never calls the LLM.

Reads the targets Rails wrote, works through them one at a time, and appends
one JSON result per target as it goes, so a run that stops early still leaves
every finished result behind. Progress goes to stderr.

Exit codes: 0 finished; 2 bad input; 3 stopped, API credit exhausted;
4 stopped, API credential missing or rejected; 5 stopped, LLM service failing.
"""

import argparse
import json
import re
import sys
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import httpx2
from playwright.sync_api import sync_playwright

from verifier.boards import find_board
from verifier.config import DEFAULT_MODEL, DOMAIN_DELAY_SECONDS, MODEL_SETTINGS
from verifier.contract import (
    BoardResult,
    BoardTarget,
    MatchResult,
    MatchTarget,
    PageResult,
    ResolutionResult,
    ResolveTarget,
    Target,
    VerificationResult,
    VerifyTarget,
)
from verifier.extract import CreditExhausted, LlmConfigError, LlmExtractor, LlmLinkPicker, LlmMatcher
from verifier.match import Matcher
from verifier.pipeline import Services, verify_page
from verifier.politeness import HostThrottle
from verifier.resolve import Resolver, ServicesReader
from verifier.robots import RobotsPolicy
from verifier.verify import verify_company

EXIT_OK, EXIT_BAD_INPUT, EXIT_CREDIT, EXIT_CREDENTIAL, EXIT_LLM_UNAVAILABLE = 0, 2, 3, 4, 5

# Failures that mean the LLM service itself is down, not that one page was hard.
# This many targets in a row stops the run rather than working through the rest.
_OUTAGE = re.compile(r"^llm_(http_5\d\d|connection_error|rate_limited)$")
OUTAGE_LIMIT = 3

Result = PageResult | ResolutionResult | MatchResult | VerificationResult | BoardResult


@dataclass
class RunSummary:
    targets: int = 0
    pages: int = 0  # pages checked: one per target when extracting, any number when resolving
    outcomes: dict[str, int] = field(default_factory=dict)
    listings: int = 0
    verdicts: dict[str, int] = field(default_factory=dict)  # when matching; "inconclusive" for no verdict
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    stopped: str | None = None  # why the run ended early, if it did

    def add(self, result: Result) -> None:
        self.targets += 1
        self.outcomes[result.outcome] = self.outcomes.get(result.outcome, 0) + 1
        for page in _pages(result):
            self.pages += 1
            self.listings += page.listing_count or 0
        if isinstance(result, MatchResult | VerificationResult):
            for verdict in result.verdicts:
                key = verdict.verdict or "inconclusive"
                self.verdicts[key] = self.verdicts.get(key, 0) + 1
        for usage in _usages(result):
            self.input_tokens += usage.input_tokens
            self.output_tokens += usage.output_tokens
            self.cost_usd = round(self.cost_usd + usage.cost_usd, 6)


def run(targets: list[Target], out_path: Path, services: Services, log=sys.stderr) -> RunSummary:
    def failed(target: Target, reason: str) -> PageResult:
        checked_at = datetime.now(UTC).isoformat(timespec="seconds")
        return PageResult(target_id=target.id, url=target.url, checked_at=checked_at, outcome="error", reason=reason)

    return _run(targets, out_path, lambda target: verify_page(target, services), failed, log)


def run_resolve(targets: list[ResolveTarget], out_path: Path, resolver: Resolver, log=sys.stderr) -> RunSummary:
    def failed(target: ResolveTarget, reason: str) -> ResolutionResult:
        return ResolutionResult(target_id=target.id, outcome="error", reason=reason)

    return _run(targets, out_path, resolver.resolve, failed, log)


def run_verify(targets: list[VerifyTarget], out_path: Path, services: Services, matcher: Matcher, log=sys.stderr):
    def failed(target: VerifyTarget, reason: str) -> VerificationResult:
        return VerificationResult(target_id=target.id, url=target.url, outcome="error", reason=reason)

    return _run(targets, out_path, lambda target: verify_company(target, services, matcher), failed, log)


def run_match(targets: list[MatchTarget], out_path: Path, matcher: Matcher, log=sys.stderr) -> RunSummary:
    def failed(target: MatchTarget, reason: str) -> MatchResult:
        return MatchResult(
            target_id=target.id,
            page_check_id=target.page_check_id,
            complete=target.complete,
            outcome="error",
            reason=reason,
        )

    return _run(targets, out_path, matcher.match, failed, log)


def run_boards(targets: list[BoardTarget], out_path: Path, reader: ServicesReader, log=sys.stderr) -> RunSummary:
    def failed(target: BoardTarget, reason: str) -> BoardResult:
        return BoardResult(target_id=target.id, outcome="error", reason=reason)

    return _run(targets, out_path, lambda target: find_board(target, reader), failed, log)


def _run(targets: list, out_path: Path, work: Callable, failed: Callable, log) -> RunSummary:
    summary = RunSummary()
    outage_streak = 0
    with out_path.open("a", encoding="utf-8") as out:
        for index, target in enumerate(targets, start=1):
            try:
                result = work(target)
            except CreditExhausted:
                summary.stopped = "credit_exhausted"
                print(f"[{index}/{len(targets)}] stopped: API credit is exhausted", file=log)
                break
            except LlmConfigError as error:
                summary.stopped = "credential"
                print(f"[{index}/{len(targets)}] stopped: {error}", file=log)
                break
            except Exception as error:  # one target's surprise must not lose the rest of the run
                result = failed(target, f"unexpected:{type(error).__name__}")

            out.write(result.model_dump_json() + "\n")
            out.flush()
            summary.add(result)
            print(f"[{index}/{len(targets)}] {_describe(target, result)}", file=log)

            outage = next((reason for reason in _reasons(result) if _OUTAGE.match(reason or "")), None)
            outage_streak = outage_streak + 1 if outage else 0
            if outage_streak >= OUTAGE_LIMIT:
                summary.stopped = "llm_unavailable"
                print(f"stopped: the LLM service is failing ({outage}) on {OUTAGE_LIMIT} targets running", file=log)
                break
    return summary


def _pages(result: Result) -> list[PageResult]:
    if isinstance(result, MatchResult | BoardResult):
        return []
    return result.checks if isinstance(result, ResolutionResult | VerificationResult) else [result]


def _usages(result: Result) -> list:
    usages = [page.llm for page in _pages(result) if page.llm]
    extra = result.llm if isinstance(result, MatchResult) else getattr(result, "match_llm", None)
    return usages + [extra] if extra else usages


def _reasons(result: Result) -> list[str | None]:
    own = [result.reason] if isinstance(result, MatchResult | VerificationResult) else []
    return [page.reason for page in _pages(result)] + own


def _describe(target: Target | ResolveTarget | BoardTarget, result: Result) -> str:
    cost = sum(usage.cost_usd for usage in _usages(result))
    timing = f"({result.duration_ms / 1000:.1f}s{f', ${cost:.4f}' if cost else ''})"
    if isinstance(result, BoardResult):
        return f"{target.name or target.id}: {result.outcome}, {result.evidence or result.reason} {timing}"
    if isinstance(result, MatchResult | VerificationResult):
        tally: dict[str, int] = {}
        for verdict in result.verdicts:
            tally[verdict.verdict or "inconclusive"] = tally.get(verdict.verdict or "inconclusive", 0) + 1
        list_kind = "whole list" if result.complete else "partial list"
        return f"{target.label or target.id}: {tally or result.reason} ({list_kind}) {timing}"
    if isinstance(result, ResolutionResult):
        label = target.label or target.domain or target.id
        if result.outcome in ("resolved", "candidate"):
            detail = f"{result.method}, {result.confidence}, {result.careers_page_url}"
        else:
            detail = result.failure or result.reason
        return f"{label}: {result.outcome}, {detail}, {len(result.checks)} checks {timing}"
    label = target.label or target.url
    detail = f"{result.listing_count} listings via {result.method}" if result.outcome == "ok" else result.reason
    return f"{label}: {result.outcome}, {detail} {timing}"


def main(argv: list[str] | None = None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--targets", type=Path, required=True, help='JSON file: {"targets": [...]}')
    common.add_argument("--out", type=Path, required=True, help="JSONL file to append results to")
    common.add_argument("--model", default=DEFAULT_MODEL, choices=sorted(MODEL_SETTINGS))
    common.add_argument("--delay", type=float, default=DOMAIN_DELAY_SECONDS, help="seconds between requests to a host")

    parser = argparse.ArgumentParser(prog="verifier")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("extract", parents=[common], help="check careers pages and extract their listings")
    commands.add_parser("resolve", parents=[common], help="find companies' careers pages")
    match = commands.add_parser("match", parents=[common], help="match postings against listings already read")
    verify = commands.add_parser("verify", parents=[common], help="read watched pages in full and verify postings")
    for command in (match, verify):
        command.add_argument("--no-llm", action="store_true", help="leave near-misses undecided")
    commands.add_parser("boards", parents=[common], help="find free boards listing the same roles as LLM-read pages")
    args = parser.parse_args(argv)

    model = {"resolve": ResolveTarget, "match": MatchTarget, "verify": VerifyTarget, "boards": BoardTarget}.get(
        args.command, Target
    )
    try:
        payload = json.loads(args.targets.read_text(encoding="utf-8"))
        targets = [model.model_validate(item) for item in payload["targets"]]
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"could not read targets from {args.targets}: {error}", file=sys.stderr)
        return EXIT_BAD_INPUT

    if args.command == "match":
        # Nothing is fetched: the listings were read before, and stored.
        matcher = Matcher(adjudicator=None if args.no_llm else LlmMatcher(model=args.model))
        summary = run_match(targets, args.out, matcher)
        print(
            f"\n{summary.targets}/{len(targets)} companies, verdicts {summary.verdicts}, "
            f"{summary.input_tokens} in / {summary.output_tokens} out tokens, est. ${summary.cost_usd:.4f}",
            file=sys.stderr,
        )
        return _exit_code(summary)

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
            if args.command == "resolve":
                resolver = Resolver(ServicesReader(services), link_picker=LlmLinkPicker(model=args.model))
                summary = run_resolve(targets, args.out, resolver)
            elif args.command == "boards":
                summary = run_boards(targets, args.out, ServicesReader(services))
            elif args.command == "verify":
                matcher = Matcher(adjudicator=None if args.no_llm else LlmMatcher(model=args.model))
                summary = run_verify(targets, args.out, services, matcher)
            else:
                summary = run(targets, args.out, services)
        finally:
            browser.close()

    print(
        f"\n{summary.targets}/{len(targets)} targets, {summary.pages} pages, outcomes {summary.outcomes}, "
        f"{summary.listings} listings, {summary.input_tokens} in / {summary.output_tokens} out tokens, "
        f"est. ${summary.cost_usd:.4f}",
        file=sys.stderr,
    )
    return _exit_code(summary)


def _exit_code(summary: RunSummary) -> int:
    return {
        "credit_exhausted": EXIT_CREDIT,
        "credential": EXIT_CREDENTIAL,
        "llm_unavailable": EXIT_LLM_UNAVAILABLE,
    }.get(summary.stopped, EXIT_OK)


if __name__ == "__main__":
    sys.exit(main())
