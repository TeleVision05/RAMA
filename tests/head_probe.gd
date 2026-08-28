extends SceneTree
## Close-ups of the sculpted head on its own, from the angles a conversation uses.
## The face is what the player looks at in every dialogue, so it gets its own harness
## rather than being judged from a full-body contact sheet where it is 40 pixels tall.


func _init() -> void:
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.15, 0.19)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.62, 0.78)
	e.ambient_light_energy = 0.42
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.ssao_enabled = true
	e.ssao_radius = 0.12
	e.ssao_intensity = 2.4
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.8
	key.shadow_enabled = true
	key.light_color = Color(1.0, 0.95, 0.88)
	w.add_child(key)
	key.look_at_from_position(Vector3(2.2, 3.0, 3.0), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.45
	fill.light_color = Color(0.6, 0.72, 1.0)
	w.add_child(fill)
	fill.look_at_from_position(Vector3(-3, 1.2, -2), Vector3.ZERO, Vector3.UP)

	var cam := Camera3D.new()
	cam.fov = 30.0
	root.add_child(cam)
	cam.current = true

	var wire: bool = false
	for a in OS.get_cmdline_user_args():
		if a == "--wire":
			wire = true
	if wire:
		RenderingServer.set_debug_generate_wireframes(true)
		get_root().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME

	var r := 0.115
	var cases := [
		{"preset": 0, "hair": MeshKit.Hair.JATA, "beard": 0.0, "col": Color(0.07, 0.055, 0.05)},
		{"preset": 4, "hair": MeshKit.Hair.BUN, "beard": 0.95, "col": Color(0.60, 0.58, 0.56)},
		{"preset": 2, "hair": MeshKit.Hair.BRAID, "beard": 0.0, "col": Color(0.09, 0.06, 0.05)},
		{"preset": 1, "hair": MeshKit.Hair.LOOSE, "beard": 0.25, "col": Color(0.10, 0.07, 0.05)},
	]
	for case in cases:
		var preset: int = case["preset"]
		var host := Node3D.new()
		w.add_child(host)
		var m := Mats.pbr("skin_warm", 4.0, "skin_warm").duplicate()
		m.normal_scale = 0.35
		m.albedo_color = Color(1.34, 1.24, 1.16)
		var mi := MeshInstance3D.new()
		mi.mesh = MeshKit.head_shell(r, preset, 0)
		mi.material_override = m
		host.add_child(mi)
		var cav := MeshInstance3D.new()
		cav.mesh = MeshKit.face_cavities(r, preset)
		cav.material_override = Mats.flat(Color(0.17, 0.085, 0.07), 0.85)
		host.add_child(cav)
		var m_hair := Mats.flat(case["col"], 0.62)
		var hair := MeshInstance3D.new()
		hair.mesh = MeshKit.hair(r, preset, case["hair"], preset * 3 + 1, 0)
		hair.material_override = m_hair
		host.add_child(hair)
		var brow := MeshInstance3D.new()
		brow.mesh = MeshKit.brows(r, preset, 0)
		brow.material_override = m_hair
		host.add_child(brow)
		if float(case["beard"]) > 0.01:
			var bd := MeshInstance3D.new()
			bd.mesh = MeshKit.beard(r, preset, float(case["beard"]), 0)
			bd.material_override = m_hair
			host.add_child(bd)
		var m_eye := Mats.flat(Color(0.82, 0.79, 0.74), 0.22)
		var m_iris := Mats.flat(Color(0.13, 0.078, 0.052), 0.08)
		var rb: float = MeshKit.EYE_R * r
		for sx in [-1.0, 1.0]:
			var eye := Node3D.new()
			eye.position = Vector3(sx * MeshKit.EYE_X * r, MeshKit.EYE_Y * r, MeshKit.EYE_Z * r)
			host.add_child(eye)
			var ball := MeshInstance3D.new()
			ball.mesh = MeshKit.sphere(rb, 18, 13)
			ball.material_override = m_eye
			eye.add_child(ball)
			var iris := MeshInstance3D.new()
			iris.mesh = MeshKit.spherical_cap(rb * 1.014, 0.50, 14, 3)
			iris.material_override = m_iris
			eye.add_child(iris)
		for up in [true, false]:
			var lids := Node3D.new()
			lids.position = Vector3(0, MeshKit.EYE_Y * r, MeshKit.EYE_Z * r)
			host.add_child(lids)
			for sx in [-1.0, 1.0]:
				var l := MeshInstance3D.new()
				l.mesh = MeshKit.eyelid(rb, up, 0)
				l.material_override = m
				l.position = Vector3(sx * MeshKit.EYE_X * r, 0, 0)
				lids.add_child(l)
		print(
			(
				"preset %d: shell %d tris  lod1 %d  lid %d  cav %d  hair %d  brow %d"
				% [
					preset,
					MeshKit.head_shell(r, preset, 0).get_faces().size() / 3,
					MeshKit.head_shell(r, preset, 1).get_faces().size() / 3,
					MeshKit.eyelid(rb, true, 0).get_faces().size() / 3,
					MeshKit.face_cavities(r, preset).get_faces().size() / 3,
					MeshKit.hair(r, preset, case["hair"], preset * 3 + 1, 0).get_faces().size() / 3,
					MeshKit.brows(r, preset, 0).get_faces().size() / 3
				]
			)
		)
		var views := {
			"front": Vector3(0, 0.0, -0.50),
			"three": Vector3(-0.26, 0.05, -0.42),
			"side": Vector3(-0.52, 0.02, -0.06),
			"low": Vector3(-0.16, -0.20, -0.46),
		}
		for k in views:
			cam.look_at_from_position(views[k], Vector3(0, -0.02, 0), Vector3.UP)
			for i in range(4):
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://build/screenshots/head_%d_%s%s.png" % [preset, k, "_wire" if wire else ""])
		host.queue_free()
		await process_frame
	print("done")
	quit()
