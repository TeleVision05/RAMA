class_name LootDrop
extends Node3D
## What a rakshasa leaves behind: a bundle of cloth and bone on the ground, in the
## group "interactable" so the player's existing prompt/raycast picks it up with no
## special case anywhere else.

const LIFETIME := 420.0
const BOB := 0.055

var contents: Array = []  # [[item_id, count], ...]
var label: String = "Spoils"
var interact_range: float = 2.8

var _t: float = 0.0
var _base_y: float = 0.0
var _taken: bool = false
var _visual: Node3D


static func drop(parent: Node, pos: Vector3, items: Array, kind: int) -> LootDrop:
	if items.is_empty():
		return null
	var l := LootDrop.new()
	l.contents = items
	l.label = EnemyTypes.item_label(String(items[0][0])) if items.size() == 1 else "Spoils"
	parent.add_child(l)
	l.global_position = pos
	l._build(kind)
	return l


func _ready() -> void:
	add_to_group("interactable")
	add_to_group("loot")
	_base_y = global_position.y


func _build(kind: int) -> void:
	_visual = Node3D.new()
	add_child(_visual)

	var m_cloth := Mats.pbr("cloth_indigo", 3.0, "cloth_indigo").duplicate()
	m_cloth.albedo_color = Color(0.44, 0.34, 0.26)
	var bundle := MeshInstance3D.new()
	bundle.mesh = MeshKit.ovoid(0.135, 0.20, 0.45, 10, 8)
	bundle.material_override = m_cloth
	bundle.position = Vector3(0, 0.10, 0)
	bundle.scale = Vector3(1.0, 0.82, 1.0)
	_visual.add_child(bundle)

	# The knot on top, and a token of what died here.
	var knot := MeshInstance3D.new()
	knot.mesh = MeshKit.tube(0.07, [[0.0, 0.030], [0.5, 0.018], [1.0, 0.034]], 8)
	knot.material_override = m_cloth
	knot.position = Vector3(0, 0.185, 0)
	_visual.add_child(knot)

	var token := MeshInstance3D.new()
	if kind == EnemyTypes.Kind.BEAST:
		token.mesh = MeshKit.tube(0.13, [[0.0, 0.022], [0.6, 0.014], [1.0, 0.002]], 6, 1.0, Vector3(0.03, 0, 0.02))
		token.material_override = Mats.flat(Color(0.86, 0.83, 0.76), 0.4)
	else:
		token.mesh = MeshKit.tube(0.16, [[0.0, 0.026], [0.5, 0.017], [1.0, 0.003]], 6, 1.0, Vector3(0.04, 0, 0.0))
		token.material_override = Mats.flat(Color(0.20, 0.18, 0.17), 0.45)
	token.position = Vector3(0.055, 0.16, 0.02)
	token.rotation = Vector3(0.5, 0.4, 0.35)
	_visual.add_child(token)

	# A faint warm glint so a drop in long grass is findable without a map marker.
	var glint := MeshInstance3D.new()
	glint.mesh = MeshKit.sphere(0.055, 8, 6)
	var mg := StandardMaterial3D.new()
	mg.albedo_color = Color(1.0, 0.78, 0.36, 0.55)
	mg.emission_enabled = true
	mg.emission = Color(1.0, 0.72, 0.30)
	mg.emission_energy_multiplier = 2.4
	mg.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mg.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mg.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	glint.material_override = mg
	glint.position = Vector3(0, 0.30, 0)
	_visual.add_child(glint)


func _process(delta: float) -> void:
	_t += delta
	if _visual:
		_visual.position.y = sin(_t * 1.7) * BOB
		_visual.rotation.y = _t * 0.55
	if _t > LIFETIME:
		queue_free()


# --- Interactable contract -------------------------------------------------
func interact_prompt() -> String:
	if contents.size() == 1:
		var n: int = int(contents[0][1])
		return "Take %s%s" % [EnemyTypes.item_label(String(contents[0][0])), (" x%d" % n) if n > 1 else ""]
	return "Take spoils"


func can_interact(_player: Node) -> bool:
	return not _taken


func interact(_player: Node) -> void:
	if _taken:
		return
	_taken = true
	var parts: Array[String] = []
	for it in contents:
		var id: String = String(it[0])
		var n: int = int(it[1])
		if id == "arrow":
			var room: int = maxi(0, GameState.max_arrows - GameState.arrows)
			var give: int = mini(n, room)
			GameState.arrows += give
			if give > 0:
				parts.append("%d arrows" % give)
		else:
			GameState.add_item(id, n)
			parts.append("%s%s" % [EnemyTypes.item_label(id), (" x%d" % n) if n > 1 else ""])
	AudioDirector.play_2d("pickup_item", -4.0)
	if not parts.is_empty():
		EventBus.notify.emit("Taken", ", ".join(parts), "item")
	queue_free()
