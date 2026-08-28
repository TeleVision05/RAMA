extends SceneTree


func _init():
	for p in [
		"res://assets/audio/fire_crackle.wav",
		"res://assets/audio/water_lap.wav",
		"res://assets/audio/amb_river.wav",
		"res://assets/audio/sword_swing_1.wav"
	]:
		var s = load(p)
		if s == null:
			print("%-40s LOAD FAILED" % p)
			continue
		print(
			(
				"%-40s class=%s loop_mode=%d loop_begin=%d loop_end=%d frames=%d"
				% [p, s.get_class(), s.loop_mode, s.loop_begin, s.loop_end, s.data.size() / 2 if s.format == 0 else -1]
			)
		)
	quit()
