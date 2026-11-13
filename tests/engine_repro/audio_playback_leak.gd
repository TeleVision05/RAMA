extends SceneTree
## Engine-only reproduction of "N ObjectDB instances were leaked at exit" listing only
## AudioStreamWAV and AudioStreamPlaybackWAV (Godot 4.7.2). No game code: one looping
## AudioStreamPlayer plays, then the program quits. Run it in an empty project:
##
##   Godot --headless --audio-driver Dummy --path <empty project> \
##       --script <this file> [-- stop | free]
##
## Measured 2026-11-13: "2 ObjectDB instances were leaked at exit" in 4 runs of 4 with no
## argument, and in 5 of 6 with `stop` (stopped one frame before quitting). With `free`
## (player stopped, freed, then 30 frames run) nothing leaked in 3 runs of 3: the AudioServer drops a playback only after
## several mix cycles, which never come once quit has begun. The game's ambience beds
## and music are alive at quit by design, so the gate's exit report shows them.


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 22050
	var data := PackedByteArray()
	data.resize(44100)
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = 22050
	var p := AudioStreamPlayer.new()
	p.stream = wav
	root.add_child(p)
	p.play()
	for i in range(5):
		await process_frame
	var args := OS.get_cmdline_user_args()
	if args.has("stop"):
		p.stop()
		await process_frame
	if args.has("free"):
		p.stop()
		p.free()
		for i in range(30):
			await process_frame
	quit(0)
