# RAMA — Overhaul brief

The baseline is a complete, passing vertical slice. This is the plan for the second
pass. The driving note from review was blunt and correct:

> "A lot of them are just 2D, make sure they're all 3D."

Close-ups confirmed it. `build/detail_sheet.png` is the evidence: leaves show edge-on as
slivers, grass lies almost flat against its own ground texture, flowers are invisible in
profile. The foliage is alpha-cut quads, and it reads as paper.

## Track 1 — True 3D vegetation (the headline)

Replace every flat card the player can get near with real geometry.

| thing | now | required |
|---|---|---|
| leaf | 1 quad, 2 tris | cupped tapered lamina: camber across the width, droop along the length, a raised midrib |
| grass blade | 3 crossed quads per tuft | tapered ribbon curving along its length, V cross-section at the base flattening to the tip |
| flower | 1 quad | real petals in 3D around a receptacle, on a stem |
| bush / fern | crossed cards | real leafy geometry |
| canopy | shell of cards | 3D leaf sprigs |
| FAR LOD | crossed-quad billboard | may stay cheap, but must not pop |

Budget: near-field foliage ~350k tris, one near tree ~6k, one grass tuft ~60.

## Track 2 — Rendering and atmosphere

Sharper, deeper, more filmic. Contact shadows, better terrain shading (detail
normals, slope-aware blending), improved water, sun shafts, considered colour grading,
better night. Keep the `Quality` tiers meaningful.

## Track 3 — Characters and creatures

The rig reads as a wooden mannequin at conversation distance. Real hands and feet,
better faces, hair with shape, cloth that folds and reacts to motion, distinct
silhouettes per NPC role, more menacing rakshasas, better animals.

## Track 4 — Content and depth

More to do and more to find: additional quests, points of interest, a cave or interior,
weather, richer combat (block, parry, hit reactions), more villagers and barks.

## Rules for every track

1. **Verify by looking.** Render close-ups, read the PNGs, iterate. A claim without a
   screenshot is not a result.
2. **`tools/run_tests.sh` must stay green.** 12 suites. Do not weaken a test to pass.
3. **Commit gate is real.** `gdlint` + Godot parse check run pre-commit. Never
   `--no-verify`.
4. **Measure performance** with `tests/perf_test.gd` and `tests/draw_audit.gd`. The
   gate is 20 fps; the target is 60. Do not silently trade the whole frame for leaves.
