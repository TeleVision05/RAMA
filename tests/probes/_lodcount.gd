extends Node


func _ready() -> void:
	await get_tree().process_frame
	var host := Node3D.new()
	add_child(host)
	var r := ProcRig.new()
	r.configure({"seed": 1, "skin": "skin_warm", "cloth": "cloth_saffron", "cloth2": "cloth_white", "topknot": true, "jewellery": true})
	host.add_child(r)
	r.build()
	for lvl in [0, 1]:
		r.set_lod(lvl)
		var tris := 0
		var draws := 0
		var stack: Array = [r]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is MeshInstance3D and (n as MeshInstance3D).is_visible_in_tree():
				tris += ((n as MeshInstance3D).mesh as ArrayMesh).get_faces().size() / 3
				draws += 1
		print("LOD %d: %d visible meshes, %d tris" % [lvl, draws, tris])
	print("grip wrap: %d tris" % (MeshKit.wrap(0.128, 0.0246, 11.0, 0.0028, 4).get_faces().size() / 3))
	get_tree().quit()
