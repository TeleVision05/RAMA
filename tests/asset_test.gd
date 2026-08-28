extends Node


## Every generated texture and sound must actually LOAD. A texture that silently fails
## shows up as a white surface at runtime and is easy to miss; this catches it.
func _ready() -> void:
	var fails: Array[String] = []
	var counts := {"tex": 0, "aud": 0}
	for dir_name in ["textures", "audio"]:
		var base := "res://assets/%s" % dir_name
		var d := DirAccess.open(base)
		if d == null:
			fails.append("cannot open " + base)
			continue
		for f in d.get_files():
			if f.ends_with(".import") or f.ends_with(".uid"):
				continue
			var path := base + "/" + f
			var r: Resource = load(path)
			if r == null:
				fails.append("failed to load: " + path)
				continue
			if r is Texture2D:
				counts.tex += 1
				var t := r as Texture2D
				if t.get_width() <= 0 or t.get_height() <= 0:
					fails.append("zero-size texture: " + path)
			elif r is AudioStream:
				counts.aud += 1
				var a := r as AudioStream
				if a.get_length() <= 0.01:
					fails.append("zero-length audio: " + path)
	print("loaded %d textures, %d audio streams" % [counts.tex, counts.aud])
	# Shaders must compile.
	var sd := DirAccess.open("res://shaders")
	var shader_n := 0
	if sd:
		for f in sd.get_files():
			if not f.ends_with(".gdshader"):
				continue
			var sh: Shader = load("res://shaders/" + f)
			if sh == null:
				fails.append("shader failed to load: " + f)
			else:
				shader_n += 1
	print("loaded %d shaders" % shader_n)
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	get_tree().quit(0 if fails.is_empty() else 1)
