extends SceneTree
## Renders the procedural humanoid in several poses so the proportions, the IK and the
## additive layers can be judged by eye.


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--nomerge":
			ProcRig.merge_enabled = false
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.15, 0.19)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.62, 0.78)
	e.ambient_light_energy = 0.45
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.6
	key.shadow_enabled = true
	key.light_color = Color(1.0, 0.95, 0.88)
	w.add_child(key)
	key.look_at_from_position(Vector3(3, 5, 4), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.5
	fill.light_color = Color(0.6, 0.72, 1.0)
	w.add_child(fill)
	fill.look_at_from_position(Vector3(-4, 2, -3), Vector3.ZERO, Vector3.UP)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mi.mesh = pm
	floor_mi.material_override = Mats.flat(Color(0.30, 0.28, 0.24), 0.95)
	w.add_child(floor_mi)

	var cam := Camera3D.new()
	cam.fov = 40.0
	root.add_child(cam)
	cam.current = true

	var poses := [
		{"n": "idle_front", "sp": 0.0, "cam": Vector3(0, 1.05, 3.4), "st": {}},
		{"n": "idle_side", "sp": 0.0, "cam": Vector3(3.2, 1.05, 0.6), "st": {}},
		{"n": "walk", "sp": 1.9, "cam": Vector3(3.2, 1.05, 1.6), "st": {}},
		{"n": "run", "sp": 5.2, "cam": Vector3(3.4, 1.10, 1.8), "st": {}},
		{"n": "aim", "sp": 0.0, "cam": Vector3(2.6, 1.25, 2.4), "st": {"aim": 1.0}},
		{"n": "attack", "sp": 0.0, "cam": Vector3(2.6, 1.25, 2.4), "st": {"atk": 0.45}},
		{"n": "jump", "sp": 3.0, "cam": Vector3(3.2, 1.20, 1.8), "st": {"air": true}},
		{"n": "dead", "sp": 0.0, "cam": Vector3(2.8, 1.10, 2.2), "st": {"dead": 1.0}},
	]

	for p in poses:
		var rig := ProcRig.new()
		(
			rig
			. configure(
				{
					"seed": 1,
					"skin": "skin_warm",
					"cloth": "cloth_saffron",
					"cloth2": "cloth_white",
					"topknot": true,
					"jewellery": true,
				}
			)
		)
		w.add_child(rig)
		rig.build()
		rig.ground_fn = func(_x, _z): return 0.0
		# Settle the pose by stepping it several times.
		for i in range(48):
			rig.aim_weight = p.st.get("aim", 0.0)
			rig.aim_dir = Vector3(0, 0.10, -1).normalized()
			rig.attack_swing = p.st.get("atk", 0.0)
			rig.dead_amount = p.st.get("dead", 0.0)
			(
				rig
				. animate(
					1.0 / 60.0,
					{
						"speed": p.sp,
						"on_floor": not p.st.get("air", false),
						"air_time": 0.35 if p.st.get("air", false) else 0.0,
					}
				)
			)
		cam.look_at_from_position(p.cam, Vector3(0, 0.95, 0), Vector3.UP)
		for i in range(6):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(
			"res://build/screenshots/rig_%s%s.png" % [p.n, "_nm" if not ProcRig.merge_enabled else ""]
		)
		print("rig_%s" % p.n)
		rig.queue_free()
		await process_frame
	# Contact-sheet the lot for one glance.
	print("done")
	quit()
