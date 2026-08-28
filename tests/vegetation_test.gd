extends SceneTree
## Vegetation in the real world: terrain + sky + scatter, photographed from the places
## the brief names. Ground-level shots are what decide whether the forest is dense and
## enclosing; the aerial and lookout shots decide whether it reads as a canopy.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/vegetation_test.gd
## (no --headless: headless renders nothing)

const OUT := "res://build/screenshots/%s.png"

# p: eye XZ, eye: metres above ground, t: target XZ, tgt: metres above ground there,
# h: hour of day, fov: optional.
const SHOTS := [
	{"n": "forest_ground", "p": Vector2(-196, -34), "eye": 1.75, "t": Vector2(-232, -74), "tgt": 3.0, "h": 10.5},
	{"n": "forest_deep", "p": Vector2(-244, 40), "eye": 1.75, "t": Vector2(-286, 96), "tgt": 6.0, "h": 15.2},
	{"n": "forest_backlit", "p": Vector2(-210, -10), "eye": 2.0, "t": Vector2(-260, -60), "tgt": 12.0, "h": 17.0},
	{"n": "village_banyan", "p": Vector2(-127, 71), "eye": 2.4, "t": Vector2(-105, 55), "tgt": 9.0, "h": 9.0},
	{"n": "banyan_under", "p": Vector2(-96, 47), "eye": 1.8, "t": Vector2(-108, 56), "tgt": 6.0, "h": 10.4},
	{"n": "village_wide", "p": Vector2(-120, 108), "eye": 8.0, "t": Vector2(-120, 44), "tgt": 3.0, "h": 8.2},
	{"n": "river_ford", "p": Vector2(-8, 44), "eye": 2.6, "t": Vector2(-40, 4), "tgt": 1.0, "h": 16.0},
	{"n": "river_bank", "p": Vector2(-64, -26), "eye": 2.2, "t": Vector2(-24, 14), "tgt": 3.0, "h": 11.0},
	{"n": "meadow_grass", "p": Vector2(-96, 12), "eye": 1.5, "t": Vector2(-130, 40), "tgt": 2.0, "h": 9.4},
	{
		"n": "lookout_valley",
		"p": Vector2(96, -150),
		"eye": 22.0,
		"t": Vector2(-120, -40),
		"tgt": 10.0,
		"h": 15.6,
		"fov": 66.0
	},
	{
		"n": "canopy_above",
		"p": Vector2(-150, 0),
		"eye": 78.0,
		"t": Vector2(-250, -70),
		"tgt": 8.0,
		"h": 12.0,
		"fov": 70.0
	},
	{"n": "badlands", "p": Vector2(168, 122), "eye": 6.5, "t": Vector2(214, 178), "tgt": 6.0, "h": 16.8},
	{"n": "ruins", "p": Vector2(-168, -104), "eye": 3.0, "t": Vector2(-168, -148), "tgt": 2.0, "h": 10.5},
]


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(true)
	var m := world.map

	var veg := Vegetation.new()
	veg.name = "Vegetation"
	root.add_child(veg)
	veg.setup(m)
	veg.set_wind(world.sky.wind_dir, world.sky.wind_strength, 1.0)

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	cam.near = 0.12
	root.add_child(cam)
	cam.current = true

	await process_frame
	for s in SHOTS:
		world.sky.paused = true
		world.sky.set_time(s.h)
		cam.fov = s.get("fov", 62.0)
		var eye := Vector3(s.p.x, m.height_at(s.p.x, s.p.y) + s.eye, s.p.y)
		var tgt := Vector3(s.t.x, m.height_at(s.t.x, s.t.y) + s.tgt, s.t.y)
		cam.global_position = eye
		cam.look_at(tgt, Vector3.UP)
		world.terrain.update_focus(eye, true)
		var t0 := Time.get_ticks_msec()
		veg.update_focus(eye, true)
		var build_ms := Time.get_ticks_msec() - t0
		# 10 frames was not enough to settle. The same viewpoint measured mean luminance
		# 17.9 here and 30.3 in a harness that rendered it alone: SSIL and the volumetric
		# fog are temporally accumulated, and after a camera teleport they need real
		# frames to converge or the shot is judged on a half-built history buffer.
		for i in range(34):
			await process_frame
		await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png(OUT % ("veg_" + s.n))
		var st := veg.stats()
		print(
			(
				"%-15s stream %4d ms | tri %6d (tree %6d grass %5d) | inst %5d lod %s | nodes %d"
				% [
					s.n,
					build_ms,
					st.total_triangles,
					st.tree_triangles,
					st.grass_triangles,
					st.drawn_instances,
					str(st.by_lod),
					st.draw_nodes
				]
			)
		)

	# Streaming check: walk the focus across the map WITHOUT the immediate flag, the way
	# the game will, and confirm the incremental path keeps up and does not leak nodes.
	var walk_from := Vector3(-240.0, 0.0, -60.0)
	var walk_to := Vector3(-60.0, 0.0, 60.0)
	var worst := 0
	var total := 0
	var steps := 40
	for i in range(steps):
		var p3 := walk_from.lerp(walk_to, float(i) / float(steps - 1))
		p3.y = m.height_at(p3.x, p3.z) + 1.8
		var t1 := Time.get_ticks_msec()
		veg.update_focus(p3)
		var dt := Time.get_ticks_msec() - t1
		worst = maxi(worst, dt)
		total += dt
		await process_frame
	print(
		(
			"streamed walk : %d steps, worst %d ms, mean %.1f ms, veg child nodes %d"
			% [steps, worst, float(total) / float(steps), veg.get_child_count()]
		)
	)

	var st2 := veg.stats()
	print("---")
	print("placed        : %d (canopy trees %d)" % [st2.placed, st2.canopy])
	print("by species    : %s" % str(st2.by_species))
	print("grass cells   : %d, instances %d" % [st2.grass_cells, st2.grass_instances])
	print("done")
	quit()
