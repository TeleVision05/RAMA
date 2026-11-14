# RAMA — Roadmap

Short entry point. The long-form plan for the second pass is `OVERHAUL.md`; the history
of what was built and what broke is `DEVELOPMENT_LOG.md`; the systems and their
contracts are `ARCHITECTURE.md`. This file says where the project stands today and what
comes next, in order.

## Current state (2026-11-13)

**Working vertical slice, with an unverified overhaul landed on top of it.**

- Work is on the `prod-ready` branch (PR #1, draft) on top of the character-model integration `d051bc5`.
- Engine: Godot 4.7.2 (Forward+ / Metal), found from `$GODOT`, `PATH`, or `~/tools/Godot.app`.
- Generated: textures and audio (music included) by the Python scripts in `tools/`, and
  every world, creature and weapon mesh procedurally in GDScript. Licensed: the humanoid
  base meshes (Quaternius) and their animation clips (KayKit, Kay Lousberg), both CC0
  1.0, listed file by file in `assets/CREDITS.md`. *(Corrected 2026-11-13: this line
  said "every asset is generated, no downloaded content", which stopped being true when
  `d051bc5` added the eight character `.glb` files.)*
- Systems present (see `ARCHITECTURE.md` "Systems now present"): world heightfield,
  chunked LOD terrain, sky/day-night, river and waterfall, vegetation streaming,
  settlements, wildlife, player with bow and sword, four enemy archetypes, twelve
  scheduled villagers, dialogue, three data-driven quests, save/load, HUD and menus,
  four graphics quality tiers.

**How that was verified (2026-11-13).** `tools/run_tests.sh` on the `prod-ready` branch with
Godot 4.7.2: parse, input, assets, worldmap, terrain, playtest, audio, quests, saveload,
leaks, accept and ui PASS with 0 script errors; the new `solids` suite passes on its own and
in the pre-commit run. `perf` was **not measured**: the machine sat at load 14 to 40 and
frame-time checks only count below load 6 (`tools/gate_load.py`). Re-run it on a quiet
machine before quoting any frame rate.

**What is not verified.** The commit message of `66c779a` is explicit that its vegetation
"is unproven in situ": the QA pass produced no rendered screenshots. The test gate being
green does not cover that; the gate asserts loads, budgets and gameplay, not how a leaf
reads edge-on. Nothing in `build/screenshots/` has been produced from the current tree by
the `scenes/qa3d_*.tscn` harnesses.

## Known gaps and bugs

| area | gap | where |
|---|---|---|
| vegetation | 3D leaves, grass ribbons, petals and palm pinnae are implemented but never rendered and inspected | `scripts/world/veg3d_leaf.gd`, `ground3d_flora.gd`, `tree_builder.gd`, `vegetation.gd`; harnesses `scenes/qa3d_edgeon.tscn`, `qa3d_cover.tscn`, `qa3d_world.tscn` |
| performance | Villagers drop shadows beyond 25 m and are hidden beyond 90 m (`NPCLod`). From a fixed camera in the village the 14 villagers cost about 75 draw calls each without LOD and about 25 with it (village 2518-2788 draws without, 1813-2040 with, at the High tier, 2026-11-13, load average 16-47; draw counts do not depend on load). `perf` asserts a budget of 2300. Enemies have no distance LOD yet | `scripts/ai/npc_lod.gd`, `tests/perf_test.gd` |
| performance | `perf` has not been measured on a quiet machine since the overhaul; the 20 fps gate is unconfirmed after +~350k foliage triangles (a loaded-machine run showed 15 fps mean) | `tools/run_tests.sh perf` |
| rendering | A new game warms the shaders behind a loading screen (four views from the spawn point), which cut the worst frame in the first 30 s of play from 442-853 ms to 81-116 ms (three runs each, load average 16-47, so indicative). Regions the spawn view does not show (river, forest, shrine) can still hitch on first entry | `scripts/core/game.gd`, `tests/first_30s_probe.gd` |
| rendering | distant foliage billboards alpha-dither against the sky; the horizon ends at the world edge with no backdrop | `scripts/world/vegetation.gd` FAR LOD, `scripts/world/sky_system.gd` |
| repo hygiene | 26 scripts are still over the 500-line house limit and are known debt (line counts on 2026-11-13): `quest/interactables.gd` 2545, `world/architecture.gd` 2278, `ai/enemy_types.gd` 1713, `quest/dialogue_data.gd` 1616, `ai/enemy.gd` 1550, `world/tree_builder.gd` 1486, `world/wildlife.gd` 1456, `ai/npc.gd` 1412, `ui/hud.gd` 1391, `world/vegetation.gd` 1227, `world/vfx.gd` 1143, `world/settlement.gd` 1142, `world/ground3d_flora.gd` 1066, `world/water.gd` 996, `ai/beast_rig.gd` 905, `quest/quest_system.gd` 879, `player/player.gd` 795, `ui/inventory_panel.gd` 784, `ai/creature_kit.gd` 782, `ai/npc_director.gd` 730, `ui/journal_panel.gd` 677, `quest/quest_data.gd` 606, `ui/dialogue_box.gd` 578, `ui/theme.gd` 551, `world/veg3d_leaf.gd` 534, `ai/enemy_director.gd` 514; and the test scripts `enemy_test.gd` 1231, `npc_test.gd` 1063, `quest_test.gd` 985, `ui_test.gd` 781. Split so far, each behind a golden-file test: `mesh_kit.gd` (now 6 files), `world_map.gd` (6 files), `proc_rig.gd` (6 files). `.gdlintrc` `max-file-lines` is 2550, just above the largest, and only goes down | `scripts/`, `.gdlintrc` |
| repo weight | about 165 MB of generated WAV and PNG are committed; history is not rewritten | owner decision |
| repo hygiene | `tests/` holds 108 `.gd` files: the 14 gate suites alongside ~96 one-off probes and shot scripts (`_lodcount.gd`, `_prof2.gd`, `dhoti_probe.gd`, `facing_probe.gd`, …) with nothing marking which is which | `tests/`, `scenes/` |
| branches | `overhaul/3d-and-depth` is redundant with `main` and its remote copy lacks `8a7bf4e` | `git branch -vv` |

## Milestones

### M1 — Prove the overhaul by looking, then close the gate
- [ ] Render `scenes/qa3d_edgeon.tscn`, `qa3d_cover.tscn`, `qa3d_world.tscn` and
      `scenes/back_view.tscn` to `build/screenshots/` from the current tree
- [ ] Compare against `build/detail_sheet.png` (the flat-card evidence) and fix any leaf,
      blade or petal that still reads as a plane
- [ ] Run the full `tools/run_tests.sh` including `perf` on a quiet machine
- [ ] Record the result and the renders in `DEVELOPMENT_LOG.md` §16 or a new section

**Done when:** `tools/run_tests.sh` prints `== ALL PASS ==` with all 14 suites, and the
close-up PNGs are committed to the log entry with a one-line verdict each.

### M2 — Re-baseline performance and add character LOD
- [ ] Run `tests/perf_test.gd` and `tests/draw_audit.gd` with nothing else on the machine;
      write the numbers and the load average into the log
- [ ] Distance LOD that swaps a character for one merged mesh past ~30 m (the trick already
      used for the settlement), for NPCs and enemies
- [ ] Re-run `draw_audit` and record village draw calls before/after

**Done when:** `perf_test` passes the 20 fps gate on the overhaul tree with figures in the
log, and `draw_audit` shows the village character share below its ~450 baseline.

### M3 — Track 2: rendering and atmosphere
- [ ] Shader warm-up pass behind the main menu (removes the first-entry hitch)
- [ ] Distant backdrop beyond the world edge; fix FAR-LOD alpha dithering against the sky
- [ ] Contact shadows, terrain detail normals with slope-aware blending, better water,
      sun shafts, colour grading, better night — keeping the `Quality` tiers distinct

**Done when:** `tests/flythrough.gd` re-renders its 10 viewpoints and each is committed
next to the previous render for comparison; `perf_test` still passes at every `Quality`
tier.

### M4 — Track 3: finish characters and creatures
- [ ] Review `char_shots`, `creature_shots`, `enemy_shots` and `back_view` renders from
      the camera the player actually sees (behind, walking away)
- [ ] Close whatever the stopped QA agents left: hands, feet, faces, hair, cloth motion,
      distinct rakshasa silhouettes, better animals
- [ ] Keep `tests/rig_test.gd`, `npc_test.gd`, `enemy_test.gd` green

**Done when:** each rendered sheet is in `build/screenshots/` with a verdict in the log,
and `playtest` + `acceptance` pass.

### M5 — Track 4: content and depth
- [ ] Combat: block, parry, hit reactions
- [ ] At least one more quest and one interior or cave
- [ ] Weather; more villagers and barks

**Done when:** `tests/quest_test.gd` drives every quest, new ones included, to completion,
and `tests/acceptance_test.gd` has a checklist row for each new mechanic.

### M6 — Repo hygiene
- [ ] Separate the 14 gate suites from the one-off probes in `tests/` (subfolder or a
      naming rule documented in `ARCHITECTURE.md`)
- [ ] No script grows past its current size; new systems land under 500 lines
- [ ] Delete `overhaul/3d-and-depth` once M1 confirms `main` is sound

**Done when:** `tools/run_tests.sh` still runs 14 suites from their new location and
`git branch -a` shows only `main`.

## Won't do / out of scope

- Third-party assets beyond the CC0 character meshes and animation clips already
  credited in `assets/CREDITS.md`. Anything else stays generated, and any new
  third-party file needs a confirmed redistributable licence and a CREDITS row before it
  is committed. *(Corrected 2026-11-13: the rule used to read "Downloaded or copied
  assets of any kind. Everything stays generated"; `d051bc5` broke it, and the owner
  chose to keep the CC0 models with credits.)*
- Weakening or skipping a test to keep the gate green (`OVERHAUL.md` rule 2).
- Splitting the 1000+-line scripts in one big refactor. They are cut down as tracks
  touch them, not as a project of their own.
- Exports for Windows or Linux. The only preset is macOS (`export_presets.cfg`, unsigned);
  the renderer is Forward+/Metal.
- CI for the rendered suites. `.github/workflows/ci.yml` runs gdlint and the 10 headless
  suites on ubuntu-latest. `quests`, `perf`, `accept` and `ui` need the macOS embedded
  renderer and a GPU, so they run on the owner's Mac. Check with
  `tools/run_tests.sh --list`.
- Multiplayer, mobile, or a story beyond the Panchavati vertical slice.

## Open questions for the owner

1. Was landing `66c779a` on `main` intended, or should `main` be reset to the verified
   baseline (`8a7bf4e`) with the overhaul continuing on its branch until M1 proves it?
2. `OVERHAUL.md` sets the gate at 20 fps and the target at 60. Which is the bar for
   calling this slice finished?
3. Should `perf` stay inside `tools/run_tests.sh` (making the gate 5+ minutes), or move
   to a separate nightly-style command with the fast 11 as the pre-push gate?
4. The GitHub repo is `TeleVision05/RAMA` while the folder is `UltraOpen`. Is `RAMA` the
   final name?
5. The repo is public (MIT). The v0.1.0-rc1 release is a draft: publish it, or not, after
   an independent review.
