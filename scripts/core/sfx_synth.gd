extends Node
## Generates every sound for the Sfx service on a worker thread, then hands
## them over. It's a child node rather than part of the autoload script so it
## can have its own state and per-frame update (see the patch-safety note in
## sfx.gd).

const RATE := 22050

var done := false
var want_music := ""
var _task := -1
var _pending := {}
var _made := 0
var _rng := RandomNumberGenerator.new()


func start() -> void:
	_rng.seed = 1337
	_task = WorkerThreadPool.add_task(_generate, false, "Cinderhold sound synthesis")


## 0..1, for loading screens.
func progress() -> float:
	return 1.0 if done else clampf(float(_made) / SOUND_COUNT, 0.0, 0.99)


func _process(_dt: float) -> void:
	if _task != -1 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		var sfx := get_parent()
		sfx.streams = _pending
		_pending = {}
		done = true
		if want_music != "":
			sfx.music(want_music)


func _exit_tree() -> void:
	# Never let the engine tear the game down under a running synthesis thread.
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


# --- synthesis ------------------------------------------------------------

## Looping streams get a copy of their first sample appended, and loop_end
## points at it: Godot plays the sample *at* loop_end before wrapping, and a
## loop_end one past the data read beyond the buffer. Android puts guard
## pages after large allocations, so that over-read crashed the game at the
## music's first loop point (desktop allocators let it slide).
func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var n := samples.size()
	var frames := n + 1 if loop else n
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	for i in frames:
		bytes.encode_s16(i * 2, int(clampf(samples[i % n], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = n   # the last sample: the copy of the first
	return w


## A gunshot: noise crack through a falling low-pass, a body thump and a tail.
func _shot(dur: float, cutoff: float, decay: float, thump: float, tail := 0.3, gain := 0.9) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var lp2 := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := exp(-t / decay)
		var c := clampf(cutoff * exp(-t * 9.0) / RATE * TAU, 0.01, 1.0)
		lp += (_rng.randf_range(-1, 1) - lp) * c
		lp2 += (lp - lp2) * c
		phase += TAU * thump * (1.0 - t * 1.5) / RATE
		var body := sin(phase) * exp(-t / (decay * 0.8)) * 0.9
		var crack := _rng.randf_range(-1, 1) * exp(-t / 0.006) * 0.6
		var rumble := lp2 * exp(-t / (decay * 3.0)) * tail
		out[i] = tanh((lp2 * env * 1.4 + body + crack + rumble) * gain * 1.6)
	return out


func _tone(dur: float, f0: float, f1: float, wave := "sine", attack := 0.005, decay := 0.2, gain := 0.6) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := lerpf(f0, f1, t / dur)
		ph += f / RATE
		var x := fmod(ph, 1.0)
		var s := 0.0
		match wave:
			"sine": s = sin(x * TAU)
			"square": s = 1.0 if x < 0.5 else -1.0
			"saw": s = x * 2.0 - 1.0
			"tri": s = 1.0 - absf(x * 4.0 - 2.0)
		var env := minf(t / attack, 1.0) * exp(-maxf(t - attack, 0.0) / decay)
		out[i] = s * env * gain
	return out


func _noise(dur: float, cutoff: float, attack: float, decay: float, gain := 0.6, hp := false) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var c := clampf(cutoff / RATE * TAU, 0.001, 1.0)
	for i in n:
		var t := float(i) / RATE
		var r := _rng.randf_range(-1, 1)
		lp += (r - lp) * c
		var s := (r - lp) if hp else lp
		out[i] = s * minf(t / maxf(attack, 0.0001), 1.0) * exp(-t / decay) * gain
	return out


func _mix(a: PackedFloat32Array, b: PackedFloat32Array, offset := 0.0, gb := 1.0) -> PackedFloat32Array:
	var off := int(offset * RATE)
	var out := a.duplicate()
	if out.size() < off + b.size():
		out.resize(off + b.size())
	for i in b.size():
		out[off + i] += b[i] * gb
	return out


func _seq(parts: Array) -> PackedFloat32Array:
	# parts: [[samples, start_time, gain], ...]
	var out := PackedFloat32Array()
	for p in parts:
		out = _mix(out, p[0], p[1], p[2] if p.size() > 2 else 1.0)
	return out


## A guttural groan: formant-ish pulse train with wobbling pitch.
func _groan(dur: float, f: float, rough: float, gain := 0.55) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	var lp := 0.0
	var bp := 0.0
	for i in n:
		var t := float(i) / RATE
		var pitch := f * (1.0 + 0.12 * sin(t * 7.0) + 0.25 * sin(t * 2.3)) * (1.0 - 0.3 * t / dur)
		ph += pitch / RATE
		var pulse := pow(absf(sin(PI * ph)), 8.0) * 2.0 - 0.4
		var src := pulse + _rng.randf_range(-1, 1) * rough
		lp += (src - lp) * 0.18
		bp += (lp - bp) * 0.05
		var env := sin(PI * clampf(t / dur, 0.0, 1.0)) * (0.7 + 0.3 * sin(t * 13.0))
		out[i] = tanh((lp - bp) * env * gain * 3.0)
	return out


func _chord(notes: Array, dur: float, wave := "tri", decay := 0.6, gain := 0.25, stagger := 0.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var k := 0
	for f in notes:
		out = _mix(out, _tone(dur, f, f, wave, 0.01, decay, gain), stagger * k)
		k += 1
	return out


## A struck metal object: inharmonic partials [frequency, amplitude,
## decay seconds] over a short noise transient. Anvils, casings, chains.
func _clang(dur: float, partials: Array, transient := 0.5) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / RATE
		var s := _rng.randf_range(-1, 1) * transient * exp(-t / 0.003)
		for p in partials:
			s += sin(TAU * p[0] * t) * p[1] * exp(-t / p[2])
		out[i] = s
	return out


## Noise through a resonant band-pass (RBJ biquad) whose centre and level
## follow callables of time: the shapes of wind, hiss and creaks.
func _band(dur: float, center: Callable, q: float, level: Callable) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	var b0 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var lv := 0.0
	for i in n:
		if i % 32 == 0:
			# filter and level move at a control rate (1.5 ms): plenty smooth, far cheaper
			var t := float(i) / RATE
			var w := TAU * clampf(center.call(t), 20.0, RATE * 0.45) / RATE
			var alpha := sin(w) / (2.0 * q)
			var a0 := 1.0 + alpha
			b0 = alpha / a0
			a1 = -2.0 * cos(w) / a0
			a2 = (1.0 - alpha) / a0
			lv = level.call(t)
		var x := _rng.randf_range(-1, 1)
		var y := b0 * (x - x2) - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x
		y2 = y1
		y1 = y
		out[i] = y * lv
	return out


## Random clicks and pops (fire crackle, falling debris): `rate` per second,
## each a tiny burst of bright noise.
func _crackle(dur: float, rate: float, gain: float, bright := 2500.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(dur * RATE))
	var t := _rng.randf() / rate
	while t < dur - 0.05:
		var pop := _noise(0.03, bright * _rng.randf_range(0.6, 1.6), 0.0002, _rng.randf_range(0.002, 0.008),
			gain * _rng.randf_range(0.3, 1.0) * (2.0 if _rng.randf() < 0.1 else 1.0), true)
		var at := int(t * RATE)
		for i in pop.size():
			if at + i < out.size():
				out[at + i] += pop[i]
		t += -log(maxf(_rng.randf(), 0.001)) / rate
	return out


## Make a sound loop seamlessly: synthesize `fade` seconds more than the
## loop, then crossfade that tail into the head.
func _loopify(a: PackedFloat32Array, fade: float) -> PackedFloat32Array:
	var f := int(fade * RATE)
	var n := a.size() - f
	var out := a.slice(0, n)
	for i in f:
		var k := float(i) / f
		out[i] = a[i] * k + a[n + i] * (1.0 - k)
	return out


func _gain(a: PackedFloat32Array, g: float) -> PackedFloat32Array:
	var out := a.duplicate()
	for i in out.size():
		out[i] = tanh(out[i] * g)
	return out


const SOUND_COUNT := 68


func _put(sound: String, stream: AudioStreamWAV) -> void:
	_pending[sound] = stream
	_made += 1


## Exported builds keep the synthesized sounds on disk, per game version, so
## only the first launch after an update spends seconds synthesizing (phones
## especially). Runs from source always synthesize fresh.
const CACHE_ROOT := "user://sfx_cache"


func _cache_dir() -> String:
	return CACHE_ROOT.path_join(preload("res://scripts/core/version.gd").VERSION)


func _load_cache() -> bool:
	if OS.has_feature("editor") or not FileAccess.file_exists(_cache_dir().path_join("complete")):
		return false
	var names := FileAccess.get_file_as_string(_cache_dir().path_join("complete")).split("\n", false)
	if names.size() != SOUND_COUNT:
		return false
	var loaded := {}
	for n in names:
		var r = ResourceLoader.load(_cache_dir().path_join(n + ".res"), "AudioStreamWAV", ResourceLoader.CACHE_MODE_IGNORE)
		if not r is AudioStreamWAV:
			return false
		loaded[n] = r
	_pending = loaded
	_made = SOUND_COUNT
	return true


func _save_cache() -> void:
	if OS.has_feature("editor"):
		return
	# older versions' caches go
	for old in DirAccess.get_directories_at(CACHE_ROOT):
		var d := CACHE_ROOT.path_join(old)
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(d.path_join(f))
		DirAccess.remove_absolute(d)
	DirAccess.make_dir_recursive_absolute(_cache_dir())
	for n in _pending:
		if ResourceSaver.save(_pending[n], _cache_dir().path_join(n + ".res")) != OK:
			return
	var f := FileAccess.open(_cache_dir().path_join("complete"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_pending.keys()))


func _generate() -> void:
	if _load_cache():
		return
	_synthesize()
	_save_cache()


func _synthesize() -> void:
	_put("pistol", _wav(_shot(0.45, 7000, 0.05, 140, 0.25)))
	_put("smg", _wav(_shot(0.3, 9000, 0.035, 170, 0.2, 0.75)))
	_put("rifle", _wav(_shot(0.6, 6000, 0.06, 105, 0.35)))
	_put("shotgun", _wav(_shot(0.9, 4200, 0.11, 70, 0.6, 1.1)))
	_put("lmg", _wav(_shot(0.55, 5200, 0.06, 90, 0.35, 0.95)))
	_put("sniper", _wav(_shot(1.3, 5000, 0.12, 60, 0.7, 1.2)))
	var zap := _tone(0.5, 1800, 220, "saw", 0.002, 0.12, 0.35)
	_put("bolt", _wav(_mix(zap, _noise(0.5, 9000, 0.001, 0.1, 0.4, true))))
	_put("empty", _wav(_noise(0.05, 8000, 0.0005, 0.008, 0.5, true)))
	_put("mag_out", _wav(_seq([[_noise(0.08, 3000, 0.001, 0.02, 0.6, true), 0.0], [_tone(0.1, 900, 700, "square", 0.001, 0.015, 0.15), 0.01]])))
	_put("mag_in", _wav(_seq([[_noise(0.1, 2500, 0.001, 0.025, 0.8, true), 0.0], [_tone(0.08, 1300, 1100, "square", 0.001, 0.01, 0.2), 0.02], [_noise(0.06, 5000, 0.001, 0.01, 0.5, true), 0.09]])))
	_put("rack", _wav(_seq([[_noise(0.1, 2000, 0.001, 0.03, 0.8, true), 0.0], [_noise(0.12, 2600, 0.001, 0.03, 0.9, true), 0.14]])))
	_put("hit", _wav(_tone(0.06, 2400, 2000, "tri", 0.001, 0.02, 0.5)))
	_put("headshot", _wav(_mix(_tone(0.25, 3200, 3100, "sine", 0.001, 0.07, 0.45), _tone(0.25, 4800, 4800, "sine", 0.001, 0.05, 0.2))))
	_put("flesh", _wav(_noise(0.12, 900, 0.001, 0.04, 0.9)))
	# the knife: a sharp swish through the air, and a wet stab
	_put("melee", _wav(_band(0.28, func(t): return 1200.0 + 9000.0 * t, 2.5, func(t): return 1.4 * sin(PI * clampf(t / 0.28, 0.0, 1.0)))))
	_put("melee_hit", _wav(_seq([[_noise(0.2, 700, 0.001, 0.05, 1.0), 0.0], [_tone(0.2, 120, 60, "sine", 0.001, 0.05, 0.6), 0.0],
		[_band(0.15, func(_t): return 900.0, 3.0, func(t): return 0.6 * exp(-t / 0.05)), 0.01]])))
	for i in 4:
		_put("groan%d" % i, _wav(_groan(_rng.randf_range(0.8, 1.6), _rng.randf_range(70, 120), 0.35)))
	_put("husk_attack", _wav(_groan(0.5, 140, 0.6, 0.8)))
	_put("husk_die", _wav(_mix(_groan(0.9, 90, 0.5, 0.7), _noise(0.4, 600, 0.01, 0.15, 0.4))))
	_put("brute_roar", _wav(_groan(1.8, 45, 0.7, 0.95)))
	_put("hurt", _wav(_mix(_noise(0.3, 500, 0.001, 0.08, 0.9), _tone(0.3, 180, 90, "sine", 0.001, 0.08, 0.5))))
	_put("buy", _wav(_chord([880, 1318.5], 0.5, "tri", 0.25, 0.22, 0.07)))
	_put("deny", _wav(_tone(0.3, 160, 140, "square", 0.002, 0.12, 0.18)))
	# a barricade door dropping into the floor: chains rattle, wood grinds, a thud
	var chain := PackedFloat32Array()
	for k in 9:
		chain = _mix(chain, _clang(0.12, [[2900 + k * 37, 0.25, 0.02], [4300, 0.12, 0.012]], 0.4), k * 0.07 + _rng.randf() * 0.02)
	var grind := _band(1.5, func(t): return 180.0 + 60.0 * sin(t * 23.0), 2.0,
		func(t): return 0.9 * minf(t / 0.1, 1.0) * (0.6 + 0.4 * absf(sin(t * 41.0))) * exp(-maxf(t - 1.0, 0.0) / 0.2))
	_put("door", _wav(_gain(_seq([[chain, 0.0, 0.8], [grind, 0.1], [_tone(0.4, 70, 40, "sine", 0.002, 0.12, 0.9), 1.45],
		[_noise(0.4, 900, 0.002, 0.1, 0.7), 1.45]]), 1.3)))
	_put("round_start", _wav(_seq([[_tone(2.8, 98, 96, "saw", 0.3, 1.2, 0.25), 0.0], [_tone(2.8, 147, 146, "saw", 0.3, 1.2, 0.18), 0.0], [_tone(2.4, 196, 190, "tri", 0.2, 0.9, 0.2), 0.5], [_noise(2.5, 200, 0.4, 1.0, 0.4), 0.0]])))
	_put("round_end", _wav(_seq([[_chord([220, 277.2, 329.6], 2.5, "tri", 1.0, 0.18, 0.12), 0.0], [_chord([246.9, 329.6, 392], 2.5, "tri", 1.2, 0.16, 0.12), 0.7]])))
	_put("powerup_spawn", _wav(_seq([[_tone(0.6, 600, 1200, "sine", 0.01, 0.3, 0.3), 0.0], [_tone(0.6, 900, 1800, "sine", 0.01, 0.3, 0.2), 0.08]])))
	_put("powerup", _wav(_chord([523.3, 659.3, 784, 1046.5], 0.9, "tri", 0.35, 0.22, 0.06)))
	# Footsteps, three takes per surface. Most of their energy sits between
	# 1 and 5 kHz so phone speakers play them (the old ones were a 600 Hz
	# thump that phones couldn't reproduce at all).
	for i in 3:
		var p := 1.0 + i * 0.07
		_put("step_stone%d" % i, _wav(_seq([[_noise(0.09, 2600 * p, 0.0005, 0.016, 0.9, true), 0.0],
			[_tone(0.08, 170 * p, 110, "sine", 0.001, 0.02, 0.45), 0.0],
			[_noise(0.07, 4200 * p, 0.003, 0.02, 0.35, true), 0.018]])))
		_put("step_wood%d" % i, _wav(_seq([[_tone(0.12, 215 * p, 165, "tri", 0.001, 0.045, 0.55), 0.0],
			[_noise(0.09, 1500 * p, 0.001, 0.022, 0.7), 0.0],
			[_noise(0.05, 3200, 0.001, 0.01, 0.3, true), 0.004]])))
		_put("step_dirt%d" % i, _wav(_seq([[_noise(0.03, 3000 * p, 0.0005, 0.008, 0.55, true), 0.0],
			[_noise(0.03, 2400 * p, 0.0005, 0.008, 0.45, true), 0.014 + i * 0.004],
			[_noise(0.04, 2000 * p, 0.0005, 0.01, 0.4, true), 0.034],
			[_noise(0.1, 900, 0.002, 0.03, 0.55), 0.0]])))
	_put("land", _wav(_mix(_tone(0.22, 95, 50, "sine", 0.001, 0.07, 0.9), _noise(0.16, 1800, 0.001, 0.05, 0.8))))
	_put("grenade_bounce", _wav(_seq([[_tone(0.18, 2250, 2200, "sine", 0.0005, 0.045, 0.35), 0.0],
		[_tone(0.16, 3400, 3350, "sine", 0.0005, 0.03, 0.2), 0.0],
		[_noise(0.03, 5000, 0.0005, 0.006, 0.45, true), 0.0]])))
	_put("throw", _wav(_noise(0.3, 1600, 0.07, 0.07, 0.6, true)))
	_put("pin", _wav(_mix(_noise(0.03, 6000, 0.0005, 0.005, 0.5, true), _tone(0.06, 3100, 2900, "square", 0.0005, 0.012, 0.14))))
	_put("revive", _wav(_chord([392, 493.9, 587.3, 784], 1.2, "sine", 0.5, 0.2, 0.1)))
	_put("downed", _wav(_seq([[_tone(1.6, 220, 80, "saw", 0.01, 0.8, 0.25), 0.0], [_noise(1.0, 400, 0.01, 0.5, 0.4), 0.0]])))
	_put("cache", _wav(_chord([659.3, 784, 987.8, 1174.7, 1318.5, 1568, 1975.5], 2.0, "sine", 0.4, 0.16, 0.18)))
	# The Ember Forge reforging a gun (3.6 s, matching the forge's timer):
	# the bellows heave, the fire roars up, four hammer blows on the anvil,
	# the blade hisses in the quench, and a bright ring when it's done.
	var bellows := _band(0.9, func(t): return 300.0 + 500.0 * t, 1.2, func(t): return 1.2 * sin(PI * clampf(t / 0.9, 0.0, 1.0)))
	var roar := _band(3.8, func(t): return 160.0 + 120.0 * minf(t, 1.5), 0.8,
		func(t): return 0.9 * minf(t / 0.8, 1.0) * (0.75 + 0.25 * sin(t * 9.0)) * exp(-maxf(t - 3.2, 0.0) / 0.25))
	var anvil := [[935.0, 0.5, 0.35], [1612.0, 0.32, 0.22], [2473.0, 0.2, 0.15], [3712.0, 0.12, 0.08], [5310.0, 0.06, 0.05]]
	var hiss := _band(1.0, func(t): return 5200.0 - 2400.0 * t, 0.7, func(t): return 0.9 * exp(-t / 0.35))
	var bubbles := PackedFloat32Array()
	for k in 7:
		var f := _rng.randf_range(260, 620)
		bubbles = _mix(bubbles, _tone(0.07, f, f * 1.6, "sine", 0.002, 0.02, 0.25), _rng.randf_range(0.0, 0.6))
	var ring := _chord([1180, 1770, 2360], 1.0, "sine", 0.45, 0.22, 0.03)
	var forge := _seq([[bellows, 0.0, 0.9], [roar, 0.1, 0.8], [_crackle(3.6, 14.0, 0.5), 0.2],
		[_clang(0.6, anvil), 0.75], [_clang(0.6, anvil), 1.3, 0.9], [_clang(0.6, anvil), 1.85], [_clang(0.7, anvil), 2.4, 1.2],
		[hiss, 2.8], [bubbles, 2.9], [ring, 3.35]])
	_put("forge", _wav(_gain(forge, 1.1)))
	_put("forge_done", _wav(_seq([[_chord([1568, 2093, 2637], 1.2, "sine", 0.5, 0.2, 0.05), 0.0],
		[_band(0.4, func(t): return 900.0 + 3000.0 * t, 1.0, func(t): return 0.5 * sin(PI * clampf(t / 0.4, 0.0, 1.0))), 0.0]])))
	_put("drink", _wav(_seq([[_noise(0.15, 500, 0.01, 0.05, 0.6), 0.0], [_noise(0.15, 500, 0.01, 0.05, 0.6), 0.22], [_noise(0.15, 500, 0.01, 0.05, 0.6), 0.44], [_chord([587.3, 880], 0.8, "sine", 0.3, 0.2, 0.05), 0.7]])))
	# blast, sub-boom, then debris pattering down
	_put("explode", _wav(_gain(_seq([[_noise(2.0, 900, 0.002, 0.5, 1.2), 0.0], [_tone(1.5, 80, 30, "sine", 0.002, 0.4, 0.9), 0.0],
		[_noise(0.08, 6000, 0.0005, 0.015, 0.9, true), 0.0], [_crackle(1.4, 22.0, 0.35, 1800.0), 0.25]]), 1.2)))
	_put("ui_hover", _wav(_tone(0.04, 1800, 1700, "sine", 0.001, 0.012, 0.15)))
	_put("ui_click", _wav(_mix(_tone(0.08, 900, 600, "tri", 0.001, 0.025, 0.35), _noise(0.03, 5000, 0.001, 0.006, 0.3, true))))
	_put("spawn", _wav(_seq([[_noise(1.0, 250, 0.2, 0.3, 0.7), 0.0], [_noise(0.5, 1500, 0.01, 0.1, 0.25, true), 0.2]])))
	# --- ambience (loops) --------------------------------------------------
	# wind: gusts from slow, whole-cycle swells (so it loops), plus a thin whistle
	var wind := _band(12.6, func(t): return 260.0 + 220.0 * sin(TAU * t / 12.0) + 90.0 * sin(TAU * t * 3.0 / 12.0), 0.7,
		func(t): return 0.55 + 0.35 * sin(TAU * t / 6.0 + 1.0) * sin(TAU * t / 4.0))
	var whistle := _band(12.6, func(t): return 820.0 + 260.0 * sin(TAU * t * 2.0 / 12.0), 18.0,
		func(t): return 0.5 * maxf(sin(TAU * t / 6.0 + 2.5), 0.0))
	_put("amb_wind", _wav(_loopify(_gain(_mix(wind, whistle), 1.6), 0.6), true))
	# brazier fire: a soft roar and crackles
	var fire := _band(6.5, func(t): return 300.0 + 80.0 * sin(TAU * t / 2.0), 0.7, func(t): return 0.45 + 0.15 * sin(TAU * t / 1.5))
	_put("amb_fire", _wav(_loopify(_gain(_mix(fire, _crackle(6.5, 9.0, 0.7)), 1.3), 0.5), true))
	# ash vent: a breathy hiss over a low rumble, the odd ember pop
	var vent_hiss := _band(6.5, func(t): return 3400.0 + 900.0 * sin(TAU * t / 3.0), 0.9, func(t): return 0.35 + 0.15 * sin(TAU * t / 6.0))
	var rumble := _band(6.5, func(_t): return 90.0, 0.8, func(_t): return 0.9)
	_put("amb_vent", _wav(_loopify(_gain(_seq([[vent_hiss, 0.0], [rumble, 0.0], [_crackle(6.5, 2.0, 0.5, 3000.0), 0.0]]), 1.2), 0.5), true))
	# tonic machine: mains hum with a faint buzz (whole cycles: 2 s loop)
	var hum := PackedFloat32Array()
	hum.resize(int(2.0 * RATE))
	for i in hum.size():
		var t := float(i) / RATE
		hum[i] = 0.32 * sin(TAU * 60.0 * t) + 0.18 * sin(TAU * 120.0 * t) + 0.08 * sin(TAU * 180.0 * t) \
			+ 0.05 * signf(sin(TAU * 120.0 * t)) * (0.6 + 0.4 * sin(TAU * t))
	_put("amb_hum", _wav(hum, true))
	# heartbeat when hurt (lub-dub, 1.2 s)
	var beat := _seq([[_tone(0.18, 62, 48, "sine", 0.004, 0.06, 0.9), 0.0], [_tone(0.16, 58, 44, "sine", 0.004, 0.05, 0.7), 0.28]])
	beat.resize(int(1.2 * RATE))
	_put("heartbeat", _wav(beat, true))
	# distant sounds to scatter around the outpost now and then
	_put("creak", _wav(_band(0.9, func(t): return 420.0 + 160.0 * sin(t * 7.0) + 80.0 * sin(t * 31.0), 25.0,
		func(t): return 0.7 * sin(PI * clampf(t / 0.9, 0.0, 1.0)) * (0.5 + 0.5 * absf(sin(t * 53.0))))))
	_put("distant", _wav(_band(2.4, func(t): return 140.0 + 60.0 * sin(t * 2.3), 6.0, func(t): return 0.8 * sin(PI * clampf(t / 2.4, 0.0, 1.0)))))

	# --- small sounds ---------------------------------------------------
	_put("impact_stone", _wav(_seq([[_noise(0.06, 5000, 0.0003, 0.008, 0.9, true), 0.0], [_clang(0.12, [[3100, 0.12, 0.02], [4700, 0.08, 0.015]], 0.2), 0.002]])))
	_put("impact_wood", _wav(_seq([[_tone(0.1, 320, 260, "tri", 0.001, 0.03, 0.5), 0.0], [_noise(0.08, 1800, 0.0005, 0.015, 0.6), 0.0]])))
	_put("impact_dirt", _wav(_noise(0.1, 900, 0.001, 0.025, 0.8)))
	_put("casing", _wav(_seq([[_clang(0.1, [[3300, 0.3, 0.03], [5100, 0.15, 0.02]], 0.1), 0.0],
		[_clang(0.08, [[3350, 0.15, 0.025], [5150, 0.08, 0.015]], 0.05), 0.09]])))
	_put("swap", _wav(_seq([[_band(0.18, func(_t): return 1400.0, 1.2, func(t): return 0.6 * sin(PI * clampf(t / 0.18, 0.0, 1.0))), 0.0],
		[_clang(0.06, [[2400, 0.25, 0.012]], 0.3), 0.16]])))
	_put("menu_music", _wav(_drone(16.0, [55.0, 82.4, 110.0, 164.8], 0.5), true))
	_put("game_music", _wav(_drone(16.0, [41.2, 61.7, 82.4, 123.5, 155.6], 0.8), true))


## Dark ambient loop: detuned filtered saws with slow swells and a heartbeat.
func _drone(dur: float, notes: Array, pulse: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var count := notes.size()
	var ph_a := PackedFloat64Array()
	var ph_b := PackedFloat64Array()
	var inc_a := PackedFloat64Array()
	var inc_b := PackedFloat64Array()
	var sw := PackedFloat64Array()
	for f in notes:
		ph_a.append(0.0)
		ph_b.append(0.0)
		inc_a.append(f / RATE)
		inc_b.append(f * 1.004 / RATE)
		sw.append(0.0)
	var lp := 0.0
	var cutoff := 0.0
	for i in n:
		var t := float(i) / RATE
		if i % 32 == 0:
			# slow swells move at a control rate; loop-safe: whole cycles per loop
			for k in count:
				sw[k] = 0.5 + 0.5 * sin(TAU * t * (k + 1) / dur + k)
			cutoff = 0.02 + 0.03 * (0.5 + 0.5 * sin(TAU * t * 2.0 / dur))
		var s := 0.0
		for k in count:
			var pa := ph_a[k] + inc_a[k]
			if pa >= 1.0:
				pa -= 1.0
			ph_a[k] = pa
			var pb := ph_b[k] + inc_b[k]
			if pb >= 1.0:
				pb -= 1.0
			ph_b[k] = pb
			s += (pa + pb - 1.0) * 2.0 * sw[k] * 0.18
		lp += (s - lp) * cutoff
		var beat_t := fmod(t, 2.0)
		var beat := sin(TAU * 48.0 * beat_t) * exp(-beat_t / 0.09) * pulse
		if beat_t > 0.28:
			beat += sin(TAU * 44.0 * (beat_t - 0.28)) * exp(-(beat_t - 0.28) / 0.08) * pulse * 0.7
		out[i] = tanh(lp * 1.6 + beat * 0.5) * 0.7
	return out
