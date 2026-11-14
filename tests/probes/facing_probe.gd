extends Node


## Is the body facing where it moves? Prints velocity direction vs the player's and the
## rig's own forward, for each movement key and while aiming.
func _ready() -> void:
	await get_tree().process_frame
	_run()


func _run() -> void:
	var game := Game.new()
	add_child(game)
	await get_tree().process_frame
	await get_tree().process_frame
	var p: Player = game.player
	var cases := [["W", "move_forward"], ["S", "move_back"], ["A", "move_left"], ["D", "move_right"]]
	print("key  vel_dir            player_fwd         rig_fwd            err_deg")
	for c in cases:
		Input.action_press(c[1])
		for i in range(60):
			await get_tree().physics_frame
		var v := Vector3(p.velocity.x, 0, p.velocity.z)
		var pf := -p.global_transform.basis.z
		var rf := -p.rig.global_transform.basis.z
		var err := 0.0
		if v.length() > 0.3:
			err = rad_to_deg(v.normalized().angle_to(rf.normalized()))
		print(
			(
				"%-4s (%5.2f,%5.2f)   (%5.2f,%5.2f)   (%5.2f,%5.2f)   %6.1f"
				% [c[0], v.normalized().x, v.normalized().z, pf.x, pf.z, rf.x, rf.z, err]
			)
		)
		Input.action_release(c[1])
		for i in range(30):
			await get_tree().physics_frame
	# and while aiming
	p.aiming = true
	game.cam.yaw = 1.2
	Input.action_press("move_forward")
	for i in range(70):
		await get_tree().physics_frame
	var v2 := Vector3(p.velocity.x, 0, p.velocity.z)
	var rf2 := -p.rig.global_transform.basis.z
	print(
		(
			"AIM  cam_yaw=%.2f face=%.2f rig_fwd=(%5.2f,%5.2f) err=%.1f"
			% [
				game.cam.yaw,
				p.facing_yaw,
				rf2.x,
				rf2.z,
				rad_to_deg(v2.normalized().angle_to(rf2.normalized())) if v2.length() > 0.3 else 0.0
			]
		)
	)
	Input.action_release("move_forward")
	get_tree().quit()
