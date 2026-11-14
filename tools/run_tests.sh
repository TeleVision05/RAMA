#!/bin/bash
# RAMA test gate. The runner is tools/run_tests.py; this wrapper keeps the old
# entry point. Quiet: no suite opens a window, takes focus or makes a sound.
#   tools/run_tests.sh [--headless-only] [--fast] [--list] [suite ...]
cd "$(dirname "$0")/.." || exit 2
if ! command -v python3 >/dev/null 2>&1; then
  echo "The test gate needs python3. Install Python 3, then run tools/run_tests.sh again."
  exit 2
fi
exec python3 tools/run_tests.py "$@"
