extends SceneTree
## Does GeometryInstance3D.visibility_range_end measure from the NODE ORIGIN or from the
## instance's transformed AABB?
##
## It matters here: Settlement._mm() adds every MultiMeshInstance3D as an untransformed
## child, so all eight of them sit at the world origin while their instances are up to
## 224 m away. If the range is measured from the node origin then RuinRubble
## (vis_end 230, props 224 m from the origin) pops out the moment the camera walks a few
## metres further from (0, 0) - nothing to do with how far it is from the rubble.
##
## Test: one MultiMesh whose single instance is 300 m from the origin, vis_end 50.
## Camera parked 10 m from the INSTANCE. If the instance draws, the range is measured
## from the geometry and the settlement is fine; if it does not, the range is measured
## from the node and every scatter in this system is mis-culled.


func _init() -> void:
	var root := get_root()
	DisplayServer.window_set_size(Vector2i(640, 400))
	await process_frame

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1, 1, 1)
	e.ambient_light_energy = 1.0
	env.environment = e
	root.add_child(env)

	var far := Vector3(300.0, 0.0, 0.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var bm := BoxMesh.new()
	bm.size = Vector3(4, 4, 4)
	mm.mesh = bm
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, far))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "FarBox"
	mmi.multimesh = mm
	mmi.custom_aabb = AABB(far - Vector3(3, 3, 3), Vector3(6, 6, 6))
	mmi.visibility_range_end = 50.0
	root.add_child(mmi)

	var cam := Camera3D.new()
	cam.far = 2000.0
	root.add_child(cam)
	cam.current = true
	await process_frame
	cam.global_position = far + Vector3(0, 2, 10)
	cam.look_at(far, Vector3.UP)

	for i in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var lit := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			if img.get_pixel(x, y).r > 0.25:
				lit += 1
	print("camera is 10 m from the instance and 300 m from the node origin")
	print("vis_end = 50 m; bright pixels = %d" % lit)
	if lit > 40:
		print("VERDICT: visibility_range is measured from the GEOMETRY - MultiMesh nodes")
		print("         at the world origin are culled correctly.")
	else:
		print("VERDICT: visibility_range is measured from the NODE ORIGIN - every")
		print("         Settlement MultiMesh is mis-culled and must carry a transform.")
	quit()
