extends SceneTree
## Engine-only reproduction of the "RID allocations of type ...Shader... were leaked at
## exit" line the gate prints (Godot 4.7.2). No game code: one GPUParticles3D with a
## default ParticleProcessMaterial, held in a local variable, added under a Node3D,
## freed, then quit. Run it in an empty project to be sure nothing of RAMA is involved:
##
##   Godot --headless --audio-driver Dummy --path <empty project> \
##       --script <this file>
##
## Measured 2026-11-13: "1 RID allocations of type
## 'N13RendererDummy15MaterialStorage11DummyShaderE' were leaked at exit", 3 runs of 3.
## Assigning the process material before the draw pass, or not keeping it in a local,
## made the line go away here, but the same reordering in WorldVFX raised the game's
## count from 4 to 7: ParticleProcessMaterial's shared shader cache keeps a use count
## that depends on timing (_update_shader runs from both get_rid() and the dirty-list
## flush), so it is left to the engine.


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	var m := ParticleProcessMaterial.new()
	var holder := Node3D.new()
	root.add_child(holder)
	var p := GPUParticles3D.new()
	p.draw_pass_1 = QuadMesh.new()
	p.process_material = m
	holder.add_child(p)
	for i in range(10):
		await process_frame
	holder.free()
	for i in range(3):
		await process_frame
	quit(0)
