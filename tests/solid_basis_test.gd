extends SceneTree
## A rotated building must get a collision box that follows its footprint, not an
## axis-aligned box around it. Builds a 10 x 4 x 10 hut rotated 45 degrees and checks
## the collider the settlement emits: ground just outside a corner-to-corner diagonal
## is walkable, ground just inside it is blocked, and an unrotated hut keeps its full
## footprint.


## True when the world point lies inside the emitted collider.
func _blocked(c: Dictionary, p: Vector3) -> bool:
	var basis: Basis = c.get("basis", Basis.IDENTITY)
	var local: Vector3 = basis.inverse() * (p - c.pos)
	var half: Vector3 = c.box * 0.5
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z


func _hut(yaw: float) -> Array:
	var s := Settlement.new()
	root.add_child(s)
	var mi := MeshInstance3D.new()
	mi.name = "Hut"
	var bm := BoxMesh.new()
	bm.size = Vector3(10.0, 4.0, 10.0)
	mi.mesh = bm
	s.add_child(mi)
	mi.rotation.y = yaw
	var out: Array = s.solid_colliders()
	s.free()
	return out


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails: Array[String] = []

	var rot := _hut(PI * 0.25)
	if rot.size() != 1:
		fails.append("rotated hut emitted %d colliders, wanted 1" % rot.size())
	else:
		var c: Dictionary = rot[0]
		# Half-diagonal of the 10 m square is 7.07 m; its face sits 5 m out along the
		# diagonal. (3.8, 3.8) is 5.37 m out (outside); (3.4, 3.4) is 4.81 m out (inside).
		if _blocked(c, Vector3(3.8, 0.0, 3.8)):
			fails.append("ground just outside the rotated hut's corner is blocked")
		if not _blocked(c, Vector3(3.4, 0.0, 3.4)):
			fails.append("ground just inside the rotated hut's wall is not blocked")
		if not _blocked(c, Vector3(6.8, 0.0, 0.0)):
			fails.append("the rotated hut's corner is not blocked")
		if absf(c.box.x - 10.0) > 0.01 or absf(c.box.z - 10.0) > 0.01:
			fails.append("rotated hut box is not its full footprint: %s" % c.box)

	var flat := _hut(0.0)
	if flat.size() == 1:
		if not _blocked(flat[0], Vector3(4.8, 0.0, 4.8)):
			fails.append("unrotated hut lost part of its footprint")
		if _blocked(flat[0], Vector3(5.3, 0.0, 0.0)):
			fails.append("unrotated hut blocks ground past its wall")
	else:
		fails.append("unrotated hut emitted %d colliders, wanted 1" % flat.size())

	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	quit(0 if fails.is_empty() else 1)
