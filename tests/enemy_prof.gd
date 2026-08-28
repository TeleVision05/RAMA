extends Node
## What the enemy system costs per frame, honestly.
##
## ARCHITECTURE.md's rule for frame cost: do not compare two runs, and do not trust a
## mean. This alternates the conditions INSIDE one process and reports the MEDIAN of
## the paired differences, in three steps, so a single number cannot hide which part
## is expensive:
##
##   none  25 enemies present, built and rendered, but neither posed nor thinking
##   pose  + `_process`          (ProcRig/BeastRig posing and the transform writes)
##   both  + `_physics_process`  (perception, the state machine, steering, motion)
##
## Every number is guarded. If Rama dies, `Game._on_player_died` teleports him to the
## village and the whole arena streams out to dormant — at which point "the enemies
## are cheap" only means "there are no enemies". The guard line at the end says how
## many enemies were inside AI_DIST in the WORST sampled frame, and refuses to let the
## result stand if that is not all of them.
##
## `tools/gd.sh scene res://scenes/enemy_prof.tscn`

var game: Game
var dir_node: EnemyDirector

var _ph: float = 0.0
var _pr: float = 0.0
var _deaths: int = 0
var _min_active: int = 99999
var _max_dist: float = 0.0
var _keep_alive: Array = []
var _valid: bool = true


func _ready() -> void:
	_run()


## Health is topped up on the PHYSICS frame, not the render frame: several rakshasas
## can land blows inside one 55 ms render frame and take Rama from full to zero
## between two top-ups on a slow machine.
func _physics_process(_d: float) -> void:
	if _keep_alive.is_empty():
		return
	GameState.health = GameState.max_health
	for e in _keep_alive:
		if is_instance_valid(e) and e.is_alive():
			e.health = e.max_health


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	game = Game.new()
	game.spawn_hud = false
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p := game.player
	game.world.sky.paused = true
	game.world.sky.set_time(10.4)
	EventBus.player_died.connect(_on_death)

	dir_node = EnemyDirector.new()
	dir_node.name = "EnemyDirector"
	game.world.add_child(dir_node)
	dir_node.setup(game.world.map, game.world.sky)
	dir_node.despawn_all()
	await _steps(30)

	var made: Array[Enemy] = []
	for i in range(25):
		var a: float = TAU * float(i) / 25.0
		var r: float = 8.0 + float(i % 5) * 3.0
		var want := Vector2(p.global_position.x + cos(a) * r, p.global_position.z + sin(a) * r)
		var spot := dir_node.find_ground_spot(want, 7.0)
		if not is_finite(spot.x):
			continue
		var e := dir_node.spawn_at(
			[
				EnemyTypes.Kind.WARRIOR,
				EnemyTypes.Kind.WARRIOR,
				EnemyTypes.Kind.ARCHER,
				EnemyTypes.Kind.BEAST,
				EnemyTypes.Kind.ELITE
			][i % 5],
			spot,
			"prof"
		)
		if e:
			made.append(e)
	_keep_alive = made
	for e in made:
		e.alert_from(p.global_position, true)
	var guard := 0
	while dir_node.pending_builds() > 0 and guard < 600:
		await get_tree().process_frame
		guard += 1
	await _steps(60)
	print("[prof] %d enemies fighting, all rigs built after %d frames" % [made.size(), guard])

	# --- 3-condition round robin, paired inside one process -----------------
	var d_pose: Array[float] = []
	var d_brain: Array[float] = []
	var d_all: Array[float] = []
	var m_none: Array[float] = []
	var m_both: Array[float] = []
	var ph_none: Array[float] = []
	var ph_both: Array[float] = []
	var pr_none: Array[float] = []
	var pr_both: Array[float] = []
	for pair in range(12):
		var a := await _block(made, false, false, 10)
		var b := await _block(made, true, false, 10)
		var c := await _block(made, true, true, 10)
		d_pose.append(b - a)
		d_brain.append(c - b)
		d_all.append(c - a)
		m_none.append(a)
		m_both.append(c)
		ph_both.append(_ph)
		pr_both.append(_pr)
		var z := await _block(made, false, false, 8)
		m_none.append(z)
		ph_none.append(_ph)
		pr_none.append(_pr)
	for arr in [d_pose, d_brain, d_all, m_none, m_both, ph_none, ph_both, pr_none, pr_both]:
		arr.sort()
	print("[ab] median frame: none %.2f ms   both %.2f ms" % [m_none[m_none.size() / 2], m_both[m_both.size() / 2]])
	print("[ab] median PAIRED difference, %d enemies:" % made.size())
	print("[ab]    posing only        %+.2f ms/frame" % d_pose[d_pose.size() / 2])
	print("[ab]    brain+motion       %+.2f ms/frame" % d_brain[d_brain.size() / 2])
	print(
		(
			"[ab]    WHOLE SYSTEM       %+.2f ms/frame  (%.3f ms each)"
			% [d_all[d_all.size() / 2], d_all[d_all.size() / 2] / float(maxi(made.size(), 1))]
		)
	)
	print("[ab] Performance monitors (median over the paired blocks):")
	print(
		(
			"[ab]    TIME_PROCESS          %.2f ms -> %.2f ms   (%+.2f)"
			% [
				pr_none[pr_none.size() / 2],
				pr_both[pr_both.size() / 2],
				pr_both[pr_both.size() / 2] - pr_none[pr_none.size() / 2]
			]
		)
	)
	print(
		(
			"[ab]    TIME_PHYSICS_PROCESS  %.2f ms -> %.2f ms   (%+.2f)"
			% [
				ph_none[ph_none.size() / 2],
				ph_both[ph_both.size() / 2],
				ph_both[ph_both.size() / 2] - ph_none[ph_none.size() / 2]
			]
		)
	)
	print("[ab] load %s" % _load())
	_report_guard("the A/B sweep", made.size())

	# --- 300 frames of the whole system running, monitors as measured --------
	for e in made:
		e.set_physics_process(true)
		e.set_process(true)
	await _steps(30)
	_deaths = 0
	_min_active = 99999
	var t0 := Time.get_ticks_usec()
	for i in range(300):
		await get_tree().process_frame
		var act := 0
		for e in made:
			if is_instance_valid(e) and e.global_position.distance_to(p.global_position) <= Enemy.AI_DIST:
				act += 1
		_min_active = mini(_min_active, act)
	var wall := float(Time.get_ticks_usec() - t0) / 1000.0
	print(
		(
			"[300f] 300 frames with %d enemies fighting: %.2f ms/frame (%.1f FPS)"
			% [made.size(), wall / 300.0, 300000.0 / wall]
		)
	)
	print(
		(
			"[300f] Performance.TIME_PROCESS         = %.2f ms"
			% (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		)
	)
	print(
		(
			"[300f] Performance.TIME_PHYSICS_PROCESS = %.2f ms"
			% (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		)
	)
	print(
		(
			"[300f] draw calls %d, objects %d, nodes %d"
			% [
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
			]
		)
	)
	_report_guard("the 300-frame block", made.size())

	print("\nRESULT: " + ("PASS" if _valid else "NOT VERIFIED"))
	get_tree().quit(0 if _valid else 1)


func _report_guard(what: String, n: int) -> void:
	print(
		(
			"[guard] %s: player deaths=%d | fewest enemies inside AI_DIST in any sampled frame=%d of %d | furthest %.1f m"
			% [what, _deaths, _min_active, n, _max_dist]
		)
	)
	if _deaths > 0 or _min_active < n:
		_valid = false
		print("[guard] !! NOT VALID: the crowd was not fully active throughout, so the cost above is understated")


func _on_death() -> void:
	_deaths += 1


func _block(made: Array, pose: bool, brain: bool, frames: int) -> float:
	for e in made:
		if is_instance_valid(e):
			e.set_physics_process(brain)
			e.set_process(pose)
	for i in range(3):
		await get_tree().process_frame  # discard the transition
	var t := Time.get_ticks_usec()
	for i in range(frames):
		await get_tree().process_frame
		var act := 0
		var far := 0.0
		for e in made:
			if not is_instance_valid(e):
				continue
			var d: float = e.global_position.distance_to(game.player.global_position)
			far = maxf(far, d)
			if d <= Enemy.AI_DIST:
				act += 1
		_min_active = mini(_min_active, act)
		_max_dist = maxf(_max_dist, far)
	_ph = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_pr = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	return float(Time.get_ticks_usec() - t) / 1000.0 / float(frames)


func _steps(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame


func _load() -> String:
	var out: Array = []
	OS.execute("/usr/sbin/sysctl", ["-n", "vm.loadavg"], out)
	return String(out[0]).strip_edges() if not out.is_empty() else "?"
