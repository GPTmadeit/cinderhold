extends CanvasLayer
## In-match interface: round, points, ammo, perks, crosshair, prompts,
## messages, downed overlay, scoreboard, pause menu and the game-over screen.

const T := preload("res://scripts/ui/ui_theme.gd")
const W := preload("res://scripts/game/weapons.gd")
const P := preload("res://scripts/game/perks.gd")
const SettingsPanel := preload("res://scripts/ui/settings_panel.gd")
const TouchControls := preload("res://scripts/ui/touch_controls.gd")

var game: Node
var player: Node

var _root: Control
var _round_lbl: Label
var _round_sub: Label
var _points_box: VBoxContainer
var _perk_row: HBoxContainer
var _health: ProgressBar
var _weapon_lbl: Label
var _ammo_lbl: Label
var _reserve_lbl: Label
var _ammo_warn: Label
var _cross: Control
var _prompt: Label
var _revive_bar: ProgressBar
var _toasts: VBoxContainer
var _big: Label
var _banner: Label
var _banner_sub: Label
var _timers: HBoxContainer
var _vignette: ColorRect
var _flash: ColorRect
var _scope: Control
var _down_panel: Control
var _down_lbl: Label
var _fps: Label
var _scoreboard: PanelContainer
var _score_grid: GridContainer
var _pause: Control
var _settings: Control
var _over: Control
var _touch: Control
var _popups: Control
var _ammo_box: Control

var _hit_t := 0.0
var _hit_head := false
var _kill_t := 0.0
var _round_shown := -1
var _perks_shown := ""
var _points_shown := ""


func bind(g: Node, p: Node) -> void:
	game = g
	player = p


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.theme = T.get_theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_overlays()
	_build_round()
	_build_points()
	_build_ammo()
	_build_center()
	_build_messages()
	_build_down()
	_build_scoreboard()
	_build_pause()
	_build_over()
	if Settings.use_touch():
		_touch = TouchControls.new()
		_touch.hud = self
		_root.add_child(_touch)
		# the fire button lives where the ammo counter would be
		_ammo_box.grow_vertical = Control.GROW_DIRECTION_END
		_ammo_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 32)
		_ammo_box.position.y += 70
	_fps = T.label("", 18, Color(1, 1, 1, 0.5))
	_fps.position = Vector2(12, 4)
	_root.add_child(_fps)


func _anchor(c: Control, preset: int, offset: Vector2) -> void:
	c.set_anchors_preset(preset)
	c.position += offset


func _ignore(c: Control) -> Control:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in c.get_children():
		if ch is Control:
			_ignore(ch)
	return c


# --- build ---------------------------------------------------------------

func _build_overlays() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform float amount = 0.0;
uniform vec4 tint : source_color = vec4(0.6, 0.02, 0.0, 1.0);
void fragment() {
	float d = distance(UV, vec2(0.5));
	float v = smoothstep(0.25, 0.75, d) * amount;
	COLOR = vec4(tint.rgb, v);
}"""
	var m := ShaderMaterial.new()
	m.shader = sh
	_vignette.material = m
	_root.add_child(_vignette)
	_scope = Control.new()
	_scope.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scope.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scope.visible = false
	_scope.draw.connect(_draw_scope)
	_root.add_child(_scope)
	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 1, 1, 0)
	_root.add_child(_flash)


func _build_round() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -18)
	_round_sub = T.label("ROUND", 22, T.EMBER_SOFT, true)
	_round_lbl = T.title("", 96, Color("d8452a"))
	v.add_child(_round_sub)
	v.add_child(_round_lbl)
	_anchor(v, Control.PRESET_TOP_LEFT, Vector2(36, 18))
	_root.add_child(_ignore(v))


func _build_points() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_perk_row = HBoxContainer.new()
	v.add_child(_perk_row)
	_health = ProgressBar.new()
	_health.custom_minimum_size = Vector2(260, 10)
	_health.show_percentage = false
	_health.add_theme_stylebox_override("fill", T.box(Color("d84a3a"), Color(0, 0, 0, 0), 0, 3, 0))
	v.add_child(_health)
	_points_box = VBoxContainer.new()
	_points_box.add_theme_constant_override("separation", 2)
	v.add_child(_points_box)
	v.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_root.add_child(_ignore(v))
	v.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 32)
	_popups = Control.new()
	_popups.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_popups.position = Vector2(250, -60)
	_popups.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_popups)


func _build_ammo() -> void:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_END
	v.add_theme_constant_override("separation", -6)
	_ammo_warn = T.label("", 22, Color("ff9a5a"), true)
	_ammo_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_ammo_warn)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_END
	_ammo_lbl = T.title("", 64, T.TEXT)
	_reserve_lbl = T.label("", 30, T.MUTED, true)
	_reserve_lbl.size_flags_vertical = Control.SIZE_SHRINK_END
	h.add_child(_ammo_lbl)
	h.add_child(_reserve_lbl)
	v.add_child(h)
	_weapon_lbl = T.label("", 24, T.EMBER_SOFT, true)
	_weapon_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(_weapon_lbl)
	v.grow_vertical = Control.GROW_DIRECTION_BEGIN
	v.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_root.add_child(_ignore(v))
	v.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 32)
	_ammo_box = v


func _build_center() -> void:
	_cross = Control.new()
	_cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cross.draw.connect(_draw_cross)
	_root.add_child(_cross)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	_prompt = T.label("", 26, T.TEXT, true)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_prompt.add_theme_constant_override("outline_size", 8)
	v.add_child(_prompt)
	_revive_bar = ProgressBar.new()
	_revive_bar.custom_minimum_size = Vector2(320, 12)
	_revive_bar.max_value = 1.0
	_revive_bar.show_percentage = false
	_revive_bar.add_theme_stylebox_override("fill", T.box(Color("9fe07a"), Color(0, 0, 0, 0), 0, 3, 0))
	_revive_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(_revive_bar)
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.position.y += 110
	v.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_root.add_child(_ignore(v))


func _build_messages() -> void:
	_toasts = VBoxContainer.new()
	_toasts.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toasts.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toasts.position = Vector2(-30, 30)
	_toasts.add_theme_constant_override("separation", 4)
	_root.add_child(_ignore(_toasts))
	_big = T.title("", 64)
	_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_big.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_big.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_big.position.y = 120
	_big.modulate.a = 0.0
	_root.add_child(_ignore(_big))
	var bv := VBoxContainer.new()
	bv.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner = T.title("", 110, Color("e0502a"))
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub = T.label("", 28, T.EMBER_SOFT, true)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bv.add_child(_banner)
	bv.add_child(_banner_sub)
	bv.set_anchors_preset(Control.PRESET_CENTER)
	bv.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bv.grow_vertical = Control.GROW_DIRECTION_BOTH
	bv.position.y -= 120
	bv.modulate.a = 0.0
	bv.name = "Banner"
	_root.add_child(_ignore(bv))
	_timers = HBoxContainer.new()
	_timers.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_timers.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_timers.position.y = 26
	_root.add_child(_ignore(_timers))


func _build_down() -> void:
	_down_panel = ColorRect.new()
	(_down_panel as ColorRect).color = Color(0.25, 0.0, 0.0, 0.25)
	_down_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_down_panel.visible = false
	_down_lbl = T.title("", 44, Color("ff6a5a"))
	_down_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_down_lbl.set_anchors_preset(Control.PRESET_CENTER)
	_down_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_down_lbl.position.y -= 200
	_down_panel.add_child(_down_lbl)
	_root.add_child(_ignore(_down_panel))


func _build_scoreboard() -> void:
	_scoreboard = PanelContainer.new()
	_scoreboard.visible = false
	var v := VBoxContainer.new()
	v.add_child(T.title("THE WATCH", 34))
	_score_grid = GridContainer.new()
	_score_grid.columns = 6
	_score_grid.add_theme_constant_override("h_separation", 34)
	v.add_child(_score_grid)
	_scoreboard.add_child(v)
	_scoreboard.set_anchors_preset(Control.PRESET_CENTER)
	_scoreboard.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_scoreboard.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_child(_ignore(_scoreboard))


func _build_pause() -> void:
	_pause = Control.new()
	_pause.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.visible = false
	_pause.add_child(T.scrim())
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(cc)
	var p := PanelContainer.new()
	p.custom_minimum_size.x = 440
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(T.title("PAUSED" if Net.solo else "MENU", 48))
	if not Net.solo:
		v.add_child(T.label("The night doesn't wait. The game keeps running.", 18, T.MUTED))
	v.add_child(T.button("Resume", func(): set_paused(false), 380))
	v.add_child(T.button("Settings", func():
		_settings.visible = true
		cc.visible = false, 380))
	var leave_txt := "Leave to menu" if (Net.solo or not Net.is_host()) else "End game (back to lobby)"
	v.add_child(T.button(leave_txt, func(): game.leave(), 380))
	if not OS.has_feature("web"):
		v.add_child(T.button("Quit to desktop", func(): get_tree().quit(), 380))
	cc.add_child(p)
	var sc := CenterContainer.new()
	sc.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sp := SettingsPanel.new()
	sp.closed.connect(func():
		_settings.visible = false
		cc.visible = true
		if player and player.camera:
			player.camera.fov = float(Settings.get_v("gameplay", "fov")))
	sc.add_child(sp)
	_settings = sc
	_settings.visible = false
	_pause.add_child(sc)
	_root.add_child(_pause)


func _build_over() -> void:
	_over = Control.new()
	_over.set_anchors_preset(Control.PRESET_FULL_RECT)
	_over.visible = false
	_root.add_child(_over)


# --- public API used by the game -------------------------------------------

func menu_open() -> bool:
	return _pause.visible or _over.visible


func set_paused(on: bool) -> void:
	if _over.visible:
		return
	_pause.visible = on
	_settings.visible = false
	_pause.get_child(1).visible = true
	if Net.solo:
		get_tree().paused = on
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if on or Settings.use_touch() else Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		set_paused(not _pause.visible)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and not menu_open() and not Settings.use_touch() and Settings.can_capture_mouse():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and Net.solo and not "--shot" in OS.get_cmdline_user_args() and _over and not _over.visible and _pause and not _pause.visible:
		set_paused(true)


func toast(text: String, color := T.TEXT) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.04, 0.045, 0.75), color.darkened(0.3), 0, 4, 12))
	var l := T.label(text, 20, color, true)
	p.add_child(l)
	_toasts.add_child(p)
	_toasts.move_child(p, 0)
	while _toasts.get_child_count() > 6:
		_toasts.get_child(_toasts.get_child_count() - 1).free()
	var tw := p.create_tween()
	tw.tween_interval(4.5)
	tw.tween_property(p, "modulate:a", 0.0, 0.6)
	tw.tween_callback(p.queue_free)


func big_message(text: String, color: Color) -> void:
	_big.text = text
	_big.add_theme_color_override("font_color", color)
	_big.modulate.a = 1.0
	_big.scale = Vector2.ONE
	var tw := _big.create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(_big, "modulate:a", 0.0, 0.8)


func flash(c: Color) -> void:
	_flash.color = c
	var tw := _flash.create_tween()
	tw.tween_property(_flash, "color:a", 0.0, 0.7)


func round_banner(r: int, starting: bool) -> void:
	var b: Control = _root.get_node("Banner")
	_banner.text = ("ROUND %d" % r) if starting else "SURVIVED"
	_banner_sub.text = _round_flavour(r) if starting else "Round %d held. Breathe." % r
	b.modulate.a = 0.0
	var tw := b.create_tween()
	tw.tween_property(b, "modulate:a", 1.0, 0.6)
	tw.tween_interval(2.2)
	tw.tween_property(b, "modulate:a", 0.0, 1.0)
	if starting:
		_round_lbl.add_theme_color_override("font_color", Color.WHITE)
		var t2 := _round_lbl.create_tween()
		t2.tween_interval(1.0)
		t2.tween_callback(func(): _round_lbl.add_theme_color_override("font_color", Color("d8452a")))


func _round_flavour(r: int) -> String:
	if r == 1:
		return "The ash stirs. Hold the outpost."
	if r % 5 == 0:
		return "The Brutes are coming."
	var lines := ["They smell the fire.", "More crawl from the vents.", "The night grows longer.", "Keep the braziers lit.", "Don't let them reach you."]
	return lines[r % lines.size()]


func points_popup(delta: int) -> void:
	var l := T.label(("+%d" % delta) if delta > 0 else str(delta), 26, Color("ffd36a") if delta > 0 else Color("ff7a6a"), true)
	l.position = Vector2(randf_range(0, 30), randf_range(-10, 10))
	_popups.add_child(l)
	var tw := l.create_tween().set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 60, 0.9)
	tw.tween_property(l, "position:x", l.position.x + randf_range(20, 60), 0.9)
	tw.tween_property(l, "modulate:a", 0.0, 0.9).set_delay(0.2)
	tw.chain().tween_callback(l.queue_free)


func hitmarker(head: bool) -> void:
	_hit_t = 0.18
	_hit_head = head


func kill_confirmed(head: bool) -> void:
	_kill_t = 0.3
	_hit_head = head
	_hit_t = 0.3


func game_over(r: int, summary: Array) -> void:
	_pause.visible = false
	for n in [_root.get_node("Banner"), _big, _toasts, _timers, _prompt, _cross]:
		n.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_over.visible = true
	_over.add_child(T.scrim(0.75))
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_over.add_child(cc)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	cc.add_child(v)
	var t := T.title("THE HOLD HAS FALLEN", 72, Color("e0502a"))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := T.label("You survived %d round%s." % [r, "" if r == 1 else "s"], 30, T.EMBER_SOFT, true)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	var p := PanelContainer.new()
	var g := GridContainer.new()
	g.columns = 6
	g.add_theme_constant_override("h_separation", 40)
	for h in ["SURVIVOR", "POINTS", "KILLS", "HEADSHOTS", "DOWNS", "REVIVES"]:
		g.add_child(T.label(h, 18, T.MUTED, true))
	for row in summary:
		g.add_child(T.label(str(row.name), 24, Settings.PLAYER_COLORS[int(row.color) % 4].lightened(0.2), true))
		for k in ["points", "kills", "headshots", "downs", "revives"]:
			g.add_child(T.label(str(row[k]), 24, T.TEXT, true))
	p.add_child(g)
	v.add_child(p)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	if Net.solo:
		h.add_child(T.button("Try again", func(): game.play_again(), 240))
	elif Net.is_host():
		h.add_child(T.button("Back to lobby", func(): game.play_again(), 240))
	else:
		h.add_child(T.label("Waiting for the host…", 22, T.MUTED))
	h.add_child(T.button("Main menu", func(): game.leave() if not (Net.is_host() and not Net.solo) else _host_quit(), 240))
	v.add_child(h)
	_over.modulate.a = 0.0
	_over.create_tween().tween_property(_over, "modulate:a", 1.0, 1.2)


func _host_quit() -> void:
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# --- per frame ---------------------------------------------------------------

func _process(dt: float) -> void:
	if player == null or game == null:
		return
	_fps.visible = bool(Settings.get_v("gameplay", "show_fps"))
	if _fps.visible:
		_fps.text = "%d fps" % Engine.get_frames_per_second()
	if game.round_num != _round_shown:
		_round_shown = game.round_num
		_round_lbl.text = str(game.round_num) if game.round_num > 0 else ""
		_round_sub.text = "ROUND" if game.round_num > 0 else "GET READY"
	_update_points()
	_update_perks()
	_health.max_value = player.max_hp
	_health.value = player.hp
	_health.modulate.a = 1.0 if player.hp < player.max_hp else 0.45

	var w: Dictionary = player.weapon()
	if w.is_empty():
		_weapon_lbl.text = "In the forge…" if player.forge_pending != "" else ""
		_ammo_lbl.text = ""
		_reserve_lbl.text = ""
		_ammo_warn.text = ""
	else:
		var def := W.get_def(w.id, w.upgraded)
		_weapon_lbl.text = def.name
		_tint(_weapon_lbl, T.EMBER if w.upgraded else T.EMBER_SOFT)
		_ammo_lbl.text = str(w.mag)
		_reserve_lbl.text = " / %d" % w.reserve
		var low: bool = w.mag <= int(ceil(def.mag * 0.25))
		_tint(_ammo_lbl, Color("ff7a5a") if w.mag == 0 else (Color("ffb070") if low else T.TEXT))
		if player.reload_t >= 0.0:
			_ammo_warn.text = "RELOADING"
		elif w.mag == 0 and w.reserve == 0:
			_ammo_warn.text = "NO AMMO"
		elif low and w.reserve > 0:
			_ammo_warn.text = "RELOAD [%s]" % Settings.bind_label("reload")
		elif w.reserve == 0:
			_ammo_warn.text = "LOW AMMO"
		else:
			_ammo_warn.text = ""

	_prompt.text = player.prompt
	var cash := int(game.points.get(player.peer_id, 0))
	_tint(_prompt, Color("ff9a8a") if player.prompt_cost > cash else T.TEXT)
	_revive_bar.visible = player.revive_progress > 0.0
	_revive_bar.value = player.revive_progress

	var vm: ShaderMaterial = _vignette.material
	var hurt := maxf(player.hurt_flash * 0.8, (1.0 - player.hp / player.max_hp) * 0.9 if player.hp < player.max_hp * 0.6 else 0.0)
	vm.set_shader_parameter("amount", hurt if not player.downed else 1.0)

	_down_panel.visible = (player.downed or player.dead) and not _over.visible
	if player.dead:
		_down_lbl.text = "BLED OUT\nSPECTATING UNTIL NEXT ROUND"
	elif player.downed:
		if player.self_revive_t >= 0.0:
			_down_lbl.text = "SECOND WIND\nGETTING BACK UP… %d" % ceili(player.self_revive_t)
		elif Net.solo:
			_down_lbl.text = "YOU ARE DOWN"
		else:
			_down_lbl.text = "YOU ARE DOWN\nBLEEDING OUT IN %d" % ceili(player.bleed_t)

	var def2: Dictionary = player._vm_def
	_scope.visible = def2.get("scope", false) and player.ads_k > 0.92 and not player.weapon().is_empty()
	if _scope.visible:
		_scope.queue_redraw()
	_hit_t = maxf(_hit_t - dt, 0.0)
	_kill_t = maxf(_kill_t - dt, 0.0)
	_cross.queue_redraw()
	_update_timers()
	_scoreboard.visible = Input.is_action_pressed("scoreboard") and not menu_open()
	if _scoreboard.visible:
		_fill_scoreboard()


## Theme overrides re-layout the label, so only touch them on a change.
func _tint(l: Label, c: Color) -> void:
	if l.get_meta("tint", Color(0, 0, 0, 0)) != c:
		l.set_meta("tint", c)
		l.add_theme_color_override("font_color", c)


func _update_points() -> void:
	var ids: Array = game.points.keys()
	ids.sort()
	var sig := str(game.points)
	if sig == _points_shown:
		return
	_points_shown = sig
	for c in _points_box.get_children():
		c.free()
	for id in ids:
		var p = game.get_player(id)
		if p == null:
			continue
		var me: bool = id == player.peer_id
		var row := HBoxContainer.new()
		var sw := ColorRect.new()
		sw.color = Settings.PLAYER_COLORS[p.color_idx % 4]
		sw.custom_minimum_size = Vector2(6, 30 if me else 22)
		row.add_child(sw)
		var pts := T.label(str(game.points[id]), 38 if me else 24, Color("ffd36a") if me else T.TEXT, true)
		pts.add_theme_font_override("font", T.DISPLAY_FONT)
		pts.add_theme_font_size_override("font_size", 34 if me else 20)
		row.add_child(pts)
		if not me or not Net.solo:
			row.add_child(T.label(p.display_name, 20 if me else 17, T.MUTED, true))
		_points_box.add_child(_ignore(row))


func _update_perks() -> void:
	var sig := ",".join(player.perks)
	if sig == _perks_shown:
		return
	_perks_shown = sig
	for c in _perk_row.get_children():
		c.free()
	for k in player.perks:
		var pd: Dictionary = P.PERKS[k]
		var pc := PanelContainer.new()
		pc.custom_minimum_size = Vector2(44, 44)
		pc.add_theme_stylebox_override("panel", T.box(pd.color.darkened(0.35), pd.color.lightened(0.3), 2, 8, 4))
		var l := T.label(pd.short.substr(0, 1), 26, Color.WHITE, true)
		l.add_theme_font_override("font", T.DISPLAY_FONT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pc.add_child(l)
		pc.tooltip_text = pd.name
		_perk_row.add_child(_ignore(pc))


func _update_timers() -> void:
	for c in _timers.get_children():
		c.free()
	for t in [["DOUBLE POINTS", game.double_t, Color("ffcf4d")], ["DEADEYE", game.deadeye_t, Color("ff5a4a")]]:
		if t[1] > 0.0:
			var l := T.label("%s  %d" % [t[0], ceili(t[1])], 22, t[2], true)
			l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
			l.add_theme_constant_override("outline_size", 6)
			_timers.add_child(l)


func _fill_scoreboard() -> void:
	for c in _score_grid.get_children():
		c.free()
	for h in ["SURVIVOR", "POINTS", "KILLS", "HEADSHOTS", "DOWNS", "REVIVES"]:
		_score_grid.add_child(T.label(h, 17, T.MUTED, true))
	for p in game.player_nodes():
		var s: Dictionary = game.stats.get(p.peer_id, {})
		_score_grid.add_child(T.label(p.display_name, 22, Settings.PLAYER_COLORS[p.color_idx % 4].lightened(0.2), true))
		_score_grid.add_child(T.label(str(game.points.get(p.peer_id, 0)), 22))
		for k in ["kills", "headshots", "downs", "revives"]:
			_score_grid.add_child(T.label(str(s.get(k, "—")), 22))


func _draw_cross() -> void:
	if player == null or player.weapon().is_empty() or player.dead:
		return
	var c := _cross.size / 2.0
	var def: Dictionary = player._vm_def
	if player.ads_k < 0.6 and not player.sprinting:
		var spread: float = lerpf(def.get("spread", 1.0), def.get("ads_spread", 0.3), player.ads_k) + player.bloom
		var gap := 6.0 + spread * 7.0
		var col := Color(1, 1, 1, 0.85 * (1.0 - player.ads_k))
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]:
			_cross.draw_line(c + d * gap, c + d * (gap + 10.0), Color(0, 0, 0, col.a * 0.6), 4.0)
			_cross.draw_line(c + d * gap, c + d * (gap + 10.0), col, 2.0)
		_cross.draw_circle(c, 1.5, col)
	if _hit_t > 0.0:
		var hc := Color("ff5a3a") if _hit_head else Color.WHITE
		if _kill_t > 0.0:
			hc = Color("ff3a2a")
		var s := 7.0 + (6.0 if _kill_t > 0.0 else 0.0)
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			_cross.draw_line(c + d * 5.0, c + d * (5.0 + s), hc, 2.5)


func _draw_scope() -> void:
	var sz := _scope.size
	var c := sz / 2.0
	var r := sz.y * 0.42
	var black := Color(0, 0, 0, 1)
	_scope.draw_rect(Rect2(0, 0, c.x - r, sz.y), black)
	_scope.draw_rect(Rect2(c.x + r, 0, sz.x - c.x - r, sz.y), black)
	_scope.draw_rect(Rect2(c.x - r, 0, r * 2, c.y - r), black)
	_scope.draw_rect(Rect2(c.x - r, c.y + r, r * 2, sz.y - c.y - r), black)
	# ring from the lens edge out past the square's corners
	var n := 72
	for i in n:
		var a0 := float(i) / n * TAU
		var a1 := float(i + 1) / n * TAU
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		_scope.draw_colored_polygon(PackedVector2Array([c + d0 * r, c + d1 * r, c + d1 * r * 1.5, c + d0 * r * 1.5]), black)
	_scope.draw_line(c - Vector2(r, 0), c + Vector2(r, 0), Color(0, 0, 0, 0.85), 1.5)
	_scope.draw_line(c - Vector2(0, r), c + Vector2(0, r), Color(0, 0, 0, 0.85), 1.5)
	_scope.draw_circle(c, 2.0, Color("ff3a2a"))
