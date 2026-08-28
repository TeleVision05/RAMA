extends SceneTree
## Renders the settlements in the real world (terrain + sky) from the viewpoints that
## matter: the road into the village, the square, the knoll, the ruins, the camp, the
## ford. Heights are always relative to the GROUND so a shot can never end up inside a
## hill. Writes build/screenshots/set_*.png.

const SHOTS := [
	{"n": "village_road", "p": Vector2(-88, 30), "eye": 4.0, "t": Vector2(-124, 54), "tgt": 3.0, "h": 8.4},
	{"n": "village_road2", "p": Vector2(-150, 20), "eye": 4.5, "t": Vector2(-124, 54), "tgt": 3.0, "h": 16.5},
	{"n": "village_over", "p": Vector2(-124, 118), "eye": 52.0, "t": Vector2(-124, 52), "tgt": 0.0, "h": 10.0},
	{"n": "village_square", "p": Vector2(-112, 48), "eye": 2.2, "t": Vector2(-128, 58), "tgt": 2.0, "h": 9.2},
	{"n": "village_well", "p": Vector2(-119, 61), "eye": 1.9, "t": Vector2(-128.6, 50.6), "tgt": 1.2, "h": 17.4},
	{"n": "shrine_foot", "p": Vector2(126, -68), "eye": 2.0, "t": Vector2(154, -78.5), "tgt": 9.0, "h": 8.0},
	{"n": "shrine_road", "p": Vector2(130, -100), "eye": 3.0, "t": Vector2(154, -78.5), "tgt": 10.0, "h": 16.0},
	{"n": "shrine_stair", "p": Vector2(150, -60), "eye": 2.0, "t": Vector2(163, -68), "tgt": 3.0, "h": 8.6},
	{"n": "shrine_court", "p": Vector2(175, -66), "eye": 3.0, "t": Vector2(155, -78.5), "tgt": 7.0, "h": 7.2},
	{"n": "shrine_close", "p": Vector2(186, -102), "eye": 16.0, "t": Vector2(154, -78.5), "tgt": 8.0, "h": 15.5},
	{"n": "shrine_east", "p": Vector2(168.5, -78.5), "eye": 1.9, "t": Vector2(154, -78.5), "tgt": 5.5, "h": 6.6},
	{"n": "shrine_wide", "p": Vector2(96, -140), "eye": 26.0, "t": Vector2(154, -78.5), "tgt": 14.0, "h": 17.8},
	{"n": "ruins", "p": Vector2(-176, -118), "eye": 4.0, "t": Vector2(-168, -150), "tgt": 1.0, "h": 9.6},
	{"n": "ruins_over", "p": Vector2(-168, -112), "eye": 26.0, "t": Vector2(-169, -150), "tgt": 0.0, "h": 12.0},
	{"n": "camp", "p": Vector2(-196, -12), "eye": 3.0, "t": Vector2(-196, -36), "tgt": 1.0, "h": 17.0},
	{"n": "fields", "p": Vector2(-60, 30), "eye": 9.0, "t": Vector2(-94, 4), "tgt": 0.0, "h": 8.0},
	{"n": "ford", "p": Vector2(-56, 26), "eye": 5.0, "t": Vector2(-32, 6), "tgt": 1.5, "h": 16.2},
	{"n": "ford_low", "p": Vector2(-46, -8), "eye": 2.0, "t": Vector2(-30, 14), "tgt": 2.0, "h": 9.0},
	{"n": "village_dusk", "p": Vector2(-96, 78), "eye": 12.0, "t": Vector2(-126, 52), "tgt": 2.0, "h": 18.6},
]


func _count_tris(n: Node) -> int:
	var t := 0
	if n is MeshInstance3D and n.mesh:
		var m: Mesh = n.mesh
		for s in range(m.get_surface_count()):
			t += m.surface_get_array_index_len(s) / 3
	elif n is MultiMeshInstance3D and n.multimesh and n.multimesh.mesh:
		var m2: Mesh = n.multimesh.mesh
		var per := 0
		for s in range(m2.get_surface_count()):
			per += m2.surface_get_array_index_len(s) / 3
		t += per * n.multimesh.instance_count
	for c in n.get_children():
		t += _count_tris(c)
	return t


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(true)
	var m := world.map

	var t0 := Time.get_ticks_msec()
	var s := Settlement.new()
	s.name = "Settlement"
	world.add_child(s)
	s.setup(m)
	print("[test] settlement built in %d ms, %d triangles" % [Time.get_ticks_msec() - t0, _count_tris(s)])
	for poi in s.points_of_interest():
		print("   POI %-32s %s r=%.0f %s" % [poi.name, poi.position, poi.radius, poi.kind])

	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.far = 2000.0
	cam.near = 0.10
	root.add_child(cam)
	cam.current = true

	await process_frame
	for sh in SHOTS:
		world.sky.paused = true
		world.sky.set_time(sh.h)
		var eye := Vector3(sh.p.x, m.height_at(sh.p.x, sh.p.y) + sh.eye, sh.p.y)
		var tgt := Vector3(sh.t.x, m.height_at(sh.t.x, sh.t.y) + sh.tgt, sh.t.y)
		cam.global_position = eye
		cam.look_at(tgt, Vector3.UP)
		world.terrain.update_focus(eye, true)
		for i in range(10):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/screenshots/set_%s.png" % sh.n)
		print("shot %-14s eye=%.1f,%.1f,%.1f" % [sh.n, eye.x, eye.y, eye.z])
	print("done")
	quit()
