extends Node
## Close-ups of the rebuilt 3D foliage, in the real world with real lighting. The
## before/after partner of build/detail_sheet.png.
##
## Framing is TREE-RELATIVE, not map-relative: it asks the scatter where the nearest
## banyan / palm / sal actually is and puts the camera under it. A fixed world position
## photographs whatever happens to be there, which is how the first pass produced two
## shots of empty sky and one from inside the river.

const SHOT_DIR := "res://build/screenshots/"

var game: Game
var cam: Camera3D
var pl: Player


func _ready() -> void:
	await get_tree().process_frame
	_run()


## Nearest instance of `sp` to `near`, in world space.
func _find(sp: int, near: Vector2) -> Vector3:
	var veg := game.vegetation
	var best := Vector3(near.x, 0.0, near.y)
	var bd := 1.0e9
	for i in range(veg._pos.size()):
		if veg._kind[i] / TreeBuilder.VARIANTS != sp:
			continue
		var p: Vector3 = veg._pos[i]
		var d: float = Vector2(p.x, p.z).distance_to(near)
		if d < bd:
			bd = d
			best = p
	return best


func _settle(at: Vector3, frames: int = 30) -> void:
	pl.global_position = at + Vector3(0, 0.2, 0)
	game.world.terrain.update_focus(pl.global_position, true)
	for i in range(frames):
		for n in [game.vegetation, game.vfx, game.wildlife, game.solids]:
			if n and n.has_method("update_focus"):
				n.update_focus(pl.global_position)
		await get_tree().physics_frame
		await get_tree().process_frame


func _snap(name: String, eye: Vector3, look: Vector3) -> void:
	cam.look_at_from_position(eye, look, Vector3.UP)
	for i in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(SHOT_DIR + "d3_%s.png" % name)
	print("shot d3_%s" % name)


func _run() -> void:
	game = Game.new()
	# No HUD. Not only for a clean frame: a stray ui_cancel opens the pause menu, which
	# DIMS the whole viewport, and a run that paused itself photographed the canopy about
	# 40% darker than it is. Two rounds of "the leaves are too dark" were that, not the
	# leaves. ARCHITECTURE names this flag for exactly this case.
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	pl = game.player
	pl.lock_input(true)
	pl.visible = false
	get_tree().paused = false
	game.world.sky.paused = true
	game.world.sky.set_time(10.5)
	TreeBuilder.set_wind(Vector2(0.82, 0.57), 0.35, 1.0)

	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.05
	add_child(cam)
	cam.current = true

	var sp := TreeBuilder.Species
	var banyan := _find(sp.BANYAN, WorldMap.P_VILLAGE + Vector2(15.0, 11.0))
	var palm := _find(sp.PALM, Vector2(-52.0, 34.0))
	var sal := _find(sp.SAL, Vector2(-198.0, -30.0))
	var mango := _find(sp.MANGO, Vector2(-196.0, -20.0))
	var bush := _find(sp.BUSH, Vector2(-180.0, 40.0))
	print("banyan %s  palm %s  sal %s  mango %s  bush %s" % [banyan, palm, sal, mango, bush])

	# --- the hero banyan: from underneath, and in silhouette
	await _settle(banyan + Vector3(6, 0, 6))
	await _snap("banyan_under", banyan + Vector3(0.6, 1.6, 0.6), banyan + Vector3(0.0, 11.0, -1.0))
	await _snap("banyan_side", banyan + Vector3(15.0, 3.0, 15.0), banyan + Vector3(0, 8.0, 0))

	# --- a mango: leaves at arm's length, then the canopy from directly below
	await _settle(mango + Vector3(3, 0, 3))
	await _snap("leaves_close", mango + Vector3(2.6, 4.6, 2.6), mango + Vector3(0, 4.2, 0))
	await _snap("canopy_under", mango + Vector3(0.4, 1.5, 0.4), mango + Vector3(0, 8.0, 0))

	# --- a sal, tall: silhouette against the sky, and the crown from below
	await _settle(sal + Vector3(8, 0, 8))
	await _snap("sal_sky", sal + Vector3(11.0, 1.4, 11.0), sal + Vector3(0, 14.0, 0))
	await _snap("sal_under", sal + Vector3(0.8, 1.5, 0.8), sal + Vector3(0, 15.0, 0))

	# --- a palm: the crown close, and a single frond
	await _settle(palm + Vector3(6, 0, 6))
	await _snap("palm_crown", palm + Vector3(5.0, 9.5, 5.0), palm + Vector3(0, 10.5, 0))
	await _snap("palm_under", palm + Vector3(1.0, 1.5, 1.0), palm + Vector3(0, 12.0, 0))
	await _snap("palm_frond", palm + Vector3(2.6, 10.0, 2.6), palm + Vector3(0.4, 9.6, 0.4))

	# --- undergrowth
	await _settle(bush + Vector3(2, 0, 2))
	await _snap("bush_close", bush + Vector3(1.3, 0.9, 1.3), bush + Vector3(0, 0.5, 0))

	# --- the forest, the same framing as the baseline sheet
	await _settle(Vector3(-196.0, game.world.map.height_at(-196.0, -20.0), -20.0))
	var g := game.world.map.height_at(-196.0, -20.0)
	await _snap("forest_wide", Vector3(-196.0, g + 2.2, -4.0), Vector3(-196.0, g + 7.0, -26.0))
	await _ladder("sal", sal, [20.0, 28.0, 44.0, 80.0, 100.0])
	print("RESULT: PASS")
	get_tree().quit()


## The LOD ladder. Same tree, same framing, at 20 / 28 / 44 / 80 / 100 m: FULL, the
## FULL->MID hand-over, MID, the MID->FAR cross-fade, and FAR. If a step pops, it shows
## up here as a silhouette that changes size or density between two frames.
func _ladder(name: String, tree: Vector3, dists: Array) -> void:
	# Constant ANGULAR size: the field of view is opened and closed so the tree covers
	# the same fraction of the frame at every distance. Comparing two frames at a fixed
	# fov only tells you the tree got smaller; this tells you whether it changed SHAPE.
	for d in dists:
		var dd: float = d
		var eye := tree + Vector3(dd * 0.7071, 8.0, dd * 0.7071)
		await _settle(tree + Vector3(dd * 0.7071 * 0.85, 0.0, dd * 0.7071 * 0.85), 26)
		cam.fov = clampf(rad_to_deg(2.0 * atan(11.0 / dd)), 6.0, 78.0)
		await _snap("lod_%s_%03d" % [name, int(dd)], eye, tree + Vector3(0, 9.0, 0))
	cam.fov = 40.0
