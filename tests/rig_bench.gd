extends Node


func _ready() -> void:
	await get_tree().process_frame
	var host := Node3D.new()
	add_child(host)
	var times: Array[float] = []
	for i in range(10):
		var t0 := Time.get_ticks_usec()
		var r := ProcRig.new()
		r.configure({"seed": i, "skin": "skin_warm", "cloth": "cloth_saffron", "cloth2": "cloth_white", "topknot": true, "jewellery": true})
		host.add_child(r)
		r.build()
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		times.append(ms)
		print("  build %2d: %7.2f ms   nodes=%d  meshcache=%s" % [i, ms, _count(r), MeshKit.cache_stats()])
	print(
		(
			"first=%.1f ms  last=%.1f ms  mean of last 5=%.1f ms"
			% [times[0], times[times.size() - 1], (times[5] + times[6] + times[7] + times[8] + times[9]) / 5.0]
		)
	)
	get_tree().quit()


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
