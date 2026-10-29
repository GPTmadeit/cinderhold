extends Node
func _ready() -> void:
	var t := Time.get_ticks_msec()
	Settings.setup()
	print("settings ", Time.get_ticks_msec() - t, " ms"); t = Time.get_ticks_msec()
	Sfx.setup()
	print("sfx synth ", Time.get_ticks_msec() - t, " ms"); t = Time.get_ticks_msec()
	var a = preload("res://scripts/world/arena.gd").new()
	add_child(a)
	await a.build(true)
	print("arena build ", Time.get_ticks_msec() - t, " ms"); t = Time.get_ticks_msec()
	var M = preload("res://scripts/voxel/models.gd")
	for v in 5:
		M.husk("husk", v); M.husk("runner", v)
	M.brute()
	for c in 4: M.survivor(c)
	for id in preload("res://scripts/game/weapons.gd").DEFS:
		M.gun(id); M.gun(id, true)
	print("model warm-up ", Time.get_ticks_msec() - t, " ms")
	get_tree().quit()
