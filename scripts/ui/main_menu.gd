extends Node3D
## Title screen over a live view of the outpost, plus solo, host/join,
## lobby, settings and update flows.

const T := preload("res://scripts/ui/ui_theme.gd")
const ArenaScript := preload("res://scripts/world/arena.gd")
const SettingsPanel := preload("res://scripts/ui/settings_panel.gd")
const M := preload("res://scripts/voxel/models.gd")
const A := preload("res://scripts/game/rig_anim.gd")
const Identity := preload("res://scripts/core/identity.gd")
const Friends := preload("res://scripts/core/friends.gd")
const LoadingScreen := preload("res://scripts/ui/loading_screen.gd")
const Diagnostics := preload("res://scripts/core/diagnostics.gd")

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
var _friends_list: VBoxContainer
var _friend_edit: LineEdit
var _my_code: Label
var _copy_addr: Button
var _invites: HFlowContainer
var _map_btns: Array[Button] = []
var _map_notes: Array[Label] = []


func _ready() -> void:
	Diagnostics.ensure(get_tree())
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
	_build_friends()
	_build_lobby()
	_build_settings()
	_build_footer()

	Net.roster_changed.connect(_refresh_lobby)
	var pr := Net.presence()
	if pr:
		pr.changed.connect(func():
			if _panels.friends.visible:
				_refresh_friends()
			elif _panels.lobby.visible:
				_refresh_lobby())
	Net.connected.connect(func(): _status.text = ""; _show("lobby"))
	Net.connection_failed.connect(_on_net_error)
	Net.disconnected.connect(_on_net_error)
	Net.game_starting.connect(func(): LoadingScreen.open(get_tree(), "Preparing %s…" % ArenaScript.map_title(Net.match_map())))
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
	_crash_notice()


## After a crash, offer the report the diagnostics kept.
func _crash_notice() -> void:
	var d := Diagnostics.ensure(get_tree())
	if not d.crashed:
		return
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(0.12, 0.05, 0.04, 0.92), Color("ff9a6a"), 1, 6, 14))
	p.custom_minimum_size.x = 560
	p.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)   # grows up and left from the corner
	p.offset_right = -28
	p.offset_bottom = -28
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var v := VBoxContainer.new()
	p.add_child(v)
	var what := T.label("Cinderhold closed unexpectedly last time (%s)." % d.summary, 19, T.TEXT)
	what.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(what)
	var hint := T.label("Copy the crash report and send it along so it can be fixed.", 17, T.MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)
	var row := HBoxContainer.new()
	row.add_child(T.button("Copy report", func():
		DisplayServer.clipboard_set(d.report())
		hint.text = "Report copied. Paste it into a message.", 220))
	row.add_child(T.button("Dismiss", func():
		d.dismiss()
		p.queue_free(), 160))
	v.add_child(row)
	_ui.add_child(p)


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
		var model := Node3D.new()
		root.add_child(model)
		var pivots := M.instance_rig(M.husk("runner" if i == 2 else "husk", i), model)
		add_child(root)
		_husks.append({"root": root, "model": model, "parts": pivots, "phase": randf() * TAU, "speed": randf_range(0.25, 0.45)})


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
		A.enemy_pose(h.parts, h.model, "husk", 1.85, {"phase": h.phase, "t": _t + float(h.speed) * 10.0,
			"speed": h.speed * 2.0, "rise": 1.0, "attack": -1.0, "flinch": 0.0}, dt)


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
	elif which == "friends":
		_refresh_friends()
	elif which == "main":
		_refresh_maps()


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
	# solo, and which map (the picker's credit line hangs below the row)
	var solo_row := HBoxContainer.new()
	solo_row.add_theme_constant_override("separation", 10)
	var solo_btn := T.button("Play Solo", _play_solo, 250)
	solo_btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	solo_row.add_child(solo_btn)
	var picker := _map_button()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	solo_row.add_child(picker)
	_main.add_child(solo_row)
	_main.add_child(T.button("Host Co-op", _host))
	_main.add_child(T.button("Join Co-op", func(): _show("join")))
	_main.add_child(T.button("Friends", func(): _show("friends")))
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
	v.add_child(T.label("Enter the host's address: their internet address from the lobby (like 203.0.113.7:47820), or a LAN, ZeroTier or Tailscale IP.", 19, T.MUTED))
	_ip_edit = LineEdit.new()
	_ip_edit.text = str(Settings.get_v("net", "last_ip"))
	_ip_edit.placeholder_text = "192.168.1.20"
	_ip_edit.custom_minimum_size.y = 50
	_ip_edit.text_submitted.connect(func(_t): _join())
	v.add_child(_ip_edit)
	v.add_child(T.label("Port %d (UDP). Connections are always encrypted. Friends you've played with can be joined from Friends." % Net.port(), 18, T.MUTED))
	var row := HBoxContainer.new()
	row.add_child(T.button("Connect", _join, 200))
	row.add_child(T.button("Back", func(): _show("main"), 160))
	v.add_child(row)


func _build_friends() -> void:
	var box := _panel("friends", true)
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(820, 0)
	box.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	p.add_child(v)
	v.add_child(T.title("FRIENDS", 44))
	var mine := HBoxContainer.new()
	_my_code = T.label("", 22, T.EMBER_SOFT, true)
	_my_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mine.add_child(_my_code)
	mine.add_child(T.button("Copy", func():
		DisplayServer.clipboard_set(Identity.code())
		_my_code.text = "Your friend code: %s  (copied)" % Identity.code(), 120))
	v.add_child(mine)
	var help := T.label("Share your code so friends can add you. Once you've played together, joining a friend " +
		"from this list checks it really is them. Everything you send is encrypted either way.", 18, T.MUTED)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(help)
	var add := HBoxContainer.new()
	_friend_edit = LineEdit.new()
	_friend_edit.placeholder_text = "Friend code, e.g. 7K2QD-M9XRA"
	_friend_edit.custom_minimum_size = Vector2(420, 48)
	_friend_edit.text_submitted.connect(func(_t): _add_friend_code())
	add.add_child(_friend_edit)
	add.add_child(T.button("Add", _add_friend_code, 120))
	v.add_child(add)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 300
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_friends_list = VBoxContainer.new()
	_friends_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_friends_list)
	v.add_child(scroll)
	v.add_child(T.button("Back", func(): _show("main"), 160))


func _add_friend_code() -> void:
	var code := Friends.normalize_code(_friend_edit.text)
	if code == "":
		_my_code.text = "That doesn't look like a friend code (10 letters and digits)."
		return
	if code == Identity.code():
		_my_code.text = "That's your own code."
		return
	Friends.remember(code)
	_friend_edit.text = ""
	_refresh_friends()


func _refresh_friends() -> void:
	if _friends_list == null:
		return
	_my_code.text = "Your friend code: %s" % Identity.code() if Identity.ready() else "Making your friend code…"
	for c in _friends_list.get_children():
		c.queue_free()
	var pr := Net.presence()
	# people who added us and wait for an answer
	if pr:
		for code in pr.requests:
			var row := PanelContainer.new()
			row.add_theme_stylebox_override("panel", T.box(Color(0.6, 0.9, 0.5, 0.06), Color("9fe07a"), 1, 4, 10))
			var h := HBoxContainer.new()
			var nm: String = pr.requests[code] if str(pr.requests[code]) != "" else "Someone"
			var l := T.label("%s  %s  wants to be friends" % [nm, code], 21, Color("9fe07a"), true)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			h.add_child(l)
			var c2: String = code
			h.add_child(T.button("Accept", func(): pr.accept(c2), 120))
			h.add_child(T.button("Ignore", func(): pr.ignore(c2), 120))
			row.add_child(h)
			_friends_list.add_child(row)
	var list := Friends.all()
	if list.is_empty() and (pr == null or pr.requests.is_empty()):
		_friends_list.add_child(T.label("No friends yet. Add one by code, or press + Friend in a lobby.", 20, T.MUTED))
	var hosting := not Net.solo and Net.is_host()
	for f in list:
		var row := PanelContainer.new()
		row.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.04), T.EMBER_SOFT, 0, 4, 10))
		var h := HBoxContainer.new()
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nm: String = f.name if str(f.name) != "" else "Friend"
		var code: String = f.code
		var on: bool = pr != null and pr.online(code)
		var dot := "●  " if on else "○  "
		info.add_child(T.label(dot + "%s   %s" % [nm, code], 22, Color("9fe07a") if on else T.TEXT, true))
		var status: String = pr.describe(code) if pr else ""
		var where := status
		if str(f.address) != "" and not on:
			where += "  ·  last hosted at %s:%d" % [f.address, int(f.port)]
		info.add_child(T.label(where, 16, Color("ffb070") if on and status.begins_with("Hosting") else T.MUTED))
		h.add_child(info)
		var live: Dictionary = pr.join_info(code) if pr else {}
		if not live.is_empty():
			h.add_child(T.button("Join", func(): join_friend_at(code, live.address, live.port), 110))
		elif str(f.address) != "":
			h.add_child(T.button("Join", func(): _join_friend(code), 110))
		if hosting and on and not _in_lobby(code):
			var btn := T.button("Invite", func(): pass, 120)
			btn.pressed.connect(func():
				btn.text = "Invited" if pr.invite(code) else "No address yet"
				btn.disabled = true)
			h.add_child(btn)
		var forget_code: String = f.code
		h.add_child(T.button("Remove", func():
			Friends.forget(forget_code)
			_refresh_friends(), 120))
		row.add_child(h)
		_friends_list.add_child(row)


func _in_lobby(code: String) -> bool:
	for p in Net.players.values():
		if str(p.get("code", "")) == code:
			return true
	return false


## Join a friend's game at a known address (an invite, or their live status).
func join_friend_at(code: String, address: String, port: int) -> void:
	if address == "":
		return
	if not await _identity_ready():
		return
	var err := Net.join(address, port, code)
	if err != OK:
		_toast("Couldn't start connecting (%s)." % error_string(err))
		return
	_show("main")
	var f := Friends.find(code)
	_toast("Connecting to %s…" % (f.name if str(f.get("name", "")) != "" else address), T.EMBER_SOFT)


func _join_friend(code: String) -> void:
	var f := Friends.find(code)
	if f.is_empty() or str(f.address) == "":
		return
	if not await _identity_ready():
		return
	var err := Net.join(str(f.address), int(f.port), code)
	if err != OK:
		_toast("Couldn't start connecting (%s)." % error_string(err))
		return
	_show("main")
	_toast("Connecting to %s…" % (f.name if str(f.name) != "" else f.address), T.EMBER_SOFT)


## The first launch makes this install's encryption key; it takes a moment
## on slower phones. False if the menu was left meanwhile.
func _identity_ready() -> bool:
	if Identity.ready():
		return true
	_toast("Preparing your encryption key…", T.EMBER_SOFT)
	while not Identity.ready():
		await get_tree().process_frame
		if not is_inside_tree():
			return false
	_toast("")
	return true


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
	_copy_addr = T.button("Copy internet address", func():
		var ps := Net.port_status()
		if str(ps.get("public_ip", "")) != "":
			DisplayServer.clipboard_set("%s:%d" % [ps.public_ip, ps.port])
			_copy_addr.text = "Copied"
			get_tree().create_timer(2.0).timeout.connect(func(): _copy_addr.text = "Copy internet address"), 300)
	v.add_child(_copy_addr)
	v.add_child(_map_button())
	_roster = VBoxContainer.new()
	_roster.custom_minimum_size.y = 230
	v.add_child(_roster)
	_invites = HFlowContainer.new()
	_invites.add_theme_constant_override("h_separation", 8)
	v.add_child(_invites)
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


## A button showing the map the next match is on; pressing it picks the
## next one (in a lobby only the host can). The map's data credit goes
## underneath.
func _map_button() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var b := T.button("", func(): pass)
	b.pressed.connect(func():
		var ids := ArenaScript.MAPS.keys()
		Net.set_map(ids[(ids.find(Net.match_map()) + 1) % ids.size()])
		_refresh_maps())
	box.add_child(b)
	var note := T.label("", 15, Color(1, 1, 1, 0.45))
	box.add_child(note)
	_map_btns.append(b)
	_map_notes.append(note)
	_refresh_maps()
	return box


func _refresh_maps() -> void:
	var lobby := not Net.solo and not Net.players.is_empty()
	for b in _map_btns:
		b.text = "Map: %s" % ArenaScript.map_title(Net.match_map())
		b.disabled = lobby and not Net.is_host()
		b.tooltip_text = "The host picks the map" if b.disabled else "Change the map"
	for n in _map_notes:
		n.text = ArenaScript.map_attribution(Net.match_map())
		n.visible = n.text != ""


# --- actions ---------------------------------------------------------------

func _play_solo() -> void:
	Net.start_solo()
	LoadingScreen.open(get_tree(), "Preparing %s…" % ArenaScript.map_title(Net.match_map()))
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _host() -> void:
	if not await _identity_ready():
		return
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
	if not await _identity_ready():
		return
	var port := 0
	if ip.count(":") == 1:     # "203.0.113.7:47820", as the host's Copy button gives it
		port = int(ip.get_slice(":", 1))
		ip = ip.get_slice(":", 0)
	var err := Net.join(ip, port)
	if err != OK:
		_toast("Couldn't start connecting (%s)." % error_string(err))
		return
	_show("main")
	_toast("Connecting to %s…" % ip, T.EMBER_SOFT)


func _on_net_error(reason: String) -> void:
	_show("main")
	var j := Net.join_info()
	if j.get("pinned", false) and reason.begins_with("Couldn't reach"):
		var f := Friends.find(str(j.code))
		reason = "Couldn't connect to %s at %s. If they're hosting, check the address; if they reinstalled the game, remove them from Friends and add them again." % [
			f.get("name", "your friend"), j.address]
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
		var code := str(p.get("code", ""))
		var friend := Friends.is_friend(code)
		var n := T.label(str(p.name) + ("  (host)" if id == 1 else "") + ("  (you)" if id == Net.me() else "") + ("  ★ friend" if friend else ""), 24, T.TEXT, true)
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(n)
		if code != "" and not friend and id != Net.me():
			var pid: int = id
			h.add_child(T.button("+ Friend", func(): _befriend(pid), 140))
		var ready_txt := "HOST" if id == 1 else ("READY" if p.ready else "not ready")
		h.add_child(T.label(ready_txt, 20, Color("9fe07a") if (p.ready or id == 1) else T.MUTED, true))
		row.add_child(h)
		_roster.add_child(row)
	var host := Net.is_host()
	_refresh_maps()
	_start_btn.visible = host
	_start_btn.disabled = not Net.everyone_ready()
	_start_btn.text = "Start the Night" if Net.everyone_ready() else "Waiting for ready…"
	_ready_btn.visible = not host
	var me: Dictionary = Net.players.get(Net.me(), {})
	_ready_btn.text = "Not ready" if me.get("ready", false) else "Ready"
	_copy_addr.visible = false
	for c in _invites.get_children():
		c.queue_free()
	var pr := Net.presence()
	if host and pr:
		for f in Friends.all():
			var code: String = f.code
			if pr.online(code) and not _in_lobby(code):
				var nm: String = f.name if str(f.name) != "" else code
				var btn := T.button("Invite %s" % nm, func(): pass, 0)
				btn.pressed.connect(func():
					btn.text = "Invited %s" % nm if pr.invite(code) else "%s: no address to send yet" % nm
					btn.disabled = true)
				_invites.add_child(btn)
	if host:
		var ps := Net.port_status()
		var lan: String = ps.get("lan_ip", "") if str(ps.get("lan_ip", "")) != "" else ", ".join(Net.local_addresses())
		var lines := ["On your network, friends join with: %s" % lan]
		var pub := str(ps.get("public_ip", ""))
		match ps.get("state", ""):
			"working":
				lines.append("Opening port %d on your router…" % Net.port())
			"open":
				lines.append("Over the internet: %s:%d  (port opened automatically)" % [pub if pub != "" else "finding your address…", Net.port()])
			"closed":
				var where := "Your internet address: %s:%d. " % [pub, Net.port()] if pub != "" else ""
				var target := lan if str(ps.get("lan_ip", "")) != "" else "this computer (its address above)"
				lines.append("%s%s To play over the internet, forward UDP port %d on your router to %s, or use Tailscale or ZeroTier." % [
					where, ps.get("note", ""), Net.port(), target])
		lines.append("Encrypted. Your friend code: %s    %d / %d survivors" % [Identity.code(), Net.players.size(), Net.MAX_PLAYERS])
		_lobby_info.text = "\n".join(lines)
		_copy_addr.visible = pub != "" and ps.get("state", "") == "open"
	else:
		var j := Net.join_info()
		var security := "Encrypted and verified: this is your friend." if j.get("pinned", false) else "Encrypted."
		_lobby_info.text = "Connected. %s Waiting for the host to start. %d / %d survivors" % [security, Net.players.size(), Net.MAX_PLAYERS]


## Add a lobby member as a friend, with what we know of them: their
## certificate (to check it's them next time) and, for the host, where
## they're hosting.
func _befriend(id: int) -> void:
	var p: Dictionary = Net.players.get(id, {})
	if p.is_empty():
		return
	var j := Net.join_info()
	var host_id: Dictionary = Net.get_meta("host_id", {})
	if id == 1 and host_id.get("code", "") == p.get("code", ""):
		Friends.remember(str(p.code), str(p.name), str(host_id.get("cert", "")), str(j.get("address", "")), int(j.get("port", 0)))
	else:
		Friends.remember(str(p.code), str(p.name), str(p.get("cert", "")))
	_refresh_lobby()


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
