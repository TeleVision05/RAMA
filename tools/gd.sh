#!/bin/bash
# Dev-loop wrapper. Re-imports (so new class_name declarations register), then runs.
#   tools/gd.sh test  tests/foo.gd            headless script
#   tools/gd.sh play  [--capture-at=..] ...   windowed run of the main scene
#   tools/gd.sh import                        just refresh the class cache
GODOT=~/tools/Godot.app/Contents/MacOS/Godot
cd "$(dirname "$0")/.." || exit 1
reimport() { "$GODOT" --headless --path . --import >/dev/null 2>&1; }
case "$1" in
  import) reimport; echo "imported";;
  test)   shift; reimport; "$GODOT" --headless --path . --script "$@";;
  play)   shift; reimport; "$GODOT" --path . -- "$@";;
  scene)  shift; SC="$1"; shift; reimport; "$GODOT" --path . "$SC" -- "$@";;
  *) echo "usage: gd.sh {import|test <script>|scene <scene> [args]|play [args]}"; exit 2;;
esac
