extends SceneTree


func _init() -> void:
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.14, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.68, 0.8)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var l := DirectionalLight3D.new()
	l.light_energy = 2.2
	w.add_child(l)
	l.look_at_from_position(Vector3(3, 4, 4), Vector3.ZERO, Vector3.UP)

	var skirt := MeshKit.profile_loft(
		0.66,
		[
			[0.00, 0.132, 0.108],
			[0.14, 0.140, 0.116],
			[0.42, 0.146, 0.122],
			[0.72, 0.150, 0.126],
			[0.93, 0.146, 0.122],
			[1.00, 0.128, 0.106]
		],
		20
	)
	var flipped := ProcRig._down(skirt)
	var mat := Mats.flat(Color(0.92, 0.52, 0.14), 0.8)
	for pair in [[skirt, -0.45, "up"], [flipped, 0.45, "down"]]:
		var mi := MeshInstance3D.new()
		mi.mesh = pair[0]
		mi.material_override = mat
		mi.position = Vector3(pair[1], 0, 0)
		w.add_child(mi)
		var a: AABB = pair[0].get_aabb()
		print("%-5s aabb pos=%s size=%s  surfaces=%d" % [pair[2], a.position, a.size, (pair[0] as ArrayMesh).get_surface_count()])
	var cam := Camera3D.new()
	cam.fov = 40.0
	root.add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(0, 0.1, 2.2), Vector3(0, -0.15, 0), Vector3.UP)
	for i in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/dhoti_probe.png")
	print("wrote dhoti_probe.png")
	quit()
