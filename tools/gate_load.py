"""Frame-time checks on a busy machine: wait, retry, and say so when it never quietens.

A frame time measured while other programs hold every core says nothing about the
game. The rule (2026-11-13): a frame-time assertion counts only when the 1-minute
load average was at most LOAD_LIMIT while it was measured. When a suite fails ONLY
on its frame-time checks (Suite.timing) and the load was above the limit, the runner
waits for the load to drop and runs the suite again, up to RETRIES times. If every
attempt was measured above the limit, the suite is BUSY: a known failure caused by
the machine, reported with the load figures, never counted as a pass. A frame-time
failure measured at or under the limit is a real FAIL. Thresholds never move.
"""

import os
import re
import time

LOAD_LIMIT = 6.0
RETRIES = 3
WAIT_POLL = 15  # seconds between load checks while waiting


def timing_only(suite, summary: dict) -> bool:
    """True when every failed assertion of this suite is one of its frame-time checks."""
    if summary["status"] != "FAIL" or not suite.timing:
        return False
    asserts = [f for f in summary["failures"] if not f.startswith(("ERROR:", "   at:", "SCRIPT ERROR"))]
    asserts = [f for f in asserts if not f.lstrip().startswith("at:")]
    return bool(asserts) and all(any(t in f for t in suite.timing) for f in asserts)


def measured_load(suite, summary: dict) -> float:
    """The highest 1-minute load stamped on this suite's frame-time lines."""
    loads = []
    for line in summary["perf"] + summary["failures"]:
        if any(t in line for t in suite.timing):
            m = re.search(r"\[load1 ([0-9.]+)\]", line)
            if m:
                loads.append(float(m.group(1)))
    return max(loads) if loads else os.getloadavg()[0]


def wait_for_quiet(budget: float, say) -> float:
    """Wait until the 1-minute load is at most LOAD_LIMIT or `budget` seconds pass."""
    deadline = time.time() + budget
    load = os.getloadavg()[0]
    while load > LOAD_LIMIT and time.time() < deadline:
        time.sleep(WAIT_POLL)
        load = os.getloadavg()[0]
    say("      load1 is %.2f; %s" % (load, "retrying" if load <= LOAD_LIMIT else "still busy, retrying anyway"))
    return load


def run_with_retries(suite, run, budget: float, say) -> dict:
    """Run `suite` via `run()` (returns a summary), retrying frame-time failures on load."""
    summary = run()
    attempts = []
    while timing_only(suite, summary):
        load = measured_load(suite, summary)
        attempts.append(load)
        if load <= LOAD_LIMIT or len(attempts) > RETRIES:
            break
        say(
            "  %-9s frame time failed at load1 %.2f (limit %.1f); waiting up to %d s for a quieter machine"
            % (suite.name, load, LOAD_LIMIT, budget)
        )
        wait_for_quiet(budget, say)
        summary = run()
    if summary["status"] == "FAIL" and attempts and all(a > LOAD_LIMIT for a in attempts) and timing_only(suite, summary):
        summary["status"] = "BUSY"
        summary["note"] = (
            "Known failure caused by the machine, not the game: the frame-time check failed on all %d "
            "attempt(s), each measured with the 1-minute load above %.1f (%s). Rerun on a quiet machine."
            % (len(attempts), LOAD_LIMIT, ", ".join("%.2f" % a for a in attempts))
        )
    summary["attempt_loads"] = attempts
    return summary
