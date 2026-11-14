extends SceneTree
## Studio harness for the rakshasas and the vyaghra.
##
## `tests/probes/enemy_shots.gd` photographs them in the village, which is where they are
## finally judged but a slow and noisy loop: it boots a whole session, the sun moves,
## the grass is taller than the tiger and one of the four frames it produced was the
## death screen. This renders the same four archetypes in a controlled studio so the
## FORM can be read — beside Rama for scale, backlit in silhouette, close up, and the
## beast mid-stride from the side.
##
## Run it as a WINDOWED script (no --headless): the dummy renderer saves black PNGs.
##   ~/tools/Godot.app/Contents/MacOS/Godot --path . --script tests/probes/creature_shots.gd
## Optional user args after `--`: a shot name to render only that one.

const OUT := "res://build/screenshots/creature_%s.png"
const KINDS := [EnemyTypes.Kind.WARRIOR, EnemyTypes.Kind.ARCHER, EnemyTypes.Kind.ELITE, EnemyTypes.Kind.BEAST]

var w: Node3D
var cam: Camera3D
var env: Environment
var key: DirectionalLight3D
var fill: DirectionalLight3D
var back: DirectionalLight3D
var floor_mi: MeshInstance3D
var only := ""


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		only = a
	_studio()
	await process_frame
	await _run()
	print("done")
	quit()


func _studio() -> void:
	var root := get_root()
	w = Node3D.new()
	root.add_child(w)
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.15, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.78)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_white = 8.0
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	w.add_child(we)

	key = DirectionalLight3D.new()
	key.light_energy = 2.6
	key.shadow_enabled = true
	key.light_color = Color(1.0, 0.95, 0.88)
	w.add_child(key)
	key.look_at_from_position(Vector3(4, 6, 5), Vector3.ZERO, Vector3.UP)
	fill = DirectionalLight3D.new()
	fill.light_energy = 0.5
	fill.light_color = Color(0.6, 0.72, 1.0)
	w.add_child(fill)
	fill.look_at_from_position(Vector3(-5, 2, -3), Vector3.ZERO, Vector3.UP)
	back = DirectionalLight3D.new()
	back.light_energy = 0.0
	back.light_color = Color(1.0, 0.97, 0.92)
	w.add_child(back)
	back.look_at_from_position(Vector3(0, 4, 9), Vector3.ZERO, Vector3.UP)

	floor_mi = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor_mi.mesh = pm
	floor_mi.material_override = Mats.flat(Color(0.30, 0.28, 0.24), 0.95)
	w.add_child(floor_mi)

	cam = Camera3D.new()
	cam.fov = 40.0
	root.add_child(cam)
	cam.current = true


# ===========================================================================
#  BUILDERS
# ===========================================================================
func _make(kind: int, seed_v: int) -> Dictionary:
	var holder := Node3D.new()
	w.add_child(holder)
	var parts := EnemyTypes.build_body(kind, holder, seed_v)
	var gf := func(_x: float, _z: float) -> float: return 0.0
	if parts.get("rig") != null:
		(parts["rig"] as ProcRig).ground_fn = gf
	if parts.get("beast") != null:
		(parts["beast"] as BeastRig).ground_fn = gf
	parts["holder"] = holder
	parts["kind"] = kind
	return parts


func _make_rama() -> ProcRig:
	var holder := Node3D.new()
	w.add_child(holder)
	var rig := ProcRig.new()
	rig.configure({"seed": 1, "topknot": true, "jewellery": true})
	holder.add_child(rig)
	rig.build()
	rig.ground_fn = func(_x: float, _z: float) -> float: return 0.0
	return rig


func _settle(parts: Array, speed: float, frames: int = 60) -> void:
	for f in range(frames):
		for p in parts:
			_step(p, speed, 1.0 / 60.0)
		if f % 12 == 0:
			await process_frame


func _step(p: Variant, speed: float, dt: float) -> void:
	if p is ProcRig:
		(p as ProcRig).animate(dt, {"speed": speed, "on_floor": true})
		return
	if p is BeastRig:
		(p as BeastRig).animate(dt, {"speed": speed, "on_floor": true})
		return
	var d: Dictionary = p
	if d.get("rig") != null:
		(d["rig"] as ProcRig).animate(dt, {"speed": speed, "on_floor": true})
	if d.get("beast") != null:
		(d["beast"] as BeastRig).animate(dt, {"speed": speed, "on_floor": true})


# ===========================================================================
#  SHOTS
# ===========================================================================
func _run() -> void:
	await _shot_kit()
	await _shot_lineup()
	await _shot_closeups()
	await _shot_beast()
	await _shot_lod()


## Every CreatureKit primitive on a shelf. Godot's front faces are CLOCKWISE, and a
## lofted surface built with the rings in the wrong order is INVISIBLE from the
## outside rather than wrong-looking — so each new generator gets photographed once,
## on its own, before it is trusted inside a creature.
func _shot_kit() -> void:
	if not _want("kit"):
		return
	var holder := Node3D.new()
	w.add_child(holder)
	# One matte material for everything, so a dark patch means a mesh problem and not
	# a metal with nothing to reflect.
	var m := Mats.flat(Color(0.66, 0.63, 0.58), 0.72)
	# [label, mesh, lift, scale] — lift raises a part that is authored hanging or centred.
	var items := [
		["horn curl", CreatureKit.horn(0.42, 0.075, 0.010, 1.15, 0.30, 0.5, 7, 0.30), 0.0, 1.0],
		["horn swept", CreatureKit.horn(0.52, 0.055, 0.008, -0.55, 0.55, 0.0, 9, 0.22), 0.0, 1.0],
		["horn broken", CreatureKit.horn(0.40, 0.085, 0.012, 1.5, 0.25, 0.0, 6, 0.34, 0.35), 0.0, 1.0],
		["plate", CreatureKit.plate(0.20, 0.30, 2.6, 0.022, 10), 0.22, 1.0],
		["wrap", CreatureKit.wrap(0.09, 0.16, 4.4, 0.03, 12), 0.16, 1.4],
		["fang", CreatureKit.fang(0.16, 0.028, 0.9), 0.0, 1.4],
		["paw", CreatureKit.paw(0.075, 0.035), 0.16, 1.6],
		["ear", CreatureKit.ear(0.13, 0.075, 0.15), 0.02, 1.6],
		["scapula", CreatureKit.scapula(0.30, 0.11, 0.045), 0.02, 1.0],
		["torso", CreatureKit.quadruped_torso(0.85, 0.19, 0.22, 0.74, 1.10), 0.24, 0.5],
		["hoof", CreatureKit.hoof(0.055), 0.22, 2.4],
		["antler", CreatureKit.antler(0.34, 0.020, 3), 0.0, 1.0],
		["bird body", CreatureKit.bird_body(0.30, 0.070), 0.24, 1.1],
		["bird wing", CreatureKit.bird_wing(0.34, 0.13), 0.24, 1.0],
		["primate hand", CreatureKit.primate_hand(0.070), 0.30, 2.2],
	]
	for i in range(items.size()):
		var cell := Vector3(-2.20 + 1.10 * float(i % 5), 0.0, 1.30 - 1.30 * float(i / 5))
		var mi := MeshInstance3D.new()
		mi.mesh = items[i][1]
		mi.material_override = m
		mi.scale = Vector3.ONE * float(items[i][3])
		mi.position = cell + Vector3(0.0, 0.02 + float(items[i][2]), 0.0)
		holder.add_child(mi)
		var lb := Label3D.new()
		lb.text = items[i][0]
		lb.font_size = 64
		lb.pixel_size = 0.0016
		lb.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		lb.modulate = Color(1.0, 0.85, 0.45)
		lb.no_depth_test = true
		lb.position = cell + Vector3(0.0, -0.03, 0.34)
		holder.add_child(lb)
	var t := Vector3(0.0, 0.24, 0.0)
	cam.look_at_from_position(t + Vector3(0.0, 2.40, 4.60), t, Vector3.UP)
	await _save("kit")
	cam.look_at_from_position(t + Vector3(3.4, 1.05, 3.4), t, Vector3.UP)
	await _save("kit_low")
	holder.get_parent().remove_child(holder)
	holder.queue_free()
	await process_frame


## All four beside Rama, front on, and the same frame backlit so only the outline reads.
func _shot_lineup() -> void:
	var made: Array = []
	var xs := [2.6, 0.9, -0.9, -3.0, -5.0]
	var rama := _make_rama()
	rama.get_parent().position = Vector3(xs[0], 0, 0)
	made.append(rama)
	for i in range(KINDS.size()):
		var p := _make(KINDS[i], 7 + i)
		var h: Node3D = p["holder"]
		h.position = Vector3(xs[i + 1], 0, 0)
		# No turn: ProcRig now builds facing -Z, the direction every controller in the
		# game actually drives, and so does BeastRig. The lens goes on that side
		# instead. (This used to rotate the rakshasas 180 degrees, because ProcRig
		# faced +Z and the beast faced -Z, and a sheet of four backs and one front is
		# how the last one shipped.)
		made.append(p)
	print("[couplings into ProcRig] %s" % EnemyTypes.build_audit)
	_report(made)
	await _settle(made, 0.0)

	var target := Vector3(-1.1, 1.05, 0)
	if _want("lineup"):
		cam.look_at_from_position(target + Vector3(0.0, 0.35, -9.6), target, Vector3.UP)
		await _save("lineup")
	if _want("lineup_side"):
		cam.look_at_from_position(target + Vector3(9.0, 0.6, -1.5), target + Vector3(0, 0, -0.4), Vector3.UP)
		await _save("lineup_side")
	if _want("silhouette"):
		# Backlit against a bright sky: nothing survives but the outline.
		env.background_color = Color(0.82, 0.88, 0.98)
		env.ambient_light_energy = 0.04
		key.light_energy = 0.0
		fill.light_energy = 0.0
		floor_mi.visible = false
		cam.look_at_from_position(target + Vector3(0.0, 0.30, -10.0), target, Vector3.UP)
		await _save("silhouette")
		env.background_color = Color(0.13, 0.15, 0.19)
		env.ambient_light_energy = 0.45
		key.light_energy = 2.6
		fill.light_energy = 0.5
		floor_mi.visible = true
	for m in made:
		var n: Node = m if m is Node else (m as Dictionary)["holder"]
		(n if n is Node3D else null).get_parent().remove_child(n)
		n.queue_free()
	await process_frame


## Each rakshasa on its own: three-quarter upper body, and a portrait.
func _shot_closeups() -> void:
	var names := {EnemyTypes.Kind.WARRIOR: "warrior", EnemyTypes.Kind.ARCHER: "archer", EnemyTypes.Kind.ELITE: "champion"}
	for kind in names:
		var nm: String = names[kind]
		if not (_want(nm) or _want(nm + "_face")):
			continue
		var p := _make(kind, 3)
		var rig: ProcRig = p["rig"]
		await _settle([p], 0.0)
		var h: float = float(rig.cfg.height)
		if _want(nm):
			var t := Vector3(0, h * 0.55, 0)
			cam.look_at_from_position(t + Vector3(-1.9, 0.55, -3.6), t, Vector3.UP)
			await _save(nm)
		if _want(nm + "_face"):
			# Aim at the FACE, not at the head node. ProcRig's head origin sits at the
			# top of the neck; the eyes are a further 1.04 * cfg.head above it and
			# 0.64 * cfg.head in front, so framing the origin puts the face in the top
			# of the frame and fills the shot with jaw.
			var hr: float = float(rig.cfg.head)
			var hp: Vector3 = rig.head.global_position + Vector3(0, hr * 0.95, -hr * 0.55)
			cam.look_at_from_position(hp + Vector3(-0.22, 0.06, -0.80), hp, Vector3.UP)
			await _save(nm + "_face")
		var holder: Node3D = p["holder"]
		holder.get_parent().remove_child(holder)
		holder.queue_free()
		await process_frame


## Prove the detail tier actually switches, and that the switch is not visible.
##
## `CreatureKit.detail` hangs the fine geometry on `visibility_range_end`, which is a
## camera-DISTANCE cull, so the only honest test is to photograph the same creature
## from inside and outside that distance at the same on-screen SIZE. The far shot
## therefore uses a narrower lens: 40 degrees at 14 m and 16.6 degrees at 34 m put the
## champion in the same number of pixels. If the two frames differ anywhere a player
## would notice, the switch distance is too close.
func _shot_lod() -> void:
	if not (_want("lod_near") or _want("lod_far")):
		return
	var p := _make(EnemyTypes.Kind.ELITE, 3)
	var rig: ProcRig = p["rig"]
	await _settle([p], 0.0)
	var t := Vector3(0, float(rig.cfg.height) * 0.55, 0)
	var near := 14.0
	var far := 34.0
	var acc := {"n": 0, "hi": 0, "mid": 0}
	_walk(p["holder"], acc)
	print("  LOD: %d instances, %d tris near, %d tris past %.0f m" % [acc.n, acc.hi, acc.mid, CreatureKit.DETAIL_DIST])
	if _want("lod_near"):
		cam.fov = 40.0
		cam.look_at_from_position(t + Vector3(0, 0.2, -near), t, Vector3.UP)
		await _save("lod_near")
	if _want("lod_far"):
		cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(40.0) * 0.5) * near / far))
		cam.look_at_from_position(t + Vector3(0, 0.2, -far), t, Vector3.UP)
		await _save("lod_far")
	cam.fov = 40.0
	var holder: Node3D = p["holder"]
	holder.get_parent().remove_child(holder)
	holder.queue_free()
	await process_frame


func _shot_beast() -> void:
	var p := _make(EnemyTypes.Kind.BEAST, 5)
	var b: BeastRig = p["beast"]
	if _want("vyaghra_side"):
		await _settle([p], 0.0)
		var t := Vector3(0, 0.72, 0)
		cam.look_at_from_position(t + Vector3(4.2, 0.55, 0.1), t, Vector3.UP)
		await _save("vyaghra_side")
	if _want("vyaghra_walk"):
		await _settle([p], 1.8, 90)
		var t2 := Vector3(0, 0.72, 0)
		cam.look_at_from_position(t2 + Vector3(4.0, 0.30, 0.1), t2, Vector3.UP)
		await _save("vyaghra_walk")
	if _want("vyaghra_run"):
		await _settle([p], 7.4, 90)
		var t3 := Vector3(0, 0.72, 0)
		cam.look_at_from_position(t3 + Vector3(4.0, 0.30, 0.1), t3, Vector3.UP)
		await _save("vyaghra_run")
	if _want("vyaghra_neck"):
		await _settle([p], 0.0, 40)
		var tn: Vector3 = b.chest.global_position
		cam.look_at_from_position(tn + Vector3(1.05, 0.30, -0.70), tn, Vector3.UP)
		await _save("vyaghra_neck")
	if _want("vyaghra_head"):
		await _settle([p], 0.0, 30)
		var hp: Vector3 = b.head.global_position
		cam.look_at_from_position(hp + Vector3(0.30, 0.16, -1.05), hp, Vector3.UP)
		await _save("vyaghra_head")
	if _want("vyaghra_3q"):
		var t4 := Vector3(0, 0.62, 0)
		cam.look_at_from_position(t4 + Vector3(2.4, 0.9, -2.6), t4, Vector3.UP)
		await _save("vyaghra_3q")
	var bh: Node3D = p["holder"]
	bh.get_parent().remove_child(bh)
	bh.queue_free()
	await process_frame


# ===========================================================================
#  MEASUREMENT
# ===========================================================================
## Triangles and draw instances per archetype, split by LOD tier. A detail mesh is
## one carrying a `visibility_range_end`; the MID tier is what survives when those
## have been culled, which is what the player sees from thirty metres out.
func _report(made: Array) -> void:
	print("archetype          inst  flat   tris HIGH   tris MID   (MID = detail culled)")
	for m in made:
		var root: Node3D
		var label: String
		if m is ProcRig:
			root = m
			label = "Rama (ProcRig)"
		else:
			var d: Dictionary = m
			root = d["holder"]
			label = EnemyTypes.display_name(d["kind"])
		var acc := {"n": 0, "hi": 0, "mid": 0}
		_walk(root, acc)
		# What the renderer actually sees: `Enemy.build_visual` runs RigOptimiser over
		# every rig it builds, and reporting the pre-merge count overstates the cost by
		# nearly half.
		var flat := RigOptimiser.flatten(root, label)
		var acc2 := {"n": 0, "hi": 0, "mid": 0}
		_walk(root, acc2)
		print("%-18s %5d %5d %10d %11d" % [label, acc.n, acc2.n, acc2.hi, acc2.mid])
		if flat.x < flat.y:
			print("  ! flatten made it worse: %d -> %d" % [flat.x, flat.y])
		# A detail instance must be ALONE in its material group at its joint, or the
		# merger swallows it and its visibility_range with it. Prove it survived.
		var lost := _lod_lost(root)
		if lost > 0:
			print("  ! %d detail meshes lost their LOD range in the merge" % lost)


func _walk(n: Node, acc: Dictionary) -> void:
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var t := _tris(mi.mesh)
			acc.n += 1
			acc.hi += t
			if mi.visibility_range_end <= 0.0:
				acc.mid += t
	for c in n.get_children():
		_walk(c, acc)


## Detail meshes are named by CreatureKit; count any that came out of the merge with
## no visibility range left on them.
func _lod_lost(n: Node) -> int:
	var bad := 0
	var stack: Array = [n]
	var want := [
		"SkullFine",
		"Teeth",
		"Hide",
		"ArmHide",
		"Rivets",
		"Trophies",
		"BeltPlates",
		"Warpaint",
		"WarpaintChest",
		"Chalk",
		"Lashing",
		"Whiskers",
		"Claws",
		"Talons",
	]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		for k in c.get_children():
			stack.append(k)
		if c is MeshInstance3D and want.has(String(c.name)) and (c as MeshInstance3D).visibility_range_end <= 0.0:
			bad += 1
	return bad


func _tris(m: Mesh) -> int:
	var total := 0
	for s in range(m.get_surface_count()):
		var idx: int = m.surface_get_array_index_len(s)
		total += (idx if idx > 0 else m.surface_get_array_len(s)) / 3
	return total


func _want(nm: String) -> bool:
	return only == "" or only == nm


func _save(nm: String) -> void:
	for i in range(4):
		await process_frame
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png(OUT % nm)
	print("  shot %s" % nm)
