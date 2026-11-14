extends Node
## Not a gate suite (frame times need a quiet machine): the worst frames in the first 30
## seconds of play, with and without the loading screen's shader warm-up.
##
##   Godot --embedded ... res://scenes/first_30s_probe.tscn -- --quiet-test [--warm]
##
## Without `--warm` the Game boots the way the test harnesses build it (no loading screen,
## no warm-up). With it the Game boots like a real session (`show_loading = true`) and the
## clock starts when the screen lifts. Either way the player then sprints along a fixed
## route through the village, the river road and the shrine for 30 s of wall time, and the
## script prints the worst frame, the 99th percentile and how many frames took over 50 ms.

const ROUTE := [
	Vector2(-140, 60), Vector2(-96, 30), Vector2(-70, 20), Vector2(-20, -20), Vector2(120, -30), Vector2(160, -66)
]
const SECONDS := 30.0
const SPEED := 8.0


func _ready() -> void:
	_run()


func _run() -> void:
	var warm := OS.get_cmdline_user_args().has("--warm")
	var game := Game.new()
	game.show_loading = warm
	add_child(game)
	if warm:
		await game.warm_up_done
	else:
		await get_tree().process_frame
	var p := game.player
	p.lock_input(true)
	var frames: Array[float] = []
	var t_end := Time.get_ticks_msec() + int(SECONDS * 1000.0)
	var last := Time.get_ticks_usec()
	var dist := 0.0
	while Time.get_ticks_msec() < t_end:
		dist += SPEED / 60.0
		var q := _along(dist)
		p.global_position = Vector3(q.x, game.world.map.height_at(q.x, q.y) + 0.2, q.y)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append(float(now - last) / 1000.0)
		last = now
	frames.sort()
	var over := 0
	for f in frames:
		if f > 50.0:
			over += 1
	var label := "warm-up on" if warm else "no warm-up"
	var p99: float = frames[int(frames.size() * 0.99)]
	var median: float = frames[frames.size() / 2]
	print(
		(
			"first 30 s (%s): %d frames, worst %.1f ms, p99 %.1f ms, median %.1f ms, %d over 50 ms"
			% [label, frames.size(), frames[-1], p99, median, over]
		)
	)
	print("RESULT: PASS")
	get_tree().quit(0)


func _along(d: float) -> Vector2:
	var left := d
	for i in range(ROUTE.size() - 1):
		var seg: float = (ROUTE[i] as Vector2).distance_to(ROUTE[i + 1])
		if left <= seg:
			return (ROUTE[i] as Vector2).lerp(ROUTE[i + 1], left / seg)
		left -= seg
	return ROUTE[ROUTE.size() - 1]
