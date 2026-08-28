class_name WorldRoot
extends Node3D
## Assembles the Vale of Panchavati. Owns the WorldMap and hands it to every system
## that needs to know where the ground is.

signal world_ready

var map: WorldMap
var terrain: Terrain
var sky: SkySystem

var _focus: Node3D = null


func build(verbose: bool = false) -> void:
	var t0 := Time.get_ticks_msec()
	map = WorldMap.load_or_bake(verbose)

	sky = SkySystem.new()
	sky.name = "Sky"
	add_child(sky)

	terrain = Terrain.new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(map, Mats.terrain_material())
	terrain.update_focus(Vector3(WorldMap.P_VILLAGE.x, 0.0, WorldMap.P_VILLAGE.y), true)

	if verbose:
		print("[world] built in %d ms" % (Time.get_ticks_msec() - t0))
	world_ready.emit()


func set_focus(n: Node3D) -> void:
	_focus = n


func _process(_d: float) -> void:
	if _focus and terrain:
		terrain.update_focus(_focus.global_position)


## Ground height at a world position - the query every other system should use.
func ground_y(x: float, z: float) -> float:
	return map.height_at(x, z)
