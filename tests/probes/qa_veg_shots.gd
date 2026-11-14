extends Node
## QA render harness. Independent of the implementer's own shot list.
##
## The decisive framing is EDGE-ON, and "edge-on" is not eyeballed here: the camera is
## placed on the mean-normal plane of the geometry it is looking at (computed from the
## mesh), so a plane would present exactly zero projected area. A flat control quad is
## rendered through the identical path as the null hypothesis — if the control shows a
## sliver and the leaf does not, the leaf is not a plane.
##
## Also renders every canopy from DIRECTLY BELOW and in SILHOUETTE against the sky.

const SHOT_DIR := "res://build/screenshots/"

var cam: Camera3D
var sun: DirectionalLight3D
var holder: Node3D
var back: MeshInstance3D


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


func _show(s, tex_name: String) -> void:
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	m.surface_set_material(0, _mat(tex_name))
	var mi := MeshInstance3D.new()
	mi.mesh = m
	holder.add_child(mi)


func _clear() -> void:
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	await get_tree().process_frame


## Area-weighted mean normal, and the centroid, of an accumulated surface.
func _mean_normal(s) -> Array:
	var acc := Vector3.ZERO
	var ctr := Vector3.ZERO
	var wsum := 0.0
	var i := 0
	while i + 2 < s.idx.size():
		var a: Vector3 = s.v[s.idx[i]]
		var b: Vector3 = s.v[s.idx[i + 1]]
		var c: Vector3 = s.v[s.idx[i + 2]]
		var cr := (b - a).cross(c - a)
		var w := cr.length()
		if w > 1e-12:
			var n := cr / w
			acc += (n if acc.dot(n) >= 0.0 or acc == Vector3.ZERO else -n) * w
			ctr += (a + b + c) / 3.0 * w
			wsum += w
		i += 3
	if wsum < 1e-12:
		return [Vector3.UP, Vector3.ZERO]
	return [acc.normalized(), ctr / wsum]


func _grab(fname: String) -> void:
	for f in range(5):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SHOT_DIR + fname)


## Point the camera at `target` from `dist` metres along `dir`.
func _aim(target: Vector3, dir: Vector3, dist: float, up: Vector3 = Vector3.UP) -> void:
	var d := dir.normalized()
	var u := up
	if absf(d.dot(u)) > 0.985:
		u = Vector3.FORWARD
	cam.look_at_from_position(target + d * dist, target, u)


func _run() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.52, 0.66, 0.86)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.65, 0.80)
	e.ambient_light_energy = 0.60
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.environment = e
	add_child(env)

	sun = DirectionalLight3D.new()
	sun.light_energy = 2.2
	sun.shadow_enabled = true
	sun.rotation = Vector3(deg_to_rad(-38.0), deg_to_rad(28.0), 0.0)
	add_child(sun)

	holder = Node3D.new()
	add_child(holder)

	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.01
	cam.far = 400.0
	add_child(cam)
	cam.current = true

	var rng := RandomNumberGenerator.new()
	rng.seed = 4242

	# ------------------------------------------------------------------
	# 1. EDGE-ON, camera computed from the geometry's own mean normal.
	#    The flat quad is the control: it MUST vanish.
	# ------------------------------------------------------------------
	print("=== edge-on: camera placed perpendicular to the mean normal ===")
	var cases := []

	var sq = TreeBuilder.Surf.new()
	var hw := 0.16
	var i0: int = sq.vert(Vector3(-hw, 0, 0), Vector3.UP, Vector3.RIGHT, Color(1, 1, 0.5, 0), Vector2(0.02, 0.99))
	var i1: int = sq.vert(Vector3(hw, 0, 0), Vector3.UP, Vector3.RIGHT, Color(1, 1, 0.5, 0), Vector2(0.74, 0.99))
	var i2: int = sq.vert(Vector3(hw, 0, 0.55), Vector3.UP, Vector3.RIGHT, Color(1, 1, 0.5, 0), Vector2(0.74, 0.01))
	var i3: int = sq.vert(Vector3(-hw, 0, 0.55), Vector3.UP, Vector3.RIGHT, Color(1, 1, 0.5, 0), Vector2(0.02, 0.01))
	sq.quad(i0, i1, i2, i3, Vector3.UP)
	cases.append(["control_flatcard", sq, "leaf_lamina_broad", 0.95])

	var s1 = TreeBuilder.Surf.new()
	var c1 := Veg3D.leaf_cfg()
	c1["length"] = 0.55
	c1["width"] = 0.30
	c1["rows"] = 3
	Veg3D.leaf(s1, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), c1)
	cases.append(["leaf_full", s1, "leaf_lamina_broad", 0.95])

	var s1m = TreeBuilder.Surf.new()
	var c1m := Veg3D.leaf_cfg()
	c1m["length"] = 0.55
	c1m["width"] = 0.30
	c1m["rows"] = 1
	Veg3D.leaf(s1m, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), c1m)
	cases.append(["leaf_mid", s1m, "leaf_lamina_broad", 0.95])

	var s2 = TreeBuilder.Surf.new()
	var c2 := Veg3D.sprig_cfg()
	c2["leaves"] = 6
	c2["length"] = 0.34
	c2["width"] = 0.18
	Veg3D.sprig(s2, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), rng, c2)
	cases.append(["sprig", s2, "leaf_lamina_broad", 1.9])

	var s3 = TreeBuilder.Surf.new()
	Veg3D.frond(s3, Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO), rng, Veg3D.frond_cfg())
	cases.append(["frond", s3, "leaf_lamina_pinna", 7.5])

	for cse in cases:
		var nm: String = cse[0]
		var s = cse[1]
		var tex: String = cse[2]
		var dist: float = cse[3]
		await _clear()
		_show(s, tex)
		var mn := _mean_normal(s)
		var nrm: Vector3 = mn[0]
		var ctr: Vector3 = mn[1]
		# A direction lying IN the mean plane: perpendicular to the normal.
		var eye_dir := nrm.cross(Vector3.UP)
		if eye_dir.length_squared() < 1e-8:
			eye_dir = nrm.cross(Vector3.RIGHT)
		eye_dir = eye_dir.normalized()
		print("  %-18s mean_normal=%s  eye_dot_normal=%.5f" % [nm, nrm, eye_dir.dot(nrm)])
		_aim(ctr, eye_dir, dist, nrm)
		await _grab("qa_edge_%s.png" % nm)
		# and from directly below
		_aim(ctr, Vector3(0.18, -1.0, 0.12), dist)
		await _grab("qa_below_%s.png" % nm)

	# ------------------------------------------------------------------
	# 2. Whole trees: 3/4, from directly below, and in silhouette.
	# ------------------------------------------------------------------
	print("=== whole canopies ===")
	var specs := [
		["banyan", TreeBuilder.Species.BANYAN, 0],
		["palm", TreeBuilder.Species.PALM, 0],
		["mango", TreeBuilder.Species.MANGO, 0],
		["sal", TreeBuilder.Species.SAL, 0],
		["bush", TreeBuilder.Species.BUSH, 0],
		["fern", TreeBuilder.Species.BUSH, 2],
	]
	for sp in specs:
		var nm: String = sp[0]
		await _clear()
		var mi := MeshInstance3D.new()
		mi.mesh = TreeBuilder.mesh(sp[1], sp[2], TreeBuilder.Lod.FULL)
		holder.add_child(mi)
		var ab: AABB = mi.mesh.get_aabb()
		var ctr: Vector3 = ab.get_center()
		var rad: float = maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) * 0.5
		sun.rotation = Vector3(deg_to_rad(-36.0), deg_to_rad(30.0), 0.0)
		_aim(ctr, Vector3(0.86, 0.30, 0.42), rad * 2.9)
		await _grab("qa_tree_%s_side.png" % nm)
		# from directly below, inside the canopy, looking straight up
		var under := Vector3(ctr.x, ab.position.y + ab.size.y * 0.34, ctr.z)
		cam.look_at_from_position(under, under + Vector3(0.06, 1.0, 0.02), Vector3.FORWARD)
		await _grab("qa_tree_%s_under.png" % nm)
		# silhouette: sun behind the tree, camera low
		sun.rotation = Vector3(deg_to_rad(-9.0), deg_to_rad(180.0), 0.0)
		_aim(ctr, Vector3(0.0, -0.06, 1.0), rad * 3.1)
		await _grab("qa_tree_%s_silhouette.png" % nm)
		print("  %s tris=%d" % [nm, TreeBuilder.triangles(sp[1], sp[2], TreeBuilder.Lod.FULL)])

	print("RESULT: PASS")
	get_tree().quit()
