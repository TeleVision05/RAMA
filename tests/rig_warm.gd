extends Node
## Warm rig-build cost. `rig_bench` rolls a fresh seed every time, so it measures the
## cost of a rig nobody has built before; this one cycles a small set of seeds, which is
## what a village of twelve actually does once its archetypes are in the mesh cache.


func _ready() -> void:
	await get_tree().process_frame
	for a in OS.get_cmdline_user_args():
		if a == "--nomerge":
			ProcRig.merge_enabled = false
	var host := Node3D.new()
	add_child(host)
	var times: Array[float] = []
	for i in range(24):
		var t0 := Time.get_ticks_usec()
		var r := ProcRig.new()
		r.configure(
			{
				"seed": i % 4,
				"skin": "skin_warm",
				"cloth": "cloth_saffron",
				"cloth2": "cloth_white",
				"topknot": i % 4 == 0,
				"jewellery": true
			}
		)
		host.add_child(r)
		r.build()
		times.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		if i >= 20:
			print("  build %2d: %7.2f ms  nodes=%d  %s" % [i, times[i], _count(r), MeshKit.cache_stats()])
		r.queue_free()
	var warm := 0.0
	for i in range(12, 24):
		warm += times[i]
	print("cold=%.1f ms   warm mean(12..23)=%.2f ms" % [times[0], warm / 12.0])
	get_tree().quit()


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c
