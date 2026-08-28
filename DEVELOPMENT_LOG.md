# RAMA — Development Log

Chronological. Every entry records what was built, what actually broke, and how it was
found — because "it compiled" was never evidence that anything worked.

---

## 1. Choosing the engine

Unreal was not installed (only the Epic launcher). Unity 6 was present but iterates in
minutes per build. Godot 4.7.2 was downloaded: it runs on Metal on this machine,
GDScript iterates in seconds, and — decisively — a running Godot scene can screenshot
its own viewport, which makes a real *build → run → look → fix* loop possible.

**First thing built was the observation harness**, not the game:
`scripts/core/dev_capture.gd` takes timed screenshots and auto-quits, so every later
change could be judged by looking at pixels.

## 2. The world model

`WorldMap` bakes a 769×769 heightfield with biomes, river and road distance fields.
Everything else queries it, so the collider, the visual mesh and every prop placement
agree exactly.

**Bugs found and fixed, in order:**

| # | symptom | root cause | fix |
|---|---|---|---|
| 1 | bake took 90 s | `river_dist` was O(cells × curve points) — 150 M distance tests | two-pass chamfer distance field, O(cells). Bake fell to ~8 s |
| 2 | 15 % of the map underwater; **half the river ran above its own water line** | a single global water level cannot work when the river descends 45 m and falls over a cliff | gave the river a downstream water-height profile and propagated it outward as a nearest-seed field; all ground near the channel is now carved *relative to local water* |
| 3 | settlements were perfect circular craters | radial falloff | noise-warped, irregular footprints |
| 4 | 16 river samples still dry | the village's flatten disc was filling the channel | flatten runs **before** the river carves; water always wins |
| 5 | a 1.66 (59°) grade on the forest road | each road slope-limited itself independently, then their corridors were blended, so the junction was steeper than either | the whole road network is solved as one graph: profiles are welded at junctions and re-limited together |
| 6 | roads cut 14 m deep slot canyons | 26 rounds × 70 smoothing passes flattened every profile into a straight ramp that ignored the terrain | smooth lightly (12 passes), let the grade limiter do the real work, and widen the shoulder from 7.5 m to 21 m |
| 7 | mountains were 90 m shark teeth | ridged noise sampled at a 12 m wavelength | long-wavelength ridge lines plus a masked blur on high ground |

A headless test (`tests/bake_map_test.gd`) asserts the river is submerged along its
whole course, the village is buildable, and no road exceeds a walkable grade — and
renders a top-down map so the layout can be looked at.

## 3. Terrain rendering

Chunked LOD mesher (12×12 chunks of 64 m, four LODs, skirts) plus one world-sized
`HeightMapShape3D` collider that lines up with the grid exactly.

- **The entire ground was invisible.** Only the chunk skirts drew, which looked like the
  world had been shredded into ribbons. Cause: Godot ArrayMesh front faces are
  **clockwise**; the grid winding was reversed. One flipped index order fixed it.
- **Then everything lit rendered black.** The terrain shader writes `NORMAL_MAP`, which
  needs `ARRAY_TANGENT`; without tangents the TBN is degenerate. Added tangents.
- **Chunk generation cost 95 ms**, a visible hitch on every LOD change. Ambient
  occlusion and layer weights were being computed per vertex; they are static, so they
  are now baked into the cached map. 95 ms → 12 ms.
- Texture imports defaulted to **mipmaps off** (ground aliased into shimmer) and
  `high_quality` compression forced **BPTC**, which Apple GPUs cannot decode — the
  texture silently failed to load. `tools/fix_imports.py` forces correct settings.

## 4. Atmosphere

Procedural sky shader (gradient, sun disc, moon with craters, twinkling stars, Milky
Way, animated clouds, horizon haze) driven from one time-of-day value together with
sun/moon lights, fog, volumetrics and colour grading.

- Fog was erasing the valley 40 m from the camera; depth curve, aerial perspective and
  sky-affect were all far too strong.
- Night was **unplayably black**. Moonlight, night ambient and night exposure were all
  raised, and night is graded (desaturated, cooler, higher contrast) rather than being
  dim daylight.

## 5. The character

No character assets exist, so `ProcRig` builds a humanoid from generated meshes and
animates it entirely in code:

- **two-bone IK on the legs** with a foot-placement cycle, so feet plant and slide
  instead of skating, and conform to the terrain under them
- additive layers for aiming, the melee arc, flinching and death
- the same class builds Rama, villagers and rakshasas from one config

First version had a barrel torso; rebuilt as a lofted elliptical ribcage. Skin showed
its whole texture once per limb, which read as wood grain — fixed with UV scale.

`MeshKit` provides the primitives (loft, profile loft, limb, ovoid, boulder…), all
tangent-generating and clockwise-wound, with `tests/meshkit_test.gd` rendering them to
prove the winding rather than trusting the derivation.

## 6. Gameplay

Player controller with acceleration, sprint/stamina, coyote time and jump buffering, a
dodge roll with i-frames, a charged bow, a three-hit melee combo, wading and swimming.
Arrows are swept-raycast projectiles so they cannot tunnel at 74 m/s.

`tests/playtest.tscn` drives the real game with synthetic input and asserts real
outcomes. Current result:

```
spawn: (-114.0, 12.58) ground=12.58
after settle: delta=0.000  on_floor=true
walked 7.23 m / 1.5 s        sprinted 10.92 m / 1.5 s   stamina 84.6
jump peak +1.75 m            dodge moved 3.51 m
draw charge 1.00             arrows 24 -> 23, 1 in flight
health 100.0 -> 76.0
worst penetration below terrain over a 10 s sprint: 0.060 m
RESULT: PASS
```

## 7. Content systems (built in parallel, then verified)

Four independent systems were specified against the `WorldMap` contract and built
concurrently, each required to render its own screenshots and look at them:

- **Water** — a ribbon mesh following the river centreline with UVs that run along the
  flow, depth-based colour reconstructed from the depth buffer, shoreline foam,
  fresnel refraction, sun glitter, a waterfall section and plunge-pool mist.
- **Vegetation** — procedural banyan (with aerial root pillars), palm, mango, sal, dead
  trees and shrubs, each with LODs and billboards; instanced grass and flowers streamed
  in cells around the player; scatter driven entirely by `WorldMap` rules.
- **Architecture / settlement** — huts with conical thatch roofs, granaries, a well, the
  shrine with a real stepped shikhara, ruins, the rakshasa camp, paddy fields, fences,
  carts, pots and wayside shrines, all placed on `map.height_at`.
- **VFX and wildlife** — pollen, fireflies, falling leaves, wind gusts, river mist,
  smoke, firelight, rain; plus chital herds, bird flocks, monkeys, butterflies and fish.

Then enemies (four archetypes with a full perception + state machine), NPCs with daily
schedules, a branching dialogue system, the whole UI (HUD, compass, notifications,
main menu, pause, settings, save/load, inventory, journal), and a data-driven quest
system with three quests.

## 8. Performance

Measured on an M2 Max at 1600x900, walking the world at sprint speed.

The first measurements were badly wrong in three separate ways, and each had to be
fixed before the numbers meant anything:

| mistake | what it did | fix |
|---|---|---|
| vsync left on | every reading was the 16.7 ms refresh cap | `VSYNC_DISABLED` in the harness |
| no warm-up | whichever configuration ran first absorbed all of Godot's lazy shader compilation, so everything measured after it looked free — and "disable any one system" appeared to halve the frame time | one long warm-up lap before any measurement |
| teleporting between waypoints | 30 m/s, six times sprint speed, thrashing the foliage streamer | traverse at 8 m/s |

With honest measurement the real costs were: SSIL ~8 ms for an effect invisible in
daylight, 4x MSAA, a 190 m volumetric fog volume, and full-density atmosphere
particles. A `Quality` tier system now scales all of them.

Two further optimisations were measured in isolation and are solid:

- **Static collision streaming** cost **10.2 ms/frame** because it re-parented
  `StaticBody3D` nodes as the player moved; the tree churn was the expense, not the
  physics. Rewritten as a fixed pool of 260 bodies that are created once and only ever
  have their transform and shape reassigned: **1.5 ms**. Frame rate in the same test
  went from 24 to 41 fps.
- **Every generated mesh is now memoised on its arguments**, and character proportions
  are snapped to a 3 cm grid before generation so different characters share meshes.
  A `ProcRig` build went from **52.7 ms to 1.3 ms** for a repeat, and 18 enemy rigs
  now build in 162 ms in total.

- **Static settlement geometry** — ~100 separate huts, racks, pots and fences, none of
  which ever move, were ~111 draw calls. `StaticMerge` collapses them by material
  within a 22 m cell (a single merged mesh would never frustum-cull), giving
  **103 -> 53 draws**. Mean frame rate went from 31 to 40 fps and the worst leg from
  24 to 34 fps; the streaming peaks fell from 139 ms to 78 ms.

**Final measurement, on a quiet machine, walking the whole map at sprint speed:**

| leg | frame | draws |
|---|---|---|
| village | 22.9 ms (44 fps) | 855 |
| river road | 20.5 ms (49 fps) | 660 |
| shrine | 26.1 ms (38 fps) | 623 |
| falls | 29.4 ms (34 fps) | 584 |
| deep wood | 24.4 ms (41 fps) | 700 |
| badlands | 27.4 ms (36 fps) | 590 |
| **mean** | **25.1 ms (40 fps)** | |

140 MB static, 390 MB video memory. LOW, MEDIUM and HIGH all land within 2 fps of each
other, which says the remaining cost is CPU-side draw submission and game logic rather
than rendering settings — so HIGH is the default, since the visual quality is free.

Repeating that run on the same idle machine gave a mean of 33 fps and a worst leg of
27, so **run-to-run variance is about ±7 fps** even with nothing else running. The
honest characterisation is **27–49 fps across the map, mean in the mid-thirties**. The
suite therefore reports against 60 and 30 fps but only GATES at 20, because a tighter
gate on that variance would be a coin toss rather than a regression detector.

**This is the weakest part of the project.** The remaining cost is draw submission:
~900 calls in the village, of which characters are still the largest share (12 NPCs
and the visible enemies account for roughly 450 between them, ~24 draws each after the
joint merge). The next real win is a distance LOD that swaps a character for a single
merged mesh past ~30 m — the same trick already applied to the settlement.

**A caveat worth stating:** most of the intermediate figures in this log were taken
while up to thirteen other Godot processes and a macOS media-analysis job shared the
machine (load average ~15), and two identical runs of the same spike test returned 142
and 443 slow frames. Every per-system number quoted here was measured in isolation
against a single change; the table above was taken with the machine otherwise idle.

A separate leak test walks a long circuit and watches node count, object count and
memory: **nodes flat at ~825, memory flat at 104.7 MB, zero orphans across seven laps**,
so the streamers genuinely free what they replace.

## 9. Finding the frame cost honestly

Guessing at performance was wrong three times in a row, so the last round was done by
measuring where the draw calls actually come from — a count that does not care how
loaded the machine is:

```
system        visible   hidden       tris
terrain           144        0     128192
vegetation        126       15     152272
settlement        111        0      90262
wildlife          111       42       8310
enemies           156        0      32556
npcs              503       58      65640     <-- 40% of all draws
player             64        4       6854
TOTAL            1246              489762
```

A `ProcRig` is built from ~42 separate `MeshInstance3D` nodes and every one is its own
draw call, so twelve villagers alone cost 503 draws. The meshes under a joint never
move relative to each other, so they are now merged by material at build time and only
the joints stay separate. **1246 draws -> 1014**, and 66 nodes per character -> 46.

## 10. What the camera taught us

`tests/framing_test.gd` projects Rama's head and feet to screen space and raycasts from
the camera to him. It caught something no frame-rate number would have: **a tree trunk
sitting exactly between the camera and the player.** Trees, huts and boulders had no
collision at all, so the spring arm passed straight through them — and the player could
walk through them too.

That produced `SolidStreamer`, and the test now asserts line of sight, not just that
Rama is somewhere on screen.

## 11. Known issues / next priorities

- **Performance figures in this log are not trustworthy.** They were taken with up to
  thirteen other Godot processes and a macOS media-analysis job on the same machine
  (load average ~15); two identical runs of the same test returned 142 and 443 slow
  frames. Every per-system optimisation here was measured in isolation against a single
  change and is real; the absolute frame rate needs re-measuring on a quiet machine.
- Godot compiles shaders lazily, so first entry into a region can hitch once. A warm-up
  pass behind the main menu would hide it.
- Distant foliage billboards show some alpha dithering against the sky.
- The horizon ends at the world edge; a distant backdrop would sell the scale.
- Buildings use axis-aligned box collision, so a rotated hut blocks slightly more
  ground than it occupies.

## 12. Quests

Built last, against interfaces the UI and dialogue systems had already published: the
HUD and journal look for a quest system **by group and by capability**, and the
dialogue trees already contained `quest_start:q_shrine` and `quest_advance:q_shrine:lamp`
hooks. Matching those ids meant a conversation and the quest log could not drift apart.

All state lives in `GameState.quests` in the shape the journal already read, so saving
needed no extra code. `tests/quest_test.gd` drives all three quests to completion —
including spawning the ambush, counting the kills, granting the rewards and a
save/reset/load round-trip — and asserts the signal order. 27 of 27 checks pass.

## 13. The bug a green test suite was hiding

The game shipped its first playable build with **every control dead**. WASD, Escape,
the bow — nothing. Eleven test suites were green at the time, including a playtest that
asserted walking, sprinting, jumping, dodging, drawing the bow and swinging a sword.

**Cause.** The `[input]` block hand-written into `project.godot` used Godot 3's
dictionary syntax for events. Godot 4 wants `Object(InputEventKey, ...)` constructor
syntax. Its parser accepted the section, **created all eighteen actions, and silently
discarded every event.** No warning, no error, no failed import.

**Why every test passed anyway.** `tests/playtest.gd` drives the game with
`Input.action_press("move_forward")`, which sets an action's state DIRECTLY and never
consults the InputMap. Every movement and combat test was exercising the game logic
*downstream* of a binding layer that did not exist. The suite was not wrong about what
it measured; it measured the wrong side of the seam.

**Fix.** Bindings now live in `scripts/core/input_setup.gd`, the first autoload, built
with `InputMap.add_action` / `action_add_event` and `physical_keycode` so WASD stays put
on a non-QWERTY layout. The `[input]` section is gone.

**The test that would have caught it.** `tests/input_probe.gd` synthesises real
`InputEventKey` and `InputEventMouseButton` events through `Input.parse_input_event()`,
which does go through the InputMap, and asserts the action rises and falls:

```
move_forward  W       -> OK      pause    Escape  -> OK
jump          Space   -> OK      attack   mouse 1 -> OK
...  18/18
```

It then flaked once, reporting W dead while Escape worked — the give-away that the map
was fine and the harness was racing. `parse_input_event` is queued and the action state
only updates on the input flush, so the first key press of the run could be read too
early. `Input.flush_buffered_events()` plus a settle before the first press made it
deterministic; five consecutive runs pass.

**The lesson worth keeping:** a test that reaches past a layer to poke the state
underneath will stay green while that layer is entirely broken. Drive the outermost
interface a real user touches, or accept that everything inside it is unverified.

## 14. One environment trap worth recording

Several cleanup steps in this session appeared to do nothing: a scene file kept
"reappearing" after being deleted. `rm` is shadowed by a shell function in this
machine's zsh profile, so every `rm` silently returned exit 1 and printed a usage
message that looked like unrelated shell noise. Using `/bin/rm` fixed it. Worth
knowing before concluding that something is regenerating a file.

## 15. Test suite

`tools/run_tests.sh` runs everything. Current state:

| suite | result |
|---|---|
| parse — every script loads | PASS |
| input — real key/mouse events raise every action | PASS (18/18) |
| assets — 74 textures, 82 sounds, 8 shaders load | PASS |
| worldmap — river wet, village buildable, roads walkable | PASS |
| terrain — LODs, budget, exact heightfield match | PASS |
| playtest — movement, sprint, jump, dodge, bow, melee, damage | PASS |
| audio — six ambience beds loop and play | PASS |
| saveload — full round-trip through the live world | PASS |
| leaks — nodes and memory flat over seven laps | PASS |
| quests — all three driven to completion, save round-trip | PASS (27/27) |
| acceptance — the full checklist, menu to gameplay | PASS (50/50) |
| perf — reports against 60/30 fps, gates at 20 | PASS |
