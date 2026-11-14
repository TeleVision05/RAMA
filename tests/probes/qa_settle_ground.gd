extends SceneTree
## QA GROUNDING AUDIT for the Settlement / Arch system.
##
## MUST BE RUN WINDOWED (no --headless). The headless dummy RenderingServer discards
## MultiMesh instance buffers: get_instance_transform() returns identity for every
## instance and multimesh.buffer is empty, so any headless audit of a MultiMesh is
## vacuously green. tests/settle_audit.gd is headless and therefore never checked a
## single one of the 250-odd scattered props.
##
## What this checks, per PLACED OBJECT (a direct child of Settlement, taking the union
## AABB of its whole subtree, plus every MultiMesh instance individually):
##   * FLOATING  - the lowest geometry sits above every support under its footprint.
##   * BURIED    - the highest geometry sits under the lowest ground under it.
##   * ORIGIN    - |global_position.y - height_at(x,z)|, the literal assertion, for
##                 every object that was actually positioned (identity-transform nodes
##                 hold world-space geometry and are reported separately).
## "Support" is the ground, or the top face of another placed object that ends at or
## below where this one begins - so a lintel resting on the ruin plinth is measured
## against the plinth, and the plinth is still measured against the ground.
##
## A second pass flags any individual leaf mesh that is ENTIRELY under the ground,
## which is how a lamp buried in the dirt on a levelled plinth gets caught.

const FLOAT_TOL := 0.30
const SUNK_TOL := 0.02
const ORIGIN_TOL := 1.50

var map: WorldMap
var units: Array = []


func _subtree_aabb(n: Node, acc: AABB, got: Array) -> AABB:
	if n is MeshInstance3D and n.mesh:
		var a: AABB = n.global_transform * (n.mesh as Mesh).get_aabb()
		acc = a if not got[0] else acc.merge(a)
		got[0] = true
	for c in n.get_children():
		acc = _subtree_aabb(c, acc, got)
	return acc


func _leaves(n: Node, out: Array) -> void:
	if n is MeshInstance3D and n.mesh:
		out.append({"aabb": n.global_transform * (n.mesh as Mesh).get_aabb(), "name": String(n.get_path())})
	for c in n.get_children():
		_leaves(c, out)


func _ground_span(a: AABB) -> Vector2:
	var lo: float = 1e9
	var hi: float = -1e9
	for j in range(4):
		for i in range(4):
			var x: float = lerpf(a.position.x, a.position.x + a.size.x, float(i) / 3.0)
			var z: float = lerpf(a.position.z, a.position.z + a.size.z, float(j) / 3.0)
			var g: float = map.height_at(x, z)
			lo = minf(lo, g)
			hi = maxf(hi, g)
	return Vector2(lo, hi)


## Highest support under (x, z) for something whose lowest point is my_bottom: the
## ground, the top face of another placed object that ends at or below my_bottom, or
## my_bottom itself if another object's mass brackets it (I am embedded in it, which is
## how a snapped pillar is set 0.55 m into the ruin plinth). `who` collects the names of
## whatever ended up holding this object up, so an "embedded" verdict can be eyeballed.
func _support(x: float, z: float, my_bottom: float, me: int, who: Dictionary) -> float:
	var s: float = map.height_at(x, z)
	var src: String = "ground"
	for i in range(units.size()):
		if i == me:
			continue
		var a: AABB = units[i].aabb
		if x < a.position.x - 0.05 or x > a.position.x + a.size.x + 0.05:
			continue
		if z < a.position.z - 0.05 or z > a.position.z + a.size.z + 0.05:
			continue
		var top: float = a.position.y + a.size.y
		if top <= my_bottom + 0.35:
			if top > s:
				s = top
				src = "on " + String(units[i].name)
		elif a.position.y <= my_bottom + 0.02 and top >= my_bottom:
			# my base is inside this object's mass
			if my_bottom > s:
				s = my_bottom
				src = "embedded in " + String(units[i].name)
	who[src] = true
	return s


func _support_span(a: AABB, me: int, who: Dictionary) -> Vector2:
	var lo: float = 1e9
	var hi: float = -1e9
	for j in range(4):
		for i in range(4):
			var x: float = lerpf(a.position.x, a.position.x + a.size.x, float(i) / 3.0)
			var z: float = lerpf(a.position.z, a.position.z + a.size.z, float(j) / 3.0)
			var sv: float = _support(x, z, a.position.y, me, who)
			lo = minf(lo, sv)
			hi = maxf(hi, sv)
	return Vector2(lo, hi)


func _init() -> void:
	var root := get_root()
	await process_frame
	map = WorldMap.load_or_bake(false)
	var s := Settlement.new()
	s.name = "Settlement"
	root.add_child(s)
	var t0 := Time.get_ticks_usec()
	s.setup(map)
	var build_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	await process_frame

	# ---- collect placed objects -------------------------------------------
	var world_space: Array = []
	var positioned: Array = []
	for child in s.get_children():
		if child is MultiMeshInstance3D:
			var mmi := child as MultiMeshInstance3D
			if mmi.multimesh == null or mmi.multimesh.mesh == null:
				continue
			var mb: AABB = mmi.multimesh.mesh.get_aabb()
			if (
				mmi.multimesh.instance_count > 0
				and mmi.multimesh.get_instance_transform(0) == Transform3D.IDENTITY
				and mmi.multimesh.get_instance_transform(mmi.multimesh.instance_count - 1) == Transform3D.IDENTITY
			):
				push_error("MultiMesh %s reads back identity - are you running headless?" % mmi.name)
			for i in range(mmi.multimesh.instance_count):
				var t: Transform3D = mmi.global_transform * mmi.multimesh.get_instance_transform(i)
				units.append({"aabb": t * mb, "name": "%s[%d]" % [mmi.name, i], "origin": t.origin, "placed": true})
			continue
		if not (child is Node3D):
			continue
		var got := [false]
		var ab: AABB = _subtree_aabb(child, AABB(), got)
		if not got[0]:
			continue
		var placed: bool = (child as Node3D).transform != Transform3D.IDENTITY
		units.append({"aabb": ab, "name": String(child.name), "origin": (child as Node3D).global_position, "placed": placed, "node": child})
		if placed:
			positioned.append(units.size() - 1)
		else:
			world_space.append(child.name)

	# ---- float / bury ------------------------------------------------------
	var floats: Array = []
	var sunk: Array = []
	var supported: Array = []
	for i in range(units.size()):
		var a: AABB = units[i].aabb
		if a.size == Vector3.ZERO:
			continue
		var c: Vector3 = a.get_center()
		if not map.in_bounds(c.x, c.z):
			floats.append("%-40s OUT OF BOUNDS at %.0f,%.0f" % [units[i].name, c.x, c.z])
			continue
		var who: Dictionary = {}
		var sp := _support_span(a, i, who)
		var gap: float = a.position.y - sp.y
		var over: float = a.position.y + a.size.y - sp.x
		if gap > FLOAT_TOL:
			floats.append(
				(
					"%-40s FLOATS %.2f m  bottom=%.2f support=%.2f  at %.0f,%.0f  [%s]"
					% [units[i].name, gap, a.position.y, sp.y, c.x, c.z, ", ".join(who.keys())]
				)
			)
		if over < SUNK_TOL:
			sunk.append(
				"%-40s BURIED %.2f m  top=%.2f ground=%.2f  at %.0f,%.0f" % [units[i].name, -over, a.position.y + a.size.y, sp.x, c.x, c.z]
			)
		if not who.has("ground") and gap <= FLOAT_TOL:
			supported.append("%-40s rests on other geometry: %s" % [units[i].name, ", ".join(who.keys())])

	# ---- leaf meshes entirely under the ground -----------------------------
	var leaves: Array = []
	_leaves(s, leaves)
	var leaf_bad: Array = []
	for l in leaves:
		var a2: AABB = l.aabb
		if a2.size == Vector3.ZERO:
			continue
		var c2: Vector3 = a2.get_center()
		if not map.in_bounds(c2.x, c2.z):
			continue
		var g := _ground_span(a2)
		if a2.position.y + a2.size.y < g.x - SUNK_TOL:
			leaf_bad.append(
				(
					"%-52s wholly under ground: top=%.2f ground=%.2f at %.0f,%.0f"
					% [l.name.get_file(), a2.position.y + a2.size.y, g.x, c2.x, c2.z]
				)
			)

	# ---- the literal origin assertion --------------------------------------
	var origin_bad: Array = []
	var worst: float = 0.0
	for i in positioned:
		var p: Vector3 = units[i].origin
		if not map.in_bounds(p.x, p.z):
			continue
		var d: float = absf(p.y - map.height_at(p.x, p.z))
		worst = maxf(worst, d)
		if d > ORIGIN_TOL:
			origin_bad.append(
				"%-40s origin=%.2f height_at=%.2f delta=%.2f at %.0f,%.0f" % [units[i].name, p.y, map.height_at(p.x, p.z), d, p.x, p.z]
			)

	print("=== QA GROUNDING AUDIT (windowed, real MultiMesh buffers) ===")
	print("setup() wall clock: %.1f ms" % build_ms)
	print("placed objects: %d   leaf meshes: %d" % [units.size(), leaves.size()])
	print("world-space nodes (identity transform, geometry already in world coords): %s" % str(world_space))
	print("worst |origin.y - height_at| over %d positioned objects: %.2f m" % [positioned.size(), worst])
	print("--- FLOATING (%d) ---" % floats.size())
	for f in floats:
		print("  " + f)
	print("--- HELD UP BY OTHER GEOMETRY, NOT THE GROUND (%d, informational) ---" % supported.size())
	for b in supported:
		print("  " + b)
	print("--- BURIED (%d) ---" % sunk.size())
	for b in sunk:
		print("  " + b)
	print("--- LEAF MESH WHOLLY UNDER GROUND (%d) ---" % leaf_bad.size())
	for b in leaf_bad:
		print("  " + b)
	print("--- ORIGIN > %.2f m FROM height_at (%d) ---" % [ORIGIN_TOL, origin_bad.size()])
	for b in origin_bad:
		print("  " + b)
	var ok: bool = floats.is_empty() and sunk.is_empty() and leaf_bad.is_empty()
	print("RESULT: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
