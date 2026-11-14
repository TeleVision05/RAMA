extends Node
## QA: what does each foliage layer actually cost, measured INSIDE one process?
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_ab.tscn
##
## Two separate runs of a frame-time test on this machine disagree by more than the
## thing being measured, so a before/after taken from two processes cannot attribute a
## regression to anything. This interleaves the states at one spot — cover on, cover
## off, trees off — and takes the PAIRED MEDIAN of each, so shader-compilation warmth,
## thermal state and background load are common to both sides and cancel.
##
## The tree layer is in here because this tree has several agents in it at once and the
## honest question is not "is the frame slow" but "which layer is spending it".

const SPOTS := [
	{"n": "village", "at": Vector2(-120, 44)},
	{"n": "meadow", "at": Vector2(-152, 86)},
	{"n": "deep wood", "at": Vector2(-210, -40)},
	{"n": "falls", "at": Vector2(34, -186)},
	{"n": "badlands", "at": Vector2(214, 178)},
]
const REPS := 7
const FRAMES := 14

var game: Game


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _cover_nodes() -> Array:
	var out: Array = []
	var veg = game.vegetation
	for cell in veg._grass_cells:
		var rec: Dictionary = veg._grass_cells[cell]
		for li in range(3):
			var lay: Dictionary = rec.layers[li]
			for node in lay.nodes:
				if node != null and node.visible:
					out.append(node)
	return out


func _tree_nodes() -> Array:
	var out: Array = []
	for slot in game.vegetation._slots:
		if slot != null and slot.node != null and slot.node.visible:
			out.append(slot.node)
	return out


func _sample() -> float:
	var t := []
	for i in range(FRAMES):
		var t0 := Time.get_ticks_usec()
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		t.append(float(Time.get_ticks_usec() - t0) / 1000.0)
	t.sort()
	return t[t.size() / 2]


func _run() -> void:
	game = Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(11.0)
	var m: WorldMap = game.world.map

	print("")
	print("== PAIRED IN-PROCESS COST, median frame ms (REPS=%d x %d frames) ==" % [REPS, FRAMES])
	var tot_cover := 0.0
	var tot_tree := 0.0
	for spot in SPOTS:
		var at: Vector2 = spot.at
		p.global_position = Vector3(at.x, m.height_at(at.x, at.y) + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(40):
			game.vegetation.update_focus(p.global_position, true)
			await get_tree().process_frame
		var d_cover: Array = []
		var d_tree: Array = []
		var d_all: Array = []
		for r in range(REPS):
			var all := await _sample()
			var cov := _cover_nodes()
			for n in cov:
				n.visible = false
			var no_cover := await _sample()
			for n in cov:
				n.visible = true
			var trs := _tree_nodes()
			for n in trs:
				n.visible = false
			var no_tree := await _sample()
			for n in trs:
				n.visible = true
			d_all.append(all)
			d_cover.append(all - no_cover)
			d_tree.append(all - no_tree)
		d_all.sort()
		d_cover.sort()
		d_tree.sort()
		var a: float = d_all[d_all.size() / 2]
		var c: float = d_cover[d_cover.size() / 2]
		var t: float = d_tree[d_tree.size() / 2]
		tot_cover += c
		tot_tree += t
		var st: Dictionary = game.vegetation.stats()
		print(
			(
				"%-10s frame %6.2f ms   GROUND COVER %+6.2f ms   trees %+6.2f ms   (cover %d inst / %d tri)"
				% [spot.n, a, c, t, st.grass_instances, st.grass_triangles]
			)
		)
	print("")
	print(
		(
			"mean ground-cover cost %.2f ms/frame   mean tree cost %.2f ms/frame"
			% [tot_cover / float(SPOTS.size()), tot_tree / float(SPOTS.size())]
		)
	)
	print("RESULT: PASS (measurement only)")
	get_tree().quit()
