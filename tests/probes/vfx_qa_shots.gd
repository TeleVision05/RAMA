extends Node
## QA render harness for WorldVFX + Wildlife.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/vfx_qa_shots.tscn -- --only=a,b
##
## Why this exists alongside tests/probes/vfx_wildlife_test.gd: that harness builds a bare
## WorldRoot and adds only VFX and Wildlife, so its twelve PNGs contain no trees, no
## huts, no shrine and NO WATER. Judging "does the mist read as mist lying on the
## river" against a picture with no river in it is not a judgement. This one boots the
## real `Game`, so vegetation, the settlement and RiverWater are all in the frame, and
## the atmosphere is judged in the world it actually ships in.
##
## A free camera is used rather than the player rig so the framing can be aimed; the
## player is moved to the vantage point anyway, because every system takes its focus
## from `player.global_position`.

const OUT := "res://build/screenshots/qa_%s.png"

# eye/target are XZ; eye_h/tgt_h are metres above the ground under them unless `abs`.
const SHOTS := [
	{"n": "dawn_river", "eye": Vector2(-26, 20), "eh": 3.0, "tgt": Vector2(-34, 8), "th": 0.6, "h": 6.1},
	{"n": "night_forest", "eye": Vector2(-182, -22), "eh": 2.0, "tgt": Vector2(-196, -34), "th": 1.2, "h": 22.6},
	{"n": "day_meadow", "eye": Vector2(-92, 6), "eh": 2.4, "tgt": Vector2(-64, -14), "th": 1.2, "h": 10.4},
	{"n": "village_dusk", "eye": Vector2(-134, 62), "eh": 4.5, "tgt": Vector2(-118, 42), "th": 2.0, "h": 18.4},
	{"n": "village_night", "eye": Vector2(-106, 56), "eh": 2.6, "tgt": Vector2(-120, 45), "th": 1.2, "h": 22.2},
	{"n": "birds", "eye": Vector2(-40, 20), "eh": 2.0, "tgt": Vector2(-66, 36), "th": 18.0, "h": 9.2},
	{"n": "monkeys", "eye": Vector2(-101, 34), "eh": 1.4, "tgt": Vector2(-104, 31), "th": 0.5, "h": 12.0, "monkey": true},
	{"n": "butterflies", "eye": Vector2(-66, -14), "eh": 1.5, "tgt": Vector2(-60, -8), "th": 1.0, "h": 11.0, "bfly": true},
	{"n": "ruins_bats", "eye": Vector2(-146, -128), "eh": 3.0, "tgt": Vector2(-168, -148), "th": 9.0, "h": 23.4},
	{"n": "deer_close", "eye": Vector2(0, 0), "eh": 1.5, "tgt": Vector2(0, 0), "th": 0.7, "h": 15.5, "deer": true},
	{"n": "river_fish", "eye": Vector2(0, 0), "eh": 1.2, "tgt": Vector2(0, 0), "th": 0.0, "h": 12.5, "fish": true},
	{"n": "gust", "eye": Vector2(-76, 26), "eh": 2.6, "tgt": Vector2(-104, 2), "th": 1.2, "h": 16.4, "gust": true},
	{"n": "rain", "eye": Vector2(-92, 6), "eh": 2.4, "tgt": Vector2(-64, -14), "th": 1.2, "h": 13.0, "rain": 0.9},
	# The art-direction checks the brief names explicitly.
	{"n": "shrine", "eye": Vector2(140, -52), "eh": 3.0, "tgt": Vector2(158, -66), "th": 2.5, "h": 18.6},
	{"n": "forest_deep", "eye": Vector2(-214, -6), "eh": 1.7, "tgt": Vector2(-238, 14), "th": 2.0, "h": 12.0},
	{"n": "waterfall", "eye": Vector2(52, -178), "eh": 6.0, "tgt": Vector2(38, -196), "th": 6.0, "h": 10.0},
]

var only: PackedStringArray = PackedStringArray()
var game: Game
var cam: Camera3D
var map: WorldMap


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7).split(",")
	_run()


func _settle(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame


func _run() -> void:
	game = Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	map = game.world.map
	game.world.sky.paused = true
	game.player.lock_input(true)
	# The player is the focus every system reads; the camera is separate so framing can
	# be aimed. Hide the rig so Rama is not standing in the middle of every shot.
	if game.player.rig:
		game.player.rig.visible = false

	# The HUD compass and health bar are drawn over everything and are not what is
	# being judged here.
	for n in get_tree().get_nodes_in_group("hud"):
		if n is CanvasItem or n is CanvasLayer:
			n.visible = false
	_hide_canvas(get_tree().root)

	cam = Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	cam.near = 0.10
	add_child(cam)
	cam.current = true

	print("--- systems ---")
	for k in ["water", "vegetation", "settlement", "vfx", "wildlife"]:
		var n: Node = game.get(k)
		print("  %-11s %s  children=%d" % [k, "YES" if n else "NO", n.get_child_count() if n else 0])
	if game.wildlife:
		print("  wildlife stats: ", game.wildlife.stats())

	for s in SHOTS:
		if only.size() > 0 and not only.has(String(s.n)):
			continue
		await _shot(s)

	print("done")
	get_tree().quit()


func _shot(s: Dictionary) -> void:
	var eye2: Vector2 = s.eye
	var tgt2: Vector2 = s.tgt
	var eye_y := 0.0
	var tgt_y := 0.0

	game.world.sky.set_time(float(s.h))
	if s.has("rain"):
		game.vfx.set_rain(float(s.rain))
	else:
		game.vfx.set_rain(0.0)

	# Special cases that need the live simulation to say where to point.
	if s.get("fish", false):
		var rp: Array = map.river_points()
		var best := -1.0
		var fp: Vector2 = rp[int(rp.size() / 2)]
		for i in range(6, rp.size() - 6):
			var q: Vector2 = rp[i]
			var d: float = map.water_depth_at(q.x, q.y)
			if d > best:
				best = d
				fp = q
		var wy := map.water_y_at(fp.x, fp.y)
		print("  fish stretch (%.0f, %.0f) depth %.2f surface %.2f" % [fp.x, fp.y, best, wy])
		eye2 = fp + Vector2(6.0, 6.0)
		tgt2 = fp
		eye_y = wy + 1.1
		tgt_y = wy - 0.45
		_park(Vector3(fp.x, wy, fp.y))
		await _settle(120)
	elif s.get("deer", false):
		# Park the player 60 m off so the herd grazes instead of bolting, let it settle,
		# THEN find the nearest animal and frame it. The old harness framed where a deer
		# had been ninety frames earlier, which is why its close-up had no deer in it.
		var anchor := map.ground(WorldMap.P_FIELDS.x + 38.0, WorldMap.P_FIELDS.y - 26.0)
		_park(anchor + Vector3(58.0, 0.0, 58.0))
		await _settle(150)
		var d: Vector3 = game.wildlife.nearest_deer(anchor)
		var v := Vector2(0.80, 0.60).normalized() * 7.0
		eye2 = Vector2(d.x + v.x, d.z + v.y)
		tgt2 = Vector2(d.x, d.z)
		eye_y = map.height_at(eye2.x, eye2.y) + float(s.eh)
		tgt_y = d.y + float(s.th)
		print("  deer framed at (%.1f, %.1f, %.1f)" % [d.x, d.y, d.z])
	else:
		eye_y = map.height_at(eye2.x, eye2.y) + float(s.eh)
		tgt_y = map.height_at(tgt2.x, tgt2.y) + float(s.th)
		_park(Vector3(eye2.x, map.height_at(eye2.x, eye2.y), eye2.y))

	var eye := Vector3(eye2.x, eye_y, eye2.y)
	cam.global_position = eye
	cam.look_at(Vector3(tgt2.x, tgt_y, tgt2.y), Vector3.UP)
	game.world.terrain.update_focus(eye, true)
	await _settle(30)

	if s.get("gust", false):
		game.vfx.update_focus(eye)
		await _settle(10)
		print("  gust fired: ", game.vfx.trigger_gust())
		await _settle(40)
	else:
		await _settle(90 if s.has("rain") else 65)

	if s.get("monkey", false):
		var m2: Vector3 = game.wildlife.nearest_monkey(eye)
		var mo := Vector2(eye.x - m2.x, eye.z - m2.z)
		if mo.length() > 0.5:
			mo = mo.normalized() * 4.0
			eye = Vector3(m2.x + mo.x, map.height_at(m2.x + mo.x, m2.z + mo.y) + 1.1, m2.z + mo.y)
			cam.global_position = eye
			cam.look_at(m2 + Vector3(0.0, 0.30, 0.0), Vector3.UP)
			print("  monkey re-framed at (%.1f, %.1f, %.1f), camera %.1f m away" % [m2.x, m2.y, m2.z, eye.distance_to(m2)])
		await _settle(3)
	elif s.get("bfly", false):
		# The butterfly flocks are held at a fixed offset from the player, so a fixed
		# camera aim misses them entirely - aim at whichever flock is actually out.
		var homes: Array = game.wildlife.flock_homes()
		var bh := Vector2(eye.x, eye.z)
		var bd := -1.0
		for h in homes:
			# Whichever flock is furthest from the village: the other one keeps landing
			# next to a granary and photographing its wall.
			if int(h.kind) == Wildlife.K_BUTTERFLY:
				var dd: float = Vector2(h.home).distance_to(WorldMap.P_VILLAGE)
				if dd > bd:
					bd = dd
					bh = h.home
		var away := Vector2(eye.x, eye.z) - bh
		if away.length() < 0.3:
			away = Vector2(1.0, 0.0)
		away = away.normalized() * 3.2
		var by := map.height_at(bh.x, bh.y)
		eye = Vector3(bh.x + away.x, by + 1.5, bh.y + away.y)
		cam.global_position = eye
		cam.look_at(Vector3(bh.x, by + 1.2, bh.y), Vector3.UP)
		print("  butterflies framed at (%.1f, %.1f)" % [bh.x, bh.y])
		await _settle(6)
	elif s.get("deer", false):
		# Re-aim on the LAST frame. A grazing chital covers 15 m in the settling time,
		# so a close-up framed before the settle is a close-up of empty grass.
		var d2: Vector3 = game.wildlife.nearest_deer(eye)
		var off := Vector2(eye.x - d2.x, eye.z - d2.z)
		if off.length() > 0.5:
			# Pick the approach with the least canopy between lens and animal, and stand
			# well back and high: a 6 m eye at 1.5 m put the camera inside a bush the
			# first time the deer happened to graze into cover.
			var best := off.normalized()
			var best_fd := 1e9
			for k in range(12):
				var a: float = TAU * float(k) / 12.0
				var c := Vector2(cos(a), sin(a))
				var q := Vector2(d2.x, d2.z) + c * 9.0
				var fdv: float = map.forest_density(q) + map.forest_density(Vector2(d2.x, d2.z) + c * 4.5)
				if fdv < best_fd:
					best_fd = fdv
					best = c
			off = best * 9.0
			eye = Vector3(d2.x + off.x, map.height_at(d2.x + off.x, d2.z + off.y) + 2.4, d2.z + off.y)
			cam.global_position = eye
			cam.look_at(d2 + Vector3(0.0, 0.75, 0.0), Vector3.UP)
			print("  deer re-framed at (%.1f, %.1f, %.1f), camera %.1f m away" % [d2.x, d2.y, d2.z, eye.distance_to(d2)])
		await _settle(3)

	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT % s.n)
	print("shot %-14s eye=(%.1f, %.1f, %.1f)  hour=%.1f" % [s.n, eye.x, eye.y, eye.z, float(s.h)])


func _hide_canvas(n: Node) -> void:
	if n is CanvasLayer:
		(n as CanvasLayer).visible = false
		return
	for c in n.get_children():
		_hide_canvas(c)


## Move the focus every system reads. `deer_close` deliberately parks it far from the
## camera so the herd does not flee the lens.
func _park(p: Vector3) -> void:
	game.player.global_position = Vector3(p.x, map.height_at(p.x, p.z) + 0.15, p.z)
	game.player.velocity = Vector3.ZERO
	for n in [game.vegetation, game.vfx, game.wildlife, game.water]:
		if n and n.has_method("update_focus"):
			n.update_focus(game.player.global_position)
