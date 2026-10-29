extends Node3D
## The outpost's background sound: crackling braziers, the forge's roar,
## hissing vents and humming tonic machines (looping, positioned), wind
## that's louder out in the open than inside the halls, and now and then a
## creak or a groan somewhere off in the dark. Emitters start once the
## synthesized sounds are ready.

## [sound, position, volume dB, audible range m, pitch]
var emitters: Array = []
## Callable(position) -> true when that spot is out in the open
var is_outdoor: Callable

var _started := false
var _wind: AudioStreamPlayer
var _distant_t := 8.0
var _rng := RandomNumberGenerator.new()


func add(sound: String, pos: Vector3, vol_db := -6.0, range_m := 12.0, pitch := 1.0) -> void:
	emitters.append([sound, pos, vol_db, range_m, pitch])


func _ready() -> void:
	_rng.randomize()


func _process(dt: float) -> void:
	if not _started:
		if Sfx.is_ready():
			_start()
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var out: bool = is_outdoor.call(cam.global_position) if is_outdoor.is_valid() else true
	_wind.volume_db = lerpf(_wind.volume_db, -15.0 if out else -26.0, clampf(dt * 1.5, 0.0, 1.0))
	_distant_t -= dt
	if _distant_t <= 0.0:
		_distant_t = _rng.randf_range(9.0, 24.0)
		var a := _rng.randf() * TAU
		var p := cam.global_position + Vector3(cos(a), 0.0, sin(a)) * _rng.randf_range(12.0, 24.0) + Vector3.UP * 2.0
		var pick: String = ["creak", "distant", "groan0", "groan2", "creak"][_rng.randi() % 5]
		Sfx.play_at(pick, p, -12.0, 0.2)


func _start() -> void:
	_started = true
	for e in emitters:
		var stream: AudioStream = Sfx.streams.get(e[0])
		if stream == null:
			continue
		var p := AudioStreamPlayer3D.new()
		p.stream = stream
		p.bus = "SFX"
		p.position = e[1]
		p.volume_db = e[2]
		p.max_distance = e[3]
		p.unit_size = 2.5
		p.pitch_scale = e[4]
		p.attenuation_filter_cutoff_hz = 5000.0
		add_child(p)
		# start each loop somewhere different so neighbours don't pulse together
		p.play(_rng.randf() * stream.get_length())
	_wind = AudioStreamPlayer.new()
	_wind.stream = Sfx.streams.get("amb_wind")
	_wind.bus = "SFX"
	_wind.volume_db = -40.0
	add_child(_wind)
	if _wind.stream:
		_wind.play(_rng.randf() * _wind.stream.get_length())
