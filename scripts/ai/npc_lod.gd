class_name NPCLod
extends RefCounted
## Distance level of detail for villagers. ProcRig already simplifies a character's hands
## and eyes at 12 m; this decides what a villager costs the rest of the time.
##
## Measured 2026-11-13 (headless node counts, see tests/npc_lod_test.gd): a rig draws
## about 20 meshes, and every one of them is drawn again into each sun-shadow split. A
## villager 60 m away is a few pixels tall, so it gets no shadow and a third of the
## animation updates; one 100 m away is not drawn or animated at all. Streaming (120 m
## in, 138 m out) is unchanged.
##
## NEAR   inside MID_IN     full detail, every frame
## MID    MID_IN..FAR_IN    no shadow, pose updated every MID_EVERY-th tick
## FAR    beyond FAR_IN     hidden, not animated
##
## Moving between levels uses a margin (HYST) so a villager standing on a boundary does
## not flicker.

enum Level { NEAR, MID, FAR }

const MID_IN := 45.0
const FAR_IN := 90.0
const HYST := 6.0
const MID_EVERY := 3


## The level for a villager `d` metres away, given the level it has now.
static func level_for(d: float, current: int) -> int:
	var mid_in := MID_IN - (HYST if current >= Level.MID else 0.0)
	var far_in := FAR_IN - (HYST if current >= Level.FAR else 0.0)
	if d >= far_in:
		return Level.FAR
	if d >= mid_in:
		return Level.MID
	return Level.NEAR


## Put a rig into `level`. `geoms` is the list of its drawable meshes (see `collect`).
static func apply(rig: Node3D, geoms: Array, level: int) -> void:
	rig.visible = level != Level.FAR
	var shadow := (
		GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if level != Level.NEAR else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	)
	for g in geoms:
		if is_instance_valid(g):
			(g as GeometryInstance3D).cast_shadow = shadow


static func collect(rig: Node) -> Array:
	return rig.find_children("*", "GeometryInstance3D", true, false)
