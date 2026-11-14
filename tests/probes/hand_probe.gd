extends SceneTree
## The three grip poses side by side, and the LOD mitten, at hand scale.


func _init() -> void:
	await process_frame
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.14, 0.16, 0.20)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.62, 0.78)
	e.ambient_light_energy = 0.45
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.ssao_enabled = true
	e.ssao_radius = 0.05
	e.ssao_intensity = 2.0
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.6
	key.shadow_enabled = true
	w.add_child(key)
	key.look_at_from_position(Vector3(0.4, 0.6, -0.5), Vector3.ZERO, Vector3.UP)
	var cam := Camera3D.new()
	cam.fov = 34.0
	cam.near = 0.01
	root.add_child(cam)
	cam.current = true
	var m := Mats.pbr("skin_warm", 4.0, "skin_warm").duplicate()
	m.albedo_color = Color(1.34, 1.24, 1.16)
	var hl := 0.155
	var names := ["open", "relaxed", "closed", "mitten"]
	for i in range(4):
		var mi := MeshInstance3D.new()
		mi.mesh = MeshKit.hand_lod(hl, 1.0, 2, 1.0) if i == 3 else MeshKit.hand(hl, 1.0, i, 1.0, 0)
		mi.material_override = m
		mi.position = Vector3(float(i) * 0.115 - 0.172, 0, 0)
		w.add_child(mi)
		print("%s: %d tris" % [names[i], mi.mesh.get_faces().size() / 3])
	for view in [["front", Vector3(0, -0.07, -0.52)], ["side", Vector3(0.05, -0.07, 0.50)], ["three", Vector3(-0.30, 0.06, -0.44)]]:
		cam.look_at_from_position(view[1], Vector3(0, -0.075, 0), Vector3.UP)
		for i in range(4):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/screenshots/hand_%s.png" % view[0])
	print("done")
	quit()
