extends Node


## Every .gd in the project must parse and load. A file with a parse error silently
## disappears from the game - that is how the wildlife system went missing once.
func _ready() -> void:
	var bad: Array[String] = []
	var n := 0
	var stack: Array[String] = ["res://scripts", "res://tests"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for sub in d.get_directories():
			stack.append(dir + "/" + sub)
		for f in d.get_files():
			if not f.ends_with(".gd"):
				continue
			var path := dir + "/" + f
			n += 1
			var s: Script = load(path)
			if s == null:
				bad.append(path + "  (failed to load)")
			elif not s.can_instantiate() and s.get_instance_base_type() == "":
				bad.append(path + "  (not instantiable)")
	print("scripts checked: %d" % n)
	print("RESULT: " + ("PASS" if bad.is_empty() else "FAIL"))
	for b in bad:
		print("  ! " + b)
	get_tree().quit(0 if bad.is_empty() else 1)
