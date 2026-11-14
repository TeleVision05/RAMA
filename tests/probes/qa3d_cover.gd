extends Node
## QA: how much of the GROUND does the ground cover actually cover, by distance band?
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_cover.tscn
##
## "Is it 3D?" and "does it read as vegetation?" are different questions and the second
## one is not answered by a triangle count. A field of thin keeled ribbons can be
## perfectly 3D and still leave the player looking at a painted ground texture, which is
## the failure the review complained about in the first place.
##
## The measurement: render each framing twice, once with the cover shown and once with
## every cover node hidden, and count the pixels that changed. That fraction IS the
## share of the frame the cover occupies, and it is taken at three ranges because the
## LOD bands thin the density with distance and the interesting question is what the
## player sees at 12 m, not at 1 m.

const RANGES := [
	{"n": "near_2m", "d": 2.0, "fov": 46.0, "eye": 0.9},
	{"n": "mid_12m", "d": 12.0, "fov": 30.0, "eye": 1.62},
	{"n": "far_30m", "d": 30.0, "fov": 20.0, "eye": 1.62},
]
const SPOTS := [
	# A spot WorldMap actually classes MEADOW, open and flat. The "meadow" by the
	# village is biome VILLAGE, weight 0.60 in _grass_weight, so judging the meadow
	# there measures the village discount rather than the meadow.
	{"n": "true_mdw", "at": Vector2(132, -204)},
	{"n": "meadow", "at": Vector2(-152, 86)},
	{"n": "village", "at": Vector2(-124, 50)},
	{"n": "forest", "at": Vector2(-214, -18)},
]

var _rows: Array = []


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _cover_nodes(veg: Node) -> Array:
	var out: Array = []
	for cell in veg._grass_cells:
		var rec: Dictionary = veg._grass_cells[cell]
		for li in range(3):
			var lay: Dictionary = rec.layers[li]
			for node in lay.nodes:
				if node != null and node.visible:
					out.append(node)
	return out


func _run() -> void:
	var game := Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	p.visible = false
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)

	var cam := Camera3D.new()
	cam.near = 0.02
	add_child(cam)
	cam.current = true
	var m: WorldMap = game.world.map
	var vp := get_viewport()

	for spot in SPOTS:
		var at: Vector2 = spot.at
		var g := m.height_at(at.x, at.y)
		p.global_position = Vector3(at.x, g + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(8):
			game.vegetation.update_focus(p.global_position, true)
			await get_tree().physics_frame
		for r in RANGES:
			var d: float = r.d
			cam.fov = r.fov
			var eye := Vector3(at.x, g + float(r.eye), at.y)
			# Look at the ground `d` metres away, so the frame is filled with terrain at
			# roughly that range and the number is a coverage at a known distance.
			var tx := at.x - d * 0.6
			var tz := at.y - d * 0.8
			var tgt := Vector3(tx, m.height_at(tx, tz), tz)
			cam.look_at_from_position(eye, tgt, Vector3.UP)
			for i in range(20):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var with_img := vp.get_texture().get_image()

			var hidden := _cover_nodes(game.vegetation)
			for n in hidden:
				n.visible = false
			for i in range(6):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var without_img := vp.get_texture().get_image()
			for n in hidden:
				n.visible = true

			var cov := _changed(with_img, without_img)
			_rows.append("%-8s %-8s  cover occupies %5.1f%% of frame" % [spot.n, r.n, cov * 100.0])
			if r.n == "mid_12m":
				with_img.save_png("res://build/screenshots/qc_%s_with.png" % spot.n)
				without_img.save_png("res://build/screenshots/qc_%s_without.png" % spot.n)
	print("")
	print("== GROUND-COVER SCREEN COVERAGE (with minus without) ==")
	for r in _rows:
		print(r)
	print("RESULT: PASS (measurement only)")
	get_tree().quit()


static func _changed(a: Image, b: Image) -> float:
	var n := 0
	var total := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			total += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			# A per-channel threshold, not a luminance one: grass over dirt is mostly a
			# hue change and a luminance test scores half of it as unchanged.
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.035:
				n += 1
	return float(n) / float(total)
