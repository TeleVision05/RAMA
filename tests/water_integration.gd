extends Node
## Does the real game actually get the water?
##
##   tools/gd.sh scene res://scenes/water_integration.tscn
##
## The builder's handover said "INTEGRATION NEEDED - add RiverWater to world_root.gd".
## It is not needed: Game._spawn_content() already instantiates every optional content
## system by class name off ProjectSettings.get_global_class_list(), and RiverWater is in
## that list. This boots the real Game and proves it, rather than taking either claim on
## trust - and screenshots what the player sees standing at the ford.


func _ready() -> void:
	_run()


func _run() -> void:
	var fails: Array[String] = []
	var game := Game.new()
	game.name = "Game"
	add_child(game)
	for _i in range(30):
		await get_tree().process_frame

	var water: Node = game.get("water")
	if water == null:
		fails.append("Game._spawn_content() did not create RiverWater")
	else:
		print(
			"[integration] Game.water = %s (%s), %d children" % [water.name, water.get_class(), water.get_child_count()]
		)
		if not (water is RiverWater):
			fails.append("Game.water is not a RiverWater")
		elif water.get_child_count() == 0:
			fails.append("RiverWater was created but setup() built nothing")
		else:
			var rw: RiverWater = water
			# Arity: Game passes the sky when setup() takes two arguments. If that
			# handshake breaks, the reflection silently stops following the clock.
			if rw.sky == null:
				fails.append("Game did not hand RiverWater the SkySystem (setup arity)")
			var d: float = rw.water_depth_at(WorldMap.P_FORD.x, WorldMap.P_FORD.y)
			print("[integration] water_depth_at(P_FORD) = %.2f m, sky = %s" % [d, rw.sky])
			if d < 1.0:
				fails.append("the ford is dry in the real game (%.2f m)" % d)

	# Stand the player on the bank at the ford and look at the river.
	var p: Node3D = game.get("player")
	if p:
		var m: WorldMap = game.world.map
		var q := WorldMap.P_FORD + Vector2(16.0, 15.0)
		p.global_position = Vector3(q.x, m.height_at(q.x, q.y) + 0.2, q.y)
		if "facing_yaw" in p:
			p.facing_yaw = atan2(WorldMap.P_FORD.x - q.x, WorldMap.P_FORD.y - q.y)
		for _i in range(90):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/water_ingame_ford.png")
		print("[integration] wrote water_ingame_ford.png from the player camera")

	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
