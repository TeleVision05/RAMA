# RAMA — The Vale of Panchavati

An open-world action-adventure vertical slice set in ancient India, inspired by the
journey of Lord Rama. Built in **Godot 4.7.2** (Forward+ / Metal), macOS only.

Every asset in this project is generated: the textures and sound are synthesised in
Python, the terrain, trees, buildings, characters and weapons are generated as meshes
in GDScript, and the music is synthesised from first principles. Nothing is downloaded
and nothing is copied.

**Status (2026-09-25): working.** The baseline slice is playable start to finish and 11
of the 12 test suites pass on `main`; the `perf` suite has not been re-run since the
3D-vegetation overhaul landed, and that overhaul has not yet been checked visually.
See [ROADMAP.md](ROADMAP.md) for what is next.

---

## Install

```bash
# 1. Godot 4.7.2 (any 4.7.x) at ~/tools/Godot.app — the scripts hard-code this path
# 2. Commit gate: gdlint + Godot parse check on staged .gd files
pip3 install "gdtoolkit==4.*"
git config core.hooksPath .githooks
# 3. Only if you regenerate textures or audio (tools/gen_*.py)
pip3 install numpy pillow
```

## Configure

There are no environment variables and no `.env`. Everything is in `project.godot`.
Graphics tiers (LOW/MEDIUM/HIGH/ULTRA) are chosen in the in-game settings menu. The
first launch bakes the world heightfield (~10 s) and caches it at `user://worldmap.cache`;
delete that file to force a re-bake.

## Run

```bash
~/tools/Godot.app/Contents/MacOS/Godot --path .     # from the repo root
tools/make_app.sh                                    # optional: ~/Desktop/RAMA.app launcher
```

## Controls

| input | action |
|---|---|
| `W A S D` / arrows / left stick | move |
| mouse / right stick | look |
| `Shift` | sprint (drains stamina) |
| `Space` | jump |
| `Ctrl` | dodge roll (invulnerable through the roll) |
| **Right mouse (hold)** | draw the bow — hold longer for more power |
| **Right mouse (release)** | loose the arrow |
| **Left mouse** | melee attack (3-hit combo) |
| `Q` | swap between bow and sword |
| `E` | interact / talk |
| `J` | journal · `I` inventory |
| `Esc` | pause · `F5` quick save · `F6` quick load |
| `F7` | developer screenshot |

## The world

A 768 × 768 m valley, hand-composed rather than pure noise:

- **Panchavati**, a village of mud-and-thatch houses on a river terrace
- **The Godavari**, which descends ~45 m across the map and falls over a cliff in the
  north — there is no flat "sea level" anywhere in this game
- **The shrine knoll** in the east, with a carved stone shrine reached by a road that
  spirals up the hill
- **Deep forest** in the west, where the rakshasas are
- **Ruins** in a north-western clearing, **badlands** in the south-east, a **hidden
  grove** far to the west, a **lookout** over the valley, **paddy fields**, and a
  **ford** where the road wades the river
- A full day/night cycle: dawn, day, dusk, night with moonlight and stars

## What there is to do

- **The Path Through the Forest** — Gopa the herder has lost two goats to something in
  the western wood. Follow the forest road, find what is left of the herd, and deal
  with what is living out there.
- **The Forgotten Shrine** — the shrine on the eastern knoll has been untended for a
  generation. Read the inscription, recover the bell from the old ruins, light the
  three lamps, and hang it again.
- **Into the Wild** — the hermit speaks of a grove nobody can find. Three places let
  you read the valley; find them, and the way west opens.

Twelve villagers keep a daily schedule and will talk to you about the harvest, the
river, and the noises after dark. Four kinds of hostile inhabit the forest and the
badlands. Ten places can be discovered. Praying at the shrine restores you and sets
where you wake.

## Test

```bash
tools/run_tests.sh                              # the full 12-suite gate; 5+ min, opens short-lived windows
tools/gd.sh scene res://scenes/playtest.tscn    # drives the game, asserts movement + combat
tools/gd.sh scene res://scenes/asset_test.tscn  # every texture, sound and shader loads
tools/gd.sh test tests/bake_map_test.gd         # world sanity + top-down map render
tools/gd.sh test tests/terrain_test.gd          # meshing, LODs, triangle budget
```

Render harnesses write PNGs to `build/screenshots/` so results can be looked at rather
than assumed.

## Documentation

- [ROADMAP.md](ROADMAP.md) — current state, known gaps, milestones, open questions
- `OVERHAUL.md` — the second-pass plan (true 3D vegetation, rendering, characters, content)
- `ARCHITECTURE.md` — systems, APIs, the contracts between them, and a table of
  Godot-4.7 traps that each cost a debugging cycle
- `DEVELOPMENT_LOG.md` — what was built, what broke, what was fixed, what is left
