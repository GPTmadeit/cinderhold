extends Node
## Persistent player options, the input map and graphics presets.
##
## PATCH SAFETY: never add, remove, retype or reorder this autoload's member
## variables; installed copies keep the old layout when a patch swaps the
## script in. See scripts/tools/check_autoload_layout.py.

signal changed

const PATH := "user://settings.cfg"

const DEFAULTS := {
	"player": {"name": "", "color": 0},
	"gameplay": {"sensitivity": 1.0, "aim_sensitivity": 0.8, "invert_y": false, "fov": 80.0, "show_fps": false,
		"aim_assist": true, "touch_controls": "auto", "touch_look": 1.0},
	"video": {"fullscreen": false, "vsync": true, "quality": 2, "render_scale": 1.0, "max_fps": 0},
	"audio": {"master": 0.8, "sfx": 0.9, "music": 0.55},
	"net": {"last_ip": "127.0.0.1", "port": 47820, "upnp": true},
	"updates": {"token": "", "auto_check": true},
}

## action -> default key (or mouse button when prefixed with "mouse_").
const ACTIONS := {
	"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
	"jump": KEY_SPACE, "sprint": KEY_SHIFT, "crouch": KEY_C,
	"fire": "mouse_1", "aim": "mouse_2", "reload": KEY_R, "interact": KEY_E,
	"melee": KEY_V, "grenade": KEY_G, "next_weapon": "mouse_wheel_up", "prev_weapon": "mouse_wheel_down",
	"weapon_1": KEY_1, "weapon_2": KEY_2, "weapon_3": KEY_3,
	"scoreboard": KEY_TAB, "pause": KEY_ESCAPE,
}
const ACTION_LABELS := {
	"move_forward": "Move forward", "move_back": "Move back", "move_left": "Strafe left",
	"move_right": "Strafe right", "jump": "Jump", "sprint": "Sprint", "crouch": "Crouch",
	"fire": "Fire", "aim": "Aim down sights", "reload": "Reload", "interact": "Interact / revive",
	"melee": "Melee", "grenade": "Throw grenade", "next_weapon": "Next weapon", "prev_weapon": "Previous weapon",
	"weapon_1": "Weapon slot 1", "weapon_2": "Weapon slot 2", "weapon_3": "Weapon slot 3",
	"scoreboard": "Scoreboard", "pause": "Pause",
}
const PAD := {
	"jump": JOY_BUTTON_A, "reload": JOY_BUTTON_X, "interact": JOY_BUTTON_X, "melee": JOY_BUTTON_RIGHT_STICK,
	"sprint": JOY_BUTTON_LEFT_STICK, "crouch": JOY_BUTTON_B, "next_weapon": JOY_BUTTON_Y,
	"grenade": JOY_BUTTON_LEFT_SHOULDER,
	"scoreboard": JOY_BUTTON_BACK, "pause": JOY_BUTTON_START,
}

const PLAYER_COLORS := [Color("e8803a"), Color("4aa3df"), Color("7bc950"), Color("c95fd1")]
const QUALITY_NAMES := ["Low", "Medium", "High", "Ultra"]

var data := {}
var binds := {}


func setup() -> void:
	data = DEFAULTS.duplicate(true)
	var cfg := ConfigFile.new()
	var first_run := cfg.load(PATH) != OK
	if first_run:
		_auto_quality()
	else:
		for section in data:
			for key in data[section]:
				data[section][key] = cfg.get_value(section, key, data[section][key])
		for action in ACTIONS:
			if cfg.has_section_key("binds", action):
				binds[action] = cfg.get_value("binds", action)
	if str(data.player.name).strip_edges() == "":
		data.player.name = _default_name()
	_build_input_map()
	apply_video()
	apply_audio()


## First launch: pick a preset the GPU can actually run.
func _auto_quality() -> void:
	var gpu := RenderingServer.get_video_adapter_name().to_lower()
	var weak := OS.has_feature("mobile") or gpu.contains("llvmpipe") or gpu.contains("swiftshader") \
		or (gpu.contains("intel") and (gpu.contains("hd graphics") or gpu.contains("uhd graphics")))
	data.video.quality = 0 if weak else 2
	data.video.render_scale = 0.85 if weak else 1.0
	print("Cinderhold: first run on '%s', quality %s" % [gpu, QUALITY_NAMES[data.video.quality]])


func get_v(section: String, key: String):
	return data[section][key]


func set_v(section: String, key: String, value) -> void:
	data[section][key] = value
	if section == "video":
		apply_video()
	elif section == "audio":
		apply_audio()
	save()
	changed.emit()


func save() -> void:
	var cfg := ConfigFile.new()
	for section in data:
		for key in data[section]:
			cfg.set_value(section, key, data[section][key])
	for action in binds:
		cfg.set_value("binds", action, binds[action])
	cfg.save(PATH)


func player_name() -> String:
	return str(data.player.name).substr(0, 16)


## False during scripted dev runs (--shot / --fps-log) so a test window never grabs the mouse.
func can_capture_mouse() -> bool:
	var a := OS.get_cmdline_user_args()
	return not ("--shot" in a or "--fps-log" in a or "--bot" in a)


## A scripted bot or action list is driving the local player (dev tests).
func bot_driving() -> bool:
	var a := OS.get_cmdline_user_args()
	return "--bot" in a or "--act" in a


func use_touch() -> bool:
	match str(data.gameplay.touch_controls):
		"on": return true
		"off": return false
	return OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


# --- input ---------------------------------------------------------------

func _build_input_map() -> void:
	for action in ACTIONS:
		if InputMap.has_action(action):
			InputMap.erase_action(action)
		InputMap.add_action(action, 0.2)
		InputMap.action_add_event(action, _event_for(binds.get(action, ACTIONS[action])))
		if PAD.has(action):
			var jb := InputEventJoypadButton.new()
			jb.button_index = PAD[action]
			InputMap.action_add_event(action, jb)
	_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_axis("fire", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_axis("aim", JOY_AXIS_TRIGGER_LEFT, 1.0)


func _axis(action: String, axis: int, dir: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = dir
	InputMap.action_add_event(action, ev)


func _event_for(code) -> InputEvent:
	if code is String and code.begins_with("mouse_"):
		var mb := InputEventMouseButton.new()
		match code:
			"mouse_wheel_up": mb.button_index = MOUSE_BUTTON_WHEEL_UP
			"mouse_wheel_down": mb.button_index = MOUSE_BUTTON_WHEEL_DOWN
			_: mb.button_index = int(code.trim_prefix("mouse_"))
		return mb
	var k := InputEventKey.new()
	k.physical_keycode = int(code)
	return k


func rebind(action: String, event: InputEvent) -> void:
	if event is InputEventKey:
		binds[action] = int(event.physical_keycode if event.physical_keycode != 0 else event.keycode)
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: binds[action] = "mouse_wheel_up"
			MOUSE_BUTTON_WHEEL_DOWN: binds[action] = "mouse_wheel_down"
			_: binds[action] = "mouse_%d" % event.button_index
	else:
		return
	_build_input_map()
	save()
	changed.emit()


func reset_binds() -> void:
	binds.clear()
	_build_input_map()
	save()
	changed.emit()


func bind_label(action: String) -> String:
	var code = binds.get(action, ACTIONS[action])
	if code is String:
		match code:
			"mouse_1": return "LMB"
			"mouse_2": return "RMB"
			"mouse_3": return "MMB"
			"mouse_wheel_up": return "Wheel Up"
			"mouse_wheel_down": return "Wheel Down"
		return "Mouse " + code.trim_prefix("mouse_")
	return OS.get_keycode_string(int(code))


# --- video / audio -------------------------------------------------------

func apply_video() -> void:
	var v: Dictionary = data.video
	if not OS.has_feature("mobile"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if v.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if v.vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = int(v.max_fps)
	var vp := get_viewport()
	var q := quality()
	vp.scaling_3d_scale = clampf(float(v.render_scale), 0.5, 1.0)
	var fsr := vp.scaling_3d_scale < 0.99 and _forward_plus()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if fsr else Viewport.SCALING_3D_MODE_BILINEAR
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][q]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q == 1 else Viewport.SCREEN_SPACE_AA_DISABLED
	RenderingServer.directional_shadow_atlas_set_size([1024, 2048, 4096, 4096][q], true)
	vp.positional_shadow_atlas_size = [0, 2048, 4096, 4096][q]


func quality() -> int:
	return clampi(int(data.video.quality), 0, 3)


func _forward_plus() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"


## Tune a WorldEnvironment for the current quality preset.
func configure_environment(env: Environment) -> void:
	var q := quality()
	var fp := _forward_plus()
	env.glow_enabled = q >= 1
	env.ssao_enabled = q >= 2 and fp
	env.ssil_enabled = false
	env.volumetric_fog_enabled = q >= 3 and fp
	env.sdfgi_enabled = false
	env.fog_enabled = true


func apply_audio() -> void:
	var a: Dictionary = data.audio
	_bus("Master", float(a.master))
	_bus("SFX", float(a.sfx))
	_bus("Music", float(a.music))


func _bus(bus_name: String, vol: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		idx = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(vol, 0.0001)))
	AudioServer.set_bus_mute(idx, vol <= 0.001)


func _default_name() -> String:
	var who := OS.get_environment("USER")
	if who == "":
		who = OS.get_environment("USERNAME")
	if who == "":
		var picks := ["Ashwalker", "Emberguard", "Lanternkeeper", "Wardstone", "Cinderfox"]
		who = picks[randi() % picks.size()]
	return who.capitalize().substr(0, 16)
