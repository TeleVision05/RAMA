extends SceneTree
## Settles two engine conventions with evidence instead of memory:
##  A) does Godot multiply DIFFUSE_LIGHT by ALBEDO after a custom light() function?
##     -> quad A is RED if it does, WHITE if it does not.
##  B) is the DEPTH_TEXTURE -> INV_PROJECTION_MATRIX reconstruction the right way up?
##     -> quad B is mid-grey (~2 m of reconstructed gap) if it is, black/red if not.

const LIGHT_SRC := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;
// ALBEDO is pure black. Ambient therefore contributes nothing, so ANY light on this
// quad can only have come from DIFFUSE_LIGHT being used WITHOUT an ALBEDO multiply.
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 1.0;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
void light() {
	DIFFUSE_LIGHT += vec3(0.6, 0.6, 0.6) * ATTENUATION * max(dot(NORMAL, LIGHT), 0.0);
}
"""

const DEPTH_SRC := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
void fragment() {
	float raw = texture(depth_tex, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vp.xyz /= vp.w;
	float behind = -vp.z;
	float here = -VERTEX.z;
	float gap = behind - here;
	// grey ramp 0..4 m; red when the reconstruction comes out negative.
	vec3 c = vec3(clamp(gap / 4.0, 0.0, 1.0));
	if (gap < -0.05) { c = vec3(1.0, 0.0, 0.0); }
	if (gap > 400.0) { c = vec3(0.0, 0.0, 1.0); }
	ALBEDO = c;
	ALPHA = 1.0;
}
"""


func quad(src: String, pos: Vector3) -> MeshInstance3D:
	var sh := Shader.new()
	sh.code = src
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(6.0, 6.0)
	mi.mesh = pm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	return mi


func _init() -> void:
	var root := get_root()
	var world := WorldRoot.new()
	root.add_child(world)
	world.build(false)
	var m := world.map

	var c := Vector2(-34.0, 30.0)
	var g := m.height_at(c.x, c.y)
	root.add_child(quad(LIGHT_SRC, Vector3(c.x - 4.0, g + 2.0, c.y)))
	root.add_child(quad(DEPTH_SRC, Vector3(c.x + 4.0, g + 2.0, c.y)))

	var cam := Camera3D.new()
	cam.fov = 55.0
	cam.far = 1500.0
	root.add_child(cam)
	cam.current = true
	await process_frame
	world.sky.paused = true
	world.sky.set_time(11.0)
	cam.global_position = Vector3(c.x, g + 9.0, c.y + 11.0)
	cam.look_at(Vector3(c.x, g + 2.0, c.y), Vector3.UP)
	world.terrain.update_focus(cam.global_position, true)
	await process_frame
	for i in range(16):
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://build/screenshots/probe_conv.png")
	print("wrote probe_conv.png")
	quit()
