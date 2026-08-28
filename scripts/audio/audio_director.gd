extends Node
## All sound goes through here.
##
## Keeps a pool of 3D and 2D players so nothing allocates during combat, runs a music
## state machine that cross-fades between exploration / village / combat / night beds,
## and layers ambience by where the player is standing.

const SFX_PATH := "res://assets/audio/%s.wav"
const POOL_3D := 24
const POOL_2D := 10

var _pool3: Array[AudioStreamPlayer3D] = []
var _pool2: Array[AudioStreamPlayer] = []
var _cache: Dictionary = {}
var _missing: Dictionary = {}

# --- music ----------------------------------------------------------------
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_on_a: bool = true
var _music_track: String = ""
var _fade: float = 1.0
var _fade_speed: float = 0.4
var music_volume: float = -9.0
var sfx_volume: float = 0.0
var ambience_volume: float = -6.0
var master_volume: float = 0.0
var _music_enabled: bool = true

# --- ambience -------------------------------------------------------------
var _amb: Dictionary = {}  # name -> AudioStreamPlayer
var _amb_target: Dictionary = {}
var _listener: Node3D = null
var world: WorldRoot = null
var sky: SkySystem = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in range(POOL_3D):
		var p := AudioStreamPlayer3D.new()
		p.max_distance = 62.0
		p.unit_size = 5.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		p.bus = "Master"
		add_child(p)
		_pool3.append(p)
	for i in range(POOL_2D):
		var p2 := AudioStreamPlayer.new()
		add_child(p2)
		_pool2.append(p2)
	_music_a = AudioStreamPlayer.new()
	add_child(_music_a)
	_music_b = AudioStreamPlayer.new()
	add_child(_music_b)
	for n in ["amb_forest_day", "amb_forest_night", "amb_river", "amb_village", "amb_wind", "amb_temple"]:
		var a := AudioStreamPlayer.new()
		a.stream = _stream(n)
		a.volume_db = -80.0
		add_child(a)
		# A stream can only start once the player is inside the tree.
		if a.stream:
			a.play()
		_amb[n] = a
		_amb_target[n] = -80.0


func bind(w: WorldRoot, s: SkySystem, listener: Node3D) -> void:
	world = w
	sky = s
	_listener = listener


const LOOPING_PREFIXES := ["amb_", "music_"]
const LOOPING_NAMES := ["fire_crackle", "water_lap"]


func _stream(name: String) -> AudioStream:
	if _cache.has(name):
		return _cache[name]
	var path: String = SFX_PATH % name
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path)
		# Enforce looping HERE rather than trusting the import settings. The .import
		# files carried edit/loop_mode=1 and the loaded streams still came back with
		# looping off, so every ambience bed played once for 30 s and then went silent
		# for the rest of the session.
		if s is AudioStreamWAV and _should_loop(name):
			var w := (s as AudioStreamWAV).duplicate() as AudioStreamWAV
			# loop_end MUST be the real sample count. It defaults to 0, and 0 alongside
			# LOOP_FORWARD is a zero-length loop: play() then fails outright and the bed
			# is silent for the whole session.
			var bps: int = 2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1
			var chans: int = 2 if w.stereo else 1
			var frames_n: int = w.data.size() / maxi(1, bps * chans)
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = maxi(1, frames_n - 1)
			s = w
	elif not _missing.has(name):
		_missing[name] = true
		push_warning("[audio] missing: " + name)
	_cache[name] = s
	return s


static func _should_loop(name: String) -> bool:
	for pre in LOOPING_PREFIXES:
		if name.begins_with(pre):
			return true
	return name in LOOPING_NAMES


# --- one-shots ------------------------------------------------------------
func play_3d(name: String, pos: Vector3, db: float = 0.0, pitch: float = 0.0) -> void:
	var s := _stream(name)
	if s == null:
		return
	for p in _pool3:
		if not p.playing:
			p.stream = s
			p.global_position = pos
			p.volume_db = db + sfx_volume + master_volume
			p.pitch_scale = 1.0 + (pitch if pitch != 0.0 else randf_range(-0.07, 0.07))
			p.play()
			return


func play_2d(name: String, db: float = 0.0, pitch: float = 0.0) -> void:
	var s := _stream(name)
	if s == null:
		return
	for p in _pool2:
		if not p.playing:
			p.stream = s
			p.volume_db = db + sfx_volume + master_volume
			p.pitch_scale = 1.0 + (pitch if pitch != 0.0 else randf_range(-0.05, 0.05))
			p.play()
			return


func play_ui(name: String) -> void:
	play_2d(name, -8.0)


# --- music ----------------------------------------------------------------
func play_music(track: String, fade: float = 2.5) -> void:
	if track == _music_track or not _music_enabled:
		return
	_music_track = track
	var s := _stream(track)
	var incoming: AudioStreamPlayer = _music_b if _music_on_a else _music_a
	incoming.stream = s
	incoming.volume_db = -60.0
	if s:
		incoming.play()
	_music_on_a = not _music_on_a
	_fade = 0.0
	_fade_speed = 1.0 / maxf(0.2, fade)


func stop_music(fade: float = 2.0) -> void:
	_music_track = ""
	_fade = 0.0
	_fade_speed = 1.0 / maxf(0.2, fade)
	var incoming: AudioStreamPlayer = _music_a if _music_on_a else _music_b
	incoming.stop()


func set_music_enabled(on: bool) -> void:
	_music_enabled = on
	if not on:
		_music_a.stop()
		_music_b.stop()
		_music_track = ""


func _process(delta: float) -> void:
	_fade = minf(1.0, _fade + delta * _fade_speed)
	var cur: AudioStreamPlayer = _music_a if _music_on_a else _music_b
	var old: AudioStreamPlayer = _music_b if _music_on_a else _music_a
	cur.volume_db = lerpf(-60.0, music_volume + master_volume, _fade)
	old.volume_db = lerpf(music_volume + master_volume, -60.0, _fade)
	if _fade >= 1.0 and old.playing:
		old.stop()
	# Watchdog: an ambience bed must never go silent for the rest of a session. This
	# sits OUTSIDE _update_ambience, which returns early before a world is bound.
	for n in _amb:
		var pl: AudioStreamPlayer = _amb[n]
		if pl.stream != null and not pl.playing:
			pl.play()
	_update_ambience(delta)


## Blend the ambience beds by where the player is and what time it is.
func _update_ambience(delta: float) -> void:
	if _listener == null or world == null:
		return
	var p := _listener.global_position
	var night: float = 0.0
	if sky:
		night = 1.0 - sky.light_level()
	var pos2 := Vector2(p.x, p.z)
	var river: float = clampf(1.0 - (world.map.river_dist(pos2) - 8.0) / 46.0, 0.0, 1.0)
	var village: float = clampf(1.0 - pos2.distance_to(WorldMap.P_VILLAGE) / 78.0, 0.0, 1.0)
	var shrine: float = clampf(1.0 - pos2.distance_to(WorldMap.P_SHRINE) / 34.0, 0.0, 1.0)
	var forest: float = world.map.forest_density(pos2)
	var altitude: float = clampf((p.y - 40.0) / 90.0, 0.0, 1.0)
	var exposure: float = maxf(altitude, 1.0 - forest)

	_amb_target["amb_forest_day"] = _db(clampf(0.30 + forest * 0.7, 0.0, 1.0) * (1.0 - night))
	_amb_target["amb_forest_night"] = _db(clampf(0.35 + forest * 0.65, 0.0, 1.0) * night)
	_amb_target["amb_river"] = _db(river)
	_amb_target["amb_village"] = _db(village * (1.0 - night * 0.55))
	_amb_target["amb_wind"] = _db(0.22 + exposure * 0.55)
	_amb_target["amb_temple"] = _db(shrine)

	for n in _amb:
		var pl: AudioStreamPlayer = _amb[n]
		pl.volume_db = lerpf(pl.volume_db, _amb_target[n], 1.0 - pow(0.15, delta))


func _db(v: float) -> float:
	if v <= 0.004:
		return -80.0
	return linear_to_db(clampf(v, 0.0, 1.0)) + ambience_volume + master_volume


func apply_volumes(master: float, music: float, sfx: float, amb: float) -> void:
	master_volume = master
	music_volume = music
	sfx_volume = sfx
	ambience_volume = amb
