extends Node
## Why is a canopy seen from below black? Four hypotheses, one framing, one process.
##
## A: as shipped.
## B: sun shadows OFF.        Godot multiplies BACKLIGHT by the light's attenuation,
##                            which INCLUDES the shadow term, so an interior leaf that
##                            is in the canopy's own shadow receives no translucency at
##                            all — exactly where translucency is the only light there is.
## C: ambient energy x2.5.    Tests whether ambient is simply too weak for undersides.
## D: translucency x4.        Tests the strength of the backlight term itself.
## E: B + D.
##
## Reports median luminance over the NON-SKY pixels, which is the foliage.

var _game: Game
var _cam: Camera3D
var _sun: DirectionalLight3D
var _env: Environment


func _ready() -> void:
	await get_tree().process_frame
	_run()


func _mats() -> Array:
	var out := []
	for sp in range(TreeBuilder.SPECIES_COUNT):
		for lod in range(3):
			var m := TreeBuilder.leaf_material(sp, lod)
			if m and not out.has(m):
				out.append(m)
	return out


func _shot(tag: String) -> void:
	for i in range(24):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://build/screenshots/qad_%s.png" % tag)
	print("shot qad_%s" % tag)


func _run() -> void:
	_game = Game.new()
	_game.spawn_hud = false
	add_child(_game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = _game.player
	p.lock_input(true)
	_game.world.sky.paused = true
	_game.world.sky.set_time(11.0)

	_cam = Camera3D.new()
	_cam.fov = 34.0
	_cam.near = 0.05
	add_child(_cam)
	_cam.current = true

	for n in _game.world.find_children("*", "DirectionalLight3D", true, false):
		if _sun == null:
			_sun = n
	for n in _game.world.find_children("*", "WorldEnvironment", true, false):
		_env = (n as WorldEnvironment).environment
	print("sun=%s env=%s" % [_sun, _env != null])

	var at := Vector2(-196, -20)
	var g: float = _game.world.map.height_at(at.x, at.y)
	var pos := Vector3(at.x, g + 0.2, at.y)
	p.global_position = pos
	_game.world.terrain.update_focus(pos, true)
	for i in range(10):
		for n in [_game.vegetation, _game.vfx, _game.wildlife, _game.solids]:
			if n and n.has_method("update_focus"):
				n.update_focus(pos)
		await get_tree().physics_frame
	var base := Vector3(at.x, g, at.y)
	_cam.look_at_from_position(base + Vector3(0, 2.0, 3.0), base + Vector3(0, 9.0, -2), Vector3.UP)

	var mats := _mats()
	var base_tr := {}
	for m in mats:
		base_tr[m] = m.get_shader_parameter("translucency")
	var base_amb: float = _env.ambient_light_energy if _env else 1.0
	var base_sh: bool = _sun.shadow_enabled if _sun else true

	await _shot("A_shipped")

	if _sun:
		_sun.shadow_enabled = false
	await _shot("B_noshadow")
	if _sun:
		_sun.shadow_enabled = base_sh

	# The world environment uses AMBIENT_SOURCE_SKY with sky_contribution 1.0, so
	# ambient_light_energy is INERT there. Boost the real knob instead.
	if _env:
		_env.ambient_light_sky_contribution = 0.0
		_env.ambient_light_color = Color(0.62, 0.72, 0.86)
		_env.ambient_light_energy = 3.0
	await _shot("C_ambient")
	if _env:
		_env.ambient_light_sky_contribution = 1.0
		_env.ambient_light_energy = base_amb

	# SSAO at intensity 2.6 / power 1.7 with a 1.6 m radius now has dense real canopy
	# geometry to bite on where it used to have a thin card shell.
	if _env:
		_env.ssao_enabled = false
	await _shot("F_nossao")
	if _sun:
		_sun.shadow_enabled = false
	await _shot("G_noshadow_nossao")
	if _sun:
		_sun.shadow_enabled = base_sh
	if _env:
		_env.ssao_enabled = true

	for m in mats:
		m.set_shader_parameter("translucency", float(base_tr[m]) * 4.0)
	await _shot("D_translucency")

	if _sun:
		_sun.shadow_enabled = false
	await _shot("E_both")

	print("RESULT: PASS")
	get_tree().quit()
