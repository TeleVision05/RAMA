class_name Mats
extends RefCounted
## Central material library. Everything that draws the world gets its material from
## here so a tweak lands everywhere at once and no two props drift apart.

const T := "res://assets/textures/%s.png"

static var _cache: Dictionary = {}


static func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var path: String = T % name
	var t: Texture2D = load(path) if ResourceLoader.exists(path) else null
	if t == null:
		push_warning("[mats] missing texture: " + name)
	_cache[name] = t
	return t


## Standard PBR set from the <base>_albedo / _normal / _rough naming convention.
## A few assets were generated without the _albedo suffix, which `alt` covers.
static func pbr(base: String, uv_scale: float = 1.0, alt: String = "") -> StandardMaterial3D:
	var key := "pbr:%s:%.3f" % [base, uv_scale]
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	var a := tex(base + "_albedo")
	if a == null:
		a = tex(alt if alt != "" else base)
	m.albedo_texture = a
	var n := tex(base + "_normal")
	if n:
		m.normal_enabled = true
		m.normal_texture = n
		m.normal_scale = 1.0
	var r := tex(base + "_rough")
	if r:
		m.roughness_texture = r
	m.roughness = 1.0
	m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	m.metallic = 0.0

	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_cache[key] = m
	return m


static func terrain_material() -> ShaderMaterial:
	if _cache.has("terrain"):
		return _cache["terrain"]
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/terrain.gdshader")
	var layers := {
		"grass": "grass",
		"forest": "forest_floor",
		"dirt": "dirt",
		"rock": "rock",
		"sand": "sand",
	}
	for slot in layers:
		var src: String = layers[slot]
		m.set_shader_parameter(slot + "_a", tex(src + "_albedo"))
		m.set_shader_parameter(slot + "_n", tex(src + "_normal"))
		m.set_shader_parameter(slot + "_r", tex(src + "_rough"))
	m.set_shader_parameter("detail_noise", tex("detail_noise"))
	_cache["terrain"] = m
	return m


## Metal / brass for temple finials, bells and weapon fittings.
static func brass() -> StandardMaterial3D:
	if _cache.has("brass"):
		return _cache["brass"]
	var m := pbr("gold_brass", 1.0).duplicate()
	m.metallic = 0.92
	m.metallic_specular = 0.85
	m.roughness = 1.0
	_cache["brass"] = m
	return m


## Alpha-cut foliage card with wind, used by every leaf and frond in the world.
static func foliage(atlas: String, cull_off: bool = true) -> ShaderMaterial:
	var key := "fol:" + atlas
	if _cache.has(key):
		return _cache[key]
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	m.set_shader_parameter("albedo_tex", tex(atlas))
	var n := tex(atlas + "_normal")
	if n:
		m.set_shader_parameter("normal_tex", n)
	m.set_shader_parameter("two_sided", cull_off)
	_cache[key] = m
	return m


static func flat(color: Color, rough: float = 0.85, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m
