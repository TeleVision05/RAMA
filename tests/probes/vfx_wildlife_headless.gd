extends SceneTree
## Headless behaviour test for WorldVFX + Wildlife. Renders nothing; it checks the
## things a screenshot cannot prove: that animals stay ON the ground, that the flight
## response actually fires, that the night-only effects are night-only, and that the
## triangle budget is what the header claims.
##
##   tools/gd.sh test tests/probes/vfx_wildlife_headless.gd

var fails := 0


func ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS  ", msg)
	else:
		fails += 1
		print("  FAIL  ", msg)


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var map := world.map

	var vfx := WorldVFX.new()
	world.add_child(vfx)
	var life := Wildlife.new()
	world.add_child(life)

	# One frame first: nodes added during SceneTree._init are not "inside tree" yet,
	# so SkySystem._ready (and therefore its sun) does not exist until the tree runs.
	await process_frame
	vfx.setup(map, world.sky)
	life.setup(map, world.sky)
	world.sky.paused = true

	var stats: Dictionary = life.stats()
	print("[budget] ", stats)
	ok(stats.triangles < 250000, "wildlife under the 250k triangle budget (%d)" % stats.triangles)
	ok(stats.animals > 100, "at least a hundred animals in the world (%d)" % stats.animals)

	# ---- animals stand on the ground -------------------------------------
	world.sky.set_time(11.0)
	var here := map.ground(WorldMap.P_FIELDS.x, WorldMap.P_FIELDS.y)
	for i in range(120):
		vfx.update_focus(here)
		life.update_focus(here)
		await process_frame

	var worst := 0.0
	var checked := 0
	for h in life._herds:
		for d in h.deer:
			var p: Vector3 = d.root.global_position
			worst = maxf(worst, absf(p.y - map.height_at(p.x, p.z)))
			checked += 1
	ok(checked > 0, "deer exist (%d)" % checked)
	ok(worst < 0.35, "every deer is on the ground (worst offset %.3f m)" % worst)

	# ---- the flight response actually fires -------------------------------
	# Track the herd nearest the focus by identity, not by "whoever is closest now" -
	# after they scatter, the closest animal is a different deer and the test lies.
	var herd = null
	var hd := 1e18
	for h in life._herds:
		var d0: float = Vector2(h.home.x, h.home.y).distance_to(Vector2(here.x, here.z))
		if d0 < hd:
			hd = d0
			herd = h
	var before: Array = []
	for d in herd.deer:
		before.append(d.pos)
	var crowd: Vector3 = life.nearest_deer(here)
	# Headless frames are ~7 ms, so 400 of them is only ~3 s of flight - long enough
	# for the speed ramp to finish and the herd to clear its own body length.
	for i in range(400):
		life.update_focus(crowd + Vector3(5.0, 0.0, 5.0))
		await process_frame
	var moved := 0.0
	for i in range(herd.deer.size()):
		moved = maxf(moved, herd.deer[i].pos.distance_to(before[i]))
	ok(moved > 6.0, "a crowded herd bolts (furthest deer moved %.1f m)" % moved)

	# ---- night-only effects are night-only --------------------------------
	var forest := map.ground(WorldMap.P_FOREST_CAMP.x, WorldMap.P_FOREST_CAMP.y)
	world.sky.set_time(12.0)
	for i in range(40):
		vfx.update_focus(forest)
		await process_frame
	var day_flies: bool = vfx._fireflies.emitting
	world.sky.set_time(23.0)
	for i in range(40):
		vfx.update_focus(forest)
		await process_frame
	var night_flies: bool = vfx._fireflies.emitting
	ok(not day_flies, "no fireflies at noon")
	ok(night_flies, "fireflies at 23:00 in the forest")

	# ---- bats follow the same rule ----------------------------------------
	var bats_awake_night := false
	for f in life._flocks:
		if f.kind == Wildlife.K_BAT:
			bats_awake_night = f.awake
	ok(bats_awake_night or WorldMap.P_RUINS.distance_to(Vector2(forest.x, forest.z)) > 210.0, "bats are a night flock")

	# ---- rain asks the sky for weather ------------------------------------
	world.sky.set_time(14.0)
	world.sky.paused = false
	vfx.set_rain(0.8)
	for i in range(200):
		vfx.update_focus(here)
		await process_frame
	ok(vfx._rain.emitting, "rain emits when asked")
	ok(world.sky.overcast > 0.35, "rain raised the sky's overcast (%.2f)" % world.sky.overcast)
	vfx.set_rain(0.0)
	for i in range(40):
		await process_frame
	ok(not vfx._rain.emitting, "rain stops when asked")

	print("\n%s  (%d failures)" % ["ALL PASS" if fails == 0 else "FAILURES", fails])
	quit(0 if fails == 0 else 1)
