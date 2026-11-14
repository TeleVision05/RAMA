class_name HumanoidModel
extends Node3D
## Instantiates CC0 Quaternius humanoid characters (King/Rama, Farmer/Villager, Woman/Sita, Adventurer/Lakshmana)
## and retargets the CC0 KayKit animation library for movement, combat and idle states.
## Sources and licences: assets/CREDITS.md.

const MODEL_PATHS := {
	"king": "res://assets/models/characters/king.glb",
	"farmer": "res://assets/models/characters/farmer.glb",
	"woman": "res://assets/models/characters/woman_medieval.glb",
	"woman_medieval": "res://assets/models/characters/woman_medieval.glb",
	"adventurer": "res://assets/models/characters/adventurer.glb",
}

const ANIM_SOURCES := {
	"movement": "res://assets/models/characters/anims/MovementBasic.glb",
	"general": "res://assets/models/characters/anims/General.glb",
	"melee": "res://assets/models/characters/anims/CombatMelee.glb",
	"ranged": "res://assets/models/characters/anims/CombatRanged.glb",
}

# Canonical animation clips to extract and rename
const CLIP_MAP := {
	"idle": ["general", "Rig_Medium|Idle_A", true],
	"idle_b": ["general", "Rig_Medium|Idle_B", true],
	"walk": ["movement", "Rig_Medium|Walking_A", true],
	"run": ["movement", "Rig_Medium|Running_A", true],
	"jump_start": ["movement", "Rig_Medium|Jump_Start", false],
	"jump_idle": ["movement", "Rig_Medium|Jump_Idle", true],
	"jump_land": ["movement", "Rig_Medium|Jump_Land", false],
	"hit": ["general", "Rig_Medium|Hit_A", false],
	"death": ["general", "Rig_Medium|Death_A", false],
	"interact": ["general", "Rig_Medium|Interact", false],
	"melee_slash": ["melee", "Rig_Medium|Melee_1H_Attack_Slice_Horizontal", false],
	"melee_chop": ["melee", "Rig_Medium|Melee_1H_Attack_Chop", false],
	"bow_aim": ["ranged", "Rig_Medium|Ranged_Bow_Aiming_Idle", true],
	"bow_draw": ["ranged", "Rig_Medium|Ranged_Bow_Draw", false],
	"bow_shoot": ["ranged", "Rig_Medium|Ranged_Bow_Release", false],
}

static var _cached_anims: Dictionary = {}
# ANIM_SOURCES key -> {source clip name: Animation}, filled by _load_raw_sources().
static var _raw_sources: Dictionary = {}
# ANIM_SOURCES key -> HumanoidRetarget.rig_data() of that source's skeleton.
static var _src_rigs: Dictionary = {}

var model_instance: Node3D
var skeleton: Skeleton3D
var anim_player: AnimationPlayer
var current_anim: String = ""
var model_path: String = ""

# Bone attachments
var attach_hand_l: BoneAttachment3D
var attach_hand_r: BoneAttachment3D
var attach_chest: BoneAttachment3D
var attach_head: BoneAttachment3D


static func build(model_key: String) -> HumanoidModel:
	var root := HumanoidModel.new()
	root.name = "HumanoidModel_" + model_key
	var path: String = MODEL_PATHS.get(model_key, MODEL_PATHS["king"])
	var packed: PackedScene = load(path)
	if packed == null:
		push_warning("Failed to load model %s at %s" % [model_key, path])
		return root

	root.model_path = path
	var inst := packed.instantiate() as Node3D
	root.model_instance = inst
	root.add_child(inst)

	# Locate skeleton
	for c in inst.find_children("*", "Skeleton3D"):
		root.skeleton = c as Skeleton3D
		break

	if root.skeleton == null:
		return root

	root._setup_bone_attachments()
	root._setup_animation_player()
	return root


func _setup_bone_attachments() -> void:
	if skeleton == null:
		return

	attach_hand_l = _create_attachment("HandSlot_L", "Hand.L")
	attach_hand_r = _create_attachment("HandSlot_R", "Hand.R")
	attach_chest = _create_attachment("ChestSlot", "Chest")
	attach_head = _create_attachment("HeadSlot", "Head")


func _create_attachment(att_name: String, bone_name: String) -> BoneAttachment3D:
	var b_idx := skeleton.find_bone(bone_name)
	if b_idx < 0:
		return null
	var att := BoneAttachment3D.new()
	att.name = att_name
	att.bone_name = bone_name
	att.bone_idx = b_idx
	skeleton.add_child(att)
	return att


func _setup_animation_player() -> void:
	if skeleton == null:
		return

	anim_player = AnimationPlayer.new()
	anim_player.name = "AnimPlayer"
	model_instance.add_child(anim_player)

	var lib := _get_or_build_library(skeleton, model_instance, model_path)
	if lib:
		anim_player.add_animation_library("", lib)
		anim_player.playback_default_blend_time = 0.20
		play("idle")


static func _get_or_build_library(skel: Skeleton3D, model_root: Node3D, path_key: String) -> AnimationLibrary:
	var skel_path := model_root.get_path_to(skel)
	# Per model file: two characters with the same skeleton path can still be built
	# differently (the woman's hips and upper legs sit elsewhere), and a clip retargeted
	# onto one is wrong on the other.
	if _cached_anims.has(path_key):
		return _cached_anims[path_key]

	var lib := AnimationLibrary.new()
	_load_raw_sources()
	var dst_rig := HumanoidRetarget.rig_data(skel, model_root)

	for clip_name in CLIP_MAP:
		var info: Array = CLIP_MAP[clip_name]
		var src_key: String = info[0]
		var raw_name: String = info[1]
		var src_clips: Dictionary = _raw_sources.get(src_key, {})
		if not src_clips.has(raw_name) or not _src_rigs.has(src_key):
			continue
		var anim := HumanoidRetarget.retarget(src_clips[raw_name], _src_rigs[src_key], dst_rig, String(skel_path))
		anim.loop_mode = Animation.LOOP_LINEAR if bool(info[2]) else Animation.LOOP_NONE
		lib.add_animation(clip_name, anim)

	_cached_anims[path_key] = lib
	return lib


## Read the clips this file uses out of each animation source, once. The source scene
## is instantiated only to reach its AnimationPlayer and is freed straight away: it is
## never added to the tree, so keeping the player (as this once did) kept its whole
## scene alive as 16 orphan nodes, and at exit leaked 88 objects and 72 resources.
static func _load_raw_sources() -> void:
	for src_key in ANIM_SOURCES:
		if _raw_sources.has(src_key):
			continue
		var clips := {}
		var packed: PackedScene = load(ANIM_SOURCES[src_key])
		if packed:
			var scene := packed.instantiate()
			var skels := scene.find_children("*", "Skeleton3D")
			if not skels.is_empty():
				_src_rigs[src_key] = HumanoidRetarget.rig_data(skels[0] as Skeleton3D, scene)
			for c in scene.find_children("*", "AnimationPlayer"):
				var ap := c as AnimationPlayer
				for clip_name in CLIP_MAP:
					var raw_name: String = CLIP_MAP[clip_name][1]
					if CLIP_MAP[clip_name][0] == src_key and ap.has_animation(raw_name):
						# A copy: the original belongs to the .glb in the resource cache,
						# and a static reference to it is still held when the engine
						# checks for resources in use at exit.
						clips[raw_name] = ap.get_animation(raw_name).duplicate()
				break
			scene.free()
		_raw_sources[src_key] = clips


func play(anim_name: String, custom_blend: float = 0.20, speed: float = 1.0) -> void:
	if anim_player == null:
		return
	if current_anim == anim_name and anim_player.is_playing():
		anim_player.speed_scale = speed
		return
	if anim_player.has_animation(anim_name):
		current_anim = anim_name
		anim_player.play(anim_name, custom_blend, speed)
