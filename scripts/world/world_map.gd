class_name WorldMap
extends WorldMapBake
## THE authoritative model of the Vale of Panchavati.
##
## Every other system — terrain meshing, foliage scatter, prop placement, NPC spawns,
## navigation, water, audio zones — queries THIS. Nothing is allowed to invent its own
## idea of where the ground is. That single rule is what keeps the world coherent and
## stops props floating or sinking.
##
## Layout (world spans WORLD_SIZE metres, centred on the origin):
##   N   rising foothills -> impassable mountain ridge backdrop
##   NE->SW  the river Godavari, carved valley, waterfall in the north
##   S bank  the village of Panchavati on a flat river terrace, fields to its south
##   E   the shrine knoll, a rocky hill with a carved stone shrine on top
##   W/SW  deep forest, dark and dense, where the rakshasas are
##   NW  ruins in a clearing
##   SE  eroded rock badlands
##   far W  a hidden grove behind a rock arch
##
## The 1,100 lines that used to live here are split by responsibility into a chain of
## classes, each extending the one before, so `WorldMap.height_at`, `WorldMap.P_VILLAGE` and
## `WorldMap.Biome` all keep working:
##
##   WorldMapBase    constants, baked arrays, noise, river, distance fields, path polylines
##   WorldMapField   raw height function and every public query
##   WorldMapGround  smoothing, levelling, biome classes, baked shading
##   WorldMapRoads   the road network carved into the heights
##   WorldMapBake    the bake itself
##   WorldMap        the on-disk cache and `load_or_bake`
##
## tests/world_map_golden_test.gd pins the result of a fresh bake.

const CACHE_PATH := "user://worldmap.cache"
const CACHE_MAGIC := 0x524D4150  # 'RMAP'
const CACHE_VERSION := 13


## Build the map, using the on-disk cache when it matches this generator. A missing,
## truncated or stale cache is not an error: the map is simply baked again (about ten
## seconds) and the cache rewritten. `cache_path` exists so a test can aim at a copy.
static func load_or_bake(verbose: bool = false, cache_path: String = CACHE_PATH) -> WorldMap:
	_report(0.0, "Surveying the vale")
	var m := WorldMap.new()
	if m._try_load_cache(cache_path):
		if verbose:
			print("[worldmap] loaded cache")
		_report(1.0, "Terrain ready")
		return m
	var t0 := Time.get_ticks_msec()
	_report(0.12, "Shaping the land for the first time. This only happens once")
	m._bake()
	if verbose:
		print("[worldmap] baked in %d ms" % (Time.get_ticks_msec() - t0))
	m._save_cache(cache_path)
	_report(1.0, "Terrain ready")
	return m


## What the cache must match: every script that takes part in the bake. The class is split
## across several files, so a change to any of them has to invalidate the cache.
const SOURCE_FILES := [
	"res://scripts/world/world_map_base.gd",
	"res://scripts/world/world_map_field.gd",
	"res://scripts/world/world_map_ground.gd",
	"res://scripts/world/world_map_roads.gd",
	"res://scripts/world/world_map_bake.gd",
	"res://scripts/world/world_map.gd",
]


static func _source_fingerprint() -> String:
	var all := ""
	for f in SOURCE_FILES:
		all += FileAccess.get_md5(f)
	return all.md5_text() if all.length() == 32 * SOURCE_FILES.size() else "v%d" % CACHE_VERSION


func _try_load_cache(path: String = CACHE_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	# Every field after the header has a known size, so a file of the wrong length is a
	# truncated or foreign file: reject it before reading, rather than half-filling arrays.
	var fingerprint := _source_fingerprint()
	var n := GRID * GRID
	var header := 4 + 4 + 4 + fingerprint.to_utf8_buffer().size()
	if f.get_length() != header + n * 4 * 6 + n * 2 + n * 4:
		push_warning("[worldmap] cache has an unexpected size; baking again")
		return false
	if f.get_32() != CACHE_MAGIC or f.get_32() != CACHE_VERSION:
		return false
	if f.get_pascal_string() != fingerprint:
		return false
	heights = f.get_buffer(n * 4).to_float32_array()
	path_mask = f.get_buffer(n * 4).to_float32_array()
	wet_mask = f.get_buffer(n * 4).to_float32_array()
	_df_river = f.get_buffer(n * 4).to_float32_array()
	_df_river_wy = f.get_buffer(n * 4).to_float32_array()
	_df_path = f.get_buffer(n * 4).to_float32_array()
	biomes = f.get_buffer(n)
	ao = f.get_buffer(n)
	layer = f.get_buffer(n * 4)
	return heights.size() == n and biomes.size() == n and ao.size() == n and layer.size() == n * 4


func _save_cache(path: String = CACHE_PATH) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[worldmap] could not write cache")
		return
	f.store_32(CACHE_MAGIC)
	f.store_32(CACHE_VERSION)
	f.store_pascal_string(_source_fingerprint())
	f.store_buffer(heights.to_byte_array())
	f.store_buffer(path_mask.to_byte_array())
	f.store_buffer(wet_mask.to_byte_array())
	f.store_buffer(_df_river.to_byte_array())
	f.store_buffer(_df_river_wy.to_byte_array())
	f.store_buffer(_df_path.to_byte_array())
	f.store_buffer(biomes)
	f.store_buffer(ao)
	f.store_buffer(layer)
