# RAMA — Architecture

Godot 4.7.2, Forward+ (Metal). GDScript. Textures and audio are synthesised in Python
and the world, creature and weapon meshes are generated in GDScript. The exceptions are
the humanoid character meshes and animation clips in `assets/models/characters/`, which
are CC0 third-party files credited in `assets/CREDITS.md`.

## The one rule

`WorldMap` is the single source of truth for the world. Terrain meshing, prop
placement, foliage scatter, NPC spawns, navigation and water all query it. Nothing
re-derives ground height from noise. This is why nothing floats or sinks.

## Layout

```
scripts/
  core/     dev_capture.gd        automated screenshot + auto-quit harness
  world/    world_map.gd          heightfield, biomes, rivers, roads  (WorldMap)
            terrain.gd            chunked LOD mesher + heightfield collider (Terrain)
            sky_system.gd         day/night, lights, fog, grading  (SkySystem)
            materials.gd          central material library  (Mats)
            world_root.gd         assembles the world  (WorldRoot)
  player/   ...                   character, camera, combat
  ai/       ...                   enemies, NPCs
  quest/    ...                   quests, dialogue
  ui/       ...                   HUD, menus
  audio/    ...                   audio director
shaders/    terrain, sky, water, foliage, grass ...
assets/     textures/ audio/      generated PNG + WAV
            models/characters/    CC0 third-party humanoid .glb (see CREDITS.md)
tools/      gd.sh                 dev loop wrapper; gen_*.py asset synthesisers
tests/      headless test scripts and render harnesses
```

## WorldMap API (scripts/world/world_map.gd)

Construct with `WorldMap.load_or_bake()` — uses a disk cache keyed on the script's
own md5, so editing the generator invalidates it automatically.

| call | meaning |
|---|---|
| `height_at(x, z) -> float` | ground height, bilinear. THE ground query. |
| `ground(x, z) -> Vector3` | `Vector3(x, height_at(x,z), z)` |
| `normal_at(x, z) -> Vector3` | surface normal |
| `slope_at(x, z) -> float` | 0 flat .. 1 vertical |
| `biome_at(x, z) -> int` | `WorldMap.Biome.{RIVERBED,SAND,MEADOW,FOREST,ROCK,MOUNTAIN,FIELD,VILLAGE,PATH}` |
| `path_at(x, z) -> float` | 0..1 how trodden this cell is |
| `wet_at(x, z) -> float` | 0..1 proximity to water |
| `water_y_at(x, z) -> float` | LOCAL water surface height (the river descends ~45 m) |
| `water_depth_at(x, z) -> float` | 0 on dry land |
| `is_underwater(x, z) -> bool` | |
| `river_dist(p: Vector2) -> float` | metres to the river centreline |
| `path_dist(p: Vector2) -> float` | metres to the nearest road |
| `forest_density(p: Vector2) -> float` | 0..1 where the forest wants to be |
| `river_points() -> Array[Vector2]` | dense centreline, north to south-west |
| `paths() -> Array` | array of polylines (`Array[Vector2]`) |
| `in_bounds(x, z) -> bool` | |

Constants: `WORLD_SIZE = 768`, `HALF = 384`, `CELL = 1.0`, `GRID = 769`.
Places: `P_VILLAGE (-120, 44)`, `P_SHRINE (158, -66)`, `P_RUINS (-168, -148)`,
`P_WATERFALL (38, -196)`, `P_FORD (-34, 8)`, `P_FOREST_CAMP (-196, -34)`,
`P_HIDDEN_GROVE (-322, 118)`, `P_BADLANDS (214, 178)`, `P_FIELDS (-92, 6)`,
`P_LOOKOUT (96, -150)`.

**There is no global water level.** The river's surface descends from ~32 m above the
falls to ~1 m at the south-west exit. Always use `water_y_at`.

## Mats API (scripts/world/materials.gd)

`Mats.tex(name)`, `Mats.pbr(base, uv_scale, alt)`, `Mats.terrain_material()`,
`Mats.brass()`, `Mats.foliage(atlas)`, `Mats.flat(color, rough, metal)`.

Textures live in `assets/textures/<name>.png` with `_albedo` / `_normal` / `_rough`
suffixes. A few were generated without `_albedo` — `bark_banyan`, `bark_palm`,
`cloth_saffron`, `cloth_indigo`, `cloth_white`, `skin_warm`, `demon_hide` — pass those
as the `alt` argument to `Mats.pbr`.

## Hard-won engine facts

| fact | consequence |
|---|---|
| Godot ArrayMesh front faces are **CLOCKWISE** | counter-clockwise winding renders the whole surface invisible from the front. Cost: one debugging cycle where only chunk skirts drew. |
| A shader writing `NORMAL_MAP` needs `ARRAY_TANGENT` | without tangents the TBN is degenerate and every lit pixel is black. |
| PNG imports default to **mipmaps off** | tiled ground aliases into shimmer. `tools/fix_imports.py` forces them on. |
| `--script` does not see `class_name` until the project is imported | use `tools/gd.sh`, which re-imports first. |
| Files under `build/` are ignored via `build/.gdignore` | otherwise Godot re-imports every screenshot. |

## Dev loop

```
tools/gd.sh import                 refresh the class cache
tools/gd.sh test tests/foo.gd      headless test
tools/gd.sh play                   run the game
~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/flythrough.gd
                                   render viewpoints to build/screenshots/
```
Every render harness writes PNGs under `build/screenshots/`; read them to judge the
result rather than assuming it worked.

## Gameplay contracts

These are the seams between systems. Implement to them and the pieces compose.

**Autoloads** — `EventBus` (all cross-system signals, see `scripts/core/event_bus.gd`),
`GameState` (serialisable state + save/load), `AudioDirector` (`play_2d`, `play_3d`,
`play_ui`, `play_music`), `DevCapture`.

**Atmosphere** (`scripts/world/vfx.gd`, `WorldVFX`) — `setup(map, sky)`, `update_focus(pos)`,
`set_rain(0..1)`, `make_firelight(intensity, range) -> Node3D`, `make_smoke(scale)`,
`trigger_gust() -> bool`. Everything unshaded (smoke, mist, leaves) must have its tint
re-driven from `sky.light_level()` each evaluation, or it keeps its daylight colour after
dark. `set_rain` drives `sky.overcast`, and re-applies the sky itself when `sky.paused`
is set, because `SkySystem._apply` otherwise never runs and rain falls from a blue sky.

**Ambient life** (`scripts/world/wildlife.gd`, `Wildlife`) — `setup(map, sky = null)`,
`update_focus(pos)`, `nearest_deer(p)`, `nearest_monkey(p)`, `stats()`, `herd_homes()`,
`flock_homes()`, `monkey_homes()`. `WorldMap.slope_at` is `1 - normal.y`, so 0.55 is a
**63-degree cliff**; deer use 0.22 (39 degrees) and reject standing ground above 0.30.

**Player** (`scripts/player/player.gd`, group `player`):
`take_damage(amount, source, hit_pos, crit)`, `heal(amount)`, `is_dead()`,
`state_name()`, `aim_direction()`, `lock_input(bool)`, `current_interactable()`,
fields `aiming`, `draw_charge`, `using_bow`, `rig`, `cam_rig`, `world`.

**Enemy** — must be in group `enemy`, and implement:
`take_damage(amount: float, source: Node, hit_pos: Vector3, crit: bool) -> void`,
`is_alive() -> bool`. `Arrow` and the melee sweep both call exactly this.

**Interactable** — in group `interactable`, implement
`interact_prompt() -> String` and `interact(player) -> void`; optional
`can_interact(player) -> bool` and an `interact_range` property (default 3.2 m).
The player raycasts these every frame and raises `EventBus.interact_target_changed`.

**Game** (`scripts/core/game.gd`) instantiates optional systems by class name if the
class exists: `RiverWater`, `Vegetation`, `Settlement`, `WorldVFX`, `Wildlife`,
`EnemyDirector`, `NPCDirector`, `QuestSystem`, `HUD`. Each gets `setup(map)` or
`setup(map, sky)` by arity, and `update_focus(pos)` each frame if it has one.

`HUD` is the exception to the shape: it is a `CanvasLayer`, not a `Node3D`, so it goes
on the Game rather than into the world and comes through `_make_node`, not `_try_make`
(which returns `Node3D` and therefore silently produced no interface at all — measured
2026-08-28: `scenes/game.tscn` shipped with no UI). It is spawned idempotently — a
session built by `HUD.launch()` already has one next to the Game and the Game adopts
it, because two HUDs means two pause menus writing `get_tree().paused` and
`Input.mouse_mode`. Set `Game.spawn_hud = false` before it enters the tree for a
world-only measurement harness.

## Quest contract

`QuestSystem` is found at runtime by the group `quest_system` and by capability, never
by a hard reference — the HUD, the journal and the dialogue system all degrade
gracefully if it is absent.

| method | used by |
|---|---|
| `start_quest(id)` / `complete_quest(id)` / `advance_quest(id, obj, n)` | dialogue actions |
| `quest_title(id)` / `quest_summary(id)` | HUD objective line, journal |
| `objective_text(qid, oid)` / `objective_total(qid, oid)` | journal |
| `notify_interact(tag)` | world objects when used |
| `notify_talk(npc_id)` | NPCs when a conversation ends |
| `save_into(GameState)` / `load_from(GameState)` | `Game.save_game` / `load_game` |

State lives entirely in `GameState.quests` as
`{quest_id: {state, objectives: {objective_id: progress}}}`, which is exactly what the
journal reads and what the save file stores — so a quest round-trips with no extra code.

Dialogue actions are strings: `quest_start:q_shrine`, `quest_advance:q_shrine:lamp`,
`quest_complete:q_lost_goat`, `flag:key=value`, `give:item:n`, `take:item:n`,
`heal:n`, `sound:name`, `notify:Title|Body`.

## Godot 4.7 API gotchas found the hard way

| symptom | cause / fix |
|---|---|
| whole mesh invisible | ArrayMesh front faces are CLOCKWISE |
| lit surface renders black | shader writes `NORMAL_MAP` but mesh has no `ARRAY_TANGENT` |
| `DEPTH_TEXTURE` shader error | removed; declare `uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;` |
| `SCREEN_TEXTURE` shader error | same: `uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;` |
| "Invalid assignment ... `lifetime_randomness`" | not on `GPUParticles3D`; it is on `ParticleProcessMaterial` |
| texture fails to load at runtime on macOS | `compress/high_quality=true` forces BPTC (BC7), which Apple GPUs do not support. Use `false`. |
| "Playback can only happen when a node is inside the scene tree" | `add_child()` the AudioStreamPlayer BEFORE `play()` |
| `StandardMaterial3D.specular` warning | property does not exist in Godot 4 |
| autoloads unresolved in a test | `--script` SceneTree scripts do not get autoloads. Run tests as SCENES: `tools/gd.sh scene res://scenes/foo.tscn` |
| controls all dead, no error | a hand-written `[input]` block in `project.godot` using Godot 3 dictionary syntax. The parser creates the ACTIONS and silently drops every event. Bind in code via `InputMap.action_add_event` instead — see `scripts/core/input_setup.gd`. |
| a test drives input and passes on a broken build | `Input.action_press()` sets the action state directly and never consults the InputMap. To test bindings, synthesise real events through `Input.parse_input_event()` and call `Input.flush_buffered_events()`. |
| `gdformat` breaks a file | it can relocate a file-header comment into the middle of an indented lambda body, producing `Unindent doesn't match the previous indentation level`. It hit 1 file in 130. The pre-commit parse check is what catches this — never format without re-running it. |
| `Node.look_at` errors | node not in tree yet; use `look_at_from_position` |
| `surface_get_arrays()[ARRAY_INDEX]` is null | a non-indexed surface; guard before assigning to `PackedInt32Array` |
| `MultiMesh.get_instance_transform()` reads back identity | only under `--headless`: the dummy renderer stores no instance buffer, so writes are accepted and lost. A headless test that needs instance positions must mirror them into a GDScript array as they are written (see `Wildlife.FishShoal.wp`). Cost: one debugging cycle chasing a "fish at the origin" bug that did not exist. |
| a WINDOWED run hangs with a blank window and never exits | a GDScript **parse error** in the scene's script. `--headless` prints it and quits; windowed sits there forever looking like a slow render. Always `grep -i "parse error"` the log before waiting. Cost: 25 minutes. |
| `Basis.looking_at(fwd, up)` produces a needle across the whole screen | `up` was zero or parallel to `fwd`; the result is garbage rather than an error. The usual substitute axis `Vector3(fwd.z, 0, -fwd.x)` is ITSELF zero when `fwd` is exactly vertical - guard that too. |
| a headless test of a `MultiMesh` passes while checking nothing | under `--headless` the dummy RenderingServer discards MultiMesh instance data: `set_instance_transform()` is dropped, `get_instance_transform()` returns IDENTITY for every instance and `.buffer` is empty. Audit or screenshot a MultiMesh **windowed** (no `--headless`), and have the test refuse to report a result it cannot trust. Cost: a settlement float-audit that read "0 issues" while never checking any of its 244 scattered props. |
| a full-screen panel draws in a 0×0 box in the top-left | `set_anchors_preset()` on a Control **already in the tree** keeps its current rect. Use `set_anchors_and_offsets_preset()`. Every state assertion still passes while nothing is on screen, so assert on pixels. |
| an `HSlider` draws no track | the slider takes its height from the stylebox's minimum size; a box with no content margins is invisible |
| `Time.get_datetime_dict_from_unix_time()` is an hour or eight out | it returns **UTC**. Add `Time.get_time_zone_from_system().bias * 60` for a stamp the player recognises. |

## Systems now present

| class | file | role |
|---|---|---|
| `WorldMap` | world/world_map.gd | heightfield, biomes, river, roads — the source of truth |
| `Terrain` | world/terrain.gd | chunked LOD mesher + world heightfield collider |
| `SkySystem` | world/sky_system.gd | day/night, sun/moon, fog, grading |
| `RiverWater` | world/water.gd | river ribbon, waterfall, ponds |
| `Vegetation` / `TreeBuilder` | world/vegetation.gd, tree_builder.gd | trees, grass, clutter, streaming |
| `Settlement` / `Arch` | world/settlement.gd, architecture.gd | village, shrine, ruins, camp, props |
| `WorldVFX` / `Wildlife` | world/vfx.gd, wildlife.gd | atmosphere particles; deer, birds, monkeys, fish |
| `Player` / `PlayerCamera` / `ProcRig` / `Weapons` / `Arrow` | player/ | the character and everything it does |
| `Enemy` / `EnemyDirector` / `Perception` | ai/ | four archetypes, perception, state machine |
| `NPC` / `NPCDirector` | ai/ | villagers with daily schedules |
| `DialogueSystem` / `DialogueData` | quest/ | branching, conditional, quest-linked conversation |
| `QuestSystem` / `QuestData` | quest/ | data-driven quests, discovery zones, objective marker |
| `Interactables` | quest/ | shrine, lamps, pickups, arrow stands, campfires |
| `SolidStreamer` | world/solid_streamer.gd | pooled static collision for trees and buildings |
| `HUD` and panels | ui/ | HUD, compass, notifications, menus, journal, inventory |
| `Quality` | core/quality.gd | LOW/MEDIUM/HIGH/ULTRA graphics tiers |
| `Game` | core/game.gd | assembles a session; save, load, death, respawn |

`HUD.launch(tree)` builds a whole session (Game + HUD) and makes it the current scene —
that is how the main menu hands over.

## Testing

| command | what it does |
|---|---|
| `tools/gd.sh scene res://scenes/playtest.tscn` | drives the real game with synthetic input, asserts movement/combat/grounding |
| `tools/gd.sh scene res://scenes/asset_test.tscn` | every texture, sound and shader loads |
| `tools/gd.sh test tests/bake_map_test.gd` | world heightfield sanity + top-down map render |
| `tools/gd.sh test tests/terrain_test.gd` | terrain meshing, LODs, triangle budget |
| `tools/gd.sh scene res://scenes/ui_test.tscn` | every panel and HUD state, 16 screenshots, settings and save round-trips |
| `tools/gd.sh scene res://scenes/ui_qa_perf.tscn` | what the interface costs per frame |

**Measuring a frame cost in this project.** Do not compare two runs. Two runs on the
same build disagree by more than 10 ms — shader cache, streaming state, and whatever
else is on the machine — and comparing across them once "showed" that a HUD which was
not drawing at all cost 4 ms more than one that was. Alternate the two conditions
inside one process and take the **median of the paired differences**; a mean is still
dragged around by a single streaming hitch, which is how the same harness reported the
same HUD at +1.5 ms and then at -1.8 ms. `tests/ui_qa_perf.gd` is the worked example.
| `tools/gd.sh scene res://scenes/acceptance_test.tscn` | the full checklist, menu to gameplay |
| `tools/gd.sh scene res://scenes/save_test.tscn` | save/load round-trips the live world |
| `tools/gd.sh scene res://scenes/leak_test.tscn` | streaming frees what it replaces |
| `tools/gd.sh scene res://scenes/perf_test.tscn` | honest frame times (vsync off, warmed up) |
| `tools/run_tests.sh` | runs the whole suite |
| `~/tools/.../Godot --path . --script tests/flythrough.gd` | renders 10 viewpoints to `build/screenshots/` |

**Writing a test that boots the game:** `HUD.launch()` replaces and frees
`tree.current_scene`. A test node loaded as the current scene therefore frees ITSELF
when the game starts — hand that role to a decoy node first. Also `await
get_tree().process_frame` before adding anything to `root`: during `_ready` the root is
still setting up children and `add_child` fails outright.

Synthetic input in a scene test: `Input.action_press("move_forward")`, wait
`await get_tree().physics_frame`, then `Input.action_release(...)`.

## The 3D rule (added after review)

**No flat cards for anything the player can get close to.** The first pass built leaves,
grass and flowers as alpha-cut quads. It reads as 2D the moment you stand near it: leaves
show edge-on as slivers, grass lies flat against its own ground texture, flowers are
invisible in profile.

Every piece of vegetation must be REAL GEOMETRY with volume:

| thing | required form |
|---|---|
| leaf | a cupped, tapered lamina with camber across its width and droop along its length — never a plane |
| grass blade | a tapered ribbon, curved along its length, with a V cross-section at the base that flattens toward the tip |
| flower | real petals arranged in 3D around a receptacle, with a stem |
| bush / fern | real leafy geometry, not a bundle of crossed planes |
| tree canopy | 3D leaf sprigs, not a shell of billboards |

Only the FAR LOD (beyond ~90 m, where a leaf is sub-pixel) may fall back to a cheaper
representation, and it must not pop.

Budgets, so this stays playable: near-field foliage may add ~350k triangles; a single
near tree ~6k; a grass tuft ~60. Use LODs and instancing aggressively, and measure with
`tests/draw_audit.gd` and `tests/perf_test.gd`.

## Git and the commit gate

The repo enforces linting before commits land, per house policy. `git config
core.hooksPath` points at `.githooks/`, which is committed, so the gate travels with
the repo rather than living in one machine's `.git/`.

`.githooks/pre-commit` runs two checks on staged `.gd` files:

1. **`gdlint`** against `.gdlintrc` — style and naming.
2. **Godot's own parser** (`--check-only`) — this is the important one. A GDScript
   parse error does not stop the game booting; the script simply fails to load and the
   node it backs silently never appears. That is how the wildlife system went missing
   for an hour with no error anyone noticed.

Never commit with `--no-verify`. If a rule is wrong for this codebase, change
`.gdlintrc` and say why in its header — several rules there are already widened with
their reasons recorded.

Setup on a fresh clone:

```bash
pip3 install "gdtoolkit==4.*"      # gdlint + gdformat
git config core.hooksPath .githooks
```
