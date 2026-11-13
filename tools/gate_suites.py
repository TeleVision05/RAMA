"""The suites the RAMA test gate runs, and what each one needs.

Every suite prints `RESULT: PASS` or `RESULT: FAIL` and lists its failed assertions
on lines that start with `  !` (the acceptance and quest suites also print
`[FAIL]` rows). tools/run_tests.py reads those lines; nothing else is parsed.

HOW A SUITE IS LAUNCHED (the `mode` column)

  headless  Godot --headless --audio-driver Dummy. No window, no renderer, no sound.
            Logic tests: input, saves, quests' bookkeeping, streaming leaks. The
            headless renderer never emits `RenderingServer.frame_post_draw`, so a
            suite that awaits it hangs here; such a suite must be `render`.
  render    Godot --embedded (macOS only). Godot's embedded display server renders
            with Metal into an off-screen layer: real pixels and real GPU timing, but
            no window, no Dock activation and no focus change. Used for suites that
            read the framebuffer or time rendering. Measured 2026-11-13: the frontmost
            app did not change across the run, and a 1600x900 frame was read back.
            On other platforms, and with --headless-only, these are reported SKIP.
            Known gap (2026-11-13): under --embedded the perf suite's GPU column
            reads 0.00 ms on every leg, so only its CPU frame time is a real figure.

Every launch also passes `-- --quiet-test` (see scripts/core/quiet_mode.gd), so the
game never captures the mouse, never asks for focus and mutes its audio.

`perf` marks suites whose output contains timing figures; the runner stamps every
such line with the 1-minute load average at the moment it was printed, because a
frame time measured on a loaded machine is not the same number.

`fast` marks suites cheap enough for the pre-commit hook (a few seconds each).
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Suite:
    name: str
    target: str  # a res:// scene, or a tests/*.gd SceneTree script
    mode: str  # "headless" or "render"
    timeout: int  # seconds before the runner kills it
    perf: bool = False
    fast: bool = False

    @property
    def is_script(self) -> bool:
        return self.target.endswith(".gd")


SUITES = [
    # Every script in the project parses and loads.
    Suite("parse", "res://scenes/parse_test.tscn", "headless", 120, fast=True),
    # Real key and mouse events raise every action; mouse motion turns the camera.
    Suite("input", "res://scenes/input_probe.tscn", "headless", 120, fast=True),
    # Every generated texture, sound and shader loads.
    Suite("assets", "res://scenes/asset_test.tscn", "headless", 120, fast=True),
    # The world map bakes and its layout is sane (writes build/map_*.png).
    Suite("worldmap", "tests/bake_map_test.gd", "headless", 300),
    # Terrain builds from the baked map with its shader.
    Suite("terrain", "tests/terrain_test.gd", "headless", 300),
    # Synthetic input drives the player: walk, sprint, jump, dodge, bow, melee.
    Suite("playtest", "res://scenes/playtest.tscn", "headless", 300),
    # Ambience beds load, loop and play (into a muted bus).
    Suite("audio", "res://scenes/audio_test.tscn", "headless", 120, fast=True),
    # All quests end to end; asserts its screenshots are real frames.
    Suite("quests", "res://scenes/quest_test.tscn", "render", 900),
    # Save, wipe, load: the live world comes back.
    Suite("saveload", "res://scenes/save_test.tscn", "headless", 300),
    # Long streaming circuit: node and memory growth.
    Suite("leaks", "res://scenes/leak_test.tscn", "headless", 600, perf=True),
    # Frame time per region, GPU and CPU.
    Suite("perf", "res://scenes/perf_test.tscn", "render", 600, perf=True),
    # The acceptance checklist; includes a frame-time check in the village.
    Suite("accept", "res://scenes/acceptance_test.tscn", "render", 600, perf=True),
    # Every UI screen rendered and sampled.
    Suite("ui", "res://scenes/ui_test.tscn", "render", 600),
]


def by_name() -> dict:
    return {s.name: s for s in SUITES}
