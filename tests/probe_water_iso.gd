extends SceneTree
## Isolates which term of water.gdshader is blowing the surface out to white when the
## sun and the eye are both near the vertical. One camera, four renders, one variable
## changed at a time.

const VARIANTS := [
	{"n": "base", "p": {}},
	{"n": "nospec", "p": {"glitter_gain": 0.0, "rough_calm": 0.95, "rough_churn": 0.95}},
	{"n": "hi_glit", "p": {"glitter_gain": 3.0}},
]


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map
	var water := RiverWater.new()
	world.add_child(water)
	water.setup(m)
	var mat: ShaderMaterial = null
	for c in water.get_children():
		if c is MeshInstance3D and c.name.begins_with("River"):
			mat = c.material_override
			break

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	root.add_child(cam)
	cam.current = true
	await process_frame
	world.sky.paused = true
	world.sky.set_time(12.0)
	var eye := Vector3(-34.0, m.height_at(-34, 10) + 44.0, 10.0)
	cam.global_position = eye
	cam.look_at(Vector3(-34.0, m.height_at(-34, 8), 8.0), Vector3.UP)
	world.terrain.update_focus(eye, true)

	for v in VARIANTS:
		# reset, then apply this variant's overrides
		for k in ["glitter_gain", "rough_calm", "rough_churn", "sky_gain", "absorb_rate", "specular_f0"]:
			mat.set_shader_parameter(k, null)
		for k in v.p:
			mat.set_shader_parameter(k, v.p[k])
		for i in range(10):
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("res://build/screenshots/iso_%s.png" % v.n)
		# average the middle of the river so the change is a number, not an impression
		var sum := Vector3.ZERO
		var n := 0
		for y in range(380, 520, 4):
			for x in range(700, 1000, 4):
				var c := img.get_pixel(x, y)
				sum += Vector3(c.r, c.g, c.b)
				n += 1
		sum /= float(n)
		print("%-12s mid-river mean rgb = %.3f %.3f %.3f" % [v.n, sum.x, sum.y, sum.z])
	quit()
