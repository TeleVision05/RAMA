#!/bin/bash
# Full test suite. Each entry prints its own RESULT line.
cd "$(dirname "$0")/.." || exit 1
GODOT=~/tools/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path . --import >/dev/null 2>&1
FAIL=0
run() {
  local name="$1"; shift
  local out
  out=$("$@" 2>&1)
  local res
  res=$(echo "$out" | grep -E "^RESULT:" | tail -1)
  local errs
  errs=$(echo "$out" | grep -c "SCRIPT ERROR")
  if echo "$res" | grep -q PASS; then
    printf "  %-14s PASS   (script errors: %s)\n" "$name" "$errs"
  else
    printf "  %-14s FAIL   (script errors: %s)\n" "$name" "$errs"
    echo "$out" | grep -E "^  !" | head -6
    FAIL=1
  fi
}
echo "== RAMA test suite =="
run parse    "$GODOT" --path . res://scenes/parse_test.tscn
run input    "$GODOT" --path . res://scenes/input_probe.tscn
run assets   "$GODOT" --path . res://scenes/asset_test.tscn
run worldmap "$GODOT" --headless --path . --script tests/bake_map_test.gd
run terrain  "$GODOT" --headless --path . --script tests/terrain_test.gd
run playtest "$GODOT" --path . res://scenes/playtest.tscn
run audio    "$GODOT" --path . res://scenes/audio_test.tscn
run quests   "$GODOT" --path . res://scenes/quest_test.tscn
run saveload "$GODOT" --path . res://scenes/save_test.tscn
run leaks    "$GODOT" --path . res://scenes/leak_test.tscn
run perf     "$GODOT" --path . res://scenes/perf_test.tscn
run accept   "$GODOT" --path . res://scenes/acceptance_test.tscn
echo "== $([ $FAIL -eq 0 ] && echo ALL PASS || echo FAILURES) =="
exit $FAIL
