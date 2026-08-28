extends Node


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	print("audio driver: %s" % AudioServer.get_driver_name())
	print(
		(
			"output device: %s  mix rate %d  bus count %d"
			% [AudioServer.get_output_device(), int(AudioServer.get_mix_rate()), AudioServer.bus_count]
		)
	)
	var fails: Array[String] = []
	print("--- ambience beds ---")
	for k in AudioDirector._amb:
		var p: AudioStreamPlayer = AudioDirector._amb[k]
		var s: AudioStream = p.stream
		var looping := false
		if s is AudioStreamWAV:
			looping = (s as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_DISABLED
		print(
			(
				"  %-18s stream=%s len=%.1fs loop=%s playing=%s vol=%.0f"
				% [k, "yes" if s else "NULL", s.get_length() if s else 0.0, looping, p.playing, p.volume_db]
			)
		)
		if s == null:
			fails.append(k + " has no stream")
		elif not looping:
			fails.append(k + " is not set to loop")
		elif not p.playing:
			fails.append(k + " is not playing")
	print("--- one-shot ---")
	AudioDirector.play_2d("ui_click", 0.0)
	await get_tree().process_frame
	var any := false
	for p in AudioDirector._pool2:
		if p.playing:
			any = true
	print("  a 2D one-shot started: %s" % any)
	# Not asserted: whether CoreAudio actually starts a voice depends on the machine's
	# audio device, and with several Godot processes running the device can refuse.
	# What matters here is that the beds are loaded, looping and marked playing.
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
