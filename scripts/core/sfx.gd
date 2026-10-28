extends Node
## Procedurally synthesised sound effects and music. Nothing is loaded from
## disk: every sound is generated once in setup().

const RATE := 22050
const POOL_3D := 24
const POOL_2D := 10

var streams := {}
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _i3 := 0
var _i2 := 0
var _music: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func setup() -> void:
	_rng.seed = 1337
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.unit_size = 6.0
		p.max_distance = 60.0
		p.attenuation_filter_cutoff_hz = 6000.0
		add_child(p)
		_pool3d.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool2d.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	add_child(_music)
	_generate()


func play(sound: String, vol_db := 0.0, pitch_var := 0.04) -> void:
	if not streams.has(sound):
		return
	var p := _pool2d[_i2]
	_i2 = (_i2 + 1) % POOL_2D
	p.stream = streams[sound]
	p.volume_db = vol_db
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.play()


func play_at(sound: String, pos: Vector3, vol_db := 0.0, pitch_var := 0.06) -> void:
	if not streams.has(sound):
		return
	var p := _pool3d[_i3]
	_i3 = (_i3 + 1) % POOL_3D
	p.stream = streams[sound]
	p.global_position = pos
	p.volume_db = vol_db
	p.pitch_scale = 1.0 + randf_range(-pitch_var, pitch_var)
	p.play()


func music(track: String) -> void:
	if track == "":
		_music.stop()
		return
	if _music.stream == streams.get(track) and _music.playing:
		return
	_music.stream = streams.get(track)
	_music.volume_db = -4.0
	_music.play()


# --- synthesis ------------------------------------------------------------

func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
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


func _generate() -> void:
	streams.pistol = _wav(_shot(0.45, 7000, 0.05, 140, 0.25))
	streams.smg = _wav(_shot(0.3, 9000, 0.035, 170, 0.2, 0.75))
	streams.rifle = _wav(_shot(0.6, 6000, 0.06, 105, 0.35))
	streams.shotgun = _wav(_shot(0.9, 4200, 0.11, 70, 0.6, 1.1))
	streams.lmg = _wav(_shot(0.55, 5200, 0.06, 90, 0.35, 0.95))
	streams.sniper = _wav(_shot(1.3, 5000, 0.12, 60, 0.7, 1.2))
	var zap := _tone(0.5, 1800, 220, "saw", 0.002, 0.12, 0.35)
	streams.bolt = _wav(_mix(zap, _noise(0.5, 9000, 0.001, 0.1, 0.4, true)))
	streams.empty = _wav(_noise(0.05, 8000, 0.0005, 0.008, 0.5, true))
	streams.mag_out = _wav(_seq([[_noise(0.08, 3000, 0.001, 0.02, 0.6, true), 0.0], [_tone(0.1, 900, 700, "square", 0.001, 0.015, 0.15), 0.01]]))
	streams.mag_in = _wav(_seq([[_noise(0.1, 2500, 0.001, 0.025, 0.8, true), 0.0], [_tone(0.08, 1300, 1100, "square", 0.001, 0.01, 0.2), 0.02], [_noise(0.06, 5000, 0.001, 0.01, 0.5, true), 0.09]]))
	streams.rack = _wav(_seq([[_noise(0.1, 2000, 0.001, 0.03, 0.8, true), 0.0], [_noise(0.12, 2600, 0.001, 0.03, 0.9, true), 0.14]]))
	streams.hit = _wav(_tone(0.06, 2400, 2000, "tri", 0.001, 0.02, 0.5))
	streams.headshot = _wav(_mix(_tone(0.25, 3200, 3100, "sine", 0.001, 0.07, 0.45), _tone(0.25, 4800, 4800, "sine", 0.001, 0.05, 0.2)))
	streams.flesh = _wav(_noise(0.12, 900, 0.001, 0.04, 0.9))
	streams.melee = _wav(_noise(0.25, 1800, 0.03, 0.06, 0.6, true))
	streams.melee_hit = _wav(_mix(_noise(0.2, 700, 0.001, 0.05, 1.0), _tone(0.2, 120, 60, "sine", 0.001, 0.05, 0.6)))
	for i in 4:
		streams["groan%d" % i] = _wav(_groan(_rng.randf_range(0.8, 1.6), _rng.randf_range(70, 120), 0.35))
	streams.husk_attack = _wav(_groan(0.5, 140, 0.6, 0.8))
	streams.husk_die = _wav(_mix(_groan(0.9, 90, 0.5, 0.7), _noise(0.4, 600, 0.01, 0.15, 0.4)))
	streams.brute_roar = _wav(_groan(1.8, 45, 0.7, 0.95))
	streams.hurt = _wav(_mix(_noise(0.3, 500, 0.001, 0.08, 0.9), _tone(0.3, 180, 90, "sine", 0.001, 0.08, 0.5)))
	streams.buy = _wav(_chord([880, 1318.5], 0.5, "tri", 0.25, 0.22, 0.07))
	streams.deny = _wav(_tone(0.3, 160, 140, "square", 0.002, 0.12, 0.18))
	streams.door = _wav(_seq([[_noise(1.6, 300, 0.05, 0.6, 0.9), 0.0], [_tone(1.4, 55, 40, "saw", 0.05, 0.5, 0.3), 0.0], [_noise(0.3, 2000, 0.001, 0.08, 0.5, true), 0.9]]))
	streams.round_start = _wav(_seq([[_tone(2.8, 98, 96, "saw", 0.3, 1.2, 0.25), 0.0], [_tone(2.8, 147, 146, "saw", 0.3, 1.2, 0.18), 0.0], [_tone(2.4, 196, 190, "tri", 0.2, 0.9, 0.2), 0.5], [_noise(2.5, 200, 0.4, 1.0, 0.4), 0.0]]))
	streams.round_end = _wav(_seq([[_chord([220, 277.2, 329.6], 2.5, "tri", 1.0, 0.18, 0.12), 0.0], [_chord([246.9, 329.6, 392], 2.5, "tri", 1.2, 0.16, 0.12), 0.7]]))
	streams.powerup_spawn = _wav(_seq([[_tone(0.6, 600, 1200, "sine", 0.01, 0.3, 0.3), 0.0], [_tone(0.6, 900, 1800, "sine", 0.01, 0.3, 0.2), 0.08]]))
	streams.powerup = _wav(_chord([523.3, 659.3, 784, 1046.5], 0.9, "tri", 0.35, 0.22, 0.06))
	streams.step0 = _wav(_noise(0.12, 600, 0.002, 0.03, 0.35))
	streams.step1 = _wav(_noise(0.12, 750, 0.002, 0.028, 0.35))
	streams.revive = _wav(_chord([392, 493.9, 587.3, 784], 1.2, "sine", 0.5, 0.2, 0.1))
	streams.downed = _wav(_seq([[_tone(1.6, 220, 80, "saw", 0.01, 0.8, 0.25), 0.0], [_noise(1.0, 400, 0.01, 0.5, 0.4), 0.0]]))
	streams.cache = _wav(_chord([659.3, 784, 987.8, 1174.7, 1318.5, 1568, 1975.5], 2.0, "sine", 0.4, 0.16, 0.18))
	streams.forge = _wav(_seq([[_tone(1.5, 1180, 1170, "sine", 0.001, 0.5, 0.35), 0.0], [_tone(1.5, 1770, 1760, "sine", 0.001, 0.35, 0.18), 0.0], [_noise(0.2, 3000, 0.001, 0.03, 0.8, true), 0.0], [_noise(1.2, 400, 0.05, 0.4, 0.5), 0.1]]))
	streams.drink = _wav(_seq([[_noise(0.15, 500, 0.01, 0.05, 0.6), 0.0], [_noise(0.15, 500, 0.01, 0.05, 0.6), 0.22], [_noise(0.15, 500, 0.01, 0.05, 0.6), 0.44], [_chord([587.3, 880], 0.8, "sine", 0.3, 0.2, 0.05), 0.7]]))
	streams.explode = _wav(_seq([[_noise(2.0, 900, 0.002, 0.5, 1.2), 0.0], [_tone(1.5, 80, 30, "sine", 0.002, 0.4, 0.9), 0.0]]))
	streams.ui_hover = _wav(_tone(0.04, 1800, 1700, "sine", 0.001, 0.012, 0.15))
	streams.ui_click = _wav(_mix(_tone(0.08, 900, 600, "tri", 0.001, 0.025, 0.35), _noise(0.03, 5000, 0.001, 0.006, 0.3, true)))
	streams.spawn = _wav(_seq([[_noise(1.0, 250, 0.2, 0.3, 0.7), 0.0], [_noise(0.5, 1500, 0.01, 0.1, 0.25, true), 0.2]]))
	streams.menu_music = _wav(_drone(16.0, [55.0, 82.4, 110.0, 164.8], 0.5), true)
	streams.game_music = _wav(_drone(16.0, [41.2, 61.7, 82.4, 123.5, 155.6], 0.8), true)


## Dark ambient loop: detuned filtered saws with slow swells and a heartbeat.
func _drone(dur: float, notes: Array, pulse: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phases := []
	for f in notes:
		phases.append([0.0, 0.0])
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		var s := 0.0
		for k in notes.size():
			var f: float = notes[k]
			# Loop-safe LFO: whole cycles over the loop length.
			var sw := 0.5 + 0.5 * sin(TAU * t * (k + 1) / dur + k)
			phases[k][0] = fmod(phases[k][0] + f / RATE, 1.0)
			phases[k][1] = fmod(phases[k][1] + f * 1.004 / RATE, 1.0)
			s += ((phases[k][0] * 2.0 - 1.0) + (phases[k][1] * 2.0 - 1.0)) * sw * 0.18
		var cutoff := 0.02 + 0.03 * (0.5 + 0.5 * sin(TAU * t * 2.0 / dur))
		lp += (s - lp) * cutoff
		var beat_t := fmod(t, 2.0)
		var beat := sin(TAU * 48.0 * beat_t) * exp(-beat_t / 0.09) * pulse
		beat += sin(TAU * 44.0 * maxf(beat_t - 0.28, 0.0)) * exp(-maxf(beat_t - 0.28, 0.0) / 0.08) * pulse * 0.7 * float(beat_t > 0.28)
		var edge := minf(minf(t, dur - t) / 0.05, 1.0)
		out[i] = tanh(lp * 1.6 + beat * 0.5) * 0.7 * lerpf(1.0, edge, 0.0)
	return out
