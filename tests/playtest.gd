extends Node
## Drives the real game with synthetic input and checks that the player actually
## moves, lands, jumps, shoots and does not fall through the world.

var game: Game
var fails: Array[String] = []
var log_lines: Array[String] = []


func _ready() -> void:
	_run()


func _run() -> void:
	QuietMode.bring_to_front()
	for i in range(10):
		await get_tree().process_frame
	game = Game.new()
	add_child(game)
	for i in range(10):
		await get_tree().process_frame
	var p := game.player
	print("spawn: %s  ground=%.2f" % [p.global_position, game.world.map.height_at(p.global_position.x, p.global_position.z)])

	# --- settle -----------------------------------------------------------
	await steps(90)
	var settled := p.global_position
	var g := game.world.map.height_at(settled.x, settled.z)
	print("after settle: y=%.3f ground=%.3f delta=%.3f on_floor=%s" % [settled.y, g, settled.y - g, p.is_on_floor()])
	if absf(settled.y - g) > 0.6:
		fails.append("player did not rest on the ground (delta %.2f)" % (settled.y - g))
	if not p.is_on_floor():
		fails.append("player is not on the floor after settling")

	# --- walk forward -----------------------------------------------------
	var before := p.global_position
	Input.action_press("move_forward")
	await steps(90)
	Input.action_release("move_forward")
	var moved := before.distance_to(p.global_position)
	print("walked %.2f m in 1.5 s (state=%s)" % [moved, p.state_name()])
	if moved < 4.0:
		fails.append("forward movement too slow: %.2f m in 1.5 s" % moved)
	await steps(20)

	# --- sprint -----------------------------------------------------------
	before = p.global_position
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await steps(90)
	Input.action_release("sprint")
	Input.action_release("move_forward")
	var sprinted := before.distance_to(p.global_position)
	print("sprinted %.2f m in 1.5 s, stamina=%.1f" % [sprinted, GameState.stamina])
	if sprinted <= moved:
		fails.append("sprint (%.2f m) is not faster than run (%.2f m)" % [sprinted, moved])
	if GameState.stamina >= GameState.max_stamina:
		fails.append("sprinting did not drain stamina")
	await steps(30)

	# --- jump -------------------------------------------------------------
	var y0 := p.global_position.y
	var peak := y0
	Input.action_press("jump")
	await steps(3)
	Input.action_release("jump")
	for i in range(60):
		await steps(1)
		peak = maxf(peak, p.global_position.y)
	print("jump peak +%.2f m, back on floor=%s" % [peak - y0, p.is_on_floor()])
	if peak - y0 < 0.8:
		fails.append("jump too weak: +%.2f m" % (peak - y0))
	await steps(60)
	if not p.is_on_floor():
		fails.append("player never landed after the jump")

	# --- dodge ------------------------------------------------------------
	before = p.global_position
	Input.action_press("dodge")
	await steps(2)
	Input.action_release("dodge")
	await steps(40)
	print("dodge moved %.2f m" % before.distance_to(p.global_position))
	if before.distance_to(p.global_position) < 1.2:
		fails.append("dodge barely moved the player")

	# --- bow --------------------------------------------------------------
	var arrows0 := GameState.arrows
	Input.action_press("aim")
	await steps(70)
	if p.draw_charge < 0.9:
		fails.append("bow did not reach full draw (%.2f)" % p.draw_charge)
	print("draw charge %.2f, aiming=%s" % [p.draw_charge, p.aiming])
	Input.action_release("aim")
	await steps(6)
	print("arrows %d -> %d" % [arrows0, GameState.arrows])
	if GameState.arrows != arrows0 - 1:
		fails.append("releasing the draw did not fire an arrow")
	var live := get_nodes_in_group_count("arrow")
	print("arrows in flight: %d" % live)
	if live < 1:
		fails.append("no Arrow node exists after firing")
	await steps(60)

	# --- melee ------------------------------------------------------------
	Input.action_press("swap_weapon")
	await steps(2)
	Input.action_release("swap_weapon")
	await steps(4)
	if game.player.using_bow:
		fails.append("weapon swap did not switch off the bow")
	Input.action_press("attack")
	await steps(2)
	Input.action_release("attack")
	await steps(10)
	print("melee state=%s" % p.state_name())
	await steps(50)

	# --- damage and death -------------------------------------------------
	var h0 := GameState.health
	p.take_damage(24.0, null)
	await steps(4)
	print("health %.1f -> %.1f" % [h0, GameState.health])
	if GameState.health >= h0:
		fails.append("take_damage did not reduce health")

	# --- never fall through the world -------------------------------------
	var worst := 0.0
	Input.action_press("move_forward")
	Input.action_press("sprint")
	for i in range(600):
		await steps(1)
		var pp := p.global_position
		var gg := game.world.map.height_at(pp.x, pp.z)
		worst = maxf(worst, gg - pp.y)
		if i % 150 == 0:
			# Turn, to cover varied ground.
			game.cam.yaw += 1.1
	Input.action_release("sprint")
	Input.action_release("move_forward")
	print("worst penetration below terrain over a 10 s run: %.3f m" % worst)
	if worst > 1.2:
		fails.append("player sank %.2f m below the terrain during a long run" % worst)

	print("\nfinal pos %s  fps-equivalent frames simulated" % p.global_position)
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)


func get_nodes_in_group_count(g: String) -> int:
	return get_tree().get_nodes_in_group(g).size()


func steps(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame
