extends Node


## Does the gameplay camera actually keep Rama in frame? Projects his head and feet to
## screen space and reports where they land.
func _ready() -> void:
	await get_tree().process_frame
	_run()


## Nearest spot to `want` that is not inside a tree trunk, so the test measures the
## camera rather than measuring a player who has been teleported into a banyan.
func _clear_spot(game: Game, want: Vector2) -> Vector2:
	var solids: SolidStreamer = game.solids
	if solids == null:
		return want
	for r in range(0, 26, 2):
		for a in range(12):
			var ang: float = TAU * float(a) / 12.0
			var q: Vector2 = want + Vector2(cos(ang), sin(ang)) * float(r)
			var ok := true
			for i in range(solids._solids.size()):
				var sol = solids._solids[i]
				if sol.box != Vector3.ZERO:
					continue
				if Vector2(sol.pos.x - q.x, sol.pos.z - q.y).length() < sol.radius + 1.6:
					ok = false
					break
			if ok:
				return q
	return want


func _run() -> void:
	var decoy := Node.new()
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var session := HUD.launch(get_tree())
	var game: Game = session.get_node("Game")
	for i in range(60):
		await get_tree().process_frame
	var p: Player = game.player
	p.lock_input(true)
	game.world.sky.paused = true
	game.world.sky.set_time(10.5)
	var fails: Array[String] = []
	var spots := [
		["open meadow", Vector2(-160.0, 80.0)],
		["village", Vector2(-124.0, 52.0)],
		["forest", Vector2(-200.0, -20.0)],
		["river bank", Vector2(-48.0, 20.0)],
	]
	for s in spots:
		var q: Vector2 = _clear_spot(game, s[1])
		p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.15, q.y)
		p.velocity = Vector3.ZERO
		game.world.terrain.update_focus(p.global_position, true)
		for i in range(50):
			await get_tree().process_frame
		var cam: Camera3D = game.cam.camera()
		var head := p.global_position + Vector3(0, 1.7, 0)
		var feet := p.global_position
		var vp := get_viewport().get_visible_rect().size
		var sh := cam.unproject_position(head)
		var sf := cam.unproject_position(feet)
		var behind := cam.is_position_behind(head)
		var dist := cam.global_position.distance_to(p.global_position)
		var on_screen: bool = not behind and sh.x > 0 and sh.x < vp.x and sh.y > 0 and sh.y < vp.y
		var height_px: float = absf(sf.y - sh.y)
		print(
			(
				"  %-12s cam-dist %.2f m  head@(%.0f,%.0f) feet@(%.0f,%.0f)  %.0f px tall  onscreen=%s"
				% [s[0], dist, sh.x, sh.y, sf.x, sf.y, height_px, on_screen]
			)
		)
		# On screen is not enough: something between the camera and Rama hides him just
		# as effectively. This is exactly how a tree trunk was covering him.
		var space := get_viewport().world_3d.direct_space_state
		var rq := PhysicsRayQueryParameters3D.create(cam.global_position, head)
		rq.collision_mask = 1 | 8
		rq.exclude = [p.get_rid()]
		var blocked := space.intersect_ray(rq)
		var clear: bool = blocked.is_empty()
		print("      line of sight: %s" % ("clear" if clear else "BLOCKED by %s" % blocked.collider))
		if not on_screen:
			fails.append("%s: Rama is not on screen" % s[0])
		elif height_px < 60.0:
			fails.append("%s: Rama is only %.0f px tall (camera too far or collapsed)" % [s[0], height_px])
		elif not clear:
			fails.append("%s: something is between the camera and Rama" % s[0])
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://build/screenshots/frame_%s.png" % String(s[0]).replace(" ", "_"))
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
