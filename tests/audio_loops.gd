extends Node
## Every looping sound must loop on a sample that exists: Godot plays the
## sample at loop_end, and reading past the data crashes Android (0.1.0-0.1.4
## died at the music's first loop point). Exits with 1 on a bad stream.

func _ready() -> void:
	var synth: Node = load("res://scripts/core/sfx_synth.gd").new()
	synth._generate()
	var bad := 0
	var loops := 0
	for sound in synth._pending:
		var w: AudioStreamWAV = synth._pending[sound]
		var frames := w.data.size() / (2 if w.format == AudioStreamWAV.FORMAT_16_BITS else 1) / (2 if w.stereo else 1)
		if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			continue
		loops += 1
		if w.loop_begin < 0 or w.loop_begin >= w.loop_end or w.loop_end > frames - 1:
			printerr("%s: loop %d..%d but only %d frames" % [sound, w.loop_begin, w.loop_end, frames])
			bad += 1
	synth.free()
	print("audio loops: %d looping streams checked, %d bad" % [loops, bad])
	get_tree().quit(1 if bad > 0 or loops == 0 else 0)
