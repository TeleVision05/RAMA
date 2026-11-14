extends SceneTree
## Guards the loop metadata on the seamless audio beds.
##
## The WAVs are synthesised to be mathematically seamless, but that is wasted
## unless Godot actually imports them as looping. `edit/loop_mode=0` in a
## .import means "Detect From WAV", not "Disabled", so with no `smpl` chunk in
## the file the beds imported as LOOP_DISABLED and played once. tools/gen_audio_sfx.py
## now writes a `smpl` chunk and pins the sidecar; this test fails if that regresses.

const LOOPING := ["res://assets/audio/fire_crackle.wav", "res://assets/audio/water_lap.wav"]
const ONE_SHOT := ["res://assets/audio/sword_swing_1.wav", "res://assets/audio/ui_click.wav"]


func _init():
	var failed := 0
	for p in LOOPING:
		var s := load(p) as AudioStreamWAV
		if s == null:
			printerr("FAIL %s: did not load as AudioStreamWAV" % p)
			failed += 1
			continue
		if s.loop_mode != AudioStreamWAV.LOOP_FORWARD:
			printerr("FAIL %s: loop_mode=%d, expected LOOP_FORWARD(1)" % [p, s.loop_mode])
			failed += 1
		elif s.loop_end <= 0:
			printerr("FAIL %s: loop_end=%d" % [p, s.loop_end])
			failed += 1
		else:
			print("ok   %s  loop_mode=FORWARD  loop_begin=%d  loop_end=%d" % [p, s.loop_begin, s.loop_end])
	for p in ONE_SHOT:
		var s := load(p) as AudioStreamWAV
		if s == null:
			printerr("FAIL %s: did not load" % p)
			failed += 1
			continue
		if s.loop_mode != AudioStreamWAV.LOOP_DISABLED:
			printerr("FAIL %s: one-shot should not loop, got %d" % [p, s.loop_mode])
			failed += 1
		else:
			print("ok   %s  loop_mode=DISABLED" % p)
	if failed > 0:
		printerr("audio_loop_test: %d FAILURE(S)" % failed)
		quit(1)
	print("audio_loop_test: PASS")
	quit(0)
