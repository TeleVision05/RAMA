extends SceneTree


## Isolate terrain GEOMETRY from shading: plain material, no fog, light overhead.
func _init() -> void:
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)

	var m := WorldMap.load_or_bake(false)
	var t := Terrain.new()
	w.add_child(t)
	var plain := StandardMaterial3D.new()
	plain.albedo_color = Color(0.55, 0.62, 0.42)
	plain.roughness = 0.95
	t.setup(m, plain)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	w.add_child(sun)
	sun.look_at_from_position(Vector3(0, 100, 0), Vector3(30, 0, 40), Vector3.UP)

	var envn := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.25, 0.45, 0.85)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.7, 0.85)
	e.ambient_light_energy = 0.5
	e.fog_enabled = false
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	envn.environment = e
	w.add_child(envn)

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	root.add_child(cam)
	cam.current = true

	await process_frame
	var views := [
		{"n": "over", "p": Vector3(-120, 190, 190), "l": Vector3(-120, 12, 44)},
		{"n": "eye", "p": Vector3(-120, 34, 90), "l": Vector3(-120, 12, 44)},
		{"n": "high", "p": Vector3(0, 520, 420), "l": Vector3(0, 20, 0)},
	]
	for v in views:
		cam.global_position = v.p
		cam.look_at(v.l, Vector3.UP)
		t.update_focus(v.p, true)
		for m2 in [Viewport.DEBUG_DRAW_DISABLED, Viewport.DEBUG_DRAW_WIREFRAME]:
			root.debug_draw = m2
			for i in range(6):
				await process_frame
			await RenderingServer.frame_post_draw
			var tag := "solid" if m2 == Viewport.DEBUG_DRAW_DISABLED else "wire"
			root.get_texture().get_image().save_png("res://build/screenshots/diag_%s_%s.png" % [v.n, tag])
			print("diag_%s_%s" % [v.n, tag])
	# Report raw geometry facts for the chunk under the camera.
	var mesh := t._build_mesh(Vector2(-128.0, 0.0), 0)
	var a := mesh.surface_get_arrays(0)
	var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	print("chunk verts=%d  first=%s  mid=%s  aabb=%s" % [vs.size(), vs[0], vs[2000], mesh.get_aabb()])
	quit()
