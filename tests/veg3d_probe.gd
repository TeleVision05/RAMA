extends Node
## Per-LOD instance counts and triangle totals for the foliage streamer, at the
## places that actually stress it. Windowed, because a MultiMesh audited under
## --headless reports nothing (see ARCHITECTURE).


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	print("%-12s %6s %6s %6s %10s %10s" % ["where", "full", "mid", "far", "tree_tris", "grass_tris"])
	var spots := {
		"village": WorldMap.P_VILLAGE,
		"deep wood": Vector2(-210, -40),
		"forest camp": WorldMap.P_FOREST_CAMP,
		"grove": WorldMap.P_HIDDEN_GROVE,
		"river road": Vector2(-34, 8),
	}
	for k in spots:
		var at: Vector2 = spots[k]
		p.global_position = Vector3(at.x, game.world.map.height_at(at.x, at.y) + 0.2, at.y)
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(40):
			for n in [game.vegetation, game.solids]:
				if n and n.has_method("update_focus"):
					n.update_focus(p.global_position)
			await get_tree().physics_frame
		var st: Dictionary = game.vegetation.stats()
		var bl: Array = st.by_lod
		print("%-12s %6d %6d %6d %10d %10d" % [k, bl[0], bl[1], bl[2], int(st.tree_triangles), int(st.grass_triangles)])
		_dump_slots(game.vegetation)
	print("RESULT: PASS")
	get_tree().quit()


func _dump_slots(veg: Vegetation) -> void:
	var lods := ["FULL", "MID", "FAR"]
	for lod in range(3):
		var line := "     %-4s " % lods[lod]
		var tot := 0
		for sp in range(TreeBuilder.SPECIES_COUNT):
			var n := 0
			var t := 0
			for va in range(TreeBuilder.VARIANTS):
				var slot = veg._slots[(sp * TreeBuilder.VARIANTS + va) * 3 + lod]
				if slot == null:
					continue
				n += int(slot.n)
				t += int(slot.n) * int(slot.tris)
			tot += t
			line += "%s=%d/%dk " % [TreeBuilder.SPECIES_NAMES[sp], n, t / 1000]
		print(line + " tris=%d" % tot)
