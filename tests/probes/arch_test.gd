extends SceneTree
## Isolated turntable of every Arch piece on a flat pad, so winding, materials and
## proportions can be judged before anything is placed in the world.

var square_seed := 0
var square_seed2 := 0


func _find_square_seeds() -> void:
	var found: Array = []
	for i in range(1, 400):
		var r := Arch.rng(i)
		if r.randf() >= 0.58:
			found.append(i)
		if found.size() >= 2:
			break
	square_seed = found[0]
	square_seed2 = found[1]
	print("square hut seeds: ", found)


func _init() -> void:
	_find_square_seeds()
	var root := get_root()
	var world := Node3D.new()
	root.add_child(world)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var pm := ProceduralSkyMaterial.new()
	pm.sky_top_color = Color(0.32, 0.50, 0.80)
	pm.sky_horizon_color = Color(0.85, 0.78, 0.62)
	pm.ground_bottom_color = Color(0.35, 0.28, 0.20)
	pm.ground_horizon_color = Color(0.66, 0.58, 0.44)
	sky.sky_material = pm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = true
	env.environment = e
	world.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.5
	sun.light_color = Color(1.0, 0.94, 0.83)
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-42, 128, 0)
	world.add_child(sun)

	var ground := MeshInstance3D.new()
	var pl := PlaneMesh.new()
	pl.size = Vector2(400, 400)
	ground.mesh = pl
	ground.material_override = Mats.pbr("dirt", 12.0)
	world.add_child(ground)

	var items := [
		["hut0", Arch.hut(1), Vector3(0, 0, 0)],
		["hut1", Arch.hut(2), Vector3(10, 0, 0)],
		["hut2", Arch.hut(square_seed), Vector3(20, 0, 0)],
		["hut3", Arch.hut(square_seed2), Vector3(-10, 0, 0)],
		["gran", Arch.granary(3), Vector3(28, 0, 0)],
		["well", Arch.well(), Vector3(36, 0, 0)],
		["cart", Arch.cart(1), Vector3(44, 0, 0)],
		["rack", Arch.drying_rack(1), Vector3(52, 0, 0)],
		["wash", Arch.washing_line(1), Vector3(60, 0, 0)],
		["fire", Arch.firepit(1), Vector3(68, 0, 0)],
		["lamp", Arch.oil_lamp(true), Vector3(72, 0, 0)],
		["gate", Arch.gate(1), Vector3(80, 0, 0)],
		["small", Arch.shrine_small(1), Vector3(88, 0, 0)],
		["lean", Arch.lean_to(1), Vector3(96, 0, 0)],
		["rw0", Arch.ruin_wall(1), Vector3(0, 0, 14)],
		["rw1", Arch.ruin_wall(4), Vector3(10, 0, 14)],
		["bp", Arch.broken_pillar(1), Vector3(18, 0, 14)],
		["bp2", Arch.broken_pillar(9), Vector3(22, 0, 14)],
		["fl", Arch.fallen_lintel(1), Vector3(28, 0, 14)],
		["bridge", Arch.bridge(24.0), Vector3(50, 0, 20)],
		["steps", Arch.stone_steps(Vector3(70, 0, 14), Vector3(76, 3.0, 14), 3.5), Vector3.ZERO],
		["shrine", Arch.shrine(2.6), Vector3(0, 1.45, -34)],
	]
	for it in items:
		var n: Node3D = it[1]
		n.position = it[2]
		world.add_child(n)

	# small props on a row
	for i in range(6):
		var p := MeshInstance3D.new()
		p.mesh = Arch.water_pot_mesh(i)
		p.position = Vector3(96 + i * 1.0, 0, 8)
		world.add_child(p)
		var b := MeshInstance3D.new()
		b.mesh = Arch.basket_mesh(i)
		b.position = Vector3(96 + i * 1.0, 0, 10)
		world.add_child(b)
	for i in range(5):
		var s := MeshInstance3D.new()
		s.mesh = Arch.stake_mesh(i)
		s.position = Vector3(102 + i * 0.8, 0, 12)
		world.add_child(s)
		var bo := MeshInstance3D.new()
		bo.mesh = Arch.bone_mesh(i)
		bo.position = Vector3(102 + i * 0.8, 0, 14)
		world.add_child(bo)
		var ms := MeshInstance3D.new()
		ms.mesh = Arch.milestone_mesh(i)
		ms.position = Vector3(102 + i * 0.8, 0, 16)
		world.add_child(ms)

	var fence_pts: Array = []
	for i in range(7):
		fence_pts.append(Vector3(60 + float(i) * 1.6, 0, -6))
	world.add_child(Arch.fence(fence_pts, 1.15, 3))

	var bund_pts: Array = []
	for i in range(9):
		bund_pts.append(Vector3(60 + float(i) * 1.6, 0, -10))
	world.add_child(Arch.bund(bund_pts))

	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.far = 900.0
	root.add_child(cam)
	cam.current = true

	var shots := [
		["village_row", Vector3(24, 9, 30), Vector3(24, 2, 2)],
		["hut_close", Vector3(7, 2.6, 0.4), Vector3(1.5, 1.6, 0)],
		["hut_sq", Vector3(27, 2.8, 1.0), Vector3(20, 1.7, 0)],
		["hut_sq2", Vector3(-3, 3.2, 6.0), Vector3(-10, 1.7, 0)],
		["hut_close2", Vector3(24, 3.0, 9), Vector3(20, 1.8, 0)],
		["props", Vector3(96, 4, 22), Vector3(101, 0.6, 12)],
		["fire_close", Vector3(70.5, 1.8, 3.2), Vector3(68, 0.7, 0)],
		["pot_close", Vector3(98, 1.4, 5.0), Vector3(98.5, 0.3, 8.6)],
		["ruins", Vector3(12, 6, 30), Vector3(12, 1.2, 14)],
		["bridge", Vector3(50, 6, 34), Vector3(50, 1.0, 20)],
		["shrine_far", Vector3(38, 8, -34), Vector3(0, 7, -34)],
		["steps", Vector3(72, 4.5, 22), Vector3(73, 1.4, 14)],
		["shrine_near", Vector3(21, 3.2, -34), Vector3(2, 4.5, -34)],
		["shrine_3q", Vector3(20, 13, -20), Vector3(0, 6, -34)],
		["shrine_top", Vector3(16, 22, -46), Vector3(0, 11, -34)],
	]
	await process_frame
	await process_frame
	for s in shots:
		cam.global_position = s[1]
		cam.look_at(s[2], Vector3.UP)
		for i in range(6):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/screenshots/arch_%s.png" % s[0])
		print("shot ", s[0])
	print("done")
	quit()
