class_name SolidStreamer
extends Node3D
## Streamed collision for the static world.
##
## Trees, boulders and buildings are drawn with MultiMesh and baked meshes, which carry
## no collision at all. Without this the player walks through tree trunks and huts, and
## — the bug that surfaced it — the third-person camera's spring arm passes straight
## through a trunk, so a tree sits between the camera and Rama and hides him completely.
##
## Colliders are registered once as lightweight descriptors, bucketed into a uniform
## grid, and only the ones near the player are ever real physics bodies.

const CELL := 24.0  # spatial hash cell, metres
## The player capsule and a 4.35 m camera arm never need more than about 12 m of
## reach; 26 m is generous and keeps the working set small.
const ACTIVE_RADIUS := 26.0
const RELEASE_RADIUS := 34.0
const POOL := 260  # fixed body pool, never grown at runtime


class Solid:
	var pos: Vector3
	var radius: float
	var height: float
	var basis: Basis = Basis.IDENTITY
	var box: Vector3 = Vector3.ZERO  # non-zero => box shape

	func _init(p: Vector3, r: float, h: float) -> void:
		pos = p
		radius = r
		height = h


var _solids: Array[Solid] = []
var _grid: Dictionary = {}  # Vector2i -> Array[int]
var _bodies: Array[StaticBody3D] = []  # fixed pool, always in the tree
var _shapes: Array[CollisionShape3D] = []
var _assigned: PackedInt32Array = PackedInt32Array()  # body slot -> solid index (-1 free)
var _slot_of: Dictionary = {}  # solid index -> body slot
var _last_focus := Vector3(1e9, 0, 0)
var _built := false


func _key(p: Vector3) -> Vector2i:
	return Vector2i(int(floor(p.x / CELL)), int(floor(p.z / CELL)))


func add_cylinder(pos: Vector3, radius: float, height: float) -> void:
	_index(Solid.new(pos, radius, height))


func add_box(centre: Vector3, size: Vector3, b: Basis = Basis.IDENTITY) -> void:
	var s := Solid.new(centre, maxf(size.x, size.z) * 0.5, size.y)
	s.box = size
	s.basis = b
	_index(s)


func _index(s: Solid) -> void:
	var i := _solids.size()
	_solids.append(s)
	var k := _key(s.pos)
	if not _grid.has(k):
		_grid[k] = []
	_grid[k].append(i)


func solid_count() -> int:
	return _solids.size()


func active_count() -> int:
	return _slot_of.size()


## Build the pool ONCE. Reparenting bodies as the player moves cost ~10 ms/frame in a
## dense forest; the tree churn was the expense, not the physics. The pool is created
## up front and only its transforms and shapes ever change.
func _build_pool() -> void:
	_built = true
	_assigned.resize(POOL)
	for i in range(POOL):
		_assigned[i] = -1
		var b := StaticBody3D.new()
		b.collision_layer = 8  # "world solid" — the camera arm and the player test it
		b.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.disabled = true
		b.add_child(cs)
		add_child(b)
		_bodies.append(b)
		_shapes.append(cs)


func update_focus(focus: Vector3, force: bool = false) -> void:
	if not _built:
		_build_pool()
		force = true
	if not force and focus.distance_squared_to(_last_focus) < 6.25:
		return
	_last_focus = focus

	# Which solids should be real right now.
	var want: Dictionary = {}
	var r := int(ceil(ACTIVE_RADIUS / CELL)) + 1
	var c := _key(focus)
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var k := Vector2i(c.x + dx, c.y + dz)
			if not _grid.has(k):
				continue
			for i in _grid[k]:
				var s: Solid = _solids[i]
				if Vector2(s.pos.x - focus.x, s.pos.z - focus.z).length() <= ACTIVE_RADIUS:
					want[i] = true

	# Free slots whose solid has moved well outside (hysteresis stops thrashing).
	var freed: Array[int] = []
	for i in _slot_of.keys():
		if want.has(i):
			continue
		var s: Solid = _solids[i]
		if Vector2(s.pos.x - focus.x, s.pos.z - focus.z).length() > RELEASE_RADIUS:
			var slot: int = _slot_of[i]
			_shapes[slot].disabled = true
			_assigned[slot] = -1
			_slot_of.erase(i)
			freed.append(slot)

	for i in want:
		if _slot_of.has(i):
			continue
		var slot := -1
		if not freed.is_empty():
			slot = freed.pop_back()
		else:
			for k2 in range(POOL):
				if _assigned[k2] == -1:
					slot = k2
					break
		if slot < 0:
			break  # pool exhausted; the nearest solids already have bodies
		_bind(slot, i)


func _bind(slot: int, i: int) -> void:
	var s: Solid = _solids[i]
	var cs: CollisionShape3D = _shapes[slot]
	if s.box != Vector3.ZERO:
		var bs := cs.shape as BoxShape3D
		if bs == null:
			bs = BoxShape3D.new()
			cs.shape = bs
		bs.size = s.box
	else:
		var cy := cs.shape as CylinderShape3D
		if cy == null:
			cy = CylinderShape3D.new()
			cs.shape = cy
		cy.radius = s.radius
		cy.height = s.height
	_bodies[slot].transform = Transform3D(s.basis, s.pos)
	cs.disabled = false
	_assigned[slot] = i
	_slot_of[i] = slot


## Pull collider descriptors out of the world systems that have them.
func harvest(vegetation: Node, settlement: Node) -> void:
	if vegetation and vegetation.has_method("tree_colliders"):
		for c in vegetation.call("tree_colliders"):
			add_cylinder(c.pos, c.radius, c.height)
	if settlement and settlement.has_method("solid_colliders"):
		for c in settlement.call("solid_colliders"):
			if c.has("box"):
				add_box(c.pos, c.box, c.get("basis", Basis.IDENTITY))
			else:
				add_cylinder(c.pos, c.radius, c.height)
