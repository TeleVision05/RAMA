extends Node
## Does the LOD hand-over pop?
##
## A screenshot of a distant tree cannot answer that — everything is small and the
## terrain gets in the way. So this renders the SAME tree as FULL, MID and FAR, in
## isolation, at the same framing, and measures the fraction of the frame its silhouette
## covers. Two LODs that cover the same area in the same shape cannot pop; a hand-over
## that changes coverage by more than a few percent will read as the tree thinning or
## thickening as you walk toward it.

const SHOT_DIR := "res://build/screenshots/"

var cam: Camera3D
var holder: Node3D


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _cover(img: Image) -> float:
	# Background is pure magenta; anything else is the tree.
	var n := 0
	var tot := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			tot += 1
			var c := img.get_pixel(x, y)
			if not (c.r > 0.6 and c.g < 0.25 and c.b > 0.6):
				n += 1
	return float(n) / float(maxi(tot, 1))


func _run() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(1.0, 0.0, 1.0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.68, 0.8)
	e.ambient_light_energy = 0.9
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.6
	sun.rotation = Vector3(deg_to_rad(-46.0), deg_to_rad(35.0), 0.0)
	add_child(sun)
	holder = Node3D.new()
	add_child(holder)
	cam = Camera3D.new()
	cam.fov = 30.0
	cam.near = 0.05
	add_child(cam)
	cam.current = true

	var names := ["banyan", "palm", "mango", "sal", "bush"]
	var species := [
		TreeBuilder.Species.BANYAN, TreeBuilder.Species.PALM, TreeBuilder.Species.MANGO, TreeBuilder.Species.SAL, TreeBuilder.Species.BUSH
	]
	var fails: Array[String] = []
	print("%-8s %8s %8s %8s   %8s %8s" % ["species", "FULL%", "MID%", "FAR%", "M/F", "F/M"])
	for k in range(species.size()):
		var sp: int = species[k]
		var covers: Array[float] = []
		# ONE framing per species, taken from the FULL mesh, used for all three LODs.
		# Framing each LOD on its own AABB is the obvious thing and it is wrong: a
		# smaller billboard just pulls the camera in, so every LOD measures the same
		# coverage and the harness reports that nothing ever pops.
		var frame: AABB = TreeBuilder.mesh(sp, 1, TreeBuilder.Lod.FULL).get_aabb()
		for lod in range(3):
			for c in holder.get_children():
				holder.remove_child(c)
				c.queue_free()
			await get_tree().process_frame
			var mi := MeshInstance3D.new()
			mi.mesh = TreeBuilder.mesh(sp, 1, lod)
			holder.add_child(mi)
			var ctr := frame.get_center()
			var rad: float = maxf(frame.size.length() * 0.5, 0.5)
			var d: float = rad / tan(deg_to_rad(cam.fov * 0.5)) * 1.12
			cam.look_at_from_position(ctr + Vector3(d * 0.94, d * 0.22, d * 0.26).normalized() * d, ctr, Vector3.UP)
			# The shaders measure their LOD ramp from lod_focus, and each LOD only keeps
			# its pixels inside its own distance band — the FAR billboard discards every
			# pixel below LOD_MID_END, which is the correct behaviour and would otherwise
			# make this harness report 0% coverage for it. So the ramp is fed the distance
			# the LOD is FOR, while the camera stays where the framing wants it.
			var ref: float = [4.0, 40.0, 200.0][lod]
			TreeBuilder.set_lod_focus(Vector3(ref, 0.0, 0.0))
			for f in range(8):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png(SHOT_DIR + "lodcmp_%s_%d.png" % [names[k], lod])
			covers.append(_cover(img))
		var mf: float = covers[1] / maxf(covers[0], 1e-4)
		var ff: float = covers[2] / maxf(covers[1], 1e-4)
		print("%-8s %7.2f%% %7.2f%% %7.2f%%   %7.2f  %7.2f" % [names[k], covers[0] * 100.0, covers[1] * 100.0, covers[2] * 100.0, mf, ff])
		# A hand-over that changes the silhouette by more than 35% is a visible pop.
		if mf < 0.65 or mf > 1.45:
			fails.append("%s FULL->MID silhouette ratio %.2f" % [names[k], mf])
		if ff < 0.65 or ff > 1.45:
			fails.append("%s MID->FAR silhouette ratio %.2f" % [names[k], ff])
	for f in fails:
		print("  ! " + f)
	print("RESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	get_tree().quit(0 if fails.is_empty() else 1)
