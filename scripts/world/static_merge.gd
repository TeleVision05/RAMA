class_name StaticMerge
extends RefCounted
## Collapse a subtree of static MeshInstance3Ds into far fewer draw calls.
##
## The settlement is ~100 separate meshes — huts, granaries, racks, pots, fences — and
## none of them ever move. Each was its own draw call. Merging them by MATERIAL within
## a SPATIAL CELL keeps frustum culling working (one giant merged mesh would always be
## drawn) while cutting the call count by roughly five to one.
##
## Must run AFTER anything that reads per-mesh AABBs — the collider harvest does — or
## the merged bounds are used as building footprints.


## Returns [draws_before, draws_after].
static func merge(root: Node3D, cell: float = 22.0, min_group: int = 2) -> Array:
	var groups: Dictionary = {}  # "cx_cz|mat_id" -> {mat, parts, nodes}
	_collect(root, root, cell, groups)

	# GDScript lambdas capture by value, so counting inside the walk silently reported
	# zero. Count from the collected groups instead.
	var before := 0
	for k in groups:
		before += (groups[k].nodes as Array).size()
	var after := 0
	for key in groups:
		var g: Dictionary = groups[key]
		if g.nodes.size() < min_group:
			after += g.nodes.size()
			continue
		var merged := MeshKit.bake(g.parts)
		var mi := MeshInstance3D.new()
		mi.mesh = merged
		mi.material_override = g.mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi)
		mi.name = "Merged_" + String(key).replace("|", "_")
		for n in g.nodes:
			n.get_parent().remove_child(n)
			n.queue_free()
		after += 1
	return [before, after]


static func _collect(root: Node3D, n: Node, cell: float, groups: Dictionary) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			# Skip anything that is not plain static decor.
			if mi.mesh == null or mi.get_child_count() > 0:
				continue
			var mat: Material = mi.material_override
			if mat == null and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)
			if mat == null:
				continue
			var gp: Vector3 = mi.global_position
			var key := "%d_%d|%d" % [int(floor(gp.x / cell)), int(floor(gp.z / cell)), mat.get_instance_id()]
			if not groups.has(key):
				groups[key] = {"mat": mat, "parts": [], "nodes": []}
			# Bake into the ROOT's local space so the merged node can live under it.
			var xform: Transform3D = root.global_transform.affine_inverse() * mi.global_transform
			groups[key].parts.append({"mesh": mi.mesh, "xform": xform})
			groups[key].nodes.append(mi)
		elif c.get_child_count() > 0:
			_collect(root, c, cell, groups)
