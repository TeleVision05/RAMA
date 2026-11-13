"""Run one Godot process for the test gate: timeout, live output, focus guard.

macOS has no `timeout` binary, so the deadline is enforced here. The process runs in
its own session, so killing it also kills anything it started.
"""

import os
import re
import signal
import subprocess
import sys
import threading
import time

POLL_SECS = 0.25


def frontmost_pid() -> int:
    """PID of the app in front on macOS, or -1 when it cannot be read."""
    if sys.platform != "darwin":
        return -1
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        if not asn:
            return -1
        out = subprocess.run(["lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return -1
    m = re.search(r'\bpid"?\s*=\s*(\d+)', out)
    return int(m.group(1)) if m else -1


def _kill(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _start_reader(proc: subprocess.Popen, rows: list) -> threading.Thread:
    def reader() -> None:
        for line in proc.stdout:
            rows.append((os.getloadavg()[0], line))

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    return t


def _watch(proc: subprocess.Popen, timeout: int, watch_focus: bool) -> tuple:
    deadline = time.time() + timeout
    while proc.poll() is None:
        if time.time() > deadline:
            _kill(proc)
            return "TIMEOUT", "Killed after %d s without finishing." % timeout
        if watch_focus and frontmost_pid() == proc.pid:
            _kill(proc)
            return "FOCUS", "Killed at once: the test process became the frontmost app."
        time.sleep(POLL_SECS)
    return "DONE", ""


def run_godot(cmd: list, cwd, timeout: int, watch_focus: bool) -> dict:
    """Run `cmd`, returning status DONE/TIMEOUT/FOCUS/CRASH, exit code, lines, loads.

    `loads[i]` is the 1-minute load average when `lines[i]` was printed.
    """
    rows: list = []
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
        start_new_session=True,
    )
    reader = _start_reader(proc, rows)
    status, note = _watch(proc, timeout, watch_focus)
    proc.wait()
    reader.join(10)
    rc = proc.returncode
    lines = [r[1] for r in rows]
    if status == "DONE" and (rc < 0 or any("handle_crash:" in ln for ln in lines)):
        status = "CRASH"
        note = "Godot crashed (exit %d); the backtrace is in the suite log." % rc
    return {"status": status, "rc": rc, "lines": lines, "loads": [r[0] for r in rows], "note": note}
