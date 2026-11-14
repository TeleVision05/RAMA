extends SceneTree
## Isolated close-ups of the ground-cover primitives, lit from three angles, with no
## world around them. This is the fast loop: it renders in a couple of seconds, so the
## geometry can be judged and fixed before anything is measured in the real game.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/probes/ground3d_gallery.gd
## (no --headless: headless renders nothing)

const OUT := "res://build/screenshots/%s.png"


func _init() -> void:
	var root := get_root()
	root.transparent_bg = false

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.42, 0.50, 0.62)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.48, 0.55, 0.66)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.6
	sun.shadow_enabled = true
	root.add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.26, 0.22, 0.15)
	fmat.roughness = 1.0
	floor_mi.mesh.surface_set_material(0, fmat)
	root.add_child(floor_mi)

	var cam := Camera3D.new()
	cam.fov = 34.0
	cam.near = 0.005
	cam.far = 60.0
	root.add_child(cam)
	cam.current = true

	await process_frame

	# One tuft and one flower of each kind, from three light angles, then the rest of
	# the family in one row each.
	var subjects := [
		{"n": "blade", "layer": Ground3D.Layer.GRASS, "v": 2, "lod": 0, "d": 0.26, "h": 0.30},
		{"n": "tuft0", "layer": Ground3D.Layer.GRASS, "v": 0, "lod": 0, "d": 0.85, "h": 0.28},
		{"n": "tuft1", "layer": Ground3D.Layer.GRASS, "v": 1, "lod": 0, "d": 0.85, "h": 0.24},
		{"n": "tuft2", "layer": Ground3D.Layer.GRASS, "v": 2, "lod": 0, "d": 0.90, "h": 0.32},
		{"n": "tuft_lod1", "layer": Ground3D.Layer.GRASS, "v": 0, "lod": 1, "d": 0.85, "h": 0.24},
		{"n": "tuft_lod2", "layer": Ground3D.Layer.GRASS, "v": 0, "lod": 2, "d": 0.85, "h": 0.22},
		{"n": "marigold", "layer": Ground3D.Layer.FLOWER, "v": 0, "lod": 0, "d": 0.90, "h": 0.52},
		{"n": "jasmine", "layer": Ground3D.Layer.FLOWER, "v": 1, "lod": 0, "d": 0.72, "h": 0.36},
		{"n": "hibiscus", "layer": Ground3D.Layer.FLOWER, "v": 2, "lod": 0, "d": 0.80, "h": 0.42},
		{"n": "fern0", "layer": Ground3D.Layer.FERN, "v": 0, "lod": 0, "d": 1.20, "h": 0.30},
		{"n": "fern1", "layer": Ground3D.Layer.FERN, "v": 1, "lod": 0, "d": 1.00, "h": 0.26},
		{"n": "broadleaf", "layer": Ground3D.Layer.FERN, "v": 2, "lod": 0, "d": 0.80, "h": 0.20},
	]
	# Three lights: raking from the left, from behind (translucency) and from overhead.
	var lights := [Vector3(-1.0, -0.45, -0.6), Vector3(0.25, -0.30, 1.0), Vector3(0.1, -1.0, 0.2)]

	var mi := MultiMeshInstance3D.new()
	root.add_child(mi)
	for s in subjects:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = Ground3D.mesh(s.layer, s.v, s.lod)
		mm.instance_count = 1
		mm.set_instance_transform(0, Transform3D.IDENTITY)
		mm.set_instance_custom_data(0, Color(0.55, 1.0, 0.37, 0.0))
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var tris := Ground3D.tris(s.layer, s.v, s.lod)
		for li in range(lights.size()):
			sun.look_at_from_position(Vector3(0, 6, 0), Vector3(0, 6, 0) + (lights[li] as Vector3), Vector3.UP)
			# Eye level just above the subject, close in, and a touch below its top —
			# the angle a card cannot survive.
			var ang := 0.9 + float(li) * 2.1
			var d: float = s.d
			var eye := Vector3(cos(ang) * d, s.h * 0.65, sin(ang) * d)
			cam.look_at_from_position(eye, Vector3(0, s.h * 0.45, 0), Vector3.UP)
			for i in range(6):
				await process_frame
			await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png(OUT % ("g3_%s_%d" % [s.n, li]))
		# One straight-down shot: a flower has to read from above too.
		cam.look_at_from_position(Vector3(0.001, s.h * 1.9, 0.0), Vector3.ZERO, Vector3.FORWARD)
		for i in range(6):
			await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png(OUT % ("g3_%s_top" % s.n))
		print("%-12s tris %5d" % [s.n, tris])

	print("--- triangle table (layer, variant, lod) ---")
	for l in range(Ground3D.LAYER_COUNT):
		for v in range(Ground3D.VARIANTS):
			var row := []
			for d in range(Ground3D.LODS):
				row.append(Ground3D.tris(l, v, d))
			print("  layer %d var %d : %s" % [l, v, str(row)])
	print("done")
	quit()
