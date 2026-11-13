#!/usr/bin/env python3
"""RAMA test gate. Runs every suite in tools/gate_suites.py and reports honestly.

    tools/run_tests.sh                    every suite
    tools/run_tests.sh quests ui          only these suites
    tools/run_tests.sh --headless-only    skip the suites that need a renderer (CI)
    tools/run_tests.sh --fast             the few-second suites (the pre-commit hook)
    tools/run_tests.sh --list             show the suites and how each one launches

Safe to run while someone is using the computer: no suite opens a window, takes
focus, captures the mouse or makes a sound (see the header of gate_suites.py).

What it guarantees:
  * Godot is found from $GODOT, then PATH, then ~/tools/Godot.app.
  * Every suite has a timeout; a hung suite is killed and reported TIMEOUT.
  * Full output of every suite goes to build/test-logs/<run>/<suite>.log, and every
    failed assertion and script error, in full, to build/test-logs/<run>/failures.txt.
    The terminal shows the first lines of each.
  * Every timing figure from a perf suite is stamped with the 1-minute load average
    at the moment it was printed.
  * summary.json in the same folder is the machine-readable result.
  * Frame-time checks measured on a busy machine are retried once it quietens, and
    reported BUSY (a known failure, with the load figures) if it never does; see
    tools/gate_load.py. Suites run with --fixed-fps 60 (see gate_suites.py).
  * Exit status 0 only if every suite that ran passed; 1 on any failure; 3 when the
    only problem is BUSY frame-time checks; 2 when the gate itself could not run (no
    Godot, bad arguments).
"""

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

import gate_load
import gate_suites
from gate_proc import run_godot

ROOT = Path(__file__).resolve().parent.parent
DETAIL_LINES = 8  # failure lines shown on the terminal per suite
STATUSES = ("PASS", "FAIL", "TIMEOUT", "FOCUS", "CRASH", "BUSY", "SKIP")
KNOWN_TAG = "    [known engine exit warning; see tools/gate_suites.py]"


def find_godot() -> str:
    env = os.environ.get("GODOT", "").strip()
    if env:
        return env if os.access(env, os.X_OK) else ""
    for name in ("godot", "godot4", "Godot"):
        hit = shutil.which(name)
        if hit:
            return hit
    mac = Path.home() / "tools/Godot.app/Contents/MacOS/Godot"
    return str(mac) if os.access(mac, os.X_OK) else ""


def godot_args(suite: gate_suites.Suite) -> list:
    if suite.mode == "headless":
        launch = ["--headless", "--audio-driver", "Dummy"]
    else:
        # The embedded display server needs a debugger singleton; the local one is a
        # no-op sink. Error breaks are ignored so a script error cannot stop the run
        # at a debugger prompt.
        launch = ["--embedded", "-d", "--ignore-error-breaks", "--skip-breakpoints", "--audio-driver", "Dummy"]
    target = ["--script", suite.target] if suite.is_script else [suite.target]
    return launch + ["--fixed-fps", "60", "--path", str(ROOT)] + target + ["--", "--quiet-test"]


def can_render() -> bool:
    return sys.platform == "darwin"


def failure_lines(lines: list) -> list:
    """Failed assertions first, then script and engine errors with their locations.

    Suites list failed assertions as `  ! ...`; the `[FAIL]` rows of the checklist
    suites repeat them, so those are used only when a suite printed no `  !` line.
    """
    bang = [ln.rstrip() for ln in lines if ln.startswith("  !")]
    rows = [ln.rstrip() for ln in lines if "[FAIL]" in ln]
    if not bang and not rows:
        # Some suites (perf, leaks) explain a failure only on their RESULT line.
        rows = [ln.rstrip() for ln in lines if ln.startswith("RESULT: FAIL")]
    errors = []
    for i, line in enumerate(lines):
        s = line.rstrip()
        if "SCRIPT ERROR" in s or s.startswith("ERROR:"):
            known = any(k in s for k in gate_suites.KNOWN_EXIT)
            errors.append(s + (KNOWN_TAG if known else ""))
            if i + 1 < len(lines) and lines[i + 1].lstrip().startswith("at:"):
                errors.append(lines[i + 1].rstrip())
    return (bang or rows) + errors


def is_perf_line(line: str) -> bool:
    low = line.lower()
    return (" ms" in low or "fps" in low) and not low.startswith(("warning", "error", "   at:"))


def judge(res: dict) -> str:
    if res["status"] in ("TIMEOUT", "FOCUS", "CRASH"):
        return res["status"]
    result = [ln for ln in res["lines"] if ln.startswith("RESULT:")]
    if result and result[-1].startswith("RESULT: PASS") and res["rc"] == 0:
        return "PASS"
    return "FAIL"


def run_one(suite, godot: str, logdir: Path) -> dict:
    watch = suite.mode == "render"
    t0 = time.time()
    res = run_godot([godot] + godot_args(suite), ROOT, suite.timeout, watch_focus=watch)
    res["secs"] = round(time.time() - t0, 1)
    res["status"] = judge(res)
    stamped = []
    for load, line in zip(res["loads"], res["lines"]):
        if suite.perf and is_perf_line(line):
            line = "%s    [load1 %.2f]" % (line.rstrip(), load)
        stamped.append(line.rstrip())
    res["lines"] = stamped
    log = logdir / ("%s.log" % suite.name)
    if log.exists():
        # A retry (gate_load.py): keep the earlier attempt's log as evidence.
        n = len(list(logdir.glob("%s.attempt*.log" % suite.name))) + 1
        log.rename(logdir / ("%s.attempt%d.log" % (suite.name, n)))
    log.write_text("\n".join(stamped) + "\n")
    return res


def summarise(suite, res: dict) -> dict:
    lines = res["lines"]
    fails = failure_lines(lines)
    perf = [ln for ln in lines if "[load1 " in ln]
    tail = [ln for ln in lines if ln.strip()][-12:]
    return {
        "name": suite.name,
        "mode": suite.mode,
        "status": res["status"],
        "secs": res["secs"],
        "rc": res["rc"],
        "script_errors": sum(1 for ln in lines if "SCRIPT ERROR" in ln),
        "failures": fails,
        "perf": perf,
        "tail": tail if (res["status"] != "PASS" and not fails) else [],
        "note": res.get("note", ""),
    }


def print_suite(s: dict) -> None:
    extra = "script errors: %d" % s["script_errors"]
    print("  %-9s %-7s %6.1fs  (%s)" % (s["name"], s["status"], s["secs"], extra), flush=True)
    if s["note"]:
        print("      " + s["note"])
    for ln in s["perf"]:
        print("      " + ln.strip())
    shown = s["failures"] if s["status"] != "PASS" else [f for f in s["failures"] if "SCRIPT ERROR" in f]
    # A failed perf assertion is already on screen with its load average.
    shown = [f for f in shown if not any(p.startswith(f) for p in s["perf"])]
    for ln in (shown or s["tail"])[:DETAIL_LINES]:
        print("      " + ln.strip())
    hidden = len(shown or s["tail"]) - DETAIL_LINES
    if hidden > 0:
        print("      ... %d more line(s) in the failures log" % hidden)


def write_failures(path: Path, results: list) -> None:
    out = []
    for s in results:
        if not s["failures"] and not s["tail"]:
            continue
        out.append("== %s  %s  (%.1fs, exit %s)" % (s["name"], s["status"], s["secs"], s["rc"]))
        if s["note"]:
            out.append(s["note"])
        out.extend(s["failures"] or ["(no failure lines; last output follows)"] + s["tail"])
        if s["status"] != "PASS" and s["perf"]:
            out.append("-- timing figures, each with the 1-minute load average when it was printed:")
            out.extend(s["perf"])
        out.append("")
    path.write_text("\n".join(out) + "\n" if out else "no failures\n")


def parse_args(argv: list) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="RAMA test gate (quiet: no window, no focus, no sound).")
    ap.add_argument("suites", nargs="*", help="run only these suites (default: all)")
    ap.add_argument("--headless-only", action="store_true", help="skip suites that need a renderer (for CI)")
    ap.add_argument("--fast", action="store_true", help="only the few-second suites (pre-commit)")
    ap.add_argument("--list", action="store_true", help="list the suites and exit")
    ap.add_argument("--no-import", action="store_true", help="skip refreshing the import cache")
    ap.add_argument(
        "--load-wait",
        type=int,
        default=300,
        help="seconds to wait for the load to drop before retrying a frame-time check (default 300)",
    )
    return ap.parse_args(argv)


def select(args: argparse.Namespace) -> list:
    table = gate_suites.by_name()
    unknown = [n for n in args.suites if n not in table]
    if unknown:
        print("Unknown suite(s): %s. Known: %s" % (", ".join(unknown), ", ".join(table)))
        sys.exit(2)
    chosen = [table[n] for n in args.suites] if args.suites else list(gate_suites.SUITES)
    if args.fast:
        chosen = [s for s in chosen if s.fast]
    return chosen


def refresh_import(godot: str, logdir: Path) -> bool:
    cmd = [godot, "--headless", "--audio-driver", "Dummy", "--path", str(ROOT), "--import"]
    res = run_godot(cmd, ROOT, 900, watch_focus=False)
    (logdir / "import.log").write_text("\n".join(ln.rstrip() for ln in res["lines"]) + "\n")
    return res["status"] == "DONE" and res["rc"] == 0


def skip_reason(suite, args) -> str:
    if suite.mode != "render":
        return ""
    if args.headless_only:
        return "needs a renderer; --headless-only"
    if not can_render():
        return "needs the macOS embedded renderer"
    return ""


def run_all(chosen: list, godot: str, args, logdir: Path) -> list:
    results = []
    for suite in chosen:
        why = skip_reason(suite, args)
        if why:
            s = {"name": suite.name, "mode": suite.mode, "status": "SKIP", "secs": 0.0, "rc": None,
                 "script_errors": 0, "failures": [], "perf": [], "tail": [], "note": why}
        else:
            s = gate_load.run_with_retries(
                suite,
                lambda suite=suite: summarise(suite, run_one(suite, godot, logdir)),
                args.load_wait,
                lambda msg: print(msg, flush=True),
            )
        print_suite(s)
        results.append(s)
    return results


def main(argv: list) -> int:
    args = parse_args(argv)
    chosen = select(args)
    if args.list:
        for s in chosen:
            print("  %-9s %-8s timeout %4ds  %s%s" % (s.name, s.mode, s.timeout, s.target, "  (fast)" if s.fast else ""))
        return 0
    godot = find_godot()
    if not godot:
        print("Could not find Godot 4. Set GODOT to the Godot executable, put `godot` on your PATH,")
        print("or install it at ~/tools/Godot.app, then run the gate again.")
        return 2
    run_id = time.strftime("%Y%m%d-%H%M%S")
    logdir = ROOT / "build" / "test-logs" / run_id
    logdir.mkdir(parents=True, exist_ok=True)
    (ROOT / "build" / "screenshots").mkdir(parents=True, exist_ok=True)
    print("== RAMA test gate  (%d suite(s), logs in build/test-logs/%s) ==" % (len(chosen), run_id), flush=True)
    print("   load average at start: %.2f %.2f %.2f" % os.getloadavg(), flush=True)
    if not args.no_import and not refresh_import(godot, logdir):
        print("The Godot import step failed, so no suite can be trusted. See build/test-logs/%s/import.log." % run_id)
        return 2
    results = run_all(chosen, godot, args, logdir)
    write_failures(logdir / "failures.txt", results)
    counts = {k: sum(1 for r in results if r["status"] == k) for k in STATUSES}
    summary = {"run": run_id, "godot": godot, "load_end": os.getloadavg(), "counts": counts, "suites": results}
    (logdir / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    return report(counts, run_id)


def report(counts: dict, run_id: str) -> int:
    bad = counts["FAIL"] + counts["TIMEOUT"] + counts["FOCUS"] + counts["CRASH"]
    parts = ["%d %s" % (v, k.lower()) for k, v in counts.items() if v]
    if bad:
        verdict, code = "FAILURES", 1
    elif counts["BUSY"]:
        verdict, code = "NO FAILURES, BUT FRAME TIME NOT MEASURED (machine busy; known failure)", 3
    else:
        verdict, code = "ALL PASS", 0
    print("== %s: %s ==" % (verdict, ", ".join(parts)))
    if code:
        print("   Failure details: build/test-logs/%s/failures.txt" % run_id)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
