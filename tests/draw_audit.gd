extends Node


## Where do the draw calls come from? Counts visible MeshInstance3D / MultiMeshInstance3D
## per system, with triangle totals. Immune to machine load, unlike a frame-time number.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	var v := Vector2(WorldMap.P_VILLAGE.x, WorldMap.P_VILLAGE.y)
	p.global_position = Vector3(v.x, game.world.map.height_at(v.x, v.y) + 0.2, v.y)
	game.world.terrain.update_focus(p.global_position, true)
	for i in range(160):
		await get_tree().process_frame

	var systems := {
		"terrain": game.world.terrain,
		"water": game.water,
		"vegetation": game.vegetation,
		"settlement": game.settlement,
		"vfx": game.vfx,
		"wildlife": game.wildlife,
		"enemies": game.enemies,
		"npcs": game.npcs,
		"player": p,
		"solids": game.solids,
	}
	var total_draws := 0
	var total_tris := 0
	print("%-12s %8s %8s %10s" % ["system", "visible", "hidden", "tris"])
	for k in systems:
		var n: Node = systems[k]
		if n == null:
			continue
		var r := {"vis": 0, "hid": 0, "tris": 0}
		_walk(n, r)
		total_draws += r.vis
		total_tris += r.tris
		print("%-12s %8d %8d %10d" % [k, r.vis, r.hid, r.tris])
	print("%-12s %8d %8s %10d" % ["TOTAL", total_draws, "", total_tris])
	print(
		(
			"engine reports: objects=%d prims=%d draws=%d"
			% [
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			]
		)
	)
	get_tree().quit()


func _walk(n: Node, r: Dictionary) -> void:
	for c in n.get_children():
		if c is GeometryInstance3D:
			var g := c as GeometryInstance3D
			if g.is_visible_in_tree():
				r.vis += 1
				r.tris += _tris(g)
			else:
				r.hid += 1
		if c.get_child_count() > 0:
			_walk(c, r)


func _tris(g: GeometryInstance3D) -> int:
	var m: Mesh = null
	var n := 1
	if g is MeshInstance3D:
		m = (g as MeshInstance3D).mesh
	elif g is MultiMeshInstance3D:
		var mm := (g as MultiMeshInstance3D).multimesh
		if mm:
			m = mm.mesh
			n = mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
	if m == null:
		return 0
	var t := 0
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		var idx = a[Mesh.ARRAY_INDEX]
		if idx != null and (idx as PackedInt32Array).size() > 0:
			t += (idx as PackedInt32Array).size() / 3
		else:
			t += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return t * n
