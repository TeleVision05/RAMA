extends SceneTree
## Isolates the hard straight seam that runs across the river in the low bank shots.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/probes/probe_water_seam.gd
##
## Four renders of ONE viewpoint, each killing a different suspect, so the seam can be
## attributed instead of guessed at:
##   seam_all        everything on - the reference
##   seam_norefr     screen-space refraction off  (suspect: the ruv rejection branch)
##   seam_onechunk   only the nearest River_* mesh drawn (suspect: two alpha-blended
##                   ribbon chunks overlapping in screen space and double-blending)
##   seam_depth      debug_mode 1, the reconstructed optical depth on its own

const EYE := Vector2(-30, 26)
const TGT := Vector2(-26, -14)


func bank(m: WorldMap, p: Vector2) -> Vector2:
	var q := p
	for _i in range(80):
		if m.height_at(q.x, q.y) > m.water_y_at(q.x, q.y) + 1.2:
			return q
		var g := Vector2(
			m.river_dist(q + Vector2(1, 0)) - m.river_dist(q - Vector2(1, 0)),
			m.river_dist(q + Vector2(0, 1)) - m.river_dist(q - Vector2(0, 1))
		)
		if g.length() < 1e-4:
			g = Vector2(1, 0)
		q += g.normalized() * 1.5
	return q


func shot(root: Viewport, nm: String) -> void:
	for _i in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/probe_%s.png" % nm)
	print("wrote probe_%s" % nm)


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map
	var water := RiverWater.new()
	water.name = "Water"
	world.add_child(water)
	water.setup(m, world.sky)

	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2000.0
	cam.near = 0.12
	root.add_child(cam)
	cam.current = true
	await process_frame
	world.sky.paused = true
	world.sky.set_time(15.5)
	water.refresh_sky()

	var ep := bank(m, EYE)
	var eye := Vector3(ep.x, m.height_at(ep.x, ep.y) + 0.9, ep.y)
	cam.global_position = eye
	cam.look_at(Vector3(TGT.x, m.height_at(TGT.x, TGT.y) + 0.3, TGT.y), Vector3.UP)
	world.terrain.update_focus(eye, true)

	await shot(root, "seam_all")

	water.set_refraction(false)
	await shot(root, "seam_norefr")
	water.set_refraction(true)

	# Which River_* chunks are on screen at all, and how far away each one is.
	var chunks: Array = []
	for c in water.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("River"):
			var aabb: AABB = (c as MeshInstance3D).get_aabb()
			var d: float = eye.distance_to(aabb.get_center())
			chunks.append([d, c])
			print("  %-10s centre %s  dist %.1f m" % [c.name, aabb.get_center(), d])
	chunks.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for e in chunks:
		(e[1] as MeshInstance3D).visible = false
	if not chunks.is_empty():
		(chunks[0][1] as MeshInstance3D).visible = true
		print("  keeping only %s" % (chunks[0][1] as MeshInstance3D).name)
	await shot(root, "seam_onechunk")
	for e in chunks:
		(e[1] as MeshInstance3D).visible = true

	water.set_debug(1)
	await shot(root, "seam_depth")
	water.set_debug(0)
	print("done")
	quit()
