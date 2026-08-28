extends SceneTree
## Close-ups of the finished rig: the face at conversation distance from three angles,
## a hand closed round a bow, a bare foot on the ground, the dhoti mid-stride, hair in
## silhouette, and a line-up of villagers to prove twelve people are twelve people.


# The root is still assembling its children during `_init`; adding to it before the
# first frame silently leaves the whole scene outside the tree.
func _init() -> void:
	await process_frame
	var root := get_root()
	var w := Node3D.new()
	root.add_child(w)
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.14, 0.16, 0.20)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.56, 0.63, 0.78)
	e.ambient_light_energy = 0.45
	e.tonemap_mode = Environment.TONE_MAPPER_AGX
	e.tonemap_white = 8.0
	e.ssao_enabled = true
	e.ssao_radius = 0.14
	e.ssao_intensity = 2.2
	var we := WorldEnvironment.new()
	we.environment = e
	w.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.7
	key.shadow_enabled = true
	key.light_color = Color(1.0, 0.95, 0.88)
	w.add_child(key)
	key.look_at_from_position(Vector3(3, 5, -4), Vector3.ZERO, Vector3.UP)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.5
	fill.light_color = Color(0.6, 0.72, 1.0)
	w.add_child(fill)
	fill.look_at_from_position(Vector3(-4, 2, 3), Vector3.ZERO, Vector3.UP)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 30)
	floor_mi.mesh = pm
	floor_mi.material_override = Mats.pbr("dirt", 8.0)
	w.add_child(floor_mi)
	var cam := Camera3D.new()
	cam.fov = 34.0
	cam.near = 0.02
	root.add_child(cam)
	cam.current = true

	# --- the hero, with his bow, for the close work
	var hero := _make(w, {"seed": 1, "topknot": true, "jewellery": true}, Vector3.ZERO)
	var bow := Weapons.bow()
	hero.hand_attach["L"].add_child(bow)
	bow.position = Vector3(0, -0.03, 0.02)
	bow.rotation = Vector3(0.10, 0.0, 1.20)
	for i in range(90):
		hero.animate(1.0 / 60.0, {"speed": 0.0, "on_floor": true})
	var eyes: Vector3 = hero.eye_centre()
	print(
		(
			"tris: shell=%d hand=%d foot=%d"
			% [
				MeshKit.head_shell(1.0, 0, 0).get_faces().size() / 3,
				MeshKit.hand(0.155, 1.0, MeshKit.Grip.CLOSED, 1.0, 0).get_faces().size() / 3,
				MeshKit.foot(0.24, 1.0, 1.0, 0).get_faces().size() / 3,
			]
		)
	)
	var shots := {
		"face_front": [eyes + Vector3(0.0, 0.02, -0.62), eyes],
		"face_three": [eyes + Vector3(-0.36, 0.06, -0.50), eyes],
		"face_side": [eyes + Vector3(-0.62, 0.02, -0.10), eyes],
		"hand_bow": [(hero.hand["L"] as Node3D).global_position + Vector3(0.10, 0.10, -0.34), (hero.hand["L"] as Node3D).global_position],
		"foot": [Vector3(0.30, 0.22, -0.46), Vector3(0.10, 0.045, -0.02)],
		"hair_back": [eyes + Vector3(0.10, 0.16, 0.60), eyes + Vector3(0, 0.05, 0)],
	}
	for k in shots:
		var pair: Array = shots[k]
		cam.look_at_from_position(pair[0], pair[1], Vector3.UP)
		for i in range(4):
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://build/screenshots/char_%s.png" % k)
		print("char_%s" % k)

	# --- mid-stride, so the dhoti's swing shows
	hero.global_position = Vector3.ZERO
	for i in range(70):
		hero.global_position += Vector3(0, 0, -2.6) / 60.0
		hero.animate(1.0 / 60.0, {"speed": 2.6, "on_floor": true})
	cam.look_at_from_position(hero.global_position + Vector3(2.3, 0.85, -0.5), hero.global_position + Vector3(0, 0.75, 0), Vector3.UP)
	for i in range(2):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/char_dhoti_stride.png")
	hero.queue_free()
	await process_frame

	# --- eight villagers, all from one config plus a seed
	var tints := [Color(1, 1, 1), Color(0.90, 0.80, 0.72), Color(0.78, 0.66, 0.58), Color(1.02, 0.94, 0.86)]
	var cloths := ["cloth_saffron", "cloth_white", "cloth_indigo"]
	for i in range(8):
		var h: float = 1.58 + float(i % 4) * 0.07
		var s: float = h / 1.80
		var cfg := {
			"seed": 40 + i * 13,
			"height": h,
			"hip_h": 0.94 * s,
			"thigh": 0.46 * s,
			"shin": 0.44 * s,
			"foot": 0.24 * s,
			"spine": 0.30 * s,
			"chest": 0.26 * s,
			"neck": 0.09 * s,
			"head": 0.115 * s,
			"shoulder_w": 0.175 * s,
			"upper_arm": 0.30 * s,
			"lower_arm": 0.28 * s,
			"hand": 0.10 * s,
			"hip_w": 0.092 * s,
			"build": 0.90 + 0.06 * float(i % 3),
			"cloth": cloths[i % 3],
			"skin_tint": tints[i % 4],
			"topknot": false,
			"jewellery": i % 4 == 0,
			"beard": i % 3 == 0,
		}
		var v := _make(w, cfg, Vector3(-2.45 + 0.70 * float(i), 0, 0))
		v.fit_garments(s, false)
		for k in range(40):
			v.animate(1.0 / 60.0, {"speed": 0.0, "on_floor": true})
	cam.look_at_from_position(Vector3(0.0, 1.35, -5.4), Vector3(0, 0.95, 0), Vector3.UP)
	for i in range(6):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/char_lineup.png")
	cam.look_at_from_position(Vector3(-0.6, 1.62, -1.95), Vector3(-0.6, 1.42, 0), Vector3.UP)
	for i in range(3):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/char_heads.png")
	print("done")
	quit()


func _make(w: Node3D, over: Dictionary, at: Vector3) -> ProcRig:
	var rig := ProcRig.new()
	var cfg := {"skin": "skin_warm", "cloth": "cloth_saffron", "cloth2": "cloth_white"}
	cfg.merge(over, true)
	rig.configure(cfg)
	w.add_child(rig)
	rig.global_position = at
	rig.build()
	rig.ground_fn = func(_x, _z): return 0.0
	return rig
