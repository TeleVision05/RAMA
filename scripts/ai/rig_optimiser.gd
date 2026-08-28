class_name RigOptimiser
extends RefCounted
## Draw-call surgery on a freshly built rig.
##
## ProcRig builds a person out of roughly forty separate MeshInstance3D nodes, which
## is exactly right for one hero: every piece can be posed independently. But most of
## those pieces never move relative to each other — the four shells that make a head,
## the two halves of a shoulder, the three pieces of a dhoti — and twenty-five
## rakshasas at forty objects each is a thousand instances in the colour pass and a
## thousand more in every shadow split.
##
## This pass merges the meshes that share BOTH a joint and a material into one mesh,
## and makes every rakshasa of a kind share the merged result, so the renderer sees a
## couple of dozen repeated resources instead of a thousand unique ones. The merge is
## computed once per archetype and cached: the twenty-fifth warrior is free.
##
## Measured on an M2 Max, 2026-08-28: a warrior goes from 41 mesh instances to 22.
##
## It is deliberately conservative — a group of one is never touched, so anything the
## animation looks up by name (the bow's "String") survives untouched.

## nodepath+group -> merged ArrayMesh, and the material that group settled on.
static var _mesh_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}


## Merge in place. `key` namespaces the cache per archetype — a warrior's head must
## never be served to an archer. Returns [instances_before, instances_after].
static func flatten(root: Node3D, key: String) -> Vector2i:
	var before := 0
	var after := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D:
			# Merge BEFORE descending. Merging frees the leaves it consumed, and a
			# freed node pushed onto the stack a moment earlier is a dangling read.
			var r := _merge_at(n as Node3D, root, key)
			before += r.x
			after += r.y
		for c in n.get_children():
			stack.append(c)
	return Vector2i(before, after)


static func _merge_at(node: Node3D, root: Node3D, key: String) -> Vector2i:
	# Group the leaf meshes hanging directly off this joint by material, keeping the
	# order they were built in so the cache key is the same for every rig of a kind.
	var order: Array = []
	var groups: Dictionary = {}
	for c in node.get_children():
		if not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		if mi.mesh == null or mi.get_child_count() > 0:
			continue
		if mi.name == "String":
			continue  # the bowstring is animated by name
		var mat: Material = mi.material_override
		if mat == null:
			continue
		var id: int = mat.get_instance_id()
		if not groups.has(id):
			groups[id] = []
			order.append(id)
		groups[id].append(mi)

	var before := 0
	var after := 0
	var path := String(root.get_path_to(node))
	for gi in range(order.size()):
		var list: Array = groups[order[gi]]
		before += list.size()
		if list.size() < 2:
			after += list.size()
			continue
		after += 1
		var ck := "%s|%s|%d" % [key, path, gi]
		var merged: ArrayMesh = _mesh_cache.get(ck, null)
		if merged == null:
			var parts: Array = []
			for mi in list:
				parts.append({"mesh": (mi as MeshInstance3D).mesh, "xform": (mi as MeshInstance3D).transform})
			merged = MeshKit.bake(parts)
			_mesh_cache[ck] = merged
			_mat_cache[ck] = (list[0] as MeshInstance3D).material_override
		var out := MeshInstance3D.new()
		out.name = "Merged%d" % gi
		out.mesh = merged
		out.material_override = _mat_cache[ck]
		out.cast_shadow = (list[0] as MeshInstance3D).cast_shadow
		node.add_child(out)
		for mi in list:
			(mi as MeshInstance3D).free()
	return Vector2i(before, after)


static func clear_cache() -> void:
	_mesh_cache.clear()
	_mat_cache.clear()
