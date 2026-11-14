extends SceneTree
## Characterisation test for ProcRig: builds rigs from fixed configs, poses them with a
## scripted sequence of animation states, and compares the result with
## tests/golden/proc_rig.txt, so proc_rig.gd can be split without changing a vertex or a pose.
##
## Per config, one line for the build (nodes, meshes, vertices, bounding box, which meshes
## are visible at each level of detail, head measurements) and one per pose step (the
## rotations of the 17 joints and the garments, the grips' world positions), rounded to 0.01;
## under --exact also a hash of the full-precision text.
##   default   compares the rounded figures (stable across platforms; what CI runs)
##   --exact   also compares the hashes (same machine and engine only)
##   --update  rewrites the golden file from the current code
## Run:  Godot --headless --path . --script tests/proc_rig_golden_test.gd -- --exact

const GOLDEN := "res://tests/golden/proc_rig.txt"
const JOINTS := ["hips", "spine", "chest", "neck", "head", "skirt_node", "sash_node"]
const SIDED := ["thigh", "knee", "ankle", "shoulder", "elbow", "hand"]

const CONFIGS := [
	["hero", {"seed": 1}],
	["villager sari", {"seed": 5, "topknot": false, "garment": "sari", "height": 1.62, "build": 0.9}],
	["elder", {"seed": 9, "beard": true, "belly": 0.2, "hair_color": Color(0.5, 0.5, 0.5)}],
	["child", {"seed": 12, "height": 1.10, "head": 0.13, "build": 0.8, "topknot": false}],
	["rakshasa", {"seed": 21, "horns": true, "claws": true, "skin": "demon_hide", "dhoti": false, "sash": false, "jewellery": false}],
	["ten heads", {"seed": 33, "ten_heads": true, "channavira": true, "skin": "demon_hide"}],
	["vanara", {"seed": 40, "vanara": true, "skin": "demon_hide"}],
]

const POSE_STEPS := [
	["idle", {"speed": 0.0, "on_floor": true}, 40],
	["walk", {"speed": 1.6, "on_floor": true}, 50],
	["sprint", {"speed": 5.5, "on_floor": true}, 50],
	["airborne", {"speed": 3.0, "on_floor": false, "air_time": 0.4}, 20],
	["dodge", {"speed": 6.0, "on_floor": true, "dodge": 0.8}, 10],
	["crouch", {"speed": 0.0, "on_floor": true, "crouch": 0.3}, 30],
]


func _initialize() -> void:
	_run.call_deferred()


func _q(v: float) -> String:
	return "%.2f" % (0.0 if absf(v) < 0.005 else v)


func _v3(v: Vector3) -> String:
	return "(%s,%s,%s)" % [_q(v.x), _q(v.y), _q(v.z)]


func _v3_full(v: Vector3) -> String:
	return "(%.7f,%.7f,%.7f)" % [v.x, v.y, v.z]


## A joint's orientation as where its forward and up axes point. Euler angles flip sign
## at +-PI, which would make the figures depend on the last bit of a float.
func _axes(n: Node3D) -> String:
	return "%s%s" % [_v3(n.basis * Vector3.FORWARD), _v3(n.basis * Vector3.UP)]


func _axes_full(n: Node3D) -> String:
	return "%s%s%s" % [_v3_full(n.basis * Vector3.FORWARD), _v3_full(n.basis * Vector3.UP), _v3_full(n.position)]


func _hash(text: String) -> String:
	return text.sha256_text().substr(0, 16)


## "name = rounded = hash" for the shape of a built rig.
func _build_line(label: String, rig: ProcRig) -> String:
	var nodes := 0
	var meshes := 0
	var visible := 0
	var verts := 0
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	var names := PackedStringArray()
	var stack: Array = [rig]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		names.append(n.name)
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			meshes += 1
			if mi.is_visible_in_tree():
				visible += 1
			var box := mi.global_transform * mi.get_aabb()
			lo = lo.min(box.position)
			hi = hi.max(box.end)
			for s in range(mi.mesh.get_surface_count()):
				verts += (mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	names.sort()
	var fm := rig.face_metrics()
	var keys := fm.keys()
	keys.sort()
	var fm_txt := ""
	for k in keys:
		fm_txt += "%s=%s;" % [k, _q(float(fm[k])) if (fm[k] is float or fm[k] is int) else str(fm[k])]
	var lods := ""
	for lvl in [1, 0]:
		rig.set_lod(lvl)
		var vis := 0
		for m in rig.find_children("*", "MeshInstance3D", true, false):
			if (m as MeshInstance3D).is_visible_in_tree():
				vis += 1
		lods += "lod%d=%d " % [lvl, vis]
	var shown := "%d nodes|%d meshes|%d visible|%d verts|%s|%s|%s|leg %s|%s" % [
		nodes, meshes, visible, verts, _v3(lo), _v3(hi), lods, _q(rig.total_leg()), fm_txt
	]
	return "%s build = %s = %s" % [label, shown, _hash(",".join(names) + shown)]


func _pose_line(label: String, step: String, rig: ProcRig) -> String:
	var parts := PackedStringArray()
	var full := PackedStringArray()
	for j in JOINTS:
		var n: Node3D = rig.get(j)
		if n == null:
			parts.append("%s=none" % j)
			continue
		parts.append("%s=%s" % [j, _axes(n)])
		full.append(_axes_full(n))
	for j in SIDED:
		var d: Dictionary = rig.get(j)
		for side in ["L", "R"]:
			var n: Node3D = d.get(side)
			if n == null:
				continue
			parts.append("%s%s=%s" % [j, side, _axes(n)])
			full.append(_axes_full(n))
	for side in ["L", "R"]:
		var a: Node3D = rig.hand_attach.get(side)
		if a != null:
			parts.append("grip%s=%s" % [side, _v3(a.global_position)])
			full.append(_v3_full(a.global_position))
	var shown := "|".join(parts)
	return "%s %s = %s = %s" % [label, step, shown, _hash("".join(full))]


func _lines() -> Array[String]:
	var out: Array[String] = []
	for c in CONFIGS:
		var host := Node3D.new()
		root.add_child(host)
		var rig := ProcRig.new()
		rig.configure((c[1] as Dictionary).duplicate())
		host.add_child(rig)
		rig.build()
		out.append(_build_line(c[0], rig))
		rig.set_lod(0)
		for st in POSE_STEPS:
			for i in range(int(st[2])):
				rig.animate(1.0 / 60.0, st[1])
			out.append(_pose_line(c[0], st[0], rig))
		rig.attack_swing = 0.6
		rig.aim_weight = 1.0
		rig.hurt_amount = 0.5
		for i in range(20):
			rig.animate(1.0 / 60.0, {"speed": 0.0, "on_floor": true})
		out.append(_pose_line(c[0], "aim+swing+hurt", rig))
		rig.dead_amount = 1.0
		rig.animate(1.0 / 60.0, {"speed": 0.0, "on_floor": true})
		out.append(_pose_line(c[0], "dead", rig))
		host.free()
	return out


func _compare(a: String, b: String, exact: bool) -> String:
	var pa := a.split(" = ")
	var pb := b.split(" = ")
	if pa[0] != pb[0]:
		return "line order changed: '%s' vs '%s'" % [pa[0], pb[0]]
	if pa[1] != pb[1]:
		return "%s: golden '%s' now '%s'" % [pa[0], pa[1], pb[1]]
	if exact and pa[2] != pb[2]:
		return "%s: exact figures differ (%s vs %s)" % [pa[0], pa[2], pb[2]]
	return ""


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var lines := _lines()
	if args.has("--update"):
		var f := FileAccess.open(GOLDEN, FileAccess.WRITE)
		f.store_string("\n".join(lines) + "\n")
		f.close()
		print("wrote %d lines to %s" % [lines.size(), GOLDEN])
		quit(0)
		return
	var want: Array = FileAccess.get_file_as_string(GOLDEN).strip_edges().split("\n")
	var fails: Array[String] = []
	if want.size() != lines.size():
		fails.append("golden has %d lines, the code produced %d" % [want.size(), lines.size()])
	for i in range(mini(want.size(), lines.size())):
		var why := _compare(want[i], lines[i], args.has("--exact"))
		if why != "":
			fails.append(why)
	print("%d lines compared%s" % [lines.size(), " (exact)" if args.has("--exact") else ""])
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
