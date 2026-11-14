extends SceneTree
## Render harness for the river Godavari. Builds the world plus RiverWater, audits the
## generated geometry numerically, then renders the named viewpoints so the result can
## actually be LOOKED at.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/probes/water_test.gd
##
## (no --headless: headless renders an empty image)

const DEBUG_MODE := 0  # 0 off, 1 depth, 2 vertex colour, 3 normal

## "bank": push the eye out of the channel until it is standing on dry ground - a
## camera dropped on the centreline ends up under the surface, looking at the riverbed.
const SHOTS := [
	{"n": "ford_noon", "p": Vector2(-20, 20), "eye": 2.2, "t": Vector2(-40, -6), "tgt": 0.4, "h": 12.0, "bank": true},
	{"n": "ford_dusk", "p": Vector2(-20, 20), "eye": 2.2, "t": Vector2(-40, -6), "tgt": 0.4, "h": 17.7, "bank": true},
	{"n": "ford_low", "p": Vector2(-30, 26), "eye": 0.9, "t": Vector2(-26, -14), "tgt": 0.3, "h": 15.5, "bank": true},
	# straight down at the ford: does the ribbon fill the channel bank to bank?
	{"n": "ford_top", "p": Vector2(-34, 10), "eye": 44.0, "t": Vector2(-34, 8), "tgt": 0.0, "h": 12.0},
	# the falls, from the plunge basin looking back up the gorge
	{"n": "falls_noon", "p": Vector2(31, -152), "eye": 10.0, "t": Vector2(35, -191), "tgt": 7.0, "h": 12.0, "w": 44},
	{"n": "falls_dusk", "p": Vector2(31, -152), "eye": 10.0, "t": Vector2(35, -191), "tgt": 7.0, "h": 17.7, "w": 44},
	# the falls from the side, at the height of the lip
	{"n": "falls_side", "p": Vector2(58, -178), "eye": 5.0, "t": Vector2(34, -191), "tgt": 6.0, "h": 12.0, "w": 44},
	# the plunge pool and its mist
	{"n": "plunge", "p": Vector2(52, -160), "eye": 5.0, "t": Vector2(34, -184), "tgt": 1.0, "h": 12.0, "w": 44, "bank": true},
	# the wide lower river
	{"n": "lower_noon", "p": Vector2(-136, 128), "eye": 4.0, "t": Vector2(-176, 162), "tgt": 0.6, "h": 12.0, "bank": true},
	{"n": "lower_dusk", "p": Vector2(-136, 128), "eye": 4.0, "t": Vector2(-176, 162), "tgt": 0.6, "h": 17.6, "bank": true},
	# from the lookout, down the valley
	{"n": "lookout_noon", "p": Vector2(96, -150), "eye": 6.0, "t": Vector2(-2, -84), "tgt": 2.0, "h": 12.0},
	{"n": "lookout_dusk", "p": Vector2(96, -150), "eye": 6.0, "t": Vector2(-2, -84), "tgt": 2.0, "h": 17.5},
	# standing water. "pool": aim at the pond RiverWater actually found.
	{"n": "grove_pond", "p": Vector2(0, 0), "eye": 2.6, "t": Vector2(0, 0), "tgt": 0.1, "h": 12.0, "pool": 0, "off": Vector2(13, -11)},
	{"n": "well_pool", "p": Vector2(-106, 45), "eye": 2.0, "t": Vector2(-113, 51), "tgt": 0.3, "h": 12.0},
	# The south-west exit, where the ribbon is clipped at the world edge. The grounding
	# audit still counts ~55 rim cells hanging over open channel out here; this is the
	# shot that says whether that is visible.
	{"n": "exit_sw", "p": Vector2(-352, 288), "eye": 16.0, "t": Vector2(-381, 316), "tgt": 0.0, "h": 12.0},
]


## Walk away from the river until the ground is clear of the local water surface.
func bank(m: WorldMap, p: Vector2) -> Vector2:
	var q := p
	for i in range(80):
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


## Mean colour of a fractional rectangle of the frame, centre (cx, cy), size (w, h).
func patch(img: Image, cx: float, cy: float, w: float, h: float) -> Color:
	var x0: int = int((cx - w * 0.5) * float(img.get_width()))
	var x1: int = int((cx + w * 0.5) * float(img.get_width()))
	var y0: int = int((cy - h * 0.5) * float(img.get_height()))
	var y1: int = int((cy + h * 0.5) * float(img.get_height()))
	var acc := Vector3.ZERO
	var n := 0
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			var p := img.get_pixel(x, y)
			acc += Vector3(p.r, p.g, p.b)
			n += 1
	acc /= maxf(float(n), 1.0)
	return Color(acc.x, acc.y, acc.z)


func audit(water: RiverWater) -> void:
	var bad_wind := 0
	var tris := 0
	var verts := 0
	var floaters := 0
	var worst := 0.0
	for child in water.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi: MeshInstance3D = child
		if mi.name.begins_with("WellKerb"):
			continue
		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		verts += v.size()
		var i := 0
		while i < idx.size():
			var a: Vector3 = v[idx[i]]
			var b: Vector3 = v[idx[i + 1]]
			var c: Vector3 = v[idx[i + 2]]
			# Godot front faces are CLOCKWISE, so the outward normal of a front face is
			# -cross(b-a, c-a). Checked against the terrain mesher's known-good winding.
			var n := -(b - a).cross(c - a)
			if n.length_squared() > 1e-9 and n.normalized().y < 0.0:
				bad_wind += 1
			tris += 1
			i += 3
		# No vertex of the FLAT river may float above the ground on its own bank. (The
		# waterfall is excluded: it is near vertical, so its own edge vertices sit tens
		# of metres above the water surface sampled at their x/z.)
		if mi.name.begins_with("River"):
			for p in v:
				var d: float = p.y - water.map.water_y_at(p.x, p.z)
				if d > 0.30:
					floaters += 1
					worst = maxf(worst, d)
	print(
		"[audit] %d tris, %d verts, downward-facing=%d, floating river verts=%d (worst %.2f m)" % [tris, verts, bad_wind, floaters, worst]
	)
	for q in [Vector2(-34, 8), Vector2(34, -184), Vector2(-150, 140), Vector2(-120, 44)]:
		print(
			(
				"[audit] water_height_at%s = %.2f  depth=%.2f  in_water(y=0)=%s"
				% [q, water.water_height_at(q.x, q.y), water.water_depth_at(q.x, q.y), water.is_in_water(Vector3(q.x, 0.0, q.y))]
			)
		)
	for p in water.pools():
		print("[audit] pool at %s level=%.2f r=%.1f" % [p.c, p.level, p.r])


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(true)
	var m := world.map

	var water := RiverWater.new()
	water.name = "Water"
	world.add_child(water)
	water.setup(m, world.sky)
	if DEBUG_MODE != 0:
		water.set_debug(DEBUG_MODE)
	audit(water)
	var pools: Array = water.pools()

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
		water.refresh_sky()
		var ep: Vector2 = s.p
		var tp: Vector2 = s.t
		if s.has("pool") and int(s.pool) < pools.size():
			var pool: Dictionary = pools[int(s.pool)]
			tp = pool.c
			ep = pool.c + (s.off as Vector2)
		if s.get("bank", false):
			ep = bank(m, ep)
		var eye := Vector3(ep.x, m.height_at(ep.x, ep.y) + s.eye, ep.y)
		var tgt := Vector3(tp.x, m.height_at(tp.x, tp.y) + s.tgt, tp.y)
		cam.global_position = eye
		cam.look_at(tgt, Vector3.UP)
		world.terrain.update_focus(eye, true)
		var w: int = s.get("w", 16)
		for i in range(w):
			await process_frame
		await RenderingServer.frame_post_draw
		var img: Image = root.get_texture().get_image()
		img.save_png("res://build/screenshots/water_%s.png" % s.n)
		# A measured number for the middle of the frame, so "the river is too dark" and
		# "the river is blown out" are claims with evidence rather than impressions.
		var c := patch(img, 0.5, 0.62, 0.16, 0.14)
		print(
			(
				"%-13s eye=%.1f,%.1f,%.1f -> %.1f,%.1f,%.1f | centre rgb %.3f %.3f %.3f  luma %.3f"
				% [s.n, eye.x, eye.y, eye.z, tgt.x, tgt.y, tgt.z, c.r, c.g, c.b, c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722]
			)
		)
	print("done")
	quit()
