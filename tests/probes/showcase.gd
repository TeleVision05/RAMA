extends Node
## The gameplay video: a scripted camera path through the village at dusk, the river and
## the falls, then the bow drawn and fired, then a conversation. Run it under Godot's movie
## writer so frames are rendered off-screen at a fixed rate, whatever the machine is doing:
##
##   Godot --embedded --write-movie out.avi --fixed-fps 30 --resolution 1280x720 \
##       --path . res://scenes/showcase.tscn -- --quiet-test
##
## Each shot prints `[shot] name first_frame frames` so the cuts can be made from the log.
## `--still` stops after the first frame of every shot and saves it as a PNG instead, for
## checking the framing without rendering a whole film (needs a renderer, not a movie).

const FPS := 30
const DUSK := 17.3
## name, seconds, camera from [x, z, metres above ground], camera to, look-at from, look-at to
const FLY_SHOTS := [
	["village", 12.0, [-66, 104, 24], [-96, 84, 17], [-120, 40, 3], [-118, 46, 3]],
	["river", 9.0, [-58, 44, 7.5], [-28, 14, 5.5], [-34, 8, 0], [-34, 2, 0]],
	["falls", 11.0, [78, -138, 24], [52, -168, 14], [38, -196, 18], [38, -196, 12]],
]

var game: Game
var _frame: int = 0
var _stills: bool = false


func _ready() -> void:
	_stills = OS.get_cmdline_user_args().has("--still")
	_run()


func _run() -> void:
	# The root is still setting up its children during the first frame.
	await get_tree().process_frame
	var decoy := Node.new()
	get_tree().root.add_child(decoy)
	get_tree().current_scene = decoy
	var session := HUD.launch(get_tree())
	game = session.get_node("Game")
	await game.warm_up_done
	for i in range(40):
		await get_tree().process_frame  # the loading screen fades out over half a second
	var hud: CanvasLayer = session.get_node("HUD")
	game.world.sky.paused = true
	game.world.sky.set_time(DUSK)
	hud.visible = false
	game.player.lock_input(true)
	for s in FLY_SHOTS:
		await _fly(s)
	hud.visible = true
	await _bow()
	await _dialogue()
	print("[shot] end %d" % _frame)
	get_tree().quit(0)


func _gy(x: float, z: float, up: float) -> Vector3:
	return Vector3(x, game.world.map.height_at(x, z) + up, z)


func _mark(name: String, frames: int) -> void:
	print("[shot] %s %d %d" % [name, _frame, frames])


func _next_frame() -> void:
	await get_tree().process_frame
	_frame += 1


func _grab(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build/screenshots"))
	img.save_png("res://build/screenshots/showcase_%s.png" % name)


func _fly(s: Array) -> void:
	var frames := int(float(s[1]) * FPS)
	var cam := Camera3D.new()
	cam.fov = 62.0
	cam.far = 2400.0
	add_child(cam)
	cam.current = true
	_mark(String(s[0]), frames)
	for f in range(frames):
		var t := smoothstep(0.0, 1.0, float(f) / float(frames - 1))
		var a: Array = s[2]
		var b: Array = s[3]
		var la: Array = s[4]
		var lb: Array = s[5]
		var cp := _gy(lerpf(a[0], b[0], t), lerpf(a[1], b[1], t), lerpf(a[2], b[2], t))
		var lp := _gy(lerpf(la[0], lb[0], t), lerpf(la[1], lb[1], t), lerpf(la[2], lb[2], t))
		cam.global_position = cp
		cam.look_at(lp)
		# The streamers follow the player, so keep him just behind the camera, out of shot.
		var back := (cp - lp).normalized() * 6.0
		game.player.global_position = _gy(cp.x + back.x, cp.z + back.z, 0.3)
		game.world.terrain.update_focus(game.player.global_position, f == 0)
		await _next_frame()
		if _stills and f == 12:
			await _grab(String(s[0]))
			break
	cam.queue_free()


func _bow() -> void:
	var p := game.player
	var spot := Vector2(-112.0, 70.0)
	p.global_position = _gy(spot.x, spot.y, 0.2)
	p.velocity = Vector3.ZERO
	p.facing_yaw = PI * 0.15
	game.cam.yaw = p.facing_yaw
	game.cam.pitch = 0.02
	game.cam.camera().current = true
	p.lock_input(false)
	for i in range(30):
		await _next_frame()
	_mark("bow", 10 * FPS)
	Input.action_press("aim")
	for i in range(int(2.6 * FPS)):
		await _next_frame()
		if _stills and i == 60:
			await _grab("bow")
	Input.action_release("aim")
	for i in range(int(7.0 * FPS)):
		await _next_frame()
	p.lock_input(true)


func _dialogue() -> void:
	var p := game.player
	var elder: NPC = (game.npcs as NPCDirector).get_npc("suryadatta")
	var away := Vector3(0.82, 0.0, 0.58).normalized()
	p.global_position = elder.global_position + away * 2.3 + Vector3(0, 0.25, 0)
	p.facing_yaw = atan2(away.x, away.z)
	game.cam.yaw = p.facing_yaw
	game.cam.pitch = -0.02
	for i in range(20):
		await _next_frame()
	_mark("dialogue", 9 * FPS)
	elder.interact(p)
	for i in range(int(9.0 * FPS)):
		await _next_frame()
		if _stills and i == 45:
			await _grab("dialogue")
