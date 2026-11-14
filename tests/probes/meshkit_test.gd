extends SceneTree


## Proves the winding convention: if any primitive is wound backwards it renders
## inside-out and this shot shows it immediately.
func _init() -> void:
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.12, 0.18)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.6, 0.8)
	e.ambient_light_energy = 0.35
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var l := DirectionalLight3D.new()
	l.light_energy = 2.4
	l.shadow_enabled = true
	w.add_child(l)
	l.look_at_from_position(Vector3(4, 6, 5), Vector3.ZERO, Vector3.UP)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.62, 0.38)
	mat.roughness = 0.6
	var items := [
		["sphere", MeshKit.sphere(0.5)],
		["ovoid", MeshKit.ovoid(0.42, 1.1)],
		["limb", MeshKit.limb(1.0, 0.16, 0.24)],
		["tube", MeshKit.tube(1.1, [[0.0, 0.30], [0.4, 0.22], [0.75, 0.16], [1.0, 0.09]], 12)],
		["box", MeshKit.box(Vector3(0.8, 0.8, 0.8))],
		["boulder", MeshKit.boulder(0.55, 7)],
		["quad", MeshKit.quad(0.9, 0.9)],
	]
	for i in range(items.size()):
		var mi := MeshInstance3D.new()
		mi.mesh = items[i][1]
		mi.material_override = mat
		mi.position = Vector3((i - 3) * 1.35, 0, 0)
		w.add_child(mi)
		var tri := 0
		for si in range(items[i][1].get_surface_count()):
			tri += items[i][1].surface_get_arrays(si)[Mesh.ARRAY_VERTEX].size() / 3
		print("%-8s tris=%d aabb=%s" % [items[i][0], tri, items[i][1].get_aabb().size])

	var cam := Camera3D.new()
	cam.fov = 46.0
	root.add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(0, 1.4, 7.0), Vector3(0, 0.1, 0), Vector3.UP)
	for i in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/meshkit.png")
	print("wrote meshkit.png")
	quit()
