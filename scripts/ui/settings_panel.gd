extends PanelContainer
## Tabbed options: Gameplay, Video, Audio, Controls and Updates.
## Used by the main menu and the in-game pause menu.

signal closed

const T := preload("res://scripts/ui/ui_theme.gd")

var _rebinding := ""
var _bind_buttons := {}
var _update_status: Label
var _update_buttons := {}
var _progress: ProgressBar
var tabs: TabContainer


func _ready() -> void:
	theme = T.get_theme()
	custom_minimum_size = Vector2(860, 620)
	var root := VBoxContainer.new()
	add_child(root)
	var head := HBoxContainer.new()
	head.add_child(T.title("SETTINGS", 40))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	head.add_child(T.button("Back", func(): closed.emit(), 140))
	root.add_child(head)
	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(tabs)
	_gameplay_tab()
	_video_tab()
	_audio_tab()
	_controls_tab()
	_updates_tab()
	Updater.state_changed.connect(_refresh_updates)
	_refresh_updates()


func open_updates() -> void:
	tabs.current_tab = 4


func _page(title_text: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title_text
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 14)
	scroll.add_child(v)
	tabs.add_child(scroll)
	return v


func _row(parent: Control, text: String, control: Control) -> void:
	var h := HBoxContainer.new()
	var l := T.label(text, 22)
	l.custom_minimum_size.x = 300
	h.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(control)
	parent.add_child(h)


func _slider(section: String, key: String, lo: float, hi: float, step: float, fmt := "%.2f") -> HBoxContainer:
	var h := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_v(section, key))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := T.label(fmt % s.value, 20, T.EMBER_SOFT, true)
	val.custom_minimum_size.x = 70
	s.value_changed.connect(func(v):
		val.text = fmt % v
		Settings.set_v(section, key, v))
	h.add_child(s)
	h.add_child(val)
	return h


func _check(section: String, key: String, text := "") -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = bool(Settings.get_v(section, key))
	c.toggled.connect(func(on): Settings.set_v(section, key, on))
	return c


func _options(section: String, key: String, labels: Array, values: Array) -> OptionButton:
	var o := OptionButton.new()
	for i in labels.size():
		o.add_item(labels[i], i)
	var cur = Settings.get_v(section, key)
	o.selected = maxi(values.find(cur), 0)
	o.item_selected.connect(func(i): Settings.set_v(section, key, values[i]))
	return o


func _gameplay_tab() -> void:
	var v := _page("Gameplay")
	var name_edit := LineEdit.new()
	name_edit.text = Settings.player_name()
	name_edit.max_length = 16
	name_edit.text_changed.connect(func(t): if t.strip_edges() != "": Settings.set_v("player", "name", t.strip_edges()))
	_row(v, "Survivor name", name_edit)
	var colors := HBoxContainer.new()
	for i in Settings.PLAYER_COLORS.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(56, 40)
		b.toggle_mode = true
		var sb := T.box(Settings.PLAYER_COLORS[i], Color.WHITE, 0, 4, 4)
		var sel := T.box(Settings.PLAYER_COLORS[i], Color.WHITE, 3, 4, 4)
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sel)
		b.add_theme_stylebox_override("pressed", sel)
		b.button_pressed = int(Settings.get_v("player", "color")) == i
		b.pressed.connect(func():
			Settings.set_v("player", "color", i)
			for c in colors.get_children():
				c.button_pressed = c == b)
		colors.add_child(b)
	_row(v, "Colour", colors)
	_row(v, "Mouse sensitivity", _slider("gameplay", "sensitivity", 0.1, 4.0, 0.05))
	_row(v, "Field of view", _slider("gameplay", "fov", 60, 110, 1, "%d°"))
	_row(v, "Invert look", _check("gameplay", "invert_y"))
	_row(v, "Show FPS", _check("gameplay", "show_fps"))
	_row(v, "Touch controls", _options("gameplay", "touch_controls", ["Automatic", "Always on", "Off"], ["auto", "on", "off"]))
	_row(v, "Touch look speed", _slider("gameplay", "touch_look", 0.2, 3.0, 0.05))
	_row(v, "Touch aim assist", _check("gameplay", "aim_assist"))


func _video_tab() -> void:
	var v := _page("Video")
	_row(v, "Quality preset", _options("video", "quality", Settings.QUALITY_NAMES, [0, 1, 2, 3]))
	v.add_child(T.label("Quality changes apply to lighting and effects the next time a map loads.", 18, T.MUTED))
	if not OS.has_feature("mobile"):
		_row(v, "Fullscreen", _check("video", "fullscreen"))
	_row(v, "V-Sync", _check("video", "vsync"))
	_row(v, "Render scale", _slider("video", "render_scale", 0.5, 1.0, 0.05, "%.2f×"))
	_row(v, "Frame rate cap", _options("video", "max_fps", ["Unlimited", "30", "60", "90", "120", "144", "240"], [0, 30, 60, 90, 120, 144, 240]))


func _audio_tab() -> void:
	var v := _page("Audio")
	_row(v, "Master volume", _slider("audio", "master", 0, 1, 0.01))
	_row(v, "Effects", _slider("audio", "sfx", 0, 1, 0.01))
	_row(v, "Music", _slider("audio", "music", 0, 1, 0.01))


func _controls_tab() -> void:
	var v := _page("Controls")
	v.add_child(T.label("Click a binding, then press a key or mouse button. Gamepads work out of the box.", 18, T.MUTED))
	for action in Settings.ACTIONS:
		var b := Button.new()
		b.custom_minimum_size = Vector2(220, 44)
		b.text = Settings.bind_label(action)
		b.pressed.connect(func():
			_rebinding = action
			b.text = "Press a key…")
		_bind_buttons[action] = b
		_row(v, Settings.ACTION_LABELS[action], b)
	var reset := T.button("Reset to defaults", func():
		Settings.reset_binds()
		_refresh_binds(), 260)
	reset.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(reset)


func _refresh_binds() -> void:
	for a in _bind_buttons:
		_bind_buttons[a].text = Settings.bind_label(a)


func _input(event: InputEvent) -> void:
	if _rebinding == "" or not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode != KEY_ESCAPE:
			Settings.rebind(_rebinding, event)
	elif event is InputEventMouseButton and event.pressed:
		Settings.rebind(_rebinding, event)
	else:
		return
	_rebinding = ""
	_refresh_binds()
	get_viewport().set_input_as_handled()


func _updates_tab() -> void:
	var v := _page("Updates")
	v.add_child(T.title("v" + Updater.current_version(), 34, T.EMBER_SOFT))
	v.add_child(T.label("Cinderhold patches itself from GitHub: updates are small downloads that apply on restart, no reinstall needed.", 19, T.MUTED))
	_update_status = T.label("", 22, T.TEXT, true)
	_update_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_update_status)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 14
	_progress.show_percentage = false
	_progress.max_value = 1.0
	v.add_child(_progress)
	var row := HBoxContainer.new()
	_update_buttons.check = T.button("Check for updates", func(): Updater.check(), 240)
	_update_buttons.download = T.button("Download update", func(): Updater.download(), 240)
	_update_buttons.restart = T.button("Restart now", func(): Updater.restart(), 200)
	_update_buttons.page = T.button("Open release page", func(): Updater.open_release_page(), 240)
	for k in ["check", "download", "restart", "page"]:
		row.add_child(_update_buttons[k])
	v.add_child(row)
	var token := LineEdit.new()
	token.secret = true
	token.placeholder_text = "github_pat_…  (read-only access to this repository)"
	token.text = str(Settings.get_v("updates", "token"))
	token.text_changed.connect(func(t): Settings.set_v("updates", "token", t.strip_edges()))
	_row(v, "GitHub access token", token)
	v.add_child(T.label("The repository is private, so each install needs a fine-grained token with \"Contents: read\" on GPTmadeit/cinderhold. It's stored only on this device.", 17, T.MUTED))
	_row(v, "Check on startup", _check("updates", "auto_check"))
	var revert := T.button("Remove installed patch", func(): Updater.revert_patch(), 280)
	revert.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(revert)


func _refresh_updates() -> void:
	if _update_status == null:
		return
	var s: int = Updater.state
	_update_status.text = Updater.message if Updater.message != "" else "Not checked yet."
	_update_buttons.check.disabled = s in [Updater.State.CHECKING, Updater.State.DOWNLOADING]
	_update_buttons.download.visible = s == Updater.State.AVAILABLE
	_update_buttons.restart.visible = s == Updater.State.READY
	_update_buttons.restart.text = "Restart now" if Updater.can_restart() else "Close the game to apply"
	_update_buttons.restart.disabled = not Updater.can_restart()
	_update_buttons.page.visible = s == Updater.State.FULL_REQUIRED
	_progress.visible = s == Updater.State.DOWNLOADING


func _process(_dt: float) -> void:
	if _progress and _progress.visible:
		_progress.value = Updater.progress
