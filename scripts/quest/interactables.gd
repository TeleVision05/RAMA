class_name Interactables
extends Node3D
## The things in the world you can walk up to and use.
##
## Each one implements the contract in ARCHITECTURE.md — group "interactable",
## `interact_prompt()`, `interact(player)`, optional `can_interact(player)` and
## `interact_range` — so the player's own raycast finds them and nothing here needs
## an Area3D.
##
## Placement is always `map.height_at()`; nothing is authored at a fixed Y. Every
## site was probed for slope and water before it was chosen (2026-08-28), which is
## why nothing here stands on the lip of the knoll where the plateau falls away.
##
## Everything with a light or an animation is switched off past `NEAR` metres from
## the player, because a shrine on the far side of the valley does not need to be
## flickering.

const NEAR := 96.0
const NEAR_POLL := 0.45

var map: WorldMap
var quests: Node
var lamp_puzzle: LampPuzzle
var _near_t: float = 0.0
var _player: Node3D


func setup(world_map: WorldMap) -> void:
	map = world_map


func bind(quest_system: Node) -> void:
	quests = quest_system
	if quests != null and quests.has_method("bind_interactables"):
		quests.call("bind_interactables", self)
	_place()
	sync_from_state()


func _g(x: float, z: float) -> Vector3:
	return Vector3(x, map.height_at(x, z), z)


static var _alt_mats: Dictionary = {}


## A PBR material for one of the textures generated WITHOUT an `_albedo` suffix —
## `bark_banyan`, `cloth_white`, `cloth_saffron`, `cloth_indigo`.
##
## `Mats.pbr(base, uv, alt)` handles these, but it finds out by asking for
## `<base>_albedo` first and pushing a "missing texture" warning when it is not
## there; a run of the game gained a warning per such material. TreeBuilder solves
## it the same way: know which bases are like that and ask for the right name.
static func alt_pbr(base: String, uv: float) -> StandardMaterial3D:
	var key := "%s:%.3f" % [base, uv]
	if _alt_mats.has(key):
		return _alt_mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_texture = Mats.tex(base)
	var n := Mats.tex(base + "_normal")
	if n != null:
		m.normal_enabled = true
		m.normal_texture = n
	var r := Mats.tex(base + "_rough")
	if r != null:
		m.roughness_texture = r
	m.roughness = 1.0
	m.metallic = 0.0
	m.uv1_scale = Vector3(uv, uv, uv)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_alt_mats[key] = m
	return m


# ===========================================================================
#  Where everything stands
# ===========================================================================
func _place() -> void:
	lamp_puzzle = LampPuzzle.new()
	lamp_puzzle.name = "LampPuzzle"
	add_child(lamp_puzzle)

	_place_shrine()
	_place_forest()
	_place_ruins()
	_place_village()
	_place_grove()


## The shrine forecourt, east of the temple, laid out along the processional.
func _place_shrine() -> void:
	_add(ShrineAltar.new(), _g(163.4, -70.8), "ShrineAltar")
	_add(OfferingChest.new("shrine_chest", {"lamp_oil": 1, "healing_salve": 1}), _g(161.8, -70.6), "ShrineOffering")
	_add(BellFrame.new(), _g(164.6, -74.4), "BellFrame")

	# The order is written out of the same constant the puzzle checks against, so the
	# stone cannot come to name an order the lamps do not accept.
	var order: Array = QuestData.LAMP_ORDER
	var lead := ["first ", "then ", "last "]
	var text := "THE LAMPS ARE LIT IN THEIR OWN ORDER\n"
	for i in range(order.size()):
		text += (
			"    %s%s%s\n"
			% [
				lead[mini(i, lead.size() - 1)],
				String(QuestData.LAMP_EMBLEM_NAMES.get(order[i], order[i])),
				"." if i == order.size() - 1 else ","
			]
		)
	text += "Each lamp wears its own mark on the stone it stands on.\n"
	text += "The bell was carried west to the old hall when the road went quiet."
	_add(InscriptionStone.new("shrine_inscription", "Read the inscription", text), _g(165.0, -78.5), "Inscription")

	_add(ThresholdLamp.new(), _g(163.2, -78.5), "ThresholdLamp")

	# The three lamps of the puzzle. Each carries its emblem on the base, which is
	# the whole of the clue: the stone names them, the bases show which is which.
	var lamps := [
		["sun", Vector2(166.0, -80.6)],
		["river", Vector2(166.9, -78.5)],
		["fig", Vector2(166.0, -76.4)],
	]
	for entry in lamps:
		var emblem: String = entry[0]
		var at: Vector2 = entry[1]
		var lamp := ShrineLamp.new(emblem)
		_add(lamp, _g(at.x, at.y), "Lamp_" + emblem)
		# Turn each lamp so its carved emblem faces the inscription stone: the clue
		# and the thing the clue is about have to be readable from one standpoint.
		var to := Vector2(165.0, -78.5) - at
		lamp.rotation.y = atan2(to.x, to.y)
		lamp_puzzle.register(lamp)


## The forest road: a cart that did not get through, and the tree beside it.
func _place_forest() -> void:
	_add(BrokenCart.new(), _g(-184.6, -14.8), "BrokenCart")
	_add(ClawedTree.new(), _g(-181.6, -17.2), "ClawedTree")
	_add(BinduPen.new(), _g(-191.5, -38.5), "BinduPen")
	_add(ArrowStand.new(), _g(-191.0, -30.0), "CampArrows")


## The old ruins: a barred way in, and the bell behind it.
func _place_ruins() -> void:
	var gate := RuinGate.new()
	_add(gate, _g(-158.6, -143.9), "RuinGate")
	gate.face(_g(-168.0, -148.0))
	_add(Pickup.new("temple_bell", "Take the bronze bell", "bell"), _g(-155.0, -145.5) + Vector3(0, 0.62, 0), "BellPickup")
	_add(OfferingChest.new("ruin_chest", {"arrow_bundle": 1, "healing_salve": 1}), _g(-153.5, -141.6), "RuinOffering")


## Panchavati: somewhere to sleep, somewhere to fill a quiver, somebody to trade with.
func _place_village() -> void:
	_add(ArrowStand.new(), _g(-114.0, 50.0), "VillageArrows")
	_add(Campfire.new(), _g(-127.0, 60.0), "VillageFire")
	_add(MerchantStall.new(), _g(-117.5, 57.5), "MerchantStall")


## The hidden grove: the end of the long walk, and the only reason to make it.
func _place_grove() -> void:
	var c := WorldMap.P_HIDDEN_GROVE
	_add(GroveHeart.new(), _g(c.x, c.y), "GroveHeart")
	for i in range(8):
		var a: float = TAU * float(i) / 8.0 + 0.35
		var p := c + Vector2(cos(a), sin(a)) * 6.2
		var st := GroveStone.new(i)
		_add(st, _g(p.x, p.y), "GroveStone%d" % i)
		st.rotation.y = -a + PI * 0.5
	_add(Pickup.new("amulet", "Take the amulet", "amulet"), _g(c.x, c.y) + Vector3(0, 1.86, 0), "GroveGift")


func _add(n: Node3D, pos: Vector3, nm: String) -> void:
	n.name = nm
	if n is Base:
		(n as Base).host = self
	add_child(n)
	n.global_position = pos
	if n.has_method("post_place"):
		n.call("post_place")


# ===========================================================================
#  Housekeeping
# ===========================================================================
## Put every object back the way the saved log says it should be. Called after a
## load, and once at build time so a session resumed from a save is not full of
## bells that have already been rung.
func sync_from_state() -> void:
	for c in get_children():
		if c.has_method("sync_from_state"):
			c.call("sync_from_state")


func _process(delta: float) -> void:
	_near_t -= delta
	if _near_t > 0.0:
		return
	_near_t = NEAR_POLL
	if _player == null or not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player") as Node3D
		if _player == null:
			return
	var p := _player.global_position
	for c in get_children():
		if c is Base:
			var b: Base = c
			b.set_near(b.global_position.distance_squared_to(p) < NEAR * NEAR)


## Every object that can currently be used, for tests and for audits.
func usable_count(player: Node) -> int:
	var n := 0
	for c in get_children():
		if not c.is_in_group("interactable"):
			continue
		if c.has_method("can_interact") and not c.call("can_interact", player):
			continue
		n += 1
	return n


func find_object(nm: String) -> Node3D:
	return get_node_or_null(NodePath(nm)) as Node3D


# ===========================================================================
#  Base
# ===========================================================================
class Base:
	extends Node3D
	var interact_range: float = 3.4
	var host: Interactables
	var near: bool = true
	var _lights: Array = []

	func _ready() -> void:
		add_to_group("interactable")

	func quests() -> Node:
		if host != null and is_instance_valid(host):
			return host.quests
		return null

	func map() -> WorldMap:
		return host.map if host != null and is_instance_valid(host) else null

	func _notify_quest(tag: String) -> void:
		var q := quests()
		if q != null and q.has_method("notify_interact"):
			q.call("notify_interact", tag)

	func _light(colour: Color, energy: float, rng: float, at: Vector3) -> OmniLight3D:
		var l := OmniLight3D.new()
		l.light_color = colour
		l.light_energy = energy
		l.omni_range = rng
		l.position = at
		l.shadow_enabled = false
		add_child(l)
		_lights.append(l)
		return l

	## Switched off when the player is far away: no flicker maths, no light.
	func set_near(v: bool) -> void:
		if v == near:
			return
		near = v
		set_process(v)
		for l in _lights:
			if is_instance_valid(l):
				(l as OmniLight3D).visible = v and _light_wanted()

	func _light_wanted() -> bool:
		return true

	func _refresh_lights() -> void:
		for l in _lights:
			if is_instance_valid(l):
				(l as OmniLight3D).visible = near and _light_wanted()

	static func t() -> float:
		return float(Time.get_ticks_msec()) / 1000.0


# ===========================================================================
#  The shrine
# ===========================================================================
## Pray at the altar: a bell, a bloom of warm light, health and stamina restored,
## and this becomes where you wake if you fall.
class ShrineAltar:
	extends Base
	var _glow: OmniLight3D
	var _used_at: float = -100.0

	func post_place() -> void:
		interact_range = 4.2
		var body := MeshInstance3D.new()
		body.mesh = MeshKit.profile_loft(
			0.62, [[0.0, 0.46, 0.46], [0.18, 0.40, 0.40], [0.72, 0.36, 0.36], [0.88, 0.44, 0.44], [1.0, 0.42, 0.42]], 16
		)
		body.material_override = Mats.pbr("carved_stone", 1.4)
		add_child(body)
		var bowl := MeshInstance3D.new()
		bowl.mesh = MeshKit.profile_loft(0.20, [[0.0, 0.13, 0.13], [1.0, 0.24, 0.24]], 14)
		bowl.material_override = Mats.brass()
		bowl.position = Vector3(0, 0.62, 0)
		add_child(bowl)
		_glow = _light(Color(1.0, 0.78, 0.42), 0.9, 9.0, Vector3(0, 0.95, 0))

	func interact_prompt() -> String:
		return "Pray at the shrine"

	func interact(player) -> void:
		AudioDirector.play_3d("bell_temple", global_position, -1.0)
		AudioDirector.play_3d("shrine_activate", global_position, -6.0)
		if player != null and player.has_method("heal"):
			player.heal(GameState.max_health)
		GameState.stamina = GameState.max_stamina
		GameState.set_flag("respawn_point", [global_position.x, global_position.y, global_position.z])
		EventBus.notify.emit("The shrine is warm", "You will wake here.", "info")
		EventBus.hit_feedback.emit(global_position, 0.25, "shoot")
		_used_at = Base.t()

	func _process(_d: float) -> void:
		if _glow != null:
			var e := Base.t()
			_glow.light_energy = 0.9 + sin(e * 1.7) * 0.12 + maxf(0.0, 3.0 - (e - _used_at)) * 1.3


# ---------------------------------------------------------------------------
## A stone with writing on it. Reading it is a quest step and, in the shrine's case,
## the whole solution to the lamps.
class InscriptionStone:
	extends Base
	var tag: String
	var prompt: String
	var body: String
	var read_once: bool = false

	func _init(t_norm: String = "", p: String = "", b: String = "") -> void:
		tag = t_norm
		prompt = p
		body = b

	func post_place() -> void:
		interact_range = 3.2
		var slab := MeshInstance3D.new()
		slab.mesh = MeshKit.box(Vector3(1.30, 1.05, 0.24), 1.0)
		slab.material_override = Mats.pbr("carved_stone", 1.1)
		slab.position = Vector3(0, 0.52, 0)
		slab.rotation = Vector3(-0.12, 0.22, 0.0)
		add_child(slab)
		var base := MeshInstance3D.new()
		base.mesh = MeshKit.box(Vector3(1.62, 0.22, 0.62), 1.0)
		base.material_override = Mats.pbr("temple_stone", 1.0)
		base.position = Vector3(0, 0.10, 0)
		add_child(base)
		# Four cut lines of text, deep enough to catch the sun.
		for i in range(4):
			var line := MeshInstance3D.new()
			line.mesh = MeshKit.box(Vector3(0.86 - float(i) * 0.06, 0.035, 0.03), 1.0)
			line.material_override = Mats.flat(Color(0.20, 0.17, 0.14), 0.95)
			line.transform = slab.transform * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.30 - float(i) * 0.18, 0.13))
			add_child(line)

	func interact_prompt() -> String:
		return prompt if not read_once else "Read it again"

	func interact(_player) -> void:
		AudioDirector.play_2d("ui_open", -9.0)
		EventBus.notify.emit(prompt, body, "info")
		if not read_once:
			read_once = true
			_notify_quest(tag)

	func sync_from_state() -> void:
		var q := quests()
		if q != null and q.has_method("progress") and int(q.call("progress", "q_shrine", "inscription")) > 0:
			read_once = true


# ---------------------------------------------------------------------------
## One of the three lamps around the forecourt. Its base carries an emblem — a sun,
## a run of water, a fig leaf — and the inscription names them in order.
class ShrineLamp:
	extends Base
	var emblem: String = "sun"
	var lit: bool = false
	var _flame: MeshInstance3D
	var _glow: OmniLight3D

	func _init(e: String = "sun") -> void:
		emblem = e

	func post_place() -> void:
		interact_range = 3.2
		# The plinth stands ON the ground. Authored at y = -0.17 it was entirely
		# below it, which buried the emblem — and the emblem IS the puzzle.
		var plinth := MeshInstance3D.new()
		plinth.mesh = MeshKit.box(Vector3(0.44, 0.62, 0.44), 1.0)
		plinth.material_override = Mats.pbr("temple_stone", 1.0)
		plinth.position = Vector3(0, 0.30, 0)
		add_child(plinth)
		var cap := MeshInstance3D.new()
		cap.mesh = MeshKit.box(Vector3(0.56, 0.10, 0.56), 1.0)
		cap.material_override = Mats.pbr("carved_stone", 1.0)
		cap.position = Vector3(0, 0.64, 0)
		add_child(cap)
		var stem := MeshInstance3D.new()
		stem.mesh = MeshKit.profile_loft(
			0.74, [[0.0, 0.15, 0.15], [0.12, 0.07, 0.07], [0.78, 0.055, 0.055], [0.90, 0.19, 0.19], [1.0, 0.16, 0.16]], 12
		)
		stem.material_override = Mats.brass()
		stem.position = Vector3(0, 0.68, 0)
		add_child(stem)
		_build_emblem()
		_flame = MeshInstance3D.new()
		_flame.mesh = MeshKit.ovoid(0.06, 0.19, 0.34, 8, 6)
		var fm := StandardMaterial3D.new()
		fm.albedo_color = Color(1.0, 0.78, 0.36)
		fm.emission_enabled = true
		fm.emission = Color(1.0, 0.66, 0.24)
		fm.emission_energy_multiplier = 7.0
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flame.material_override = fm
		_flame.position = Vector3(0, 1.50, 0)
		_flame.visible = false
		add_child(_flame)
		_glow = _light(Color(1.0, 0.70, 0.34), 0.0, 9.0, Vector3(0, 1.55, 0))
		_glow.visible = false

	## The clue, set in brass on a sunken panel in the plinth's face. Cut from the
	## same sandstone as the plinth it was invisible at two metres, which is the only
	## distance that matters: the emblem IS the puzzle.
	func _build_emblem() -> void:
		var mat := Mats.brass()
		var panel := MeshInstance3D.new()
		panel.mesh = MeshKit.box(Vector3(0.33, 0.33, 0.03), 1.0)
		panel.material_override = Mats.flat(Color(0.19, 0.16, 0.13), 0.95)
		panel.position = Vector3(0, 0.34, 0.215)
		add_child(panel)
		var root := Node3D.new()
		root.position = Vector3(0, 0.34, 0.232)
		add_child(root)
		match emblem:
			"sun":
				# A flattened SPHERE. A lofted cylinder has no end caps, so seen face
				# on it is an open tube and the sun lost its disc entirely; an ovoid
				# tapers at its poles and gave a diamond. A sphere's silhouette is
				# the circle this wants.
				var disc := MeshInstance3D.new()
				disc.mesh = MeshKit.sphere(0.062, 20, 14)
				disc.material_override = mat
				disc.scale = Vector3(1.0, 1.0, 0.24)
				disc.position = Vector3(0, 0, 0.008)
				root.add_child(disc)
				for i in range(8):
					var a: float = TAU * float(i) / 8.0
					var ray := MeshInstance3D.new()
					ray.mesh = MeshKit.box(Vector3(0.026, 0.062, 0.026), 1.0)
					ray.material_override = mat
					ray.position = Vector3(cos(a) * 0.108, sin(a) * 0.108, 0.010)
					ray.rotation = Vector3(0, 0, a)
					root.add_child(ray)
			"river":
				for i in range(3):
					var wave := MeshInstance3D.new()
					wave.mesh = MeshKit.box(Vector3(0.24, 0.032, 0.030), 1.0)
					wave.material_override = mat
					wave.position = Vector3(0, 0.062 - float(i) * 0.062, 0.010)
					wave.rotation = Vector3(0, 0, 0.16 if i % 2 == 0 else -0.16)
					root.add_child(wave)
			_:
				var stalk := MeshInstance3D.new()
				stalk.mesh = MeshKit.box(Vector3(0.024, 0.19, 0.024), 1.0)
				stalk.material_override = mat
				stalk.position = Vector3(0, -0.07, 0.010)
				root.add_child(stalk)
				var blade := MeshInstance3D.new()
				blade.mesh = MeshKit.ovoid(0.105, 0.20, 0.55, 10, 6)
				blade.material_override = mat
				blade.scale = Vector3(1.0, 1.0, 0.20)
				blade.position = Vector3(0, 0.08, 0.010)
				root.add_child(blade)

	func emblem_label() -> String:
		return String(QuestData.LAMP_EMBLEM_NAMES.get(emblem, emblem))

	func can_interact(_p) -> bool:
		return not lit

	func interact_prompt() -> String:
		return "Light the lamp of %s" % emblem_label()

	func interact(_player) -> void:
		if lit:
			return
		if host != null and host.lamp_puzzle != null:
			host.lamp_puzzle.light(self)

	func set_lit(v: bool, quiet: bool = false) -> void:
		if lit == v:
			return
		lit = v
		_flame.visible = v
		_glow.light_energy = 1.6 if v else 0.0
		_refresh_lights()
		if quiet:
			return
		if v:
			AudioDirector.play_3d("torch_light", global_position, -4.0)
		else:
			AudioDirector.play_3d("ui_close", global_position, -7.0)

	func _light_wanted() -> bool:
		return lit

	func _process(_d: float) -> void:
		if not lit:
			return
		var e := Base.t()
		if _glow != null:
			_glow.light_energy = 1.6 + sin(e * 9.1) * 0.20 + sin(e * 3.3) * 0.13
		_flame.scale = Vector3(1.0 + sin(e * 11.0) * 0.10, 1.0 + sin(e * 7.3) * 0.14, 1.0 + sin(e * 11.0) * 0.10)


# ---------------------------------------------------------------------------
## The order the lamps must be lit in, and what happens when you get it wrong.
##
## The rule is entirely in the world: the inscription names sun, river, fig, and each
## lamp wears its emblem. Light one out of turn and all three go out together, so the
## mistake is legible and the retry costs nothing but the walk between them.
class LampPuzzle:
	extends Node
	var lamps: Array = []  # Array[ShrineLamp], in the order they were placed
	var sequence: Array = []  # emblems lit so far, this attempt

	func register(l) -> void:
		lamps.append(l)

	func order() -> Array:
		return QuestData.LAMP_ORDER

	func lamp_of(emblem: String):
		for l in lamps:
			if is_instance_valid(l) and l.emblem == emblem:
				return l
		return null

	## Returns true if the lamp was the right one.
	func light(lamp) -> bool:
		var want := String(order()[sequence.size()]) if sequence.size() < order().size() else ""
		if lamp.emblem != want:
			_wrong(lamp)
			return false
		sequence.append(lamp.emblem)
		lamp.set_lit(true)
		var q := _quests()
		if q != null and q.has_method("notify_interact"):
			q.call("notify_interact", "shrine_lamp")
		if sequence.size() >= order().size():
			AudioDirector.play_3d("shrine_activate", lamp.global_position, -4.0)
			EventBus.notify.emit("The lamps are lit", "Three flames, in the order the stone names them.", "quest")
		return true

	func _wrong(lamp) -> void:
		AudioDirector.play_3d("ui_close", lamp.global_position, -3.0)
		var named: String = String(QuestData.LAMP_EMBLEM_NAMES.get(order()[0], order()[0]))
		if sequence.is_empty():
			EventBus.notify.emit("Nothing takes", "The wick will not hold a flame. The stone names %s first." % named, "warn")
		else:
			EventBus.notify.emit("The flames go out", "All three, together. The order on the stone was not this one.", "warn")
		reset()

	func reset() -> void:
		sequence.clear()
		for l in lamps:
			if is_instance_valid(l):
				l.set_lit(false, true)
		var q := _quests()
		if q != null and q.has_method("reset_objective"):
			q.call("reset_objective", "q_shrine", "lamps")

	## Re-light whatever the saved log says was already lit, silently.
	func sync_from_state() -> void:
		var q := _quests()
		if q == null or not q.has_method("progress"):
			return
		var done: int = int(q.call("progress", "q_shrine", "lamps"))
		sequence.clear()
		for i in range(order().size()):
			var l = lamp_of(String(order()[i]))
			if l == null:
				continue
			var on: bool = i < done
			l.set_lit(on, true)
			if on:
				sequence.append(l.emblem)

	func _quests() -> Node:
		for n in get_tree().get_nodes_in_group("quest_system"):
			return n
		return null


# ---------------------------------------------------------------------------
## The lamp on the shrine's threshold, the one the east road used to be lit by. It
## needs the traveller's oil, which is what Bhadra hands over.
class ThresholdLamp:
	extends Base
	var lit: bool = false
	var _flame: MeshInstance3D
	var _glow: OmniLight3D

	func post_place() -> void:
		interact_range = 3.2
		var post := MeshInstance3D.new()
		post.mesh = MeshKit.profile_loft(1.24, [[0.0, 0.20, 0.20], [0.10, 0.13, 0.13], [0.85, 0.11, 0.11], [1.0, 0.16, 0.16]], 10)
		post.material_override = Mats.pbr("temple_stone", 1.1)
		add_child(post)
		var cup := MeshInstance3D.new()
		cup.mesh = MeshKit.profile_loft(0.16, [[0.0, 0.10, 0.10], [1.0, 0.20, 0.20]], 12)
		cup.material_override = Mats.brass()
		cup.position = Vector3(0, 1.24, 0)
		add_child(cup)
		_flame = MeshInstance3D.new()
		_flame.mesh = MeshKit.ovoid(0.07, 0.22, 0.34, 8, 6)
		var fm := StandardMaterial3D.new()
		fm.albedo_color = Color(1.0, 0.78, 0.36)
		fm.emission_enabled = true
		fm.emission = Color(1.0, 0.64, 0.22)
		fm.emission_energy_multiplier = 7.5
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_flame.material_override = fm
		_flame.position = Vector3(0, 1.42, 0)
		_flame.visible = false
		add_child(_flame)
		_glow = _light(Color(1.0, 0.68, 0.32), 0.0, 14.0, Vector3(0, 1.45, 0))
		_glow.visible = false

	func can_interact(_p) -> bool:
		return not lit

	func interact_prompt() -> String:
		if GameState.has_item("lamp_oil"):
			return "Fill and light the threshold lamp"
		return "The lamp is dry — it needs oil"

	func interact(_player) -> void:
		if lit:
			return
		if not GameState.remove_item("lamp_oil", 1):
			AudioDirector.play_2d("ui_close", -8.0)
			EventBus.notify.emit("Dry", "There is a wick, and no oil in the world " + "will get here on its own.", "warn")
			return
		_set_lit(true)
		AudioDirector.play_3d("torch_light", global_position, -3.0)
		EventBus.notify.emit("The threshold lamp", "Small, and orange, and visible from the ford.", "quest")
		_notify_quest("threshold_lamp")

	func _set_lit(v: bool) -> void:
		lit = v
		_flame.visible = v
		_glow.light_energy = 2.1 if v else 0.0
		_refresh_lights()

	func _light_wanted() -> bool:
		return lit

	func sync_from_state() -> void:
		var q := quests()
		if q != null and q.has_method("progress"):
			_set_lit(int(q.call("progress", "q_shrine", "lamp")) > 0)

	func _process(_d: float) -> void:
		if lit and _glow != null:
			_glow.light_energy = 2.1 + sin(Base.t() * 8.7) * 0.24


# ---------------------------------------------------------------------------
## The empty frame the bell used to hang in. Hang the bell, and ring it.
class BellFrame:
	extends Base
	var hung: bool = false
	var _bell: Node3D
	var _swing: float = 0.0

	func post_place() -> void:
		interact_range = 3.6
		var mat := Mats.pbr("wood_beam", 1.6)
		for s in [-1.0, 1.0]:
			var leg := MeshInstance3D.new()
			leg.mesh = MeshKit.profile_loft(2.05, [[0.0, 0.11, 0.11], [1.0, 0.085, 0.085]], 8)
			leg.material_override = mat
			leg.position = Vector3(0.62 * s, 0, 0)
			leg.rotation = Vector3(0, 0, -0.055 * s)
			add_child(leg)
		var beam := MeshInstance3D.new()
		beam.mesh = MeshKit.box(Vector3(1.72, 0.15, 0.16), 1.0)
		beam.material_override = mat
		beam.position = Vector3(0, 2.06, 0)
		add_child(beam)
		var hook := MeshInstance3D.new()
		hook.mesh = MeshKit.tube(0.16, [[0.0, 0.018], [1.0, 0.018]], 6)
		hook.material_override = Mats.brass()
		hook.position = Vector3(0, 1.90, 0)
		add_child(hook)
		_bell = Node3D.new()
		_bell.position = Vector3(0, 1.88, 0)
		add_child(_bell)
		var body := MeshInstance3D.new()
		body.mesh = MeshKit.profile_loft(
			0.52, [[0.0, 0.30, 0.30], [0.25, 0.26, 0.26], [0.62, 0.16, 0.16], [0.86, 0.09, 0.09], [1.0, 0.05, 0.05]], 16
		)
		body.material_override = Mats.brass()
		body.position = Vector3(0, -0.52, 0)
		_bell.add_child(body)
		_bell.visible = false

	func can_interact(_p) -> bool:
		if hung:
			return true
		return GameState.has_item("temple_bell")

	func interact_prompt() -> String:
		if hung:
			return "Ring the bell"
		if GameState.has_item("temple_bell"):
			return "Hang the bell in its frame"
		return "The frame is empty"

	func interact(_player) -> void:
		if not hung:
			if not GameState.remove_item("temple_bell", 1):
				return
			hung = true
			_bell.visible = true
			GameState.set_flag("shrine_bell_hung", true)
			EventBus.notify.emit("The bell is hung", "It finds its old hook as though it had never left.", "quest")
		_swing = 1.0
		AudioDirector.play_3d("bell_temple", global_position, 1.0)
		EventBus.hit_feedback.emit(global_position, 0.3, "shoot")
		_notify_quest("shrine_bell_mount")

	func sync_from_state() -> void:
		hung = bool(GameState.get_flag("shrine_bell_hung", false))
		if _bell != null:
			_bell.visible = hung

	func _process(delta: float) -> void:
		if _swing <= 0.0:
			return
		_swing = maxf(0.0, _swing - delta * 0.55)
		if _bell != null:
			_bell.rotation.z = sin(Base.t() * 7.4) * 0.30 * _swing


# ===========================================================================
#  The forest road
# ===========================================================================
## A cart that did not get through. Bindu's bell is in the wreck of it.
class BrokenCart:
	extends Base
	var examined: bool = false

	func post_place() -> void:
		interact_range = 3.8
		var wood := Mats.pbr("wood_beam", 1.4)
		var bed := MeshInstance3D.new()
		bed.mesh = MeshKit.box(Vector3(2.20, 0.20, 1.24), 1.2)
		bed.material_override = wood
		bed.position = Vector3(0, 0.62, 0)
		bed.rotation = Vector3(0.0, 0.28, 0.72)
		add_child(bed)
		for i in range(3):
			var plank := MeshInstance3D.new()
			plank.mesh = MeshKit.box(Vector3(1.70, 0.07, 0.22), 1.6)
			plank.material_override = wood
			plank.position = Vector3(-0.30 + float(i) * 0.34, 0.16 + float(i) * 0.06, 0.52 + float(i) * 0.26)
			plank.rotation = Vector3(0.06 * float(i - 1), 0.30 + 0.12 * float(i), 0.05 * float(i - 1))
			add_child(plank)
		# One wheel still on the axle, one thrown clear.
		var axle := MeshInstance3D.new()
		axle.mesh = MeshKit.tube(1.46, [[0.0, 0.05], [1.0, 0.05]], 8)
		axle.material_override = wood
		axle.position = Vector3(0.42, 0.30, -0.73)
		axle.rotation = Vector3(PI * 0.5, 0, 0.16)
		add_child(axle)
		add_child(_wheel(Vector3(0.30, 0.52, -0.66), Vector3(0.0, 0.0, 0.20), wood))
		add_child(_wheel(Vector3(-1.55, 0.11, 0.92), Vector3(1.42, 0.5, 0.0), wood))
		# Spilled grain sacks, sun-bleached.
		for i in range(3):
			var sack := MeshInstance3D.new()
			sack.mesh = MeshKit.ovoid(0.26, 0.42, 0.5, 10, 7)
			sack.material_override = Interactables.alt_pbr("cloth_white", 1.4)
			sack.position = Vector3(-0.9 + float(i) * 0.7, 0.20, 0.75 + float(i) * 0.22)
			sack.rotation = Vector3(1.35, float(i) * 1.1, 0.2)
			add_child(sack)

	func _wheel(at: Vector3, rot: Vector3, mat: Material) -> Node3D:
		var n := Node3D.new()
		n.position = at
		n.rotation = rot
		var rim := MeshInstance3D.new()
		rim.mesh = MeshKit.tube(0.10, [[0.0, 0.50], [1.0, 0.50]], 18)
		rim.material_override = mat
		rim.rotation = Vector3(PI * 0.5, 0, 0)
		rim.position = Vector3(0, 0, 0.05)
		n.add_child(rim)
		for i in range(6):
			var a: float = TAU * float(i) / 6.0
			var spoke := MeshInstance3D.new()
			spoke.mesh = MeshKit.box(Vector3(0.045, 0.94, 0.045), 1.0)
			spoke.material_override = mat
			spoke.rotation = Vector3(0, 0, a)
			n.add_child(spoke)
		return n

	func can_interact(_p) -> bool:
		return not examined

	func interact_prompt() -> String:
		return "Search the broken cart"

	func interact(_player) -> void:
		if examined:
			return
		examined = true
		AudioDirector.play_3d("pickup_item", global_position, -4.0)
		EventBus.notify.emit(
			"The cart", "Split along the axle and pushed off the road. Under the boards, a brass " + "bell with a split lip.", "item"
		)
		GameState.set_flag("saw_cart", true)
		GameState.add_item("goat_bell", 1)
		_notify_quest("forest_evidence")

	func sync_from_state() -> void:
		examined = bool(GameState.get_flag("saw_cart", false))


# ---------------------------------------------------------------------------
## The tree beside the cart. Whatever came through went up it.
class ClawedTree:
	extends Base
	var examined: bool = false
	var _marks: Array = []

	func post_place() -> void:
		interact_range = 3.4
		var trunk := MeshInstance3D.new()
		trunk.mesh = MeshKit.profile_loft(4.6, [[0.0, 0.46, 0.46], [0.16, 0.34, 0.34], [0.62, 0.27, 0.27], [1.0, 0.21, 0.21]], 12)
		trunk.material_override = Interactables.alt_pbr("bark_banyan", 2.2)
		add_child(trunk)
		# Four gouges, chest high. Authored at radius 0.30 they sat INSIDE the bark —
		# the trunk is 0.315 across at that height — so the marks the whole objective
		# is about were invisible. They stand proud of the surface now.
		var pale := Mats.flat(Color(0.78, 0.68, 0.50), 0.8)
		for i in range(4):
			var m := MeshInstance3D.new()
			m.mesh = MeshKit.box(Vector3(0.055, 0.74, 0.05), 1.0)
			m.material_override = pale
			var a: float = -0.34 + float(i) * 0.20
			m.position = Vector3(sin(a) * 0.325, 1.46 + float(i % 2) * 0.10, cos(a) * 0.325)
			m.rotation = Vector3(0.0, a, 0.20 - float(i) * 0.05)
			add_child(m)
			_marks.append(m)
		# A shred of hide caught on the lowest one.
		var tuft := MeshInstance3D.new()
		tuft.mesh = MeshKit.quad(0.10, 0.16)
		tuft.material_override = Mats.flat(Color(0.42, 0.36, 0.30), 0.95)
		tuft.position = Vector3(sin(-0.34) * 0.35, 1.14, cos(-0.34) * 0.35)
		tuft.rotation = Vector3(0.2, -0.34, 0.3)
		add_child(tuft)

	func can_interact(_p) -> bool:
		return not examined

	func interact_prompt() -> String:
		return "Examine the marks on the tree"

	func interact(_player) -> void:
		if examined:
			return
		examined = true
		AudioDirector.play_2d("ui_open", -9.0)
		EventBus.notify.emit(
			"The tree",
			"Four gouges, a hand's width apart and taller than a tiger can reach. " + "Whatever made them was standing up.",
			"info"
		)
		GameState.set_flag("saw_claws", true)
		_notify_quest("forest_evidence")

	func sync_from_state() -> void:
		examined = bool(GameState.get_flag("saw_claws", false))


# ---------------------------------------------------------------------------
## Bindu, tied in the rakshasa camp, and the hurdle she is tied to.
class BinduPen:
	extends Base
	var opened: bool = false
	var goat: Escortee

	func post_place() -> void:
		interact_range = 3.6
		var wood := Mats.pbr("wood_beam", 2.0)
		for i in range(5):
			var stake := MeshInstance3D.new()
			stake.mesh = MeshKit.profile_loft(1.15, [[0.0, 0.055, 0.055], [1.0, 0.035, 0.035]], 6)
			stake.material_override = wood
			stake.position = Vector3(-0.9 + float(i) * 0.45, 0, 0.0)
			stake.rotation = Vector3(0.06 * float(i - 2), 0, 0.05 * float(i - 2))
			add_child(stake)
		for j in range(2):
			var rail := MeshInstance3D.new()
			rail.mesh = MeshKit.tube(2.0, [[0.0, 0.033], [1.0, 0.030]], 6)
			rail.material_override = wood
			rail.position = Vector3(-0.95, 0.44 + float(j) * 0.42, 0.0)
			rail.rotation = Vector3(0, 0, -PI * 0.5)
			add_child(rail)
		goat = Escortee.new("bindu", "Bindu")
		goat.name = "Bindu"
		add_child(goat)
		goat.position = Vector3(1.15, 0, 0.55)
		goat.build()

	func can_interact(_p) -> bool:
		if opened:
			return false
		var q := quests()
		if q != null and q.has_method("is_objective_live"):
			return bool(q.call("is_objective_live", "q_lost_goat", "bindu"))
		return true

	func interact_prompt() -> String:
		return "Cut Bindu loose"

	func interact(player) -> void:
		if opened:
			return
		opened = true
		AudioDirector.play_3d("pickup_item", global_position, -5.0)
		if goat != null:
			goat.start_following(player)
		EventBus.notify.emit("Bindu", "Thin, filthy, and entirely unimpressed. She falls in behind you.", "quest")

	func sync_from_state() -> void:
		var q := quests()
		if q == null or not q.has_method("progress"):
			return
		if int(q.call("progress", "q_lost_goat", "bindu")) > 0:
			opened = true
			if goat != null:
				goat.arrive_home()


# ---------------------------------------------------------------------------
## A goat that walks where you walk. The escort target for "The Path Through the
## Forest": she is the reason to go into the camp at all.
class Escortee:
	extends Node3D
	const SPEED := 2.45
	const FOLLOW_MIN := 2.4
	const FOLLOW_MAX := 3.6
	## Left this far behind — a cliff, a river, a sprint — and she catches up off
	## screen rather than being lost somewhere the player will never walk back to.
	const CATCHUP := 26.0

	var escort_id: String = "bindu"
	var display_name: String = "Bindu"
	var following: bool = false
	var home: bool = false
	var _target: Node3D
	var _map: WorldMap
	var _legs: Array = []
	var _body: Node3D
	var _gait: float = 0.0
	var _speed: float = 0.0

	func _init(eid: String = "bindu", nm: String = "Bindu") -> void:
		escort_id = eid
		display_name = nm

	func _ready() -> void:
		add_to_group("escortee")

	func build() -> void:
		# Dun body, dark legs and face: a white blob read as a sheep in the first
		# screenshots, with no head you could find.
		var hide := Mats.flat(Color(0.56, 0.49, 0.39), 0.95)
		var pale := Mats.flat(Color(0.78, 0.72, 0.60), 0.94)
		var dark := Mats.flat(Color(0.27, 0.23, 0.20), 0.9)
		_body = Node3D.new()
		add_child(_body)
		var barrel := MeshInstance3D.new()
		barrel.mesh = MeshKit.ovoid(0.215, 0.86, 0.48, 14, 9)
		barrel.material_override = hide
		barrel.rotation = Vector3(PI * 0.5, 0, 0)
		barrel.scale = Vector3(1.0, 1.0, 0.88)
		barrel.position = Vector3(0, 0.56, -0.04)
		_body.add_child(barrel)
		var shoulder := MeshInstance3D.new()
		shoulder.mesh = MeshKit.ovoid(0.185, 0.30, 0.5, 12, 7)
		shoulder.material_override = hide
		shoulder.rotation = Vector3(PI * 0.5, 0, 0)
		shoulder.position = Vector3(0, 0.60, 0.26)
		_body.add_child(shoulder)
		var neck := MeshInstance3D.new()
		neck.mesh = MeshKit.limb(0.32, 0.075, 0.115, 1.02, 9)
		neck.material_override = hide
		neck.position = Vector3(0, 0.62, 0.30)
		neck.rotation = Vector3(-0.62, 0, 0)
		_body.add_child(neck)
		# A long wedge of a head, level and forward, so the animal has a front.
		var head := MeshInstance3D.new()
		head.mesh = MeshKit.ovoid(0.078, 0.30, 0.62, 12, 8)
		head.material_override = pale
		head.rotation = Vector3(PI * 0.5, 0, 0)
		head.scale = Vector3(1.0, 1.0, 0.86)
		head.position = Vector3(0, 0.81, 0.50)
		_body.add_child(head)
		var muzzle := MeshInstance3D.new()
		muzzle.mesh = MeshKit.ovoid(0.048, 0.10, 0.5, 10, 6)
		muzzle.material_override = dark
		muzzle.rotation = Vector3(PI * 0.5, 0, 0)
		muzzle.position = Vector3(0, 0.795, 0.66)
		_body.add_child(muzzle)
		for s2 in [-1.0, 1.0]:
			var eye := MeshInstance3D.new()
			eye.mesh = MeshKit.sphere(0.019, 8, 6)
			eye.material_override = dark
			eye.position = Vector3(0.058 * s2, 0.845, 0.545)
			_body.add_child(eye)
			# Goat ears hang; the first pair stood straight up like a rabbit's.
			var ear := MeshInstance3D.new()
			ear.mesh = MeshKit.ovoid(0.042, 0.17, 0.4, 8, 5)
			ear.material_override = pale
			ear.scale = Vector3(1.0, 1.0, 0.30)
			ear.position = Vector3(0.085 * s2, 0.80, 0.42)
			ear.rotation = Vector3(0.55, 0, 1.55 * s2)
			_body.add_child(ear)
			var horn := MeshInstance3D.new()
			horn.mesh = MeshKit.tube(0.26, [[0.0, 0.024], [0.5, 0.016], [1.0, 0.007]], 7, 1.0, Vector3(0.0, 0.0, -0.16))
			horn.material_override = dark
			horn.position = Vector3(0.058 * s2, 0.90, 0.43)
			horn.rotation = Vector3(-0.95, 0, 0.40 * s2)
			_body.add_child(horn)
		var beard := MeshInstance3D.new()
		beard.mesh = MeshKit.ovoid(0.032, 0.13, 0.35, 8, 5)
		beard.material_override = pale
		beard.position = Vector3(0, 0.70, 0.62)
		beard.rotation = Vector3(0.35, 0, 0)
		_body.add_child(beard)
		var tail := MeshInstance3D.new()
		tail.mesh = MeshKit.tube(0.15, [[0.0, 0.032], [1.0, 0.012]], 6)
		tail.material_override = pale
		tail.position = Vector3(0, 0.70, -0.42)
		tail.rotation = Vector3(-0.85, 0, 0)
		_body.add_child(tail)
		# A rope collar. The brass bell that hung on it is in the wreck of the cart.
		var collar := MeshInstance3D.new()
		collar.mesh = MeshKit.tube(0.035, [[0.0, 0.098], [1.0, 0.098]], 12)
		collar.material_override = Mats.flat(Color(0.52, 0.42, 0.28), 0.96)
		collar.position = Vector3(0, 0.70, 0.35)
		collar.rotation = Vector3(-0.62, 0, 0)
		_body.add_child(collar)
		for i in range(4):
			var fx: float = -0.115 if i % 2 == 0 else 0.115
			var fz: float = 0.24 if i < 2 else -0.24
			var leg := MeshInstance3D.new()
			leg.mesh = MeshKit.limb(0.50, 0.052, 0.028, 1.03, 7)
			leg.material_override = hide
			leg.position = Vector3(fx, 0.02, fz)
			_body.add_child(leg)
			_legs.append(leg)
			var hoof := MeshInstance3D.new()
			hoof.mesh = MeshKit.profile_loft(0.07, [[0.0, 0.036, 0.030], [1.0, 0.030, 0.026]], 7)
			hoof.material_override = dark
			hoof.position = Vector3(fx, 0.0, fz)
			_body.add_child(hoof)

	func start_following(target: Node) -> void:
		following = true
		home = false
		_target = target as Node3D
		if _target == null:
			_target = get_tree().get_first_node_in_group("player") as Node3D

	func arrive_home() -> void:
		following = false
		home = true
		var p := WorldMap.P_VILLAGE + Vector2(4.0, -3.0)
		var m := _world_map()
		if m != null:
			global_position = Vector3(p.x, m.height_at(p.x, p.y), p.y)

	func is_following() -> bool:
		return following

	func _world_map() -> WorldMap:
		if _map != null:
			return _map
		var n := get_parent()
		while n != null:
			if n is Interactables:
				_map = (n as Interactables).map
				return _map
			n = n.get_parent()
		return null

	func _process(delta: float) -> void:
		var m := _world_map()
		if m == null:
			return
		var want := 0.0
		if following and _target != null and is_instance_valid(_target):
			var to: Vector3 = _target.global_position - global_position
			to.y = 0.0
			var d := to.length()
			if d > CATCHUP:
				var behind: Vector3 = _target.global_position - _target.global_basis.z * 2.8
				global_position = Vector3(behind.x, m.height_at(behind.x, behind.z), behind.z)
				rotation.y = _target.rotation.y
				want = SPEED
			elif d > FOLLOW_MAX:
				want = SPEED * clampf((d - FOLLOW_MIN) / 6.0, 0.25, 1.6)
				var step := to.normalized() * want * delta
				var np := global_position + step
				global_position = Vector3(np.x, m.height_at(np.x, np.z), np.z)
				rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), 1.0 - pow(0.001, delta))
			elif d > FOLLOW_MIN:
				rotation.y = lerp_angle(rotation.y, atan2(to.x, to.z), 1.0 - pow(0.02, delta))
		else:
			global_position = Vector3(global_position.x, m.height_at(global_position.x, global_position.z), global_position.z)
		_speed = lerpf(_speed, want, 1.0 - pow(0.002, delta))
		_gait += delta * (2.4 + _speed * 2.6)
		if _body != null:
			_body.position.y = sin(_gait * 2.0) * 0.022 * clampf(_speed, 0.2, 1.0)
		for i in range(_legs.size()):
			var l: MeshInstance3D = _legs[i]
			if is_instance_valid(l):
				var ph: float = _gait + PI * float((i % 2) ^ (1 if i >= 2 else 0))
				l.rotation.x = sin(ph) * 0.42 * clampf(_speed, 0.06, 1.0)


# ===========================================================================
#  The ruins
# ===========================================================================
## A slab of fallen lintel wedged across the way in. It grinds aside, and what has
## been keeping the bell company comes out.
class RuinGate:
	extends Base
	var open: bool = false
	var _leaf: Node3D
	var _body: StaticBody3D
	var _shape: CollisionShape3D
	var _anim: float = 0.0
	var _woke: bool = false

	func post_place() -> void:
		interact_range = 4.0
		var mat := Mats.pbr("brick_ruin", 1.0)
		for s in [-1.0, 1.0]:
			var jamb := MeshInstance3D.new()
			jamb.mesh = MeshKit.box(Vector3(0.46, 2.90, 0.52), 1.0)
			jamb.material_override = mat
			jamb.position = Vector3(1.42 * s, 1.45, 0)
			add_child(jamb)
		var lintel := MeshInstance3D.new()
		lintel.mesh = MeshKit.box(Vector3(3.30, 0.42, 0.60), 1.0)
		lintel.material_override = mat
		lintel.position = Vector3(0, 3.10, 0)
		add_child(lintel)
		# Two wall stubs stepping down to nothing, so this reads as a doorway in
		# something rather than an arch standing on its own in a field. Both courses
		# stand ON the ground: an earlier version capped them with a block floating
		# clear of the wall it was supposed to be falling off.
		for s3 in [-1.0, 1.0]:
			var wall := MeshInstance3D.new()
			wall.mesh = MeshKit.box(Vector3(1.60, 2.30, 0.46), 1.0)
			wall.material_override = mat
			wall.position = Vector3(2.45 * s3, 1.12, 0)
			wall.rotation = Vector3(0, 0, 0.015 * s3)
			add_child(wall)
			var low := MeshInstance3D.new()
			low.mesh = MeshKit.box(Vector3(1.35, 1.45, 0.42), 1.0)
			low.material_override = mat
			low.position = Vector3(3.80 * s3, 0.70, 0)
			low.rotation = Vector3(0, 0, 0.05 * s3)
			add_child(low)
		_leaf = Node3D.new()
		_leaf.position = Vector3(-1.18, 0, 0)
		add_child(_leaf)
		var slab := MeshInstance3D.new()
		slab.mesh = MeshKit.box(Vector3(2.36, 2.78, 0.22), 1.0)
		slab.material_override = Mats.pbr("temple_stone", 0.9)
		slab.position = Vector3(1.18, 1.40, 0)
		_leaf.add_child(slab)
		var ring := MeshInstance3D.new()
		ring.mesh = MeshKit.tube(0.04, [[0.0, 0.11], [1.0, 0.11]], 10)
		ring.material_override = Mats.brass()
		ring.position = Vector3(2.02, 1.34, 0.14)
		ring.rotation = Vector3(PI * 0.5, 0, 0)
		_leaf.add_child(ring)
		# Real collision: a gate you can walk through is not a gate.
		_body = StaticBody3D.new()
		add_child(_body)
		_shape = CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.36, 2.78, 0.30)
		_shape.shape = box
		_shape.position = Vector3(0, 1.40, 0)
		_body.add_child(_shape)

	## Turn the gateway to face a point, so the way through leads into the hall.
	## The passage runs along local +Z and the wall along local X, so the yaw that
	## points +Z at the target is the whole of it — the extra quarter turn that was
	## here put the wall across the approach and the doorway side-on to it.
	func face(p: Vector3) -> void:
		var to := p - global_position
		if Vector2(to.x, to.z).length_squared() < 0.01:
			return
		rotation.y = atan2(to.x, to.z)

	func can_interact(_p) -> bool:
		return not open

	func interact_prompt() -> String:
		return "Heave the slab aside"

	func interact(_player) -> void:
		if open:
			return
		open = true
		_anim = 0.0
		GameState.set_flag("ruin_gate_open", true)
		AudioDirector.play_3d("arrow_hit_stone", global_position, 2.0)
		EventBus.hit_feedback.emit(global_position, 0.4, "block")
		EventBus.notify.emit("The way in", "Stone on stone, and then a smell of old smoke.", "info")
		_wake_guards()

	## Whatever has been sitting with the bell in the dark.
	func _wake_guards() -> void:
		if _woke:
			return
		_woke = true
		var q := quests()
		if q == null or not q.has_method("spawn_at"):
			return
		var m := map()
		if m == null:
			return
		var at := Vector2(-157.0, -145.0)
		var n: int = int(q.call("spawn_at", 0, Vector3(at.x, m.height_at(at.x, at.y), at.y), 2))
		if n > 0:
			AudioDirector.play_3d("enemy_alert_1", global_position, -1.0)

	func sync_from_state() -> void:
		var was := bool(GameState.get_flag("ruin_gate_open", false))
		if was and not open:
			open = true
			_woke = true
			_anim = 1.0
			_apply()

	func _apply() -> void:
		if _leaf != null:
			_leaf.rotation.y = -1.62 * _anim
		if _shape != null:
			_shape.disabled = _anim > 0.35

	func _process(delta: float) -> void:
		if not open or _anim >= 1.0:
			return
		_anim = minf(1.0, _anim + delta * 0.62)
		_apply()


# ---------------------------------------------------------------------------
## An offering box: a hinged lid, and what somebody left inside.
class OfferingChest:
	extends Base
	var tag: String
	var contents: Dictionary
	var opened: bool = false
	var _lid: Node3D
	var _anim: float = 0.0

	func _init(t_norm: String = "chest", c: Dictionary = {}) -> void:
		tag = t_norm
		contents = c.duplicate()

	func post_place() -> void:
		interact_range = 3.0
		var wood := Mats.pbr("wood_beam", 1.8)
		var box := MeshInstance3D.new()
		box.mesh = MeshKit.box(Vector3(0.86, 0.50, 0.56), 1.2)
		box.material_override = wood
		box.position = Vector3(0, 0.25, 0)
		add_child(box)
		for s in [-1.0, 1.0]:
			var band := MeshInstance3D.new()
			band.mesh = MeshKit.box(Vector3(0.05, 0.54, 0.60), 1.0)
			band.material_override = Mats.brass()
			band.position = Vector3(0.28 * s, 0.25, 0)
			add_child(band)
		_lid = Node3D.new()
		_lid.position = Vector3(0, 0.50, -0.28)
		add_child(_lid)
		var lid := MeshInstance3D.new()
		lid.mesh = MeshKit.box(Vector3(0.90, 0.10, 0.60), 1.2)
		lid.material_override = wood
		lid.position = Vector3(0, 0.05, 0.28)
		_lid.add_child(lid)

	func can_interact(_p) -> bool:
		return not opened

	func interact_prompt() -> String:
		return "Open the offering box"

	func interact(_player) -> void:
		if opened:
			return
		opened = true
		GameState.set_flag("chest_" + tag, true)
		AudioDirector.play_3d("ui_open", global_position, -4.0)
		var parts: Array = []
		for item in contents:
			GameState.add_item(String(item), int(contents[item]))
			parts.append("%s x%d" % [QuestData.item_name(String(item)), int(contents[item])])
		AudioDirector.play_3d("pickup_item", global_position, -5.0)
		EventBus.notify.emit("The box was not empty", ", ".join(parts), "item")

	func sync_from_state() -> void:
		opened = bool(GameState.get_flag("chest_" + tag, false))
		_anim = 1.0 if opened else 0.0
		if _lid != null:
			_lid.rotation.x = -1.15 * _anim

	func _process(delta: float) -> void:
		var want: float = 1.0 if opened else 0.0
		if is_equal_approx(_anim, want):
			return
		_anim = move_toward(_anim, want, delta * 1.9)
		if _lid != null:
			_lid.rotation.x = -1.15 * _anim


# ---------------------------------------------------------------------------
## Something on the ground worth stooping for. Bobs, turns, and glows a little.
class Pickup:
	extends Base
	var item: String
	var prompt: String
	var shape: String
	var _t: float = 0.0
	var _base_y: float = 0.0
	var _visual: Node3D
	var _taken: bool = false

	func _init(i: String = "", p: String = "", s: String = "bell") -> void:
		item = i
		prompt = p
		shape = s

	func post_place() -> void:
		interact_range = 2.9
		_base_y = global_position.y
		_visual = Node3D.new()
		add_child(_visual)
		match shape:
			"amulet":
				var ring := MeshInstance3D.new()
				ring.mesh = MeshKit.tube(0.02, [[0.0, 0.115], [1.0, 0.115]], 16)
				ring.material_override = Mats.brass()
				ring.rotation = Vector3(PI * 0.5, 0, 0)
				_visual.add_child(ring)
				var bead := MeshInstance3D.new()
				bead.mesh = MeshKit.ovoid(0.055, 0.11, 0.5, 10, 7)
				var bm := StandardMaterial3D.new()
				bm.albedo_color = Color(0.42, 0.72, 0.86, 0.85)
				bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				bm.emission_enabled = true
				bm.emission = Color(0.40, 0.80, 0.95)
				bm.emission_energy_multiplier = 2.2
				bm.roughness = 0.06
				bead.material_override = bm
				bead.position = Vector3(0, -0.11, 0)
				_visual.add_child(bead)
			"seed":
				var pod := MeshInstance3D.new()
				pod.mesh = MeshKit.ovoid(0.10, 0.24, 0.42, 12, 8)
				pod.material_override = Mats.flat(Color(0.42, 0.55, 0.30), 0.7)
				_visual.add_child(pod)
				var husk := MeshInstance3D.new()
				husk.mesh = MeshKit.ovoid(0.13, 0.10, 0.5, 12, 6)
				husk.material_override = Mats.brass()
				husk.position = Vector3(0, -0.05, 0)
				_visual.add_child(husk)
			_:
				var bell := MeshInstance3D.new()
				bell.mesh = MeshKit.profile_loft(
					0.42, [[0.0, 0.24, 0.24], [0.28, 0.21, 0.21], [0.66, 0.13, 0.13], [0.90, 0.07, 0.07], [1.0, 0.04, 0.04]], 14
				)
				bell.material_override = Mats.brass()
				bell.position = Vector3(0, -0.21, 0)
				_visual.add_child(bell)
		_light(Color(1.0, 0.86, 0.52), 0.85, 5.0, Vector3(0, 0.12, 0))

	func can_interact(_p) -> bool:
		return not _taken

	func interact_prompt() -> String:
		return prompt

	func interact(_player) -> void:
		if _taken:
			return
		_taken = true
		GameState.set_flag("picked_" + item, true)
		GameState.add_item(item, 1)
		AudioDirector.play_3d("pickup_item", global_position, -4.0)
		var d: Dictionary = QuestData.ITEMS.get(item, {})
		EventBus.notify.emit(String(d.get("name", item)), String(d.get("desc", "")), "item")
		_set_shown(false)

	func _set_shown(v: bool) -> void:
		visible = v
		_refresh_lights()

	func _light_wanted() -> bool:
		return not _taken

	func sync_from_state() -> void:
		_taken = bool(GameState.get_flag("picked_" + item, false))
		_set_shown(not _taken)

	func _process(delta: float) -> void:
		if _taken:
			return
		_t += delta
		global_position.y = _base_y + sin(_t * 1.7) * 0.075
		if _visual != null:
			_visual.rotate_y(delta * 0.6)


# ===========================================================================
#  Village and camp
# ===========================================================================
class ArrowStand:
	extends Base

	func post_place() -> void:
		interact_range = 3.0
		var post := MeshInstance3D.new()
		post.mesh = MeshKit.profile_loft(0.68, [[0.0, 0.17, 0.17], [1.0, 0.20, 0.20]], 10)
		post.material_override = Mats.pbr("wood_beam", 2.0)
		add_child(post)
		var quiver := MeshInstance3D.new()
		quiver.mesh = MeshKit.profile_loft(0.34, [[0.0, 0.12, 0.12], [1.0, 0.14, 0.14]], 10)
		quiver.material_override = Mats.pbr("terracotta", 1.2)
		quiver.position = Vector3(0, 0.68, 0)
		add_child(quiver)
		for i in range(7):
			var a: float = TAU * float(i) / 7.0
			var shaft := MeshInstance3D.new()
			shaft.mesh = MeshKit.tube(0.52, [[0.0, 0.007], [1.0, 0.007]], 5)
			shaft.material_override = Mats.pbr("wood_beam", 6.0)
			shaft.position = Vector3(cos(a) * 0.075, 0.88, sin(a) * 0.075)
			shaft.rotation = Vector3(sin(a) * 0.13, 0, -cos(a) * 0.13)
			add_child(shaft)
			var fletch := MeshInstance3D.new()
			fletch.mesh = MeshKit.quad(0.05, 0.13)
			fletch.material_override = Mats.flat(Color(0.86, 0.42, 0.12), 0.9)
			fletch.position = Vector3(cos(a) * 0.10, 1.36, sin(a) * 0.10)
			add_child(fletch)

	func can_interact(_p) -> bool:
		return GameState.arrows < GameState.max_arrows

	func interact_prompt() -> String:
		return "Take arrows (%d/%d)" % [GameState.arrows, GameState.max_arrows]

	func interact(_player) -> void:
		GameState.arrows = GameState.max_arrows
		AudioDirector.play_3d("arrow_pickup", global_position, -4.0)
		EventBus.notify.emit("Quiver full", "%d arrows." % GameState.arrows, "item")


# ---------------------------------------------------------------------------
## Rest by the fire: health, stamina, and the hours pass.
class Campfire:
	extends Base
	var _glow: OmniLight3D

	func post_place() -> void:
		interact_range = 3.6
		for i in range(7):
			var a: float = TAU * float(i) / 7.0
			var st := MeshInstance3D.new()
			st.mesh = MeshKit.boulder(0.17, i * 31)
			st.material_override = Mats.pbr("rock", 2.0)
			st.position = Vector3(cos(a) * 0.64, 0.06, sin(a) * 0.64)
			add_child(st)
		for i in range(4):
			var lg := MeshInstance3D.new()
			lg.mesh = MeshKit.tube(0.72, [[0.0, 0.055], [1.0, 0.04]], 6)
			lg.material_override = Mats.pbr("wood_beam", 3.0)
			lg.position = Vector3(0, 0.08, 0)
			lg.rotation = Vector3(1.15, TAU * float(i) / 4.0, 0)
			add_child(lg)
		var embers := MeshInstance3D.new()
		embers.mesh = MeshKit.ovoid(0.20, 0.16, 0.5, 10, 5)
		var em := StandardMaterial3D.new()
		em.albedo_color = Color(1.0, 0.46, 0.14)
		em.emission_enabled = true
		em.emission = Color(1.0, 0.40, 0.10)
		em.emission_energy_multiplier = 3.4
		em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		embers.material_override = em
		embers.position = Vector3(0, 0.13, 0)
		add_child(embers)
		_glow = _light(Color(1.0, 0.62, 0.26), 2.4, 12.0, Vector3(0, 0.7, 0))

	func interact_prompt() -> String:
		return "Rest by the fire"

	func interact(player) -> void:
		if player != null and player.has_method("heal"):
			player.heal(GameState.max_health * 0.6)
		GameState.stamina = GameState.max_stamina
		var to: float = 7.2 if GameState.time_of_day > 12.0 else 19.0
		for s in get_tree().get_nodes_in_group("sky"):
			if s.has_method("set_time"):
				s.call("set_time", to)
		GameState.time_of_day = to
		AudioDirector.play_3d("fire_crackle", global_position, -6.0)
		EventBus.notify.emit("You rest", "The hours pass, and the fire keeps its own counsel.", "info")

	func _process(_d: float) -> void:
		if _glow != null:
			var e := Base.t()
			_glow.light_energy = 2.4 + sin(e * 8.3) * 0.35 + sin(e * 3.1) * 0.25


# ---------------------------------------------------------------------------
## A trestle in the square. One press, one trade — the deal is written on the prompt,
## so nobody has to open a menu to find out what a tiger claw is worth.
class MerchantStall:
	extends Base
	const TRADES := [
		{"give": "beast_claw", "n": 2, "arrows": 12, "label": "12 arrows"},
		{"give": "rakshasa_horn", "n": 1, "get": "healing_salve", "gn": 2, "label": "2 salves"},
		{"give": "rakshasa_fang", "n": 3, "get": "lamp_oil", "gn": 1, "label": "a flask of til oil"},
		{"give": "iron_scrap", "n": 2, "arrows": 8, "label": "8 arrows"},
	]

	func post_place() -> void:
		interact_range = 3.6
		var wood := Mats.pbr("wood_beam", 1.6)
		var top := MeshInstance3D.new()
		top.mesh = MeshKit.box(Vector3(2.10, 0.09, 0.86), 1.4)
		top.material_override = wood
		top.position = Vector3(0, 0.86, 0)
		add_child(top)
		for sx in [-0.92, 0.92]:
			for sz in [-0.34, 0.34]:
				var leg := MeshInstance3D.new()
				leg.mesh = MeshKit.profile_loft(0.86, [[0.0, 0.045, 0.045], [1.0, 0.04, 0.04]], 6)
				leg.material_override = wood
				leg.position = Vector3(sx, 0, sz)
				add_child(leg)
		# Awning: four posts and a stretch of saffron cotton. Two posts left the
		# front edge of the cloth hanging over the counter with nothing under it.
		for sx2 in [-1.0, 1.0]:
			var back := MeshInstance3D.new()
			back.mesh = MeshKit.profile_loft(2.26, [[0.0, 0.05, 0.05], [1.0, 0.04, 0.04]], 6)
			back.material_override = wood
			back.position = Vector3(sx2, 0, -0.56)
			add_child(back)
			var front := MeshInstance3D.new()
			front.mesh = MeshKit.profile_loft(2.04, [[0.0, 0.05, 0.05], [1.0, 0.04, 0.04]], 6)
			front.material_override = wood
			front.position = Vector3(sx2, 0, 0.56)
			add_child(front)
		var cloth := MeshInstance3D.new()
		cloth.mesh = MeshKit.box(Vector3(2.34, 0.03, 1.26), 1.0)
		cloth.material_override = Interactables.alt_pbr("cloth_saffron", 1.2)
		cloth.position = Vector3(0, 2.16, 0.0)
		cloth.rotation = Vector3(-0.175, 0, 0)
		add_child(cloth)
		# Goods: pots and a folded stack of cloth.
		for i in range(3):
			var pot := MeshInstance3D.new()
			pot.mesh = MeshKit.profile_loft(0.24, [[0.0, 0.07, 0.07], [0.45, 0.13, 0.13], [1.0, 0.08, 0.08]], 10)
			pot.material_override = Mats.pbr("terracotta", 1.0)
			pot.position = Vector3(-0.62 + float(i) * 0.34, 0.90, 0.06)
			add_child(pot)
		var bolt := MeshInstance3D.new()
		bolt.mesh = MeshKit.box(Vector3(0.52, 0.16, 0.34), 1.0)
		bolt.material_override = Interactables.alt_pbr("cloth_indigo", 1.0)
		bolt.position = Vector3(0.62, 0.98, 0.0)
		add_child(bolt)

	func _affordable() -> Dictionary:
		for t in TRADES:
			if GameState.item_count(String(t["give"])) >= int(t["n"]):
				return t
		return {}

	func can_interact(_p) -> bool:
		return true

	func interact_prompt() -> String:
		var t := _affordable()
		if t.is_empty():
			return "Trade: he wants claws, horns, fangs or scrap"
		return "Trade %d %s for %s" % [int(t["n"]), QuestData.item_name(String(t["give"])).to_lower(), String(t["label"])]

	func interact(_player) -> void:
		var t := _affordable()
		if t.is_empty():
			AudioDirector.play_2d("ui_close", -8.0)
			EventBus.notify.emit("Nothing to trade", "He turns a pot over in his hands and waits.", "info")
			return
		if not GameState.remove_item(String(t["give"]), int(t["n"])):
			return
		if t.has("arrows"):
			GameState.arrows = mini(GameState.max_arrows, GameState.arrows + int(t["arrows"]))
		if t.has("get"):
			GameState.add_item(String(t["get"]), int(t["gn"]))
		AudioDirector.play_3d("pickup_item", global_position, -5.0)
		EventBus.notify.emit("Traded", "You take %s." % String(t["label"]), "item")


# ===========================================================================
#  The hidden grove
# ===========================================================================
## A low plinth of pale stone with a bowl of standing water on it, and light coming
## up out of the ground. The end of a very long walk.
class GroveHeart:
	extends Base
	var _motes: GPUParticles3D

	func post_place() -> void:
		interact_range = 3.8
		var step := MeshInstance3D.new()
		step.mesh = MeshKit.profile_loft(0.52, [[0.0, 2.10, 2.10], [0.55, 1.92, 1.92], [0.80, 1.72, 1.72], [1.0, 1.66, 1.66]], 22)
		step.material_override = Mats.pbr("temple_stone", 1.6)
		add_child(step)
		var dais := MeshInstance3D.new()
		dais.mesh = MeshKit.profile_loft(0.62, [[0.0, 1.08, 1.08], [0.80, 0.96, 0.96], [1.0, 1.04, 1.04]], 20)
		dais.material_override = Mats.pbr("carved_stone", 1.2)
		dais.position = Vector3(0, 0.52, 0)
		add_child(dais)
		var bowl := MeshInstance3D.new()
		bowl.mesh = MeshKit.profile_loft(0.34, [[0.0, 0.30, 0.30], [0.55, 0.56, 0.56], [1.0, 0.62, 0.62]], 20)
		bowl.material_override = Mats.brass()
		bowl.position = Vector3(0, 1.14, 0)
		add_child(bowl)
		var water := MeshInstance3D.new()
		water.mesh = MeshKit.profile_loft(0.01, [[0.0, 0.57, 0.57], [1.0, 0.57, 0.57]], 20)
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.42, 0.62, 0.58, 0.86)
		wm.metallic = 0.5
		wm.roughness = 0.06
		wm.emission_enabled = true
		wm.emission = Color(0.30, 0.55, 0.50)
		wm.emission_energy_multiplier = 0.5
		water.material_override = wm
		water.position = Vector3(0, 1.44, 0)
		add_child(water)
		_light(Color(0.62, 0.90, 0.72), 4.2, 20.0, Vector3(0, 2.2, 0))
		# A slow column of green light standing out of the bowl. The grove is a
		# basin under closed forest canopy: without this it is a dark fern thicket
		# you can walk past, which is what the first screenshots showed.
		var shaft := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.10
		cyl.bottom_radius = 0.95
		cyl.height = 22.0
		cyl.radial_segments = 18
		cyl.rings = 1
		shaft.mesh = cyl
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.66, 1.0, 0.76, 0.10)
		sm.emission_enabled = true
		sm.emission = Color(0.50, 0.95, 0.66)
		sm.emission_energy_multiplier = 1.15
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sm.cull_mode = BaseMaterial3D.CULL_BACK
		sm.disable_receive_shadows = true
		shaft.mesh.surface_set_material(0, sm)
		shaft.position = Vector3(0, 12.4, 0)
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(shaft)

		_motes = GPUParticles3D.new()
		_motes.amount = 90
		_motes.lifetime = 8.0
		_motes.preprocess = 5.0
		_motes.visibility_aabb = AABB(Vector3(-9, 0, -9), Vector3(18, 12, 18))
		var pm := ParticleProcessMaterial.new()
		pm.lifetime_randomness = 0.6
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = Vector3(7.0, 0.5, 7.0)
		pm.direction = Vector3(0, 1, 0)
		pm.spread = 22.0
		pm.initial_velocity_min = 0.10
		pm.initial_velocity_max = 0.42
		pm.gravity = Vector3(0.03, 0.05, 0.0)
		pm.scale_min = 0.03
		pm.scale_max = 0.09
		var g := Gradient.new()
		g.set_color(0, Color(1.0, 0.92, 0.58, 0.0))
		g.set_color(1, Color(0.72, 0.96, 0.66, 0.0))
		g.add_point(0.3, Color(1.0, 0.90, 0.56, 0.85))
		g.add_point(0.75, Color(0.80, 0.98, 0.68, 0.45))
		var gt := GradientTexture1D.new()
		gt.gradient = g
		pm.color_ramp = gt
		_motes.process_material = pm
		var q := QuadMesh.new()
		q.size = Vector2(0.14, 0.14)
		var qm := StandardMaterial3D.new()
		qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		qm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		qm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		qm.albedo_color = Color(1.0, 1.0, 1.0)
		# Two things a mote needs. A round TEXTURE, or the quad is a hard square
		# whatever its alpha says; and `vertex_color_use_as_albedo`, or the process
		# material's colour ramp never reaches the shader at all. An emission term
		# is not modulated by the ramp either, so there is none.
		qm.albedo_texture = QuestData.soft_dot()
		qm.vertex_color_use_as_albedo = true
		qm.emission_enabled = false
		q.material = qm
		_motes.draw_pass_1 = q
		_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_motes)

	func set_near(v: bool) -> void:
		super.set_near(v)
		if _motes != null:
			_motes.emitting = v

	func interact_prompt() -> String:
		return "Drink from the bowl"

	func interact(player) -> void:
		if player != null and player.has_method("heal"):
			player.heal(GameState.max_health)
		GameState.stamina = GameState.max_stamina
		GameState.set_flag("respawn_point", [global_position.x, global_position.y, global_position.z])
		AudioDirector.play_3d("heal", global_position, -3.0)
		EventBus.notify.emit("The bowl", "Cold, and faintly green, and older than " + "anyone who could have told you about it.", "info")


# ---------------------------------------------------------------------------
## One of the stones that stand around the grove, each with a lamp bowl cut into it.
class GroveStone:
	extends Base
	var idx: int = 0

	func _init(i: int = 0) -> void:
		idx = i

	func post_place() -> void:
		interact_range = 2.6
		var shaft := MeshInstance3D.new()
		shaft.mesh = MeshKit.profile_loft(
			1.62 + float(idx % 3) * 0.20, [[0.0, 0.34, 0.26], [0.35, 0.29, 0.22], [0.82, 0.24, 0.19], [1.0, 0.26, 0.20]], 9
		)
		shaft.material_override = Mats.pbr("temple_stone", 0.75)
		shaft.rotation = Vector3(0.03 * float(idx - 3), 0, 0.025 * float(idx - 2))
		add_child(shaft)
		var bowl := MeshInstance3D.new()
		bowl.mesh = MeshKit.profile_loft(0.13, [[0.0, 0.11, 0.11], [1.0, 0.19, 0.19]], 10)
		bowl.material_override = Mats.brass()
		bowl.position = Vector3(0, 1.62 + float(idx % 3) * 0.20, 0)
		add_child(bowl)
		var flame := MeshInstance3D.new()
		flame.mesh = MeshKit.ovoid(0.058, 0.20, 0.34, 8, 6)
		var fm := StandardMaterial3D.new()
		# A brass lamp burns yellow. Green flames read as white blobs against the
		# green shaft; the gold against the green is what makes the grove a place.
		fm.albedo_color = Color(1.0, 0.80, 0.38)
		fm.emission_enabled = true
		fm.emission = Color(1.0, 0.66, 0.24)
		fm.emission_energy_multiplier = 5.0
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		flame.material_override = fm
		flame.position = Vector3(0, 1.81 + float(idx % 3) * 0.20, 0)
		add_child(flame)
		_light(Color(1.0, 0.76, 0.40), 1.7, 9.5, Vector3(0, 1.81 + float(idx % 3) * 0.20, 0))

	const LINES := [
		"A hand, cut small and worn nearly flat, pressed into the stone.",
		"Rain-marks, and under them a row of names too shallow to read.",
		"A river, cut in three strokes, running the wrong way up the stone.",
		"Nothing at all. Whoever raised this one did not get to finish it.",
		"A fig leaf, and beneath it a bowl, and beneath that a bird.",
		"The same six words four times over, in four different hands.",
	]

	func interact_prompt() -> String:
		return "Look at the stone"

	func interact(_player) -> void:
		AudioDirector.play_2d("ui_open", -10.0)
		EventBus.notify.emit(
			"The %s stone" % ["first", "second", "third", "fourth", "fifth", "sixth"][idx % 6], String(LINES[idx % LINES.size()]), "info"
		)
