class_name Vegetation
extends Node3D
## Everything that grows in the Vale of Panchavati: 4-5k trees, thousands of shrubs and
## boulders, and a carpet of grass and flowers that streams around the player.
##
## Placement is driven entirely by WorldMap — density from `forest_density`, exclusion
## from `slope_at`, `path_at`, `river_dist` and `water_depth_at`, height from
## `height_at`. Nothing here re-derives the ground, which is why nothing floats.
##
## The scatter is fully deterministic: one seeded RandomNumberGenerator walked in a
## fixed order. The same world always grows the same forest, so a screenshot taken
## today can be compared with one taken next week.
##
## DRAW STRATEGY. Godot does not cull individual MultiMesh instances — a MultiMesh that
## spans the map draws every instance in it, every frame. So the instance buffers are
## rebuilt around the focus point instead: one MultiMesh per (species, variant, LOD),
## each holding only the instances currently at that LOD. That is ~60 draw calls for
## the whole forest, and the triangle count tracks the LOD radii rather than the map
## size. Rebuilds are throttled by distance moved, not by frame count.

const SPECIES_N := TreeBuilder.SPECIES_COUNT
const VARIANTS := TreeBuilder.VARIANTS
const LODS := TreeBuilder.LOD_COUNT
const ROW := 16  # 12 transform floats + 4 custom

const SEED := 0x5241_4D41 ^ 0x0F0_1A6E

const BUCKET := 32.0  # spatial index cell, metres
## Metres of travel before the FULL/MID lists are rebuilt. This number is paid for
## TWICE: once as the rebuild itself (measured 1.3 ms) and once as the safety margin
## _rebuild_near has to add to every cut-off, since between two rebuilds a tree can walk
## this far into a band it is not listed for. 11 m cost ~30k triangles of margin in the
## deep forest; 8 m costs ~22k and one extra rebuild every 24 m.
const NEAR_REBUILD_MOVE := 8.0

const GRASS_CELL := 20.0
const GRASS_RADIUS := 58.0
const GRASS_PER_CELL := 560
const FLOWERS_PER_CELL := 26
## Suitability is sampled on a coarse lattice over the cell and interpolated, rather
## than queried per candidate. See _build_grass_cell for why. 7 nodes = a 3.33 m step.
const GRASS_GRID := 7
## Cells built per frame while the queue drains. Sprint is 8 m/s, a 20 m cell column
## every 2.5 s, about 2.7 new cells a second — one a frame is four times the demand.
const GRASS_PER_FRAME := 1

## Scatter tuning. Read these as "one candidate per N square metres, accepted with
## probability p" — the product is the density that actually lands.
const TREE_STEP := 5.0
const CLUTTER_STEP := 4.2
const ROCK_STEP := 12.0
const BANYAN_STEP := 44.0

var map: WorldMap

var _rng := RandomNumberGenerator.new()
var _pos := PackedVector3Array()
var _rows := PackedFloat32Array()
var _kind := PackedInt32Array()  # species * VARIANTS + variant
var _ljit := PackedFloat32Array()  # per-tree LOD switch multiplier
var _canopy := PackedInt32Array()  # indices that get a billboard LOD
var _buckets: Dictionary = {}  # bucket key -> Array[int]

var _slots: Array = []  # (species*VARIANTS+variant)*LODS + lod
var _grass_cells: Dictionary = {}
var _grass_mesh: ArrayMesh
var _flower_meshes: Array[ArrayMesh] = []

var _near_at := Vector3(1e9, 0, 0)
var _grass_at := Vector3(1e9, 0, 0)
var _grass_pending: Array[Vector2i] = []
var _y_lo := 0.0
var _y_hi := 120.0
var _species_count := PackedInt32Array()
var _built := false


# --- Setup -----------------------------------------------------------------
## `sky` is optional so the render harnesses can build a forest without one. Game
## passes it (it dispatches on setup()'s arity), and it is the only way the foliage
## ever learns what the wind is doing — without it every shader sits on its own
## compiled-in default and the canopy ignores the weather.
func setup(world_map: WorldMap, sky: SkySystem = null) -> void:
	map = world_map
	_rng.seed = SEED
	_species_count.resize(SPECIES_N)
	var t0 := Time.get_ticks_msec()

	var lo := 1e9
	var hi := -1e9
	for h in map.heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	_y_lo = lo - 4.0
	_y_hi = hi + 40.0

	_bake_scatter()
	_build_slots()
	_build_far_static()
	_grass_mesh = _make_grass_clump()
	for i in range(3):
		_flower_meshes.append(_make_flower_clump(i))
	_built = true
	if sky != null:
		set_wind(sky.wind_dir, sky.wind_strength, 1.0)
	print(
		(
			"[veg] %d trees + %d clutter baked in %d ms"
			% [_canopy.size(), _pos.size() - _canopy.size(), Time.get_ticks_msec() - t0]
		)
	)


## Move the streaming window. Cheap when the focus has barely moved; `immediate`
## forces every stage to run this call, which is what the render harness needs.
func update_focus(pos: Vector3, immediate: bool = false) -> void:
	if not _built:
		return
	# Every frame, not only on a rebuild: this is what the shaders measure their LOD
	# ramp from, and it has to track the viewer smoothly or trees step between LODs.
	TreeBuilder.set_lod_focus(pos)
	if immediate or pos.distance_to(_near_at) > NEAR_REBUILD_MOVE:
		_near_at = pos
		_rebuild_near(pos)
	if immediate or pos.distance_to(_grass_at) > GRASS_CELL * 0.4:
		_grass_at = pos
		_update_grass(pos, immediate)
	elif not _grass_pending.is_empty():
		# Cells that could not be afforded when the window moved trickle in afterwards,
		# a couple a frame, instead of all landing in the frame that noticed them.
		_drain_grass(GRASS_PER_FRAME)


## Hand the current weather to every foliage shader at once.
func set_wind(dir: Vector2, strength: float, speed: float = 1.0) -> void:
	TreeBuilder.set_wind(dir, strength, speed)
	for m in [_grass_material(), _flower_material()]:
		m.set_shader_parameter("wind_dir", dir.normalized())
		m.set_shader_parameter("wind_strength", strength)
		m.set_shader_parameter("wind_speed", speed)


# --- Scatter ---------------------------------------------------------------
func _bake_scatter() -> void:
	# Occupancy grid for minimum-spacing tests. 8 m cells: big enough that a bush test
	# touches 9 cells and a banyan test 121, small enough that neither is a linear scan.
	var occ: Dictionary = {}

	# 1. THE hero banyan. Beside the village square, not on top of it, so whoever
	#    builds the village still has a square. Placed first and exempt from spacing.
	var hero := WorldMap.P_VILLAGE + Vector2(15.0, 11.0)
	_add(hero, TreeBuilder.Species.BANYAN, 0, 1.58, occ, 0.0)

	# 2. Palms along the Godavari. Walking the centreline guarantees the read that a
	#    density field never quite gives: a fringe of palms following the water.
	_scatter_river_palms(occ)

	# 3. Landmark banyans in clearings — never in the deep forest, where they would be
	#    swallowed, and never on a slope a 12 m crown could not stand on.
	var g := int(WorldMap.WORLD_SIZE / BANYAN_STEP)
	for j in range(g):
		for i in range(g):
			var p := _jitter(i, j, BANYAN_STEP)
			var fd := map.forest_density(p)
			if fd < 0.12 or fd > 0.66:
				continue
			if _rng.randf() > 0.34:
				continue
			if map.slope_at(p.x, p.y) > 0.26:
				continue
			if map.biome_at(p.x, p.y) == WorldMap.Biome.MOUNTAIN:
				continue
			if not _site_ok(p, 12.0):
				continue
			_add(p, TreeBuilder.Species.BANYAN, _rng.randi() % VARIANTS, _rng.randf_range(0.85, 1.25), occ, 62.0)

	# 4. The forest proper.
	g = int(WorldMap.WORLD_SIZE / TREE_STEP)
	for j in range(g):
		for i in range(g):
			var p := _jitter(i, j, TREE_STEP)
			var fd := map.forest_density(p)
			var chance := 0.06 + 0.58 * pow(fd, 1.1)
			if _rng.randf() > chance:
				continue
			if not _site_ok(p, 7.0):
				continue
			if map.biome_at(p.x, p.y) == WorldMap.Biome.MOUNTAIN:
				continue
			var sp := _pick_species(p, fd)
			if sp < 0:
				continue
			var spacing := 3.9
			var scale := _rng.randf_range(0.82, 1.22)
			match sp:
				TreeBuilder.Species.PALM:
					spacing = 3.6
					scale = _rng.randf_range(0.8, 1.3)
				TreeBuilder.Species.SAL:
					spacing = 3.9
				TreeBuilder.Species.DEAD:
					spacing = 6.5
			_add(p, sp, _rng.randi() % VARIANTS, scale, occ, spacing)

	# 5. Undergrowth. This is what makes the forest floor feel enclosing rather than
	#    like a park with tall poles in it.
	g = int(WorldMap.WORLD_SIZE / CLUTTER_STEP)
	for j in range(g):
		for i in range(g):
			var p := _jitter(i, j, CLUTTER_STEP)
			var fd := map.forest_density(p)
			var b := map.biome_at(p.x, p.y)
			var chance := 0.04 + 0.34 * fd
			if b == WorldMap.Biome.MEADOW:
				chance += 0.07
			elif b == WorldMap.Biome.SAND or b == WorldMap.Biome.ROCK:
				chance *= 0.35
			elif b == WorldMap.Biome.MOUNTAIN or b == WorldMap.Biome.RIVERBED:
				chance = 0.0
			if _rng.randf() > chance:
				continue
			if not _site_ok(p, 3.5, 0.52):
				continue
			var variant := 2 if _rng.randf() < 0.32 else (_rng.randi() % 2)
			_add(p, TreeBuilder.Species.BUSH, variant, _rng.randf_range(0.7, 1.5), occ, 1.5)

	# 6. Boulders. Weighted to the rocky ground and the badlands, with a thin scatter
	#    everywhere else so no patch of ground is completely featureless.
	g = int(WorldMap.WORLD_SIZE / ROCK_STEP)
	for j in range(g):
		for i in range(g):
			var p := _jitter(i, j, ROCK_STEP)
			var b := map.biome_at(p.x, p.y)
			var chance := 0.09
			if b == WorldMap.Biome.ROCK or b == WorldMap.Biome.MOUNTAIN:
				chance = 0.5
			elif b == WorldMap.Biome.SAND:
				chance = 0.22
			elif b == WorldMap.Biome.VILLAGE or b == WorldMap.Biome.FIELD:
				chance = 0.05
			if p.distance_to(WorldMap.P_BADLANDS) < 130.0:
				chance += 0.28
			if _rng.randf() > chance:
				continue
			# Boulders are allowed on ground too steep for a tree — that is where they
			# come from — but still not in the water or on the road.
			if not _site_ok(p, 1.5, 0.85, true):
				continue
			_add(p, TreeBuilder.Species.ROCK, _rng.randi() % VARIANTS, _rng.randf_range(0.45, 1.9), occ, 2.6)

	_build_buckets()


func _jitter(i: int, j: int, step: float) -> Vector2:
	return Vector2(-WorldMap.HALF + (float(i) + _rng.randf()) * step, -WorldMap.HALF + (float(j) + _rng.randf()) * step)


## Every placement rule the brief lays down, in one place.
func _site_ok(p: Vector2, edge: float, max_slope: float = 0.45, allow_steep: bool = false) -> bool:
	if absf(p.x) > WorldMap.HALF - edge - 2.0 or absf(p.y) > WorldMap.HALF - edge - 2.0:
		return false
	if not allow_steep and map.slope_at(p.x, p.y) > max_slope:
		return false
	if map.path_at(p.x, p.y) > 0.25:
		return false
	if map.water_depth_at(p.x, p.y) > 0.0:
		return false
	# The channel itself, including the dry-but-scoured shoulder the river carved.
	if map.river_dist(p) < 6.5 + edge * 0.25:
		return false
	if map.height_at(p.x, p.y) < map.water_y_at(p.x, p.y) + 0.35:
		return false
	if p.distance_to(WorldMap.P_VILLAGE) < 26.0:
		return false
	if p.distance_to(WorldMap.P_SHRINE) < 22.0:
		return false
	return true


func _pick_species(p: Vector2, fd: float) -> int:
	var d_riv := map.river_dist(p)
	var d_vil := p.distance_to(WorldMap.P_VILLAGE)
	var d_fld := p.distance_to(WorldMap.P_FIELDS)
	var d_bad := p.distance_to(WorldMap.P_BADLANDS)
	var d_ruin := p.distance_to(WorldMap.P_RUINS)
	var b := map.biome_at(p.x, p.y)

	# Dead wood: the badlands, the ruins, and any bare rock shelf.
	var dead_w := 0.02
	if d_bad < 190.0:
		dead_w += 0.95 * (1.0 - d_bad / 190.0)
	if d_ruin < 90.0:
		dead_w += 0.75 * (1.0 - d_ruin / 90.0)
	if b == WorldMap.Biome.ROCK or b == WorldMap.Biome.SAND:
		dead_w += 0.5
	if _rng.randf() < dead_w:
		return TreeBuilder.Species.DEAD

	# Palms take the bank; the density scatter adds to the explicit river pass.
	if d_riv < 34.0 and _rng.randf() < 0.45 * (1.0 - d_riv / 34.0) + 0.08:
		return TreeBuilder.Species.PALM

	# Mango is the village and orchard tree.
	var mango_w := 0.18
	if d_vil < 140.0:
		mango_w += 0.62 * (1.0 - d_vil / 140.0)
	if d_fld < 120.0:
		mango_w += 0.5 * (1.0 - d_fld / 120.0)
	mango_w += (1.0 - fd) * 0.30
	if _rng.randf() < mango_w:
		return TreeBuilder.Species.MANGO

	# Everything left standing in the deep forest is sal.
	return TreeBuilder.Species.SAL


func _scatter_river_palms(occ: Dictionary) -> void:
	var pts := map.river_points()
	if pts.is_empty():
		return
	var i := 0
	while i < pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[mini(i + 3, pts.size() - 1)]
		var dir := b - a
		if dir.length_squared() < 1e-6:
			i += 3
			continue
		var perp := dir.normalized().orthogonal()
		# Clusters, not a hedge: 0-3 palms at a time with gaps between them.
		var n := 0 if _rng.randf() < 0.22 else _rng.randi_range(1, 4)
		for k in range(n):
			var side := 1.0 if _rng.randf() < 0.5 else -1.0
			var off := _rng.randf_range(9.0, 27.0) * side
			var along := _rng.randf_range(-4.0, 4.0)
			var p := a + perp * off + dir.normalized() * along
			if not _site_ok(p, 8.0, 0.38):
				continue
			_add(p, TreeBuilder.Species.PALM, _rng.randi() % VARIANTS, _rng.randf_range(0.82, 1.3), occ, 4.0)
		i += 2


func _occ_key(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / 8.0)), int(floor(p.y / 8.0)))


func _spaced(p: Vector2, occ: Dictionary, min_dist: float) -> bool:
	if min_dist <= 0.0:
		return true
	var k := _occ_key(p)
	var r := int(ceil(min_dist / 8.0))
	var d2 := min_dist * min_dist
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var cell: Array = occ.get(Vector2i(k.x + dx, k.y + dz), [])
			for q in cell:
				if p.distance_squared_to(q) < d2:
					return false
	return true


func _add(p: Vector2, species: int, variant: int, scale: float, occ: Dictionary, min_dist: float) -> void:
	if not _spaced(p, occ, min_dist):
		return
	var k := _occ_key(p)
	if not occ.has(k):
		occ[k] = []
	occ[k].append(p)

	# Sunk into the ground so a slope can never open a gap under the trunk. Bushes and
	# boulders sink less: burying a 1 m shrub by 0.3 m removes a third of it.
	var sink := 0.30
	if species == TreeBuilder.Species.BUSH:
		sink = 0.10
	elif species == TreeBuilder.Species.ROCK:
		sink = 0.22 * scale
	var y := map.height_at(p.x, p.y) - sink
	var idx := _pos.size()
	_pos.push_back(Vector3(p.x, y, p.y))
	_kind.push_back(species * VARIANTS + variant)
	_ljit.push_back(_rng.randf_range(0.86, 1.16))
	_species_count[species] += 1
	if species != TreeBuilder.Species.BUSH and species != TreeBuilder.Species.ROCK:
		_canopy.push_back(idx)

	# Lean with the ground, but only a third of the way: a tree grows toward the light,
	# not perpendicular to the hill. Fully aligned trunks on a slope look wrong.
	var n := map.normal_at(p.x, p.y)
	var up := Vector3.UP.lerp(n, 0.34).normalized()
	var basis := Basis(Vector3.UP, _rng.randf() * TAU)
	var axis := Vector3.UP.cross(up)
	if axis.length_squared() > 1e-8:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(up)) * basis
	basis = basis.scaled(Vector3(scale, scale, scale))

	# Dryness: east and south-east of the valley bakes, the wet river margin does not.
	var dry := clampf(
		(
			inverse_lerp(-90.0, 250.0, p.x) * 0.75
			+ clampf(1.0 - p.distance_to(WorldMap.P_BADLANDS) / 190.0, 0.0, 1.0) * 0.5
		),
		0.0,
		1.0
	)
	dry *= 1.0 - map.wet_at(p.x, p.y) * 0.85

	var o := Vector3(p.x, y, p.y)
	_rows.push_back(basis.x.x)
	_rows.push_back(basis.y.x)
	_rows.push_back(basis.z.x)
	_rows.push_back(o.x)
	_rows.push_back(basis.x.y)
	_rows.push_back(basis.y.y)
	_rows.push_back(basis.z.y)
	_rows.push_back(o.y)
	_rows.push_back(basis.x.z)
	_rows.push_back(basis.y.z)
	_rows.push_back(basis.z.z)
	_rows.push_back(o.z)
	_rows.push_back(_rng.randf())  # tint mix
	_rows.push_back(_rng.randf_range(0.84, 1.16))  # brightness
	_rows.push_back(_rng.randf())  # wind phase
	_rows.push_back(dry)


func _bucket_key(x: float, z: float) -> int:
	var gx := int(floor((x + WorldMap.HALF) / BUCKET))
	var gz := int(floor((z + WorldMap.HALF) / BUCKET))
	return gz * 4096 + gx


func _build_buckets() -> void:
	for i in range(_pos.size()):
		var k := _bucket_key(_pos[i].x, _pos[i].z)
		if not _buckets.has(k):
			_buckets[k] = []
		_buckets[k].append(i)


# --- MultiMesh slots -------------------------------------------------------
func _slot_index(species: int, variant: int, lod: int) -> int:
	return (species * VARIANTS + variant) * LODS + lod


func _build_slots() -> void:
	var caps := PackedInt32Array()
	caps.resize(SPECIES_N * VARIANTS)
	for i in range(_pos.size()):
		caps[_kind[i]] += 1

	_slots.resize(SPECIES_N * VARIANTS * LODS)
	for sp in range(SPECIES_N):
		var clutter := sp == TreeBuilder.Species.BUSH or sp == TreeBuilder.Species.ROCK
		for va in range(VARIANTS):
			var cap: int = caps[sp * VARIANTS + va]
			for lod in range(LODS):
				var si := _slot_index(sp, va, lod)
				if cap == 0 or (clutter and lod == TreeBuilder.Lod.FAR):
					_slots[si] = null
					continue
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_custom_data = true
				mm.mesh = TreeBuilder.mesh(sp, va, lod)
				mm.instance_count = 0
				var mi := MultiMeshInstance3D.new()
				mi.name = "%s_v%d_l%d" % [TreeBuilder.SPECIES_NAMES[sp], va, lod]
				mi.multimesh = mm
				# A real AABB, refreshed on every rebuild. Without one Godot walks all
				# instances to derive it, which is exactly the per-frame cost the
				# streaming design exists to avoid.
				mi.custom_aabb = AABB(
					Vector3(-WorldMap.HALF, _y_lo, -WorldMap.HALF),
					Vector3(WorldMap.WORLD_SIZE, _y_hi - _y_lo, WorldMap.WORLD_SIZE)
				)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				mi.visible = false
				add_child(mi)
				_slots[si] = {
					"node": mi,
					"mm": mm,
					"tris": TreeBuilder.triangles(sp, va, lod),
					"n": 0,
				}


func _fill(indices: Array, lod: int, focus: Vector3, radius: float) -> void:
	# Group by slot first so each MultiMesh buffer is written once, contiguously.
	var lists: Array = []
	lists.resize(SPECIES_N * VARIANTS)
	for i in range(lists.size()):
		lists[i] = []
	for i in indices:
		lists[_kind[i]].append(i)

	for kind in range(SPECIES_N * VARIANTS):
		var sp := kind / VARIANTS
		var va := kind % VARIANTS
		var si := _slot_index(sp, va, lod)
		var slot = _slots[si]
		if slot == null:
			continue
		var list: Array = lists[kind]
		var n: int = list.size()
		slot.n = n
		var mm: MultiMesh = slot.mm
		var node: MultiMeshInstance3D = slot.node
		if n == 0:
			node.visible = false
			continue
		# Size the upload to what is actually drawn. Allocating every slot at the
		# whole-map count and relying on visible_instance_count would push a megabyte
		# of mostly-unused instance data to the GPU on every rebuild.
		var buf := PackedFloat32Array()
		buf.resize(n * ROW)
		var o := 0
		for i in list:
			var src: int = i * ROW
			for k in range(ROW):
				buf[o + k] = _rows[src + k]
			o += ROW
		if mm.instance_count != n:
			mm.instance_count = n
		mm.buffer = buf
		mm.visible_instance_count = n
		node.visible = true
		node.custom_aabb = AABB(
			Vector3(focus.x - radius, _y_lo, focus.z - radius), Vector3(radius * 2.0, _y_hi - _y_lo, radius * 2.0)
		)


func _rebuild_near(focus: Vector3) -> void:
	# MARGIN. The lists are rebuilt only every NEAR_REBUILD_MOVE metres, but the shader
	# fades on the LIVE camera distance, so between two rebuilds a tree can walk that
	# far into a band whose CPU list it is not in. It then draws only the far half of
	# the cross-fade and reads as a see-through ghost until the next rebuild. Every
	# cut-off here therefore has to sit NEAR_REBUILD_MOVE beyond the distance at which
	# the shader stops asking for that LOD — plus half of LOD_JITTER, since the shader
	# pushes each tree's own hand-over up to that far out. Measured cost of the margin:
	# about 47 extra MID trees, ~10k triangles.
	var near_end := TreeBuilder.LOD_NEAR_END
	var half_jit := TreeBuilder.LOD_JITTER * 0.5
	var mid_end := TreeBuilder.LOD_MID_END + TreeBuilder.LOD_BAND + half_jit + NEAR_REBUILD_MOVE + 2.0
	var clutter_end := TreeBuilder.CLUTTER_END + half_jit + NEAR_REBUILD_MOVE
	var scan := mid_end + BUCKET
	var full: Array = []
	var mid: Array = []

	var gx0 := int(floor((focus.x - scan + WorldMap.HALF) / BUCKET))
	var gx1 := int(floor((focus.x + scan + WorldMap.HALF) / BUCKET))
	var gz0 := int(floor((focus.z - scan + WorldMap.HALF) / BUCKET))
	var gz1 := int(floor((focus.z + scan + WorldMap.HALF) / BUCKET))
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var cell: Array = _buckets.get(gz * 4096 + gx, [])
			for i in cell:
				var p: Vector3 = _pos[i]
				var d := Vector2(focus.x - p.x, focus.z - p.z).length()
				var sp: int = _kind[i] / VARIANTS
				var limit: float = (
					clutter_end if (sp == TreeBuilder.Species.BUSH or sp == TreeBuilder.Species.ROCK) else mid_end
				)
				if d > limit:
					continue
				# The FULL/MID swap distance is jittered per tree so a stand hands over
				# a few trees at a time. MID/FAR is NOT jittered: that boundary is a
				# shader cross-fade and the two sides must agree on the raw distance.
				if d * _ljit[i] < near_end:
					full.append(i)
				else:
					mid.append(i)

	_fill(full, TreeBuilder.Lod.FULL, focus, near_end + 8.0)
	_fill(mid, TreeBuilder.Lod.MID, focus, mid_end + 4.0)


## The billboard layer is built ONCE and never rebuilt.
##
## It used to be re-filled every FAR_REBUILD_MOVE metres, which cost a measured 6.8 ms
## mean / 9.7 ms peak per rebuild — and bought nothing. LOD_FAR_END is 520 m against a
## 768 m map, so the radius test was already keeping 3973 of 4252 trees; the rebuild was
## re-uploading essentially the whole set to move a boundary that hardly moved. Every
## canopy tree now goes in permanently. The near billboards discard every pixel (the
## shader's fade-in ramp starts past LOD_MID_END) so they cost only vertex shading, and
## that is also what keeps the near and far layers from ever double-drawing a tree.
func _build_far_static() -> void:
	var list: Array = []
	for i in _canopy:
		list.append(i)
	_fill(list, TreeBuilder.Lod.FAR, Vector3.ZERO, WorldMap.HALF + 8.0)


# --- Grass -----------------------------------------------------------------
static var _grass_mat: ShaderMaterial = null
static var _flower_mat: ShaderMaterial = null


func _grass_material() -> ShaderMaterial:
	if _grass_mat != null:
		return _grass_mat
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/grass.gdshader")
	m.set_shader_parameter("albedo_tex", Mats.tex("grass_blades"))
	m.set_shader_parameter("fade_begin", GRASS_RADIUS - 16.0)
	m.set_shader_parameter("fade_end", GRASS_RADIUS)
	m.set_shader_parameter("ground_tint", Color(0.28, 0.24, 0.15))
	# 0.72 read well in an open meadow and was far too strong under a canopy, where the
	# tinted lower half of every blade went black. 0.58 still seats the grass in the dirt.
	m.set_shader_parameter("ground_blend", 0.58)
	_grass_mat = m
	return m


func _flower_material() -> ShaderMaterial:
	if _flower_mat != null:
		return _flower_mat
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/grass.gdshader")
	m.set_shader_parameter("albedo_tex", Mats.tex("flowers"))
	m.set_shader_parameter("fade_begin", GRASS_RADIUS * 0.62)
	m.set_shader_parameter("fade_end", GRASS_RADIUS * 0.82)
	m.set_shader_parameter("ground_blend", 0.12)
	m.set_shader_parameter("tint_a", Vector3(1.0, 1.0, 1.0))
	m.set_shader_parameter("tint_b", Vector3(1.0, 0.95, 0.9))
	m.set_shader_parameter("albedo_gain", 1.0)
	m.set_shader_parameter("bend_scale", 0.16)
	m.set_shader_parameter("translucency", 0.4)
	m.set_shader_parameter("alpha_cut", 0.5)
	_flower_mat = m
	return m


## Three crossed cards. The three sample different thirds of the blade texture so a
## single clump already has variety in it before per-instance scale and tint.
func _make_grass_clump() -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	# A clump is ankle-to-shin high. At 0.55 m base x 1.55 scale x 1.5 y-stretch the
	# grass reached 1.28 m and read as ferns the player was wading through.
	var w := 0.30
	var h := 0.30
	for k in range(3):
		var a := PI * float(k) / 3.0
		var right := Vector3(cos(a), 0.0, sin(a)) * w
		var nrm := Vector3(-sin(a), 0.0, cos(a))
		var u0 := float(k) / 3.0
		var u1 := float(k + 1) / 3.0
		var lo := Color(0.0, 0.4, 0.5, 0.0)
		var hi := Color(1.0, 1.0, 0.5, 0.0)
		var rn := right.normalized()
		var i0 := s.vert(-right, nrm, rn, lo, Vector2(u0, 1.0))
		var i1 := s.vert(right, nrm, rn, lo, Vector2(u1, 1.0))
		var i2 := s.vert(right + Vector3(0, h, 0), nrm, rn, hi, Vector2(u1, 0.0))
		var i3 := s.vert(-right + Vector3(0, h, 0), nrm, rn, hi, Vector2(u0, 0.0))
		s.quad(i0, i1, i2, i3, nrm)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	m.surface_set_material(0, _grass_material())
	return m


const FLOWER_RECTS := [
	Rect2(0.06, 0.10, 0.27, 0.28),  # marigold
	Rect2(0.60, 0.10, 0.30, 0.28),  # marigold
	Rect2(0.30, 0.55, 0.28, 0.29),  # marigold
	Rect2(0.04, 0.60, 0.28, 0.30),  # hibiscus
	Rect2(0.60, 0.55, 0.30, 0.29),  # hibiscus
	Rect2(0.40, 0.04, 0.20, 0.24),  # jasmine
	Rect2(0.04, 0.46, 0.22, 0.20),  # jasmine
	Rect2(0.46, 0.84, 0.26, 0.16),  # jasmine
]


func _make_flower_clump(variant: int) -> ArrayMesh:
	var s := TreeBuilder.Surf.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ (variant * 7717)
	for k in range(4):
		var rect: Rect2 = FLOWER_RECTS[(variant * 3 + k) % FLOWER_RECTS.size()]
		var a := rng.randf() * TAU
		var off := Vector3(cos(a), 0.0, sin(a)) * rng.randf_range(0.0, 0.22)
		var sz := rng.randf_range(0.16, 0.26)
		var yaw := rng.randf() * TAU
		var right := Vector3(cos(yaw), 0.0, sin(yaw)) * sz
		var nrm := Vector3(-sin(yaw), 0.0, cos(yaw))
		var base := off + Vector3(0, rng.randf_range(0.02, 0.10), 0)
		var lo := Color(0.15, 0.5, 0.5, 0.0)
		var hi := Color(1.0, 1.0, 0.5, 0.0)
		var rn := right.normalized()
		var i0 := s.vert(base - right, nrm, rn, lo, Vector2(rect.position.x, rect.end.y))
		var i1 := s.vert(base + right, nrm, rn, lo, Vector2(rect.end.x, rect.end.y))
		var i2 := s.vert(base + right + Vector3(0, sz * 2.0, 0), nrm, rn, hi, Vector2(rect.end.x, rect.position.y))
		var i3 := s.vert(base - right + Vector3(0, sz * 2.0, 0), nrm, rn, hi, Vector2(rect.position.x, rect.position.y))
		s.quad(i0, i1, i2, i3, nrm)
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s.to_arrays())
	m.surface_set_material(0, _flower_material())
	return m


func _grass_weight(p: Vector2) -> float:
	# The badlands read as badlands only if they are dry. WorldMap still classes some of
	# those eroded ridges as meadow, so the dry-down is applied here rather than
	# arguing with the biome map.
	var dry := clampf(p.distance_to(WorldMap.P_BADLANDS) / 150.0, 0.0, 1.0) * 0.78 + 0.22
	match map.biome_at(p.x, p.y):
		WorldMap.Biome.MEADOW:
			return 1.0 * dry
		WorldMap.Biome.FIELD:
			return 0.92 * dry
		WorldMap.Biome.VILLAGE:
			return 0.60 * dry
		# The forest floor carries real cover. At 0.58 the ground under the canopy read
		# as bare rock with a few sprigs on it, which is the opposite of enclosing.
		WorldMap.Biome.FOREST:
			return 0.78 * dry
		WorldMap.Biome.SAND:
			return 0.10 * dry
		WorldMap.Biome.ROCK:
			return 0.06 * dry
		_:
			return 0.0


## Sample the placement rules on a GRASS_GRID x GRASS_GRID lattice over the cell.
##
## This is the whole reason a cell is affordable. Asking WorldMap per candidate meant
## `slope_at` (which is `normal_at`, four bilinear height samples) plus `water_depth_at`
## (a distance-field sample, a width query, a water-height sample and another height
## sample) plus `river_dist` and `path_at`, 560 times — measured at 5.2 ms per cell,
## and four cells landed in one frame, so sprinting hitched 20-36 ms about once a
## second. None of those fields carries detail finer than a few metres, so they are
## sampled every 3.33 m and interpolated. A candidate now costs one lerp pair.
##
## The lattice includes both edges, so neighbouring cells sample the same boundary
## values and no seam appears between them.
##
## Returns [ag, kg, blocked]:
##   ag       accept probability (biome/dryness weight x path/slope gate)
##   kg       the path/slope gate alone, which the flowers want on its own
##   blocked  one flag per lattice QUAD, set if any of its four corners is water,
##            river channel or off the edge of the map. A hard reject rather than an
##            interpolated one: widening the setback by a lattice step is invisible,
##            and it is the safe direction to be wrong in.
func _sample_grid(ox: float, oz: float) -> Array:
	var n := GRASS_GRID * GRASS_GRID
	var ag := PackedFloat32Array()
	var kg := PackedFloat32Array()
	var wet := PackedByteArray()
	ag.resize(n)
	kg.resize(n)
	wet.resize(n)
	var step := GRASS_CELL / float(GRASS_GRID - 1)
	for j in range(GRASS_GRID):
		for i in range(GRASS_GRID):
			var p := Vector2(ox + float(i) * step, oz + float(j) * step)
			var k := j * GRASS_GRID + i
			# Cells sit on an infinite lattice around the focus, so the ones at the rim
			# of the map straddle the edge. height_at CLAMPS outside the grid, so a
			# blade placed out there is grounded on the edge height and hangs in the air
			# off the end of the terrain mesh; QA found 415 of them on the western rim.
			if not map.in_bounds(p.x, p.y):
				wet[k] = 1
				continue
			if map.water_depth_at(p.x, p.y) > 0.0 or map.river_dist(p) < 5.0:
				wet[k] = 1
				continue
			var gate := (
				clampf(1.0 - map.path_at(p.x, p.y) * 2.4, 0.0, 1.0)
				* clampf(1.0 - map.slope_at(p.x, p.y) * 1.7, 0.0, 1.0)
			)
			kg[k] = gate
			ag[k] = _grass_weight(p) * gate
	var q := GRASS_GRID - 1
	var blocked := PackedByteArray()
	blocked.resize(q * q)
	for j in range(q):
		for i in range(q):
			var r := j * GRASS_GRID + i
			blocked[j * q + i] = 1 if (wet[r] | wet[r + 1] | wet[r + GRASS_GRID] | wet[r + GRASS_GRID + 1]) != 0 else 0
	return [ag, kg, blocked]


func _build_grass_cell(cell: Vector2i) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ (cell.x * 73856093) ^ (cell.y * 19349663)
	var ox := float(cell.x) * GRASS_CELL
	var oz := float(cell.y) * GRASS_CELL

	var grids := _sample_grid(ox, oz)
	var ag: PackedFloat32Array = grids[0]
	var kg: PackedFloat32Array = grids[1]
	var blocked: PackedByteArray = grids[2]

	var gbuf := PackedFloat32Array()
	var fbuf := PackedFloat32Array()
	gbuf.resize(GRASS_PER_CELL * ROW)
	fbuf.resize(FLOWERS_PER_CELL * ROW)
	var gn := 0
	var fn := 0
	var quads := GRASS_GRID - 1
	var inv := float(quads) / GRASS_CELL

	# The lattice lookup is written out inline rather than called. At 560 candidates a
	# cell and a cell a frame, a GDScript function call per candidate is not free.
	for i in range(GRASS_PER_CELL):
		var lx := rng.randf() * GRASS_CELL
		var lz := rng.randf() * GRASS_CELL
		var u := lx * inv
		var v := lz * inv
		var gi := int(u)
		var gj := int(v)
		if blocked[gj * quads + gi] != 0:
			continue
		var r := gj * GRASS_GRID + gi
		var tu := u - float(gi)
		var tv := v - float(gj)
		var a := lerpf(lerpf(ag[r], ag[r + 1], tu), lerpf(ag[r + GRASS_GRID], ag[r + GRASS_GRID + 1], tu), tv)
		if a <= 0.0 or rng.randf() > a:
			continue
		var px := ox + lx
		var pz := oz + lz
		var y := map.height_at(px, pz) - 0.06
		var sc := rng.randf_range(0.62, 1.15)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc * rng.randf_range(0.75, 1.25), sc))
		var o := gn * ROW
		gn += 1
		_write_row(gbuf, o, basis, Vector3(px, y, pz), rng.randf(), rng.randf_range(0.78, 1.2), rng.randf(), 0.0)

	# Flowers only where the grass is actually lush, and never on the forest floor.
	# Twenty-six candidates, so the biome test stays exact; only the expensive
	# slope/path/water gate comes off the lattice.
	for i in range(FLOWERS_PER_CELL):
		var lx := rng.randf() * GRASS_CELL
		var lz := rng.randf() * GRASS_CELL
		var u := lx * inv
		var v := lz * inv
		var gi := int(u)
		var gj := int(v)
		if blocked[gj * quads + gi] != 0:
			continue
		var r := gj * GRASS_GRID + gi
		var tu := u - float(gi)
		var tv := v - float(gj)
		var k := lerpf(lerpf(kg[r], kg[r + 1], tu), lerpf(kg[r + GRASS_GRID], kg[r + GRASS_GRID + 1], tu), tv)
		if k < 0.62 or rng.randf() > 0.42:
			continue
		var px := ox + lx
		var pz := oz + lz
		var b := map.biome_at(px, pz)
		if b != WorldMap.Biome.MEADOW and b != WorldMap.Biome.FIELD and b != WorldMap.Biome.VILLAGE:
			continue
		var y := map.height_at(px, pz) - 0.03
		var sc := rng.randf_range(0.42, 0.72)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc, sc))
		var o := fn * ROW
		fn += 1
		_write_row(fbuf, o, basis, Vector3(px, y, pz), rng.randf(), rng.randf_range(0.85, 1.15), rng.randf(), 0.0)

	var res := {"g": null, "f": null, "gn": gn, "fn": fn}
	# Size the upload to what was actually written. Uploading the full candidate count
	# pushed 35 kB per cell where a typical cell needs a third of that.
	if gn > 0:
		gbuf.resize(gn * ROW)
		res.g = _make_cell_node(_grass_mesh, gbuf, gn, gn, ox, oz, "grass")
	if fn > 0:
		fbuf.resize(fn * ROW)
		var fm: ArrayMesh = _flower_meshes[posmod(cell.x + cell.y, 3)]
		res.f = _make_cell_node(fm, fbuf, fn, fn, ox, oz, "flowers")
	return res


func _write_row(
	buf: PackedFloat32Array, o: int, b: Basis, origin: Vector3, c0: float, c1: float, c2: float, c3: float
) -> void:
	buf[o + 0] = b.x.x
	buf[o + 1] = b.y.x
	buf[o + 2] = b.z.x
	buf[o + 3] = origin.x
	buf[o + 4] = b.x.y
	buf[o + 5] = b.y.y
	buf[o + 6] = b.z.y
	buf[o + 7] = origin.y
	buf[o + 8] = b.x.z
	buf[o + 9] = b.y.z
	buf[o + 10] = b.z.z
	buf[o + 11] = origin.z
	buf[o + 12] = c0
	buf[o + 13] = c1
	buf[o + 14] = c2
	buf[o + 15] = c3


func _make_cell_node(
	mesh: ArrayMesh, buf: PackedFloat32Array, n: int, cap: int, ox: float, oz: float, tag: String
) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = cap
	mm.buffer = buf
	mm.visible_instance_count = n
	var mi := MultiMeshInstance3D.new()
	mi.name = "%s_%d_%d" % [tag, int(ox), int(oz)]
	mi.multimesh = mm
	# Thousands of thin cards are a terrible shadow caster: the shadow map fills with
	# noise and the cost is real. Ground cover takes light, it does not give shade.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lo := map.height_at(ox + GRASS_CELL * 0.5, oz + GRASS_CELL * 0.5)
	mi.custom_aabb = AABB(Vector3(ox - 1.0, lo - 14.0, oz - 1.0), Vector3(GRASS_CELL + 2.0, 30.0, GRASS_CELL + 2.0))
	add_child(mi)
	return mi


## Build the next few queued cells. Called every frame the window has not moved far
## enough to warrant a full re-evaluation, which is what turns a once-a-second hitch
## into a cost you cannot see.
func _drain_grass(budget: int) -> void:
	var n := mini(budget, _grass_pending.size())
	for i in range(n):
		var cell: Vector2i = _grass_pending[i]
		if not _grass_cells.has(cell):
			_grass_cells[cell] = _build_grass_cell(cell)
	if n > 0:
		_grass_pending = _grass_pending.slice(n)


func _update_grass(focus: Vector3, immediate: bool) -> void:
	var r := int(ceil(GRASS_RADIUS / GRASS_CELL)) + 1
	var cx := int(floor(focus.x / GRASS_CELL))
	var cz := int(floor(focus.z / GRASS_CELL))
	var wanted: Dictionary = {}
	var pending: Array[Vector2i] = []

	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var cell := Vector2i(cx + dx, cz + dz)
			var centre := Vector2((float(cell.x) + 0.5) * GRASS_CELL, (float(cell.y) + 0.5) * GRASS_CELL)
			var d := Vector2(focus.x, focus.z).distance_to(centre)
			if d > GRASS_RADIUS + GRASS_CELL:
				continue
			wanted[cell] = d
			if not _grass_cells.has(cell):
				pending.append(cell)

	# Nearest first. Building a cell is the most expensive thing this system does per
	# frame, so unless the caller wants the whole window now (the render harness does)
	# the rest go on a queue that drains a cell a frame.
	pending.sort_custom(func(a, b): return float(wanted[a]) < float(wanted[b]))
	_grass_pending = pending
	_drain_grass(_grass_pending.size() if immediate else GRASS_PER_FRAME)

	for cell in _grass_cells.keys():
		var rec: Dictionary = _grass_cells[cell]
		if not wanted.has(cell):
			if rec.g:
				rec.g.queue_free()
			if rec.f:
				rec.f.queue_free()
			_grass_cells.erase(cell)
			continue
		# Density falls off with distance by drawing fewer of the same instances. They
		# were generated in random order, so any prefix is already an even thinning.
		var d: float = wanted[cell]
		var frac := 1.0
		if d > 34.0:
			frac = 0.38
		elif d > 19.0:
			frac = 0.72
		if rec.g:
			rec.g.multimesh.visible_instance_count = maxi(1, int(float(rec.gn) * frac))
		if rec.f:
			rec.f.multimesh.visible_instance_count = maxi(1, int(float(rec.fn) * frac))


# --- Reporting -------------------------------------------------------------
## Triangle and instance census of what is on screen right now. Called by the render
## harness; the budget is 250k triangles for this system.
## Collision descriptors for trunks and boulders, consumed by SolidStreamer.
## Bushes are deliberately excluded: you should be able to push through undergrowth.
const TRUNK_RADIUS := [1.05, 0.24, 0.46, 0.40, 0.30, 0.0, 0.85]
const TRUNK_HEIGHT := [7.0, 9.0, 6.0, 8.0, 5.0, 0.0, 1.6]


func tree_colliders() -> Array:
	var out: Array = []
	for i in range(_pos.size()):
		var sp: int = _kind[i] / VARIANTS
		var r: float = TRUNK_RADIUS[sp]
		if r <= 0.0:
			continue
		var h: float = TRUNK_HEIGHT[sp]
		var p: Vector3 = _pos[i]
		out.append({"pos": p + Vector3(0, h * 0.5 - 0.4, 0), "radius": r, "height": h})
	return out


func stats() -> Dictionary:
	var tri := 0
	var inst := 0
	var by_lod := [0, 0, 0]
	for sp in range(SPECIES_N):
		for va in range(VARIANTS):
			for lod in range(LODS):
				var slot = _slots[_slot_index(sp, va, lod)]
				if slot == null or int(slot.n) == 0:
					continue
				inst += int(slot.n)
				by_lod[lod] += int(slot.n)
				tri += int(slot.n) * int(slot.tris)
	var g_inst := 0
	var g_tri := 0
	for cell in _grass_cells:
		var rec: Dictionary = _grass_cells[cell]
		if rec.g:
			var n: int = rec.g.multimesh.visible_instance_count
			g_inst += n
			g_tri += n * 6
		if rec.f:
			var n2: int = rec.f.multimesh.visible_instance_count
			g_inst += n2
			g_tri += n2 * 8
	var counts: Dictionary = {}
	for sp in range(SPECIES_N):
		counts[TreeBuilder.SPECIES_NAMES[sp]] = _species_count[sp]
	return {
		"placed": _pos.size(),
		"canopy": _canopy.size(),
		"by_species": counts,
		"drawn_instances": inst,
		"tree_triangles": tri,
		"by_lod": by_lod,
		"grass_instances": g_inst,
		"grass_triangles": g_tri,
		"grass_cells": _grass_cells.size(),
		"total_triangles": tri + g_tri,
		"draw_nodes": inst_node_count(),
	}


func inst_node_count() -> int:
	var n := 0
	for c in get_children():
		if c is MultiMeshInstance3D and c.visible:
			n += 1
	return n
