#!/usr/bin/env python3
"""Run an XCTest command and write its results as a JUnit XML report.

Usage:

    python3 scripts/xctest-junit.py --run LABEL REPORT.xml -- COMMAND [ARG...]

Runs COMMAND (`swift test` or `xcodebuild test`), passing its output through
unchanged, then writes REPORT.xml from the lines XCTest printed. CI uploads
the reports to Codecov Test Analytics (see the `codecov` job in
.github/workflows/build.yml). The report is written when tests fail too:
that's when it matters.

Why not `swift test --xunit-output`: for XCTest, SwiftPM (6.1 to 6.4) writes
that report only with --parallel, which runs every test in a process of its
own, reports skipped tests as passed, times the processes rather than the
tests, and (before 6.2) gives every failure the message "failed". The lines
XCTest prints in a normal run carry each test's outcome, duration, skip
reason and assertion messages. (Without --parallel, --xunit-output writes
only Swift Testing's report, which couldn't carry the run label below; this
suite has no Swift Testing tests.)

Reads Apple's XCTest format, `-[Module.Class testName]`, which `swift test`
on macOS and `xcodebuild test` (Xcode 16, tests not run in parallel) print.
Each XCTest class becomes a <testsuite>; classname is Module.Class, as in
SwiftPM's own report, and the name is the test's followed by the run's
LABEL, e.g. "testFoo (Mac Catalyst)". Codecov identifies a test by its name,
classname and testsuite (not by flag) and keeps one outcome per test and
commit, so without the label CI's runs of a test (macOS, Mac Catalyst, with
the dictionary) would count as one: a failure in one run could show as
another run's pass or skip. Changing any of these starts a new history for
every test.

Exit status: always COMMAND's. If the output held no XCTest results, or
their number disagrees with XCTest's own totals (the format changed?), the
script only warns: the report feeds Codecov analytics, and like the Codecov
steps it must not turn CI red when the tests passed. The report is written
whenever there are results.

Standard library only (Python 3.9+).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

TEST = r"-\[(?P<cls>[^\s\]]+) (?P<name>[^\s\]]+)\]"
START = re.compile(rf"^Test Case '{TEST}' started\.$")
END = re.compile(
    rf"^Test Case '{TEST}' (?P<outcome>passed|failed|skipped)"
    r" \((?P<seconds>\d+(?:\.\d+)?) seconds\)\.$"
)
# "<file>:<line>: error: -[M.C test] : XCTAssertEqual failed: ..."
FAILURE = re.compile(rf"^(?P<location>.*?): error: {TEST} : (?P<message>.*)$")
# "<file>:<line>: -[M.C test] : Test skipped - <reason>"
SKIP = re.compile(rf"^(?P<location>.*?): {TEST} : Test skipped(?: - (?P<message>.*))?$")
SUITE = re.compile(r"^Test Suite '(?P<suite>[^']*)' (?:started|passed|failed) at ")
# The line after "Test Suite 'All tests' passed at ...":
# "Executed 32 tests, with 6 tests skipped and 0 failures (0 unexpected) in ..."
TOTALS = re.compile(
    r"^\s*Executed (?P<run>\d+) tests?, with"
    r"(?: (?P<skipped>\d+) tests? skipped and)? \d+ failures? \(\d+ unexpected\)"
)
# `swift test` runs Swift Testing after XCTest, also after XCTest crashed.
SWIFT_TESTING_START = re.compile(r"Test run started\.$")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# Characters XML 1.0 can't carry, even escaped.
NOT_XML = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]")

CRASHED = (
    "The test started but never finished: the test process crashed or was"
    " killed. See the CI log."
)
CRASH_CONTEXT_LINES = 10  # of the test's own output, e.g. "Fatal error: ..."


class Result:
    def __init__(self, cls: str, name: str, outcome: str, seconds: float) -> None:
        self.cls = cls
        self.name = name
        self.outcome = outcome  # passed, failed or skipped
        self.seconds = seconds
        self.failures: list[list[str]] = []  # one list of lines per failure
        self.skip_reason: str | None = None


def repo_relative(location: str) -> str:
    """Drops the working directory from an absolute "<file>:<line>"."""
    cwd = os.getcwd().rstrip("/") + "/"
    return location[len(cwd):] if location.startswith(cwd) else location


def parse(lines: list[str]) -> tuple[list[Result], tuple[int, int] | None]:
    results: list[Result] = []
    # Failure and skip lines by test, until that test's result line.
    pending: dict[tuple[str, str], Result] = {}
    running: tuple[str, str] | None = None
    output: list[str] = []  # what the running test printed
    collecting = False  # whether lines are still the running test's output
    continued: list[str] | None = None  # the failure message being read
    totals: tuple[int, int] | None = None
    overall_suite_ended = False

    def details(key: tuple[str, str]) -> Result:
        return pending.setdefault(key, Result(key[0], key[1], "failed", 0.0))

    def crashed(key: tuple[str, str]) -> None:
        result = pending.pop(key, None) or Result(key[0], key[1], "failed", 0.0)
        result.outcome = "failed"
        result.failures.append([CRASHED, *output[-CRASH_CONTEXT_LINES:]])
        results.append(result)

    for raw in lines:
        line = ANSI.sub("", raw.rstrip("\r\n"))
        start = START.match(line)
        end = END.match(line)
        failure = FAILURE.match(line)
        skip = SKIP.match(line)
        match = start or end or failure or skip
        key = (match["cls"], match["name"]) if match else None
        if start:
            # A test that started while another was running: the first one
            # never finished (xcodebuild restarts the runner after a crash).
            if running is not None and running != key:
                crashed(running)
            running = key
            output = []
            collecting = True
            continued = None
        elif end:
            result = pending.pop(key, None) or Result(key[0], key[1], "", 0.0)
            result.outcome = end["outcome"]
            result.seconds = float(end["seconds"])
            results.append(result)
            if running == key:
                running = None
            continued = None
        elif failure:
            continued = [f"{repo_relative(failure['location'])}: {failure['message']}"]
            details(key).failures.append(continued)
        elif skip:
            details(key).skip_reason = skip["message"] or "Test skipped"
            continued = None
        else:
            suite = SUITE.match(line)
            totals_match = TOTALS.match(line)
            if suite:
                overall_suite_ended = suite["suite"] in ("All tests", "Selected tests") and (
                    " passed at " in line or " failed at " in line
                )
                continued = None
            elif totals_match:
                if overall_suite_ended:
                    totals = (int(totals_match["run"]), int(totals_match["skipped"] or 0))
                overall_suite_ended = False
                continued = None
            elif SWIFT_TESTING_START.search(line):
                collecting = False  # not a crashed XCTest's output any more
                continued = None
            elif continued is not None and running is not None:
                # The rest of a multi-line failure message (or output the
                # test printed after it, which is context too).
                continued.append(line)
            elif collecting and running is not None:
                output.append(line)

    if running is not None:
        crashed(running)
    return results, totals


def clean(text: str) -> str:
    return NOT_XML.sub("\ufffd", text)


def report(results: list[Result], label: str) -> ET.Element:
    def counts(rs: list[Result]) -> dict[str, str]:
        return {
            "tests": str(len(rs)),
            "failures": str(sum(r.outcome == "failed" for r in rs)),
            "errors": "0",
            "skipped": str(sum(r.outcome == "skipped" for r in rs)),
            "time": f"{sum(r.seconds for r in rs):.3f}",
        }

    by_class: dict[str, list[Result]] = {}
    for result in results:
        by_class.setdefault(result.cls, []).append(result)

    root = ET.Element("testsuites", counts(results))
    for cls, class_results in by_class.items():
        suite = ET.SubElement(
            root, "testsuite", {"name": cls.rsplit(".", 1)[-1], **counts(class_results)}
        )
        for r in class_results:
            case = ET.SubElement(
                suite,
                "testcase",
                classname=r.cls,
                name=f"{r.name} ({label})",
                time=f"{r.seconds:.3f}",
            )
            if r.outcome == "failed":
                messages = ["\n".join(lines).rstrip() for lines in r.failures]
                text = clean("\n\n".join(messages) or "failed (XCTest printed no message)")
                failure = ET.SubElement(
                    case, "failure", message=text.splitlines()[0], type="XCTestFailure"
                )
                failure.text = text
            elif r.outcome == "skipped":
                ET.SubElement(case, "skipped", message=clean(r.skip_reason or "Test skipped"))
    return root


def say(level: str, message: str) -> None:
    """Prints a note, as a workflow command when running in GitHub Actions."""
    if os.environ.get("GITHUB_ACTIONS") == "true" and level != "notice":
        print(f"::{level}::xctest-junit: {message}", flush=True)
    else:
        print(f"xctest-junit: {level}: {message}", flush=True)


def main(argv: list[str]) -> int:
    if len(argv) < 6 or argv[1] != "--run" or not argv[2] or argv[4] != "--":
        print(
            "usage: xctest-junit.py --run LABEL REPORT.xml -- COMMAND [ARG...]",
            file=sys.stderr,
        )
        return 2
    label, report_path, command = argv[2], argv[3], argv[5:]

    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE)
    except OSError as error:
        say("error", f"cannot run {command[0]}: {error}")
        return 127
    lines = []
    out = sys.stdout.buffer
    assert process.stdout is not None
    for raw in process.stdout:
        out.write(raw)
        out.flush()
        lines.append(raw.decode("utf-8", "replace"))
    status = process.wait()
    if status < 0:  # killed by a signal
        status = 128 - status

    results, totals = parse(lines)
    problem = None
    if not results:
        problem = "found no XCTest results in the output"
    else:
        tree = ET.ElementTree(report(results, label))
        if hasattr(ET, "indent"):
            ET.indent(tree)
        os.makedirs(os.path.dirname(os.path.abspath(report_path)), exist_ok=True)
        # <skipped ...></skipped>, not <skipped .../>: some versions of
        # Codecov's parser (test-results-parser 0.6.1) read the short form
        # as a pass.
        tree.write(
            report_path, encoding="UTF-8", xml_declaration=True, short_empty_elements=False
        )
        failed = sum(r.outcome == "failed" for r in results)
        skipped = sum(r.outcome == "skipped" for r in results)
        say("notice", f"wrote {report_path}: {len(results)} tests, {failed} failed, {skipped} skipped")
        if totals is not None and totals != (len(results), skipped):
            problem = (
                f"XCTest reported {totals[0]} tests, {totals[1]} skipped;"
                f" the report has {len(results)}, {skipped} skipped"
            )
    if problem:
        # A warning, not a failure: the step's result is the tests' result.
        # When the tests passed, the likely cause is a change in XCTest's
        # output format, which this script needs updating for.
        hint = "" if status != 0 else " Did XCTest's output format change?"
        say("warning", f"{problem}.{hint} The Codecov test report may be missing or incomplete.")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
