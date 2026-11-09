class_name Mats
extends RefCounted
## Central material library. Everything that draws the world gets its material from
## here so a tweak lands everywhere at once and no two props drift apart.

const T := "res://assets/textures/%s.png"

static var _tex_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}


static func tex(name: String, silent: bool = false) -> Texture2D:
	if _tex_cache.has(name):
		var cached: Variant = _tex_cache[name]
		if cached is Texture2D:
			return cached as Texture2D
		return null
	var path: String = T % name
	if ResourceLoader.exists(path):
		var t: Texture2D = load(path) as Texture2D
		if t != null:
			_tex_cache[name] = t
			return t
	if not silent:
		push_warning("[mats] missing texture: " + name)
	_tex_cache[name] = null
	return null


## Standard PBR set from the <base>_albedo / _normal / _rough naming convention.
## A few assets were generated without the _albedo suffix, which `alt` covers.
static func pbr(base: String, uv_scale: float = 1.0, alt: String = "") -> StandardMaterial3D:
	var key := "pbr:%s:%.3f:%s" % [base, uv_scale, alt]
	if _mat_cache.has(key):
		var cached_mat: Variant = _mat_cache[key]
		if cached_mat is StandardMaterial3D:
			return cached_mat as StandardMaterial3D
	var m := StandardMaterial3D.new()
	var a := tex(base + "_albedo", true)
	if a == null:
		a = tex(alt if alt != "" else base)
	m.albedo_texture = a
	var n := tex(base + "_normal", true)
	if n == null and alt != "":
		n = tex(alt + "_normal", true)
	if n:
		m.normal_enabled = true
		m.normal_texture = n
		m.normal_scale = 1.0
	var r := tex(base + "_rough", true)
	if r == null and alt != "":
		r = tex(alt + "_rough", true)
	if r:
		m.roughness_texture = r
	m.roughness = 1.0
	m.uv1_scale = Vector3(uv_scale, uv_scale, uv_scale)
	m.metallic = 0.0

	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_mat_cache[key] = m
	return m


static func terrain_material() -> ShaderMaterial:
	if _mat_cache.has("terrain"):
		var cached_sm: Variant = _mat_cache["terrain"]
		if cached_sm is ShaderMaterial:
			return cached_sm as ShaderMaterial
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
	_mat_cache["terrain"] = m
	return m


## Metal / brass for temple finials, bells and weapon fittings.
static func brass() -> StandardMaterial3D:
	if _mat_cache.has("brass"):
		var cached_b: Variant = _mat_cache["brass"]
		if cached_b is StandardMaterial3D:
			return cached_b as StandardMaterial3D
	var m := pbr("gold_brass", 1.0).duplicate()
	m.metallic = 0.92
	m.metallic_specular = 0.85
	m.roughness = 1.0
	_mat_cache["brass"] = m
	return m


## Alpha-cut foliage card with wind, used by every leaf and frond in the world.
static func foliage(atlas: String, cull_off: bool = true) -> ShaderMaterial:
	var key := "fol:" + atlas
	if _mat_cache.has(key):
		var cached_f: Variant = _mat_cache[key]
		if cached_f is ShaderMaterial:
			return cached_f as ShaderMaterial
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	m.set_shader_parameter("albedo_tex", tex(atlas))
	var n := tex(atlas + "_normal")
	if n:
		m.set_shader_parameter("normal_tex", n)
	m.set_shader_parameter("two_sided", cull_off)
	_mat_cache[key] = m
	return m


static func flat(color: Color, rough: float = 0.85, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m
