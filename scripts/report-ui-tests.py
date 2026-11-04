#!/usr/bin/env python3
"""Print the failed UI tests of a result bundle with their app log lines.

Usage: scripts/report-ui-tests.py <result.xcresult> <app.log> [report.txt]

Runs on the CI E2E jobs after xcodebuild, so `gh run view --log-failed` shows
for each failed test its failure messages and what the app logged while the
test ran, without downloading the result bundle. The app log is the simulator's
`log stream` of the app's subsystem; each test writes a
`test-start <Class>/<method>` line when it starts (KonomiTVUITestCase.setUp).

Also appends the failures to $GITHUB_STEP_SUMMARY when it is set. Never fails:
the test step's own exit status decides the job.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

MARKER = re.compile(r"test-start (\S+)")
MAX_LOG_LINES = 800


def load_summary(bundle: str) -> dict | None:
    try:
        output = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        return json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"report-ui-tests: cannot read {bundle}: {error}")
        return None


def split_log(path: str) -> dict[str, list[str]]:
    """App log lines per test identifier ("Class/method")."""
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = MARKER.search(line)
                if match:
                    current = sections.setdefault(match.group(1), [])
                if current is not None:
                    current.append(line.rstrip("\n"))
    except OSError as error:
        print(f"report-ui-tests: cannot read {path}: {error}")
    return sections


class Tee:
    def __init__(self, *streams) -> None:
        self.streams = streams

    def write(self, text: str) -> None:
        for stream in self.streams:
            stream.write(text)

    def flush(self) -> None:
        for stream in self.streams:
            stream.flush()


def identifier(failure: dict) -> str:
    raw = failure.get("testIdentifierString") or failure.get("testName") or "?"
    return raw.removesuffix("()")


def main() -> None:
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        return
    bundle, log_path = sys.argv[1], sys.argv[2]
    if len(sys.argv) == 4:
        # Also keep a copy: the CI logs artifact survives when GitHub fails
        # to store a long job's log.
        sys.stdout = Tee(sys.stdout, open(sys.argv[3], "w", encoding="utf-8"))

    summary = load_summary(bundle)
    if summary is None:
        return
    failures = summary.get("testFailures") or []
    print(
        f"UI tests: {summary.get('passedTests', '?')} passed, "
        f"{summary.get('failedTests', '?')} failed, "
        f"{summary.get('skippedTests', '?')} skipped"
    )
    if not failures:
        return

    logs = split_log(log_path)
    grouped: dict[str, list[str]] = {}
    for failure in failures:
        grouped.setdefault(identifier(failure), []).append(failure.get("failureText", ""))

    for test, messages in grouped.items():
        print(f"::group::FAILED {test}")
        for message in messages:
            print(f"  ✗ {message}")
        lines = logs.get(test, [])
        if not lines:
            print("  (no app log lines for this test)")
        elif len(lines) > MAX_LOG_LINES:
            print(f"  … {len(lines) - MAX_LOG_LINES} earlier lines omitted")
            lines = lines[-MAX_LOG_LINES:]
        for line in lines:
            print(f"  | {line}")
        print("::endgroup::")
        for message in messages:
            # Annotations show on the run page; keep them to one line.
            print(f"::error title={test}::{message.splitlines()[0] if message else 'failed'}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(f"### Failed UI tests ({len(grouped)})\n\n")
            for test, messages in grouped.items():
                text = "; ".join(m.replace("\n", " ") for m in messages)
                handle.write(f"- `{test}`: {text}\n")
            handle.write("\n")


if __name__ == "__main__":
    main()
