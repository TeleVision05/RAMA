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
game never captures the mouse, never asks for focus and mutes its audio, and seeds the
global random number generator with a fixed value.

Every launch also passes `--fixed-fps 60`: each frame advances the game by exactly
1/60 s and one physics tick, however long it took to compute. Game time is then a
pure function of the frame count, so a busy machine slows a suite down but cannot
change what it sees. (Without it, a stalled frame hands the game a longer delta, and
anything paced on process time drifts from anything paced on physics ticks.) Timing
figures are unaffected: they read Performance.TIME_PROCESS and the GPU timer, which
measure the work, not the step.

`perf` marks suites whose output contains timing figures; the runner stamps every
such line with the 1-minute load average at the moment it was printed, because a
frame time measured on a loaded machine is not the same number.

`timing` lists the failure lines (by substring) that are frame-time assertions.
When a suite fails ONLY on those and the 1-minute load average was above
LOAD_LIMIT when they were measured, the runner waits for the machine to quieten and
runs the suite again (tools/gate_load.py). If the load never drops, the suite is
reported BUSY: a known failure caused by the machine, with the load figures as the
evidence, never a PASS. Thresholds are never loosened for load.

`fast` marks suites cheap enough for the pre-commit hook (a few seconds each).

KNOWN ENGINE EXIT WARNINGS (Godot 4.7.2; measured 2026-11-13, see KNOWN_EXIT below)

Each of these is printed at exit and reproduced in an EMPTY project with no game code,
so it is the engine's, not the game's. The runner labels the shader lines in
failures.txt; "resources still in use" is left unlabelled because a game leak prints
the same line (run the suite with --verbose to see which resources). None of these
affect a suite's result.
  * "N ObjectDB instances were leaked" listing only AudioStreamWAV and
    AudioStreamPlaybackWAV, and "resources still in use" naming a .wav: an
    AudioStreamPlayer that has played and is still alive at quit leaves its playback
    in the AudioServer, even when stopped first; only freeing it and letting several
    frames run releases it. Repro: tests/engine_repro/audio_playback_leak.gd.
  * "4 RID allocations of type ...DummyShader... leaked", or under --embedded "4
    shaders of type ParticlesShaderRD were never freed" with "4 RID allocations of type
    ...MaterialStorage6Shader... leaked": ParticleProcessMaterial's shared shader cache
    keeps a use count that sometimes never returns to zero. Repro:
    tests/engine_repro/particle_shader_leak.gd (1 shader leaked, 3 runs of 3). The
    count moves with assignment order and timing, not with what the game frees.
Both repro scripts say in their header how to run them in an empty project.
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
    timing: tuple = ()  # substrings of the failure lines that are frame-time checks

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
    # A rotated building's collider follows its footprint instead of an axis-aligned box.
    Suite("solids", "tests/solid_basis_test.gd", "headless", 120, fast=True),
    # Every MeshKit builder still makes the same geometry (golden file; guards the split).
    Suite("meshkit", "tests/mesh_kit_golden_test.gd", "headless", 120, fast=True),
    # Villagers lose shadows, animation rate and then their draw with distance.
    Suite("npclod", "res://scenes/npc_lod_test.tscn", "headless", 120, fast=True),
    # A damaged save, a cut-off world cache and an unsupported renderer all end safely;
    # the loading screen's progress only moves forward.
    Suite("failsafe", "res://scenes/failsafe_test.tscn", "headless", 300),
    # ProcRig builds and poses exactly as before (golden file; guards the proc_rig.gd split).
    Suite("riggolden", "tests/proc_rig_golden_test.gd", "headless", 180),
    # A fresh bake still matches the golden figures (guards the world_map.gd split).
    Suite("mapgolden", "tests/world_map_golden_test.gd", "headless", 300),
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
    Suite("perf", "res://scenes/perf_test.tscn", "render", 600, perf=True, timing=("a leg averaged under 20 fps",)),
    # The acceptance checklist; includes a frame-time check in the village.
    Suite("accept", "res://scenes/acceptance_test.tscn", "render", 600, perf=True, timing=("performance is playable",)),
    # Every UI screen rendered and sampled.
    Suite("ui", "res://scenes/ui_test.tscn", "render", 600),
]


# Lines printed at exit that are the engine's (see the header). Matched by substring.
KNOWN_EXIT = (
    "RID allocations of type 'N13RendererDummy15MaterialStorage11DummyShaderE'",
    "RID allocations of type 'N10RendererRD15MaterialStorage6ShaderE'",
    "shaders of type ParticlesShaderRD were never freed",
)


def by_name() -> dict:
    return {s.name: s for s in SUITES}
