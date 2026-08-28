extends SceneTree
## Render harness for WorldVFX + Wildlife. Builds the real world, drops both systems
## into it, walks the focus to each viewpoint, lets the simulation settle and writes a
## PNG per shot into build/screenshots/. Look at the PNGs; that is the point.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/vfx_wildlife_test.gd
##
## Not --headless: headless renders nothing and every image comes out empty.

const OUT := "res://build/screenshots/vfx_%s.png"

var only: PackedStringArray = PackedStringArray()

var world: WorldRoot
var vfx: WorldVFX
var life: Wildlife
var cam: Camera3D
var map: WorldMap


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7).split(",")
	if only.size() > 0:
		print("[shots] only: ", only)
	var root := get_root()
	world = WorldRoot.new()
	root.add_child(world)
	world.build(true)
	map = world.map

	vfx = WorldVFX.new()
	vfx.name = "VFX"
	world.add_child(vfx)
	vfx.setup(map, world.sky)

	life = Wildlife.new()
	life.name = "Wildlife"
	world.add_child(life)
	life.setup(map, world.sky)

	cam = Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	cam.near = 0.10
	root.add_child(cam)
	cam.current = true

	world.sky.paused = true
	print("[wildlife] ", life.stats())
	var herds: Array = life.herd_homes()
	var flocks: Array = life.flock_homes()
	var monkeys: Array = life.monkey_homes()
	print("[wildlife] herds=", herds)
	print("[wildlife] monkeys=", monkeys.size(), " first=", monkeys[0] if monkeys.size() > 0 else "-")

	await process_frame

	# --- dawn on the river: mist -------------------------------------------
	var ford := WorldMap.P_FORD
	await shot("dawn_river", ford + Vector2(26.0, 26.0), 4.5, ford, 1.0, 6.1)

	# --- night in the forest: fireflies + the camp fire ---------------------
	var camp := WorldMap.P_FOREST_CAMP
	await shot("night_forest", camp + Vector2(14.0, 15.0), 2.2, camp + Vector2(2.5, -1.5), 1.2, 22.6)

	# --- daylight meadow: pollen, butterflies, a herd -----------------------
	var herd: Vector2 = herds[0] if herds.size() > 0 else WorldMap.P_FIELDS
	var hanchor := Vector3(herd.x, map.height_at(herd.x, herd.y), herd.y)
	life.update_focus(hanchor + Vector3(50.0, 0.0, 50.0))
	vfx.update_focus(hanchor + Vector3(26.0, 0.0, 26.0))
	world.sky.set_time(10.4)
	for i in range(80):
		await process_frame
	var mdeer := life.nearest_deer(hanchor)
	# 29 m out: past the 21 m flight radius, so the focus can stay ON the camera and
	# the pollen and butterflies (which live around the player) are in frame too.
	var mv := Vector2(0.75, 0.66).normalized() * 29.0
	print("meadow deer at ", mdeer)
	await shot_abs(
		"day_meadow",
		Vector2(mdeer.x + mv.x, mdeer.z + mv.y),
		map.height_at(mdeer.x + mv.x, mdeer.z + mv.y) + 3.6,
		Vector2(mdeer.x, mdeer.z),
		mdeer.y + 0.75,
		10.4,
		110
	)

	# --- the village at dusk: smoke and firelight ---------------------------
	var vil := WorldMap.P_VILLAGE
	await shot("village_dusk", vil + Vector2(23.0, 24.0), 5.0, vil, 1.5, 19.3)
	await shot("village_night", vil + Vector2(17.0, 18.0), 3.2, vil + Vector2(-1.0, 2.0), 1.2, 22.2)

	# --- birds against the sky ----------------------------------------------
	var bf: Dictionary = flocks[0]
	var bh: Vector2 = bf.home
	await shot("birds", bh + Vector2(46.0, 46.0), 3.0, bh, float(bf.alt) * 0.85, 9.2)

	# --- monkeys -------------------------------------------------------------
	var mk: Vector2 = monkeys[0] if monkeys.size() > 0 else vil
	var mky := map.height_at(mk.x, mk.y)
	await shot_abs(
		"monkeys",
		mk + Vector2(3.4, 3.6),
		map.height_at(mk.x + 3.4, mk.y + 3.6) + 1.1,
		mk,
		mky + 0.35,
		12.0,
		100,
		Vector3(mk.x + 30.0, mky, mk.y + 30.0)
	)

	# --- bats over the ruins at night ---------------------------------------
	var ruins := WorldMap.P_RUINS
	await shot("ruins_bats", ruins + Vector2(24.0, 26.0), 5.0, ruins, 9.0, 23.4)

	# --- a close look at the deer rig ---------------------------------------
	# 24 m out: outside the 21 m flight radius, so they stay and graze.
	var h2: Vector2 = herds[1] if herds.size() > 1 else herd
	# Walk the focus to the herd first so they wake up and settle, then frame the
	# nearest actual animal from 23 m - just outside the 21 m flight radius.
	var anchor := Vector3(h2.x, map.height_at(h2.x, h2.y), h2.y)
	life.update_focus(anchor + Vector3(40.0, 0.0, 40.0))
	for i in range(90):
		await process_frame
	var dpos := life.nearest_deer(anchor)
	var dv := Vector2(1.0, 1.0).normalized() * 11.0
	print("deer at ", dpos)
	# The camera comes in to 11 m but the FOCUS - what the herd flees from - stays
	# 60 m away, so this frames a grazing animal instead of a fleeing one.
	await shot_abs(
		"deer_close",
		Vector2(dpos.x + dv.x, dpos.z + dv.y),
		map.height_at(dpos.x + dv.x, dpos.z + dv.y) + 1.2,
		Vector2(dpos.x, dpos.z),
		dpos.y + 0.6,
		15.5,
		70,
		Vector3(dpos.x + 45.0, dpos.y, dpos.z + 45.0)
	)

	# --- fish in the shallows: find water that is actually deep --------------
	var rp: Array = map.river_points()
	var fishp: Vector2 = rp[int(rp.size() / 2)]
	var best := -1.0
	for i in range(6, rp.size() - 6):
		var q: Vector2 = rp[i]
		var d: float = map.water_depth_at(q.x, q.y)
		if d > best:
			best = d
			fishp = q
	print("fish stretch at ", fishp, " depth=%.2f" % best)
	var fwy := map.water_y_at(fishp.x, fishp.y)
	await shot_abs("river_fish", fishp + Vector2(7.5, 7.5), fwy + 1.5, fishp, fwy - 0.35, 12.5)

	# --- a wind gust crossing open ground -----------------------------------
	await shot_gust(
		"gust", WorldMap.P_FIELDS + Vector2(16.0, 20.0), 3.5, WorldMap.P_FIELDS + Vector2(-14.0, -6.0), 1.2, 16.4
	)

	# --- rain -----------------------------------------------------------------
	vfx.set_rain(0.9)
	await shot("rain", WorldMap.P_FIELDS + Vector2(20.0, 22.0), 3.0, WorldMap.P_FIELDS, 1.0, 13.0, 260)
	vfx.set_rain(0.0)

	print("done")
	quit()


func shot(nm: String, eye2: Vector2, eye_h: float, tgt2: Vector2, tgt_h: float, hour: float, frames: int = 100) -> void:
	await shot_abs(
		nm, eye2, map.height_at(eye2.x, eye2.y) + eye_h, tgt2, map.height_at(tgt2.x, tgt2.y) + tgt_h, hour, frames
	)


## Same, but with absolute world Y for eye and target - needed for water shots where
## the ground under the camera is the riverbed, not where you want the lens.
func shot_gust(nm: String, eye2: Vector2, eye_h: float, tgt2: Vector2, tgt_h: float, hour: float) -> void:
	world.sky.set_time(hour)
	var eye := Vector3(eye2.x, map.height_at(eye2.x, eye2.y) + eye_h, eye2.y)
	vfx.update_focus(eye)
	life.update_focus(eye)
	for i in range(20):
		await process_frame
	print("gust fired: ", vfx.trigger_gust())
	await shot_abs(
		nm, eye2, map.height_at(eye2.x, eye2.y) + eye_h, tgt2, map.height_at(tgt2.x, tgt2.y) + tgt_h, hour, 55
	)


func shot_abs(
	nm: String,
	eye2: Vector2,
	eye_y: float,
	tgt2: Vector2,
	tgt_y: float,
	hour: float,
	frames: int = 100,
	focus_at: Vector3 = Vector3.INF
) -> void:
	if only.size() > 0 and not only.has(nm):
		return
	world.sky.set_time(hour)
	var eye := Vector3(eye2.x, eye_y, eye2.y)
	var tgt := Vector3(tgt2.x, tgt_y, tgt2.y)
	var foc := eye if focus_at == Vector3.INF else focus_at
	cam.global_position = eye
	cam.look_at(tgt, Vector3.UP)
	world.terrain.update_focus(eye, true)
	vfx.update_focus(eye)
	life.update_focus(foc)
	for i in range(frames):
		vfx.update_focus(eye)
		life.update_focus(foc)
		if i % 8 == 0:
			# The sky is PAUSED for repeatability, so _process never re-applies it;
			# without this the overcast the rain asks for is stored and never lands.
			world.sky.set_time(hour)
		await process_frame
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	img.save_png(OUT % nm)
	print("shot %-14s eye=(%.1f, %.1f, %.1f)  h=%.1f" % [nm, eye.x, eye.y, eye.z, hour])
