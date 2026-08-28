extends Node
## Isolated close-ups of the 3D vegetation primitives. No world, no streaming — just
## the geometry, lit from three angles, so "is this actually curved" is answerable by
## looking rather than by reading the builder.

const SHOT_DIR := "res://build/screenshots/"

var cam: Camera3D
var sun: DirectionalLight3D
var holder: Node3D


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _mat(tex_name: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	m.set_shader_parameter("albedo_tex", Mats.tex(tex_name))
	m.set_shader_parameter("normal_tex", Mats.tex(tex_name + "_normal"))
	m.set_shader_parameter("two_sided", true)
	m.set_shader_parameter("use_normal_map", true)
	m.set_shader_parameter("tint_a", Vector3(1.02, 1.06, 0.76))
	m.set_shader_parameter("tint_b", Vector3(0.66, 0.90, 0.56))
	m.set_shader_parameter("roughness_value", 0.86)
	m.set_shader_parameter("ao_strength", 0.40)
	m.set_shader_parameter("normal_depth", 0.55)
	m.set_shader_parameter("albedo_gain", 1.55)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("translucency_color", Color(0.52, 0.74, 0.24))
	m.set_shader_parameter("translucency", 0.85)
	m.set_shader_parameter("wind_strength", 0.0)
	return m


func _show(s, tex_name: String) -> MeshInstance3D:
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	m.surface_set_material(0, _mat(tex_name))
	var mi := MeshInstance3D.new()
	mi.mesh = m
	holder.add_child(mi)
	return mi


func _clear() -> void:
	for c in holder.get_children():
		c.queue_free()
	await get_tree().process_frame


func _shot(name: String, eye: Vector3, look: Vector3, angles: Array) -> void:
	for i in range(angles.size()):
		var a: Vector2 = angles[i]
		sun.rotation = Vector3(deg_to_rad(a.x), deg_to_rad(a.y), 0.0)
		cam.look_at_from_position(eye, look, Vector3.UP)
		for f in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(SHOT_DIR + "v3_%s_%d.png" % [name, i])
	print("shot %s" % name)


func _run() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.45, 0.60, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.62, 0.78)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e
	add_child(env)

	sun = DirectionalLight3D.new()
	sun.light_energy = 2.1
	sun.shadow_enabled = true
	add_child(sun)

	holder = Node3D.new()
	add_child(holder)

	cam = Camera3D.new()
	cam.fov = 32.0
	cam.near = 0.01
	add_child(cam)
	cam.current = true

	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var lit := [Vector2(-42, 20), Vector2(-14, 155), Vector2(-70, -95)]

	# --- ONE LEAF, big, from the side so the camber and droop have to show
	var s1 = TreeBuilder.Surf.new()
	var c1 := Veg3D.leaf_cfg()
	c1["length"] = 0.60
	c1["width"] = 0.30
	c1["rows"] = 4
	c1["camber"] = 0.70
	c1["droop"] = 0.75
	c1["twist"] = 0.45
	Veg3D.leaf(s1, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), c1)
	_show(s1, "leaf_lamina_broad")
	print("  leaf tris=%d (predicted %d)" % [s1.idx.size() / 3, Veg3D.leaf_tris(4, false)])
	await _shot("leaf_side", Vector3(1.05, 0.36, 0.30), Vector3(0.0, -0.02, 0.30), lit)
	await _shot("leaf_edge", Vector3(0.04, 0.08, -0.78), Vector3(0.0, -0.04, 0.26), lit)
	await _shot("leaf_below", Vector3(0.36, -0.72, -0.30), Vector3(0.0, -0.05, 0.28), lit)
	await _clear()

	# --- ONE SPRIG
	var s2 = TreeBuilder.Surf.new()
	var c2 := Veg3D.sprig_cfg()
	c2["stem_len"] = 0.62
	c2["stem_r"] = 0.020
	c2["leaves"] = 6
	c2["length"] = 0.36
	c2["width"] = 0.19
	c2["rows"] = 3
	Veg3D.sprig(s2, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), rng, c2)
	_show(s2, "leaf_lamina_broad")
	print("  sprig tris=%d (predicted %d)" % [s2.idx.size() / 3, Veg3D.sprig_tris(c2)])
	await _shot("sprig", Vector3(1.85, 0.70, 0.10), Vector3(0.0, -0.16, 0.40), lit)
	await _shot("sprig_below", Vector3(0.42, -1.35, 0.10), Vector3(0.0, -0.10, 0.38), lit)
	await _clear()

	# --- ONE PALM FROND
	var s3 = TreeBuilder.Surf.new()
	var c3 := Veg3D.frond_cfg()
	Veg3D.frond(s3, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), rng, c3)
	_show(s3, "leaf_lamina_pinna")
	print("  frond tris=%d (predicted %d)" % [s3.idx.size() / 3, Veg3D.frond_tris(c3)])
	await _shot("frond", Vector3(4.4, 0.9, -3.4), Vector3(0.0, -0.85, 2.1), lit)
	await _shot("frond_close", Vector3(1.1, 0.45, 1.35), Vector3(0.05, -0.45, 2.25), lit)
	await _clear()

	print("RESULT: PASS")
	get_tree().quit()
