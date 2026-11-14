extends SceneTree
## Species gallery. Lines every tree up on flat ground under a real sky and photographs
## the row at each LOD, then close-ups. This is the fast loop for judging SILHOUETTE and
## MATERIAL — the world flythrough is for judging density and placement.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/veg_gallery.gd
## (no --headless: headless renders nothing)

const OUT := "res://build/screenshots/%s.png"
const SPACING := 13.0

var _root: Node3D
var _cam: Camera3D
var _sky: SkySystem
var _rows: Array[Node3D] = []


func _init() -> void:
	var root := get_root()
	_root = Node3D.new()
	root.add_child(_root)

	_sky = SkySystem.new()
	_root.add_child(_sky)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(1200, 1200)
	pm.subdivide_width = 8
	pm.subdivide_depth = 8
	ground.mesh = pm
	ground.material_override = Mats.pbr("grass", 40.0)
	_root.add_child(ground)

	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.far = 2000.0
	_cam.near = 0.1
	root.add_child(_cam)
	_cam.current = true

	for lod in range(TreeBuilder.LOD_COUNT):
		var row := Node3D.new()
		row.visible = false
		_root.add_child(row)
		_rows.append(row)
		var x := 0.0
		for sp in range(TreeBuilder.SPECIES_COUNT):
			for va in range(TreeBuilder.VARIANTS):
				var m := TreeBuilder.mesh(sp, va, lod)
				if m.get_surface_count() == 0:
					x += SPACING
					continue
				_spawn(row, m, Vector3(x, 0, 0), float(va) * 0.31 + float(sp) * 0.17)
				x += SPACING

	await process_frame
	await process_frame

	_sky.paused = true
	_sky.set_time(9.6)
	TreeBuilder.set_wind(Vector2(0.82, 0.57), 0.55, 1.0)

	# Each LOD has to be photographed at a distance where its own material is the one
	# the shader keeps: LOD1 discards past LOD_MID_END and LOD2 discards inside it, so a
	# single camera distance would show two of the three rows as empty ground.
	var span := SPACING * float(TreeBuilder.SPECIES_COUNT * TreeBuilder.VARIANTS)
	var lod_dist := [44.0, 74.0, 150.0]
	for lod in range(TreeBuilder.LOD_COUNT):
		for r in _rows:
			r.visible = false
		_rows[lod].visible = true
		for pan in range(3):
			var cx := span * (float(pan) * 2.0 + 1.0) / 6.0
			await _shot("gal_lod%d_%d" % [lod, pan], Vector3(cx, 12.0, lod_dist[lod]), Vector3(cx, 7.0, 0.0))

	for r in _rows:
		r.visible = false
	_rows[0].visible = true

	# Close-ups, one per species, framed on that species' three variants.
	var names := TreeBuilder.SPECIES_NAMES
	for sp in range(TreeBuilder.SPECIES_COUNT):
		var cx := (float(sp) * float(TreeBuilder.VARIANTS) + 1.0) * SPACING
		var h: float = [15.0, 17.0, 11.0, 22.0, 10.0, 1.6, 1.4][sp]
		var dist: float = [32.0, 34.0, 22.0, 40.0, 20.0, 5.0, 4.5][sp]
		await _shot("gal_%s" % names[sp], Vector3(cx, maxf(1.4, h * 0.42), dist), Vector3(cx, h * 0.40, 0.0))

	# Backlit: the sun low and behind the row, which is the shot that proves the
	# translucency term is doing something.
	_sky.set_time(17.4)
	await _shot("gal_backlit", Vector3(SPACING * 4.0, 7.0, 34.0), Vector3(SPACING * 4.0, 8.0, 0.0))

	print("[gallery] triangle counts")
	for sp in range(TreeBuilder.SPECIES_COUNT):
		var line := "  %-7s" % names[sp]
		for lod in range(TreeBuilder.LOD_COUNT):
			var t := 0
			for va in range(TreeBuilder.VARIANTS):
				t += TreeBuilder.triangles(sp, va, lod)
			line += "  lod%d avg %5d" % [lod, t / TreeBuilder.VARIANTS]
		print(line)
	print("done")
	quit()


func _spawn(parent: Node3D, m: ArrayMesh, pos: Vector3, seedf: float) -> void:
	# One-instance MultiMesh rather than a MeshInstance3D: the shaders read
	# INSTANCE_CUSTOM for tint and phase, and a plain MeshInstance3D leaves it zero,
	# which would show every tree at the dim end of its brightness range.
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = m
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis(Vector3.UP, seedf * 4.0), pos))
	mm.set_instance_custom_data(0, Color(fmod(seedf * 3.7, 1.0), 1.0, fmod(seedf * 1.7, 1.0), 0.15))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.custom_aabb = AABB(pos + Vector3(-14, -2, -14), Vector3(28, 34, 28))
	parent.add_child(mi)


func _shot(name: String, eye: Vector3, target: Vector3) -> void:
	_cam.global_position = eye
	_cam.look_at(target, Vector3.UP)
	for i in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(OUT % name)
	print("[gallery] %s" % name)
