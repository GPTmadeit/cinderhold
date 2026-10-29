extends Node3D
## Animation review: survivors and enemies in every pose, side by side.
## `godot --path . res://tests/anim_gallery.tscn -- --shot out.png 3`
const M := preload("res://scripts/voxel/models.gd")
const A := preload("res://scripts/game/rig_anim.gd")

var _rigs: Array = []   # [kind, parts, body, state]
var _t := 0.0


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("1b1720")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("7a7f9a")
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40, 200, 0)
	key.light_energy = 1.2
	add_child(key)
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 12)
	floor_mi.mesh = pm
	floor_mi.position = Vector3(0, 0, 2)
	add_child(floor_mi)
	var survivor_states := [
		{"label": "walk", "speed": 4.6}, {"label": "sprint", "speed": 6.9, "sprint": true},
		{"label": "aim up", "speed": 0.0, "pitch": 0.5, "aim": true}, {"label": "crouch", "speed": 2.0, "crouch": true},
		{"label": "reload", "speed": 0.0, "reload": true}, {"label": "melee", "speed": 0.0, "melee": 0.45},
		{"label": "throw", "speed": 0.0, "throw": 0.55}, {"label": "jump", "speed": 3.0, "air": true},
		{"label": "downed", "speed": 0.0, "down": true},
	]
	var x := -9.0
	for st in survivor_states:
		_add("survivor", M.survivor(1), Vector3(x, 0, 0), st)
		x += 2.0
	var enemy_states := [
		["husk", {"label": "shamble", "speed": 1.6}], ["husk", {"label": "attack wind-up", "speed": 0.0, "attack": 0.6}],
		["husk", {"label": "attack strike", "speed": 0.0, "attack": 0.95}], ["husk", {"label": "rise", "speed": 0.0, "rise": 0.7}],
		["runner", {"label": "run", "speed": 5.0}], ["brute", {"label": "stomp", "speed": 2.2}],
		["brute", {"label": "slam", "speed": 0.0, "attack": 0.92}],
	]
	x = -7.0
	for e in enemy_states:
		var parts: Dictionary = M.brute() if e[0] == "brute" else M.husk(e[0], 1)
		_add(e[0], parts, Vector3(x, 0, 4.5), e[1])
		x += 2.3 if e[0] != "brute" else 2.8
	# `-- --row 1` frames the enemies, otherwise the survivors
	var row := 1 if "--row" in OS.get_cmdline_user_args() else 0
	var cam := Camera3D.new()
	cam.position = Vector3(-0.6, 2.2, -7.0 + row * 4.5)
	cam.fov = 75
	add_child(cam)
	cam.look_at(Vector3(-0.2, 1.0, row * 4.5))
	cam.current = true
	for r in _rigs:
		r[2].get_parent().visible = (r[0] == "survivor") == (row == 0)
	# `-- --only <label>`: one pose, close up
	var args := OS.get_cmdline_user_args()
	var only := args.find("--only")
	if only != -1 and only + 1 < args.size():
		for r in _rigs:
			var root: Node3D = r[2].get_parent()
			root.visible = r[3].label == args[only + 1]
			if root.visible:
				cam.position = root.position + Vector3(1.6, 1.6, -2.6)
				cam.look_at(root.position + Vector3(0, 0.6, 0))
	add_child(load("res://scripts/core/dev_tools.gd").new())


func _add(kind: String, parts: Dictionary, pos: Vector3, st: Dictionary) -> void:
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = -0.6      # three-quarter view towards the camera
	add_child(root)
	var body := Node3D.new()
	root.add_child(body)
	var pivots := M.instance_rig(parts, body)
	var label := Label3D.new()
	label.text = st.label
	label.position = Vector3(0, 2.4 if kind != "brute" else 3.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.006
	root.add_child(label)
	_rigs.append([kind, pivots, body, st])


func _process(dt: float) -> void:
	_t += dt
	for r in _rigs:
		var st: Dictionary = r[3]
		var spd: float = st.get("speed", 0.0)
		if r[0] == "survivor":
			A.survivor_pose(r[1], r[2], {"phase": _t * (1.2 + spd * 2.9), "speed": spd, "pitch": st.get("pitch", 0.0),
				"sprint": st.get("sprint", false), "crouch": st.get("crouch", false), "down": st.get("down", false),
				"aim": st.get("aim", false), "reload": st.get("reload", false), "air": st.get("air", false),
				"kick": 0.0, "melee": st.get("melee", 0.0), "throw": st.get("throw", 0.0)}, dt)
		else:
			var h := 2.7 if r[0] == "brute" else 1.85
			A.enemy_pose(r[1], r[2], r[0], h, {"phase": _t * (0.8 + spd * 2.9), "t": _t, "speed": spd,
				"rise": st.get("rise", 1.0), "attack": st.get("attack", -1.0), "flinch": 0.0}, dt)
