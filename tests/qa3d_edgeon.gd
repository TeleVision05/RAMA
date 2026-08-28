extends Node
## QA: photograph every vegetation type ISOLATED, EDGE-ON and FROM BELOW, against a
## flat card rendered in the same rig as the control.
##
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . res://scenes/qa3d_edgeon.tscn
##
## "A flat card is invisible edge-on" is a claim about pixels, so this measures pixels.
## The camera orbits each subject at 36 azimuths on the horizon, dead level with the
## middle of the subject, and the covered-pixel count is recorded at each one. For a
## card that count collapses to nothing twice per revolution; the ratio min/mean is the
## number that separates geometry from paper, and CARD is in the list to calibrate it.
##
## Everything is drawn white-on-black with an unshaded material so the count is a
## silhouette area and not a lighting result.

const W := 480
const H := 480
const AZ := 36
const SHEET_COLS := 9

var _cam: Camera3D
var _holder: Node3D
var _rows: Array = []
var _fails: Array = []


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _subjects() -> Array:
	var out: Array = []
	# The control. Two triangles, no thickness — what the first pass shipped.
	out.append({"n": "CARD (control)", "mesh": _card(), "card": true})
	# The primitive on its own, so nothing else in the frame can fill in for it.
	out.append({"n": "one grass blade", "mesh": _one(_blade_cfg())})
	out.append({"n": "one petal", "mesh": _one(_petal_cfg())})
	var names := ["grass", "flower", "fern"]
	var sub := [["mat", "mid", "upright"], ["marigold", "jasmine", "hibiscus"], ["fern_a", "fern_b", "broadleaf"]]
	for l in range(3):
		for v in range(3):
			out.append({"n": "%s/%s" % [names[l], sub[l][v]], "mesh": Ground3D.mesh(l, v, 0)})
	# The far tier too: a LOD that collapsed to a card would be a pop the brief bans.
	out.append({"n": "grass/mat LOD2", "mesh": Ground3D.mesh(0, 0, 2)})
	out.append({"n": "grass/upright LOD2", "mesh": Ground3D.mesh(0, 2, 2)})
	return out


static func _blade_cfg() -> Dictionary:
	return {
		"origin": Vector3.ZERO,
		"dir": Vector3.UP,
		"bend": Vector3.RIGHT,
		"length": 0.21,
		"width": 0.011,
		"segs": 3,
		"ribs": 3,
		"droop": 1.55,
		"keel": 0.85,
		"twist": 0.6,
		"taper": 0.52,
		"bulge": 0.24,
		"dpow": 1.95,
	}


static func _petal_cfg() -> Dictionary:
	return {
		"origin": Vector3.ZERO,
		"dir": Vector3(0.6, 0.8, 0.0).normalized(),
		"bend": Vector3.RIGHT,
		"length": 0.06,
		"width": 0.016,
		"segs": 2,
		"ribs": 5,
		"droop": 0.9,
		"keel": -0.8,
		"twist": 0.15,
		"taper": 0.45,
		"bulge": 0.5,
	}


static func _one(cfg: Dictionary) -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	Ground3D._lamina(s, cfg)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	return m


## An alpha-cut quad of the same footprint as a tuft: the thing being replaced.
static func _card() -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	var w := 0.12
	var h := 0.30
	var a := s.vert(Vector3(-w, 0, 0), Vector3.BACK, Vector3.RIGHT, Color.WHITE, Vector2(0, 0))
	var b := s.vert(Vector3(w, 0, 0), Vector3.BACK, Vector3.RIGHT, Color.WHITE, Vector2(1, 0))
	var c := s.vert(Vector3(w, h, 0), Vector3.BACK, Vector3.RIGHT, Color.WHITE, Vector2(1, 1))
	var d := s.vert(Vector3(-w, h, 0), Vector3.BACK, Vector3.RIGHT, Color.WHITE, Vector2(0, 1))
	s.quad(a, b, c, d, Vector3.BACK)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	return m


func _run() -> void:
	var vp := get_viewport()
	vp.transparent_bg = false
	get_window().size = Vector2i(W, H)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	_holder = Node3D.new()
	add_child(_holder)
	_cam = Camera3D.new()
	_cam.near = 0.005
	_cam.far = 40.0
	add_child(_cam)
	_cam.current = true

	var unlit := StandardMaterial3D.new()
	unlit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	unlit.albedo_color = Color(1, 1, 1)
	unlit.cull_mode = BaseMaterial3D.CULL_DISABLED

	var subs := _subjects()
	var sheets: Array = []
	for s in subs:
		var mi := MeshInstance3D.new()
		mi.mesh = s.mesh
		mi.material_override = unlit
		_holder.add_child(mi)
		await get_tree().process_frame
		var aabb: AABB = s.mesh.get_aabb()
		var mid := aabb.get_center()
		var rad := maxf(aabb.size.length() * 0.5, 0.02)
		var dist := rad * 2.6

		var counts: Array = []
		var frames: Array = []
		for k in range(AZ):
			var a := TAU * float(k) / float(AZ)
			# Dead level with the middle of the subject: the elevation at which a card
			# genuinely vanishes. Any tilt at all lets a card catch light and the test
			# stops asking the question.
			var eye := mid + Vector3(cos(a), 0.0, sin(a)) * dist
			_cam.look_at_from_position(eye, mid, Vector3.UP)
			_cam.fov = 40.0
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			counts.append(_coverage(img))
			if k % 3 == 0:
				frames.append(img)
		# From directly below, looking up — the other view a flat ground decal fails.
		var below := mid - Vector3(0.02, rad * 2.2, 0.015)
		_cam.look_at_from_position(below, mid, Vector3.FORWARD)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img_b := vp.get_texture().get_image()
		var cov_b := _coverage(img_b)
		frames.append(img_b)

		var mn: float = counts.min()
		var mx: float = counts.max()
		var sum := 0.0
		for c in counts:
			sum += c
		var mean := sum / float(counts.size())
		var ratio := mn / maxf(mean, 1e-9)
		_rows.append(
			"%-22s  min %6.4f  mean %6.4f  max %6.4f   min/mean %5.1f%%   from-below %6.4f" % [s.n, mn, mean, mx, ratio * 100.0, cov_b]
		)
		if not s.get("card", false):
			if ratio < 0.30:
				_fails.append("%s collapses edge-on: min/mean %.1f%%" % [s.n, ratio * 100.0])
			if cov_b < 0.004:
				_fails.append("%s nearly invisible from below: %.4f coverage" % [s.n, cov_b])
		sheets.append({"n": s.n, "frames": frames})
		_holder.remove_child(mi)
		mi.queue_free()

	_write_sheets(sheets)
	print("")
	print("== EDGE-ON SILHOUETTE COVERAGE (fraction of frame, orbit at 0 deg elevation) ==")
	for r in _rows:
		print(r)
	print("")
	if _fails.is_empty():
		print("RESULT: PASS  (nothing collapses edge-on or from below)")
	else:
		for f in _fails:
			print("  ! %s" % f)
		print("RESULT: FAIL  (%d subjects read as flat)" % _fails.size())
	get_tree().quit()


static func _coverage(img: Image) -> float:
	var n := 0
	var total := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			total += 1
			if img.get_pixel(x, y).r > 0.10:
				n += 1
	return float(n) / float(total)


func _write_sheets(sheets: Array) -> void:
	var th := 160
	for s in sheets:
		var frames: Array = s.frames
		var cols := mini(SHEET_COLS, frames.size())
		var rows_n := int(ceil(float(frames.size()) / float(cols)))
		var sheet := Image.create(cols * th, rows_n * th, false, Image.FORMAT_RGB8)
		sheet.fill(Color(0.05, 0.05, 0.06))
		for i in range(frames.size()):
			var f: Image = frames[i]
			f.resize(th, th, Image.INTERPOLATE_LANCZOS)
			if f.get_format() != Image.FORMAT_RGB8:
				f.convert(Image.FORMAT_RGB8)
			sheet.blit_rect(f, Rect2i(0, 0, th, th), Vector2i((i % cols) * th, (i / cols) * th))
		var safe: String = (s.n as String).replace("/", "_").replace(" ", "_").replace("(", "").replace(")", "")
		sheet.save_png("res://build/screenshots/qa3d_%s.png" % safe)
