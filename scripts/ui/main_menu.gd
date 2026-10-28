extends Node3D
## Title screen over a live view of the outpost, plus solo, host/join,
## lobby, settings and update flows.

const T := preload("res://scripts/ui/ui_theme.gd")
const ArenaScript := preload("res://scripts/world/arena.gd")
const SettingsPanel := preload("res://scripts/ui/settings_panel.gd")
const M := preload("res://scripts/voxel/models.gd")
const LoadingScreen := preload("res://scripts/ui/loading_screen.gd")

var _ui: Control
var _cam: Camera3D
var _t := 0.0
var _husks: Array = []
var _main: VBoxContainer
var _panels := {}
var _status: Label
var _roster: VBoxContainer
var _lobby_info: Label
var _start_btn: Button
var _ready_btn: Button
var _update_badge: Button
var _ip_edit: LineEdit


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var ls = LoadingScreen.open(get_tree(), "Lighting the braziers…")
	var arena := ArenaScript.new()
	add_child(arena)
	await arena.build(true, func(f, stage): ls.set_progress(f * 0.85, stage))
	_cam = Camera3D.new()
	_cam.fov = 62
	add_child(_cam)
	_cam.current = true
	_pose_husks()

	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.theme = T.get_theme()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_ui)
	var shade := TextureRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.texture = _side_gradient()
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(shade)

	_build_main()
	_build_join()
	_build_lobby()
	_build_settings()
	_build_footer()

	Net.roster_changed.connect(_refresh_lobby)
	Net.connected.connect(func(): _status.text = ""; _show("lobby"))
	Net.connection_failed.connect(_on_net_error)
	Net.disconnected.connect(_on_net_error)
	Net.game_starting.connect(func(): LoadingScreen.open(get_tree(), "Preparing the outpost…"))
	Updater.state_changed.connect(_refresh_badge)
	_refresh_badge()

	while not Sfx.is_ready():   # first launch: sounds are still being synthesised
		ls.set_progress(0.85 + 0.14 * Sfx.progress(), "Tuning the bells…")
		await get_tree().process_frame
	ls.close()
	Sfx.music("menu_music")

	if Net.last_message != "":
		_show("main")
		_toast(Net.last_message)
		Net.last_message = ""
	elif not Net.solo and not Net.players.is_empty():
		_show("lobby")       # came back from a match
	else:
		_show("main")


func _side_gradient() -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, Color(0.02, 0.01, 0.015, 0.92))
	g.set_color(1, Color(0.02, 0.01, 0.015, 0.0))
	g.add_point(0.45, Color(0.02, 0.01, 0.015, 0.55))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill_from = Vector2(0, 0)
	t.fill_to = Vector2(1, 0)
	return t


func _pose_husks() -> void:
	var spots := [Vector3(14.5, 0, 24.2), Vector3(15.2, 0, 19.8), Vector3(8.6, 0, 25.5), Vector3(9.6, 0, 16.5)]
	for i in spots.size():
		var root := Node3D.new()
		root.position = spots[i]
		root.rotation.y = randf() * TAU
		var parts: Dictionary = M.husk("runner" if i == 2 else "husk", i)
		var pivots := {}
		for pname in parts:
			var pv := Node3D.new()
			pv.position = parts[pname].joint
			var mi := MeshInstance3D.new()
			mi.mesh = parts[pname].mesh
			pv.add_child(mi)
			root.add_child(pv)
			pivots[pname] = pv
		add_child(root)
		_husks.append({"root": root, "parts": pivots, "phase": randf() * TAU, "speed": randf_range(0.25, 0.45)})


func _process(dt: float) -> void:
	if _cam == null:
		return   # still loading
	_t += dt
	var c := Vector3(11.5, 0.0, 21.0)
	var a := _t * 0.05 + 0.6
	_cam.position = c + Vector3(cos(a) * 8.0, 2.6 + sin(_t * 0.2) * 0.3, sin(a) * 5.5)
	_cam.look_at(c + Vector3(0, 1.0, 0))
	for h in _husks:
		h.phase += dt * 2.4
		var root: Node3D = h.root
		var fwd := -root.global_basis.z
		root.position += fwd * h.speed * dt
		if root.position.distance_to(c) > 5.0:
			root.rotation.y = lerp_angle(root.rotation.y, atan2(-(c - root.position).x, -(c - root.position).z), dt)
		var s := sin(h.phase)
		h.parts.leg_l.rotation.x = s * 0.45
		h.parts.leg_r.rotation.x = -s * 0.45
		h.parts.arm_l.rotation.x = -1.3 + sin(h.phase * 0.5) * 0.1
		h.parts.arm_r.rotation.x = -1.2 + sin(h.phase * 0.5 + 1.0) * 0.1
		h.parts.torso.rotation.x = -0.15
		h.parts.head.rotation.z = sin(h.phase * 0.3) * 0.2


# --- panels ----------------------------------------------------------------

func _panel(name_: String, center := false) -> Control:
	var holder := MarginContainer.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if center:
		var cc := CenterContainer.new()
		cc.set_anchors_preset(Control.PRESET_FULL_RECT)
		holder.add_child(cc)
	else:
		holder.add_theme_constant_override("margin_left", 90)
		holder.add_theme_constant_override("margin_top", 70)
	_ui.add_child(holder)
	_panels[name_] = holder
	return holder.get_child(0) if center else holder


func _show(which: String) -> void:
	for k in _panels:
		_panels[k].visible = k == which
	if which == "lobby":
		_refresh_lobby()


func _build_main() -> void:
	var holder := _panel("main")
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 12)
	_main.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_main.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	holder.add_child(_main)
	var t := T.title("CINDERHOLD", 96)
	_main.add_child(t)
	_main.add_child(T.label("HOLD THE LINE UNTIL DAWN", 26, T.EMBER_SOFT, true))
	var gap := Control.new()
	gap.custom_minimum_size.y = 36
	_main.add_child(gap)
	_main.add_child(T.button("Play Solo", _play_solo))
	_main.add_child(T.button("Host Co-op", _host))
	_main.add_child(T.button("Join Co-op", func(): _show("join")))
	_main.add_child(T.button("Settings", func(): _show("settings")))
	_update_badge = T.button("Updates", func():
		_show("settings")
		_panels.settings.get_child(0).get_child(0).open_updates())
	_main.add_child(_update_badge)
	if not OS.has_feature("web"):
		_main.add_child(T.button("Quit", func(): get_tree().quit()))
	_status = T.label("", 22, Color("ff9a8a"), true)
	_main.add_child(_status)


func _build_join() -> void:
	var box := _panel("join", true)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(620, 0)
	box.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(T.title("JOIN A HOLD", 40))
	v.add_child(T.label("Enter the host's address (LAN, ZeroTier or Tailscale IP).", 19, T.MUTED))
	_ip_edit = LineEdit.new()
	_ip_edit.text = str(Settings.get_v("net", "last_ip"))
	_ip_edit.placeholder_text = "192.168.1.20"
	_ip_edit.custom_minimum_size.y = 50
	_ip_edit.text_submitted.connect(func(_t): _join())
	v.add_child(_ip_edit)
	v.add_child(T.label("Port %d (UDP)" % Net.port(), 18, T.MUTED))
	var row := HBoxContainer.new()
	row.add_child(T.button("Connect", _join, 200))
	row.add_child(T.button("Back", func(): _show("main"), 160))
	v.add_child(row)


func _build_lobby() -> void:
	var box := _panel("lobby", true)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(760, 0)
	box.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(T.title("LOBBY", 44))
	_lobby_info = T.label("", 19, T.MUTED)
	_lobby_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_lobby_info)
	_roster = VBoxContainer.new()
	_roster.custom_minimum_size.y = 230
	v.add_child(_roster)
	var row := HBoxContainer.new()
	_start_btn = T.button("Start the Night", func(): Net.start_game(), 260)
	_ready_btn = T.button("Ready", func():
		var me: Dictionary = Net.players.get(Net.me(), {})
		Net.set_ready(not me.get("ready", false)), 200)
	row.add_child(_start_btn)
	row.add_child(_ready_btn)
	row.add_child(T.button("Leave", func():
		Net.leave()
		_show("main"), 160))
	v.add_child(row)


func _build_settings() -> void:
	var box := _panel("settings", true)
	var sp := SettingsPanel.new()
	sp.closed.connect(func(): _show("main"))
	box.add_child(sp)


func _build_footer() -> void:
	var f := T.label("v%s  ·  port %d" % [Updater.current_version(), Net.port()], 18, Color(1, 1, 1, 0.35))
	f.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	f.position = Vector2(24, -40)
	f.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ui.add_child(f)


# --- actions ---------------------------------------------------------------

func _play_solo() -> void:
	Net.start_solo()
	LoadingScreen.open(get_tree(), "Preparing the outpost…")
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _host() -> void:
	var err := Net.host()
	if err != OK:
		_toast("Couldn't host on port %d (%s). Is another copy running?" % [Net.port(), error_string(err)])
		return
	_show("lobby")


func _join() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		return
	Settings.set_v("net", "last_ip", ip)
	var err := Net.join(ip)
	if err != OK:
		_toast("Couldn't start connecting (%s)." % error_string(err))
		return
	_show("main")
	_toast("Connecting to %s…" % ip, T.EMBER_SOFT)


func _on_net_error(reason: String) -> void:
	_show("main")
	_toast(reason)


func _toast(text: String, color := Color("ff9a8a")) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _refresh_lobby() -> void:
	if _roster == null:
		return
	for c in _roster.get_children():
		c.queue_free()
	var ids := Net.players.keys()
	ids.sort()
	for id in ids:
		var p: Dictionary = Net.players[id]
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.04), Settings.PLAYER_COLORS[int(p.color) % 4], 0, 4, 12))
		var h := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = Settings.PLAYER_COLORS[int(p.color) % 4]
		sw.custom_minimum_size = Vector2(10, 30)
		h.add_child(sw)
		var n := T.label(str(p.name) + ("  (host)" if id == 1 else "") + ("  (you)" if id == Net.me() else ""), 24, T.TEXT, true)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(n)
		var ready_txt := "HOST" if id == 1 else ("READY" if p.ready else "not ready")
		h.add_child(T.label(ready_txt, 20, Color("9fe07a") if (p.ready or id == 1) else T.MUTED, true))
		row.add_child(h)
		_roster.add_child(row)
	var host := Net.is_host()
	_start_btn.visible = host
	_start_btn.disabled = not Net.everyone_ready()
	_start_btn.text = "Start the Night" if Net.everyone_ready() else "Waiting for ready…"
	_ready_btn.visible = not host
	var me: Dictionary = Net.players.get(Net.me(), {})
	_ready_btn.text = "Not ready" if me.get("ready", false) else "Ready"
	if host:
		var addrs := Net.local_addresses()
		_lobby_info.text = "Friends join with one of: %s  (UDP port %d)\n%d / %d survivors" % [", ".join(addrs), Net.port(), Net.players.size(), Net.MAX_PLAYERS]
	else:
		_lobby_info.text = "Connected. Waiting for the host to start. %d / %d survivors" % [Net.players.size(), Net.MAX_PLAYERS]


func _refresh_badge() -> void:
	if _update_badge == null:
		return
	match Updater.state:
		Updater.State.AVAILABLE:
			_update_badge.text = "Update available: v%s" % Updater.latest_version
			_update_badge.add_theme_color_override("font_color", Color("9fe07a"))
		Updater.State.READY:
			_update_badge.text = "Restart to play v%s" % Updater.latest_version
			_update_badge.add_theme_color_override("font_color", Color("9fe07a"))
		Updater.State.DOWNLOADING:
			_update_badge.text = "Downloading update…"
		Updater.State.FULL_REQUIRED:
			_update_badge.text = "New version: full download needed"
			_update_badge.add_theme_color_override("font_color", T.EMBER_SOFT)
		_:
			_update_badge.text = "Updates"
			_update_badge.remove_theme_color_override("font_color")
