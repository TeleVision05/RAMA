class_name Terrain
extends Node3D
## Chunked terrain with distance LOD, baked per-vertex biome weights and AO, and a
## single world-sized heightfield collider.
##
## The mesh is generated from WorldMap.heights, never from noise sampled again — one
## source of truth means the collider, the visual mesh and every prop placement agree
## to the millimetre.

const CHUNK: float = 64.0
const CHUNKS: int = 12  # 12 * 64 = 768 m
const LOD_STEP := [1, 2, 4, 8]  # heightfield cells per mesh quad
## Switch distances. Measured 2026-08-28 on an M2 Max: pulling these in from
## 104/210/400 cut the shadow-pass primitive count roughly in half with no visible
## difference at 1600x900, because the terrain silhouette is what carries at range.
const LOD_DIST := [82.0, 168.0, 320.0]
## Skirt depth scales with the LOD step: a neighbouring chunk two levels coarser can
## be tens of metres off in the mountains, and a fixed 6 m curtain tore open there.
const SKIRT_BASE: float = 5.0
const SKIRT_PER_STEP: float = 7.0

var map: WorldMap
var material: Material

var _chunks: Array = []  # Array[Dictionary]
var _cache: Dictionary = {}  # "cx_cz_lod" -> ArrayMesh
var _pending: Array = []  # chunk indices needing a rebuild
var _budget_per_frame: int = 3
var _focus: Vector3 = Vector3.ZERO


func setup(world_map: WorldMap, mat: Material) -> void:
	map = world_map
	material = mat
	_build_chunk_nodes()
	_build_collider()


func _build_chunk_nodes() -> void:
	for cz in range(CHUNKS):
		for cx in range(CHUNKS):
			var mi := MeshInstance3D.new()
			mi.name = "Chunk_%d_%d" % [cx, cz]
			mi.material_override = material
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			# Chunks are authored in world space, so no per-chunk transform.
			add_child(mi)
			var origin := Vector2(-WorldMap.HALF + float(cx) * CHUNK, -WorldMap.HALF + float(cz) * CHUNK)
			(
				_chunks
				. append(
					{
						"cx": cx,
						"cz": cz,
						"node": mi,
						"lod": -1,
						"centre": Vector3(origin.x + CHUNK * 0.5, 0.0, origin.y + CHUNK * 0.5),
						"origin": origin,
					}
				)
			)


## One heightfield shape for the whole world. Godot's HeightMapShape3D is centred on
## the origin with 1 unit spacing, which is exactly the WorldMap grid, so the collider
## and the visual mesh cannot drift apart.
func _build_collider() -> void:
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := HeightMapShape3D.new()
	shape.map_width = WorldMap.GRID
	shape.map_depth = WorldMap.GRID
	shape.map_data = map.heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _lod_for(dist: float) -> int:
	for i in range(LOD_DIST.size()):
		if dist < LOD_DIST[i]:
			return i
	return LOD_DIST.size()


## Refresh which LOD each chunk should be at. Rebuilds are queued and spread over
## frames so crossing a threshold never costs a visible hitch.
func update_focus(focus: Vector3, immediate: bool = false) -> void:
	_focus = focus
	for i in range(_chunks.size()):
		var c: Dictionary = _chunks[i]
		var d: float = Vector2(focus.x - c.centre.x, focus.z - c.centre.z).length()
		var want := _lod_for(d)
		if want != c.lod and not _pending.has(i):
			_pending.append(i)
	# Nearest first, so what the player is standing on sharpens before the horizon.
	_pending.sort_custom(func(a, b): return _focus.distance_squared_to(_chunks[a].centre) < _focus.distance_squared_to(_chunks[b].centre))
	if immediate:
		while not _pending.is_empty():
			_apply(_pending.pop_front())


func _process(_dt: float) -> void:
	var n := 0
	while not _pending.is_empty() and n < _budget_per_frame:
		_apply(_pending.pop_front())
		n += 1


func _apply(i: int) -> void:
	var c: Dictionary = _chunks[i]
	var d: float = Vector2(_focus.x - c.centre.x, _focus.z - c.centre.z).length()
	var lod := _lod_for(d)
	if lod == c.lod:
		return
	var key := "%d_%d_%d" % [c.cx, c.cz, lod]
	var mesh: ArrayMesh = _cache.get(key)
	if mesh == null:
		mesh = _build_mesh(c.origin, lod)
		_cache[key] = mesh
	c.node.mesh = mesh
	c.lod = lod
	_chunks[i] = c


func _build_mesh(origin: Vector2, lod: int) -> ArrayMesh:
	var step: int = LOD_STEP[lod]
	var quads := int(CHUNK / float(step))  # 64, 32, 16, 8
	var side := quads + 1
	var gx0 := int((origin.x + WorldMap.HALF) / WorldMap.CELL)
	var gz0 := int((origin.y + WorldMap.HALF) / WorldMap.CELL)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tans := PackedFloat32Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	var total := side * side + side * 4  # grid + skirt ring
	verts.resize(total)
	norms.resize(total)
	cols.resize(total)
	uvs.resize(total)
	uv2s.resize(total)
	tans.resize(total * 4)

	for j in range(side):
		for i in range(side):
			var gx: int = gx0 + i * step
			var gz: int = gz0 + j * step
			var wx: float = -WorldMap.HALF + float(gx) * WorldMap.CELL
			var wz: float = -WorldMap.HALF + float(gz) * WorldMap.CELL
			var h: float = map.heights[map._idx(gx, gz)]
			var vi := j * side + i
			verts[vi] = Vector3(wx, h, wz)
			var nn := _normal(gx, gz, step)
			norms[vi] = nn
			# Tangents are REQUIRED: the terrain shader writes NORMAL_MAP, and without a
			# tangent basis Godot's TBN is degenerate and every lit pixel comes out
			# black. UV runs along world X (u) and world Z (v), so the tangent is +X
			# projected onto the surface.
			var tg: Vector3 = (Vector3.RIGHT - nn * nn.x).normalized()
			tans[vi * 4] = tg.x
			tans[vi * 4 + 1] = tg.y
			tans[vi * 4 + 2] = tg.z
			tans[vi * 4 + 3] = 1.0
			var li := map._idx(gx, gz) * 4
			cols[vi] = Color8(map.layer[li], map.layer[li + 1], map.layer[li + 2], map.layer[li + 3])
			uvs[vi] = Vector2(wx, wz) / WorldMap.WORLD_SIZE
			uv2s[vi] = Vector2(_wetness(gx, gz), float(map.ao[map._idx(gx, gz)]) / 255.0)

	for j in range(quads):
		for i in range(quads):
			var a := j * side + i
			var b := a + 1
			var c2 := a + side
			var d2 := c2 + 1
			# Godot treats CLOCKWISE as front-facing. The reverse winding here made the
			# entire ground surface back-face culled: only the chunk skirts drew, which
			# looked like the world had been shredded into ribbons.
			idx.append(a)
			idx.append(b)
			idx.append(c2)
			idx.append(b)
			idx.append(d2)
			idx.append(c2)

	# Skirt: a vertical curtain around the chunk edge. Neighbouring chunks at a coarser
	# LOD leave hairline gaps along the seam; the curtain fills them without needing
	# stitched geometry.
	var sbase := side * side
	var edges := [
		{"fixed": 0, "axis": "j"},  # i = 0
		{"fixed": quads, "axis": "j"},  # i = quads
		{"fixed": 0, "axis": "i"},  # j = 0
		{"fixed": quads, "axis": "i"},  # j = quads
	]
	var so := sbase
	for e in edges:
		var ring: Array[int] = []
		for k in range(side):
			var vi: int = (k * side + int(e.fixed)) if e.axis == "j" else (int(e.fixed) * side + k)
			ring.append(vi)
		for k in range(side):
			var src: int = ring[k]
			var t := so + k
			verts[t] = verts[src] - Vector3(0, SKIRT_BASE + SKIRT_PER_STEP * float(step), 0)
			norms[t] = norms[src]
			tans[t * 4] = tans[src * 4]
			tans[t * 4 + 1] = tans[src * 4 + 1]
			tans[t * 4 + 2] = tans[src * 4 + 2]
			tans[t * 4 + 3] = tans[src * 4 + 3]
			cols[t] = cols[src]
			uvs[t] = uvs[src]
			uv2s[t] = uv2s[src]
		for k in range(side - 1):
			var a2: int = ring[k]
			var b2: int = ring[k + 1]
			var a3 := so + k
			var b3 := so + k + 1
			idx.append(a2)
			idx.append(b2)
			idx.append(a3)
			idx.append(b2)
			idx.append(b3)
			idx.append(a3)
		so += side

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TANGENT] = tans
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_TEX_UV2] = uv2s
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _normal(gx: int, gz: int, step: int) -> Vector3:
	var s: float = float(step) * WorldMap.CELL
	var hl: float = map.heights[map._idx(gx - step, gz)]
	var hr: float = map.heights[map._idx(gx + step, gz)]
	var hd: float = map.heights[map._idx(gx, gz - step)]
	var hu: float = map.heights[map._idx(gx, gz + step)]
	return Vector3(hl - hr, 2.0 * s, hd - hu).normalized()


func _wetness(gx: int, gz: int) -> float:
	var i := map._idx(gx, gz)
	var d: float = map._df_river[i]
	var above: float = map.heights[i] - map._df_river_wy[i]
	return clampf(1.0 - d / 14.0, 0.0, 1.0) * clampf(1.0 - above / 3.5, 0.0, 1.0)
