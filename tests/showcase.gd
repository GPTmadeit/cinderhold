extends Node3D
## Model review scene: every character, weapon and machine side by side.
const M := preload("res://scripts/voxel/models.gd")

func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("1b1720")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("6a6f8a")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.glow_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 200, 0)
	key.light_energy = 1.3
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-2, 2, 3)
	fill.light_color = Color("ff9a5a")
	fill.omni_range = 10
	add_child(fill)
	var x := -4.2
	for spec in [["husk", 0], ["husk", 2], ["runner", 1], ["brute", 0], ["survivor", 1]]:
		var parts: Dictionary
		match spec[0]:
			"brute": parts = M.brute()
			"survivor": parts = M.survivor(spec[1])
			_: parts = M.husk(spec[0], spec[1])
		var root := Node3D.new()
		root.position = Vector3(x, 0, 0)
		root.rotation.y = -0.35
		var pv := M.instance_rig(parts, root)
		if spec[0] != "survivor":
			pv.arm_l.rotation.x = 1.3     # reaching forward
			pv.arm_r.rotation.x = 1.2
			pv.fore_l.rotation.x = 0.3
		add_child(root)
		x += 2.0 if spec[0] != "brute" else 2.4
	var gx := -3.6
	for g in ["tinder", "kestrel", "warden", "breacher", "maul", "longshot", "cinderbolt"]:
		var mi := MeshInstance3D.new()
		mi.mesh = M.gun(g, g == "warden")
		mi.position = Vector3(gx, 3.6, 0.5)
		mi.rotation.y = PI * 0.5
		mi.scale = Vector3.ONE * 1.6
		add_child(mi)
		gx += 1.25
	var tm := MeshInstance3D.new()
	tm.mesh = M.tonic_machine(Color("d0453a"))
	tm.position = Vector3(6.6, 0, -1.0)
	tm.rotation.y = -0.5
	add_child(tm)
	var cam := Camera3D.new()
	cam.position = Vector3(1.2, 2.4, -9.0)
	cam.fov = 58
	add_child(cam)
	cam.look_at(Vector3(1.2, 1.9, 0))
	cam.current = true
	add_child(load("res://scripts/core/dev_tools.gd").new())
