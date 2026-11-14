extends Node
## Villager level of detail (scripts/ai/npc_lod.gd). Logic only, so it runs headless:
##   1. the distance thresholds, including the margin that stops flicker on a boundary;
##   2. on a real built villager: NEAR draws every mesh and casts shadows, MID keeps the
##      meshes but casts no shadow and updates the pose every third tick, FAR draws nothing
##      and does not animate, and coming back to NEAR restores exactly what NEAR drew.
## Draw calls themselves need a renderer; the perf suite asserts the village budget.


func _npc() -> NPC:
	var n := NPC.new()
	n.configure(
		{
			"id": "lod_probe",
			"display_name": "Probe",
			"look": {"height": 1.7, "build": 0.9, "cloth": "cloth_white", "cloth2": "cloth_saffron", "topknot": true},
		}
	)
	add_child(n)
	n.build()
	return n


## Meshes that would be drawn (visible in the tree) and how many of them cast a shadow.
func _drawn(n: NPC) -> Vector2i:
	var drawn := 0
	var shadows := 0
	for g in n.rig.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		if gi.is_visible_in_tree():
			drawn += 1
			if gi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				shadows += 1
	return Vector2i(drawn, shadows)


func _ready() -> void:
	_run()


func _run() -> void:
	var fails: Array[String] = []
	_check_thresholds(fails)
	var n := _npc()
	_check_levels(n, fails)
	print("\nRESULT: " + ("PASS" if fails.is_empty() else "FAIL"))
	for f in fails:
		print("  ! " + f)
	n.free()
	get_tree().quit(0 if fails.is_empty() else 1)


func _check_thresholds(fails: Array[String]) -> void:
	var L := NPCLod.Level
	var cases := [
		[10.0, L.NEAR, L.NEAR],
		[24.0, L.NEAR, L.NEAR],
		[26.0, L.NEAR, L.MID],
		[89.0, L.MID, L.MID],
		[91.0, L.MID, L.FAR],
		[300.0, L.NEAR, L.FAR],
		# Margin: already MID at 21 m stays MID (25 - 6 = 19); NEAR at 21 m stays NEAR.
		[21.0, L.MID, L.MID],
		[21.0, L.NEAR, L.NEAR],
		[18.0, L.MID, L.NEAR],
		# Already FAR at 85 m stays FAR (90 - 6 = 84); MID at 85 m stays MID.
		[85.0, L.FAR, L.FAR],
		[85.0, L.MID, L.MID],
		[80.0, L.FAR, L.MID],
	]
	for c in cases:
		var got := NPCLod.level_for(c[0], c[1])
		if got != c[2]:
			fails.append("level_for(%.0f m, from level %d) gave %d, wanted %d" % [c[0], c[1], got, c[2]])


func _check_levels(n: NPC, fails: Array[String]) -> void:
	# ProcRig applies its own hand and eye detail level on its first animation tick; settle
	# that first so the baseline is the state the villager really sits in at close range.
	n.rig.set_lod(0)
	var near := _drawn(n)
	if near.x < 8:
		fails.append("a built villager draws only %d meshes; the test cannot tell levels apart" % near.x)
	if near.y != near.x:
		fails.append("NEAR: %d of %d meshes cast shadows, wanted all" % [near.y, near.x])

	n.update_lod(60.0)
	var mid := _drawn(n)
	if n.lod != NPCLod.Level.MID:
		fails.append("60 m did not give MID (got %d)" % n.lod)
	if mid.x != near.x:
		fails.append("MID draws %d meshes, NEAR drew %d; MID should only drop shadows" % [mid.x, near.x])
	if mid.y != 0:
		fails.append("MID: %d meshes still cast shadows" % mid.y)
	_check_cadence(n, NPCLod.Level.MID, fails)

	n.update_lod(120.0)
	var far := _drawn(n)
	if far.x != 0:
		fails.append("FAR still draws %d meshes" % far.x)
	_check_cadence(n, NPCLod.Level.FAR, fails)

	n.update_lod(5.0)
	var back := _drawn(n)
	if back != near:
		fails.append("back at NEAR the villager draws %s, it drew %s before" % [back, near])


## MID updates the pose on every MID_EVERY-th tick; FAR never does. The accumulator holds
## the time not yet given to the rig, so it is zero right after an update.
func _check_cadence(n: NPC, level: int, fails: Array[String]) -> void:
	n._lod_acc = 0.0
	n._lod_tick = 0
	for i in range(NPCLod.MID_EVERY * 2):
		n._drive_rig(0.016)
	if level == NPCLod.Level.MID and n._lod_acc != 0.0:
		fails.append("MID: the pose was not updated on the %dth tick (acc %.3f)" % [NPCLod.MID_EVERY * 2, n._lod_acc])
	if level == NPCLod.Level.FAR and n._lod_acc < 0.09:
		fails.append("FAR: the pose was updated (acc %.3f, wanted it to keep growing)" % n._lod_acc)
