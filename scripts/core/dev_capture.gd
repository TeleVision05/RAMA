extends Node
## Dev harness: headless-friendly automated capture + auto-quit.
## Usage: godot --  --capture-at=1.0,4.0 --capture-dir=res://build/screenshots --quit-after=5 --tag=world
## Drives the whole build->run->observe loop. Not active unless --capture-at is passed.

var _times: Array[float] = []
var _dir: String = "res://build/screenshots"
var _tag: String = "shot"
var _quit_after: float = -1.0
var _t: float = 0.0
var _idx: int = 0
var _active: bool = false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture-at="):
			for s in a.substr(13).split(","):
				if s.strip_edges() != "":
					_times.append(float(s))
			_active = true
		elif a.begins_with("--capture-dir="):
			_dir = a.substr(14)
		elif a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--quit-after="):
			_quit_after = float(a.substr(13))
	_times.sort()
	if _active:
		print("[capture] armed times=", _times, " tag=", _tag, " quit=", _quit_after)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	set_process(_active or _quit_after > 0.0)


func _process(delta: float) -> void:
	_t += delta
	while _idx < _times.size() and _t >= _times[_idx]:
		_shoot(_idx)
		_idx += 1
	if _quit_after > 0.0 and _t >= _quit_after:
		print("[capture] done, quitting at t=%.2f" % _t)
		get_tree().quit(0)


func _shoot(i: int) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		push_error("[capture] null image")
		return
	var path := "%s/%s_%02d.png" % [_dir, _tag, i]
	var err := img.save_png(path)
	print("[capture] t=%.2f -> %s (err=%d) %dx%d" % [_t, path, err, img.get_width(), img.get_height()])


## Manual screenshot (bound to F12 in-game).
func snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img:
		img.save_png("res://build/screenshots/%s.png" % name)
		print("[capture] manual -> ", name)
