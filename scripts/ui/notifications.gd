extends CanvasLayer
## Pop-up notes in the top-right corner (friends coming online, hosting,
## invites, friend requests), above every menu and the in-match HUD. While
## the mouse is captured in a match, notes show without their buttons.

const T := preload("res://scripts/ui/ui_theme.gd")
const NODE := "Notifications"
const MAX_SHOWN := 4

const INFO := Color("e0d6c8")
const FRIEND := Color("9fe07a")
const INVITE := Color("ffb070")

var _box: VBoxContainer


## Show a note. buttons: [[label, Callable], ...]; seconds before it fades.
static func post(text: String, color := INFO, buttons: Array = [], seconds := 8.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	if Settings.bot_driving():
		print("NOTE ", text)
	var layer: Node = tree.root.get_node_or_null(NODE)
	if layer == null:
		layer = load("res://scripts/ui/notifications.gd").new()
		layer.name = NODE
		tree.root.add_child(layer)
	layer._add(text, color, buttons, seconds)


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = T.get_theme()
	add_child(root)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 8)
	_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 24)
	_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_box.position.y += 70
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_box)


func _add(text: String, color: Color, buttons: Array, seconds: float) -> void:
	if _box == null:
		await ready
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", T.box(Color(0.06, 0.05, 0.055, 0.92), color.darkened(0.2), 2, 6, 12))
	card.custom_minimum_size.x = 360
	var v := VBoxContainer.new()
	card.add_child(v)
	var l := T.label(text, 20, color, true)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	var playing := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if not buttons.is_empty() and not playing:
		var row := HBoxContainer.new()
		for b in buttons:
			var cb: Callable = b[1]
			row.add_child(T.button(str(b[0]), func():
				cb.call()
				card.queue_free(), 120))
		v.add_child(row)
	elif not buttons.is_empty():
		v.add_child(T.label("Open Friends from the menu to answer.", 16, T.MUTED))
	_box.add_child(card)
	while _box.get_child_count() > MAX_SHOWN:
		_box.get_child(0).queue_free()
	Sfx.play("ui_click", -6.0, 0.0)
	var tw := card.create_tween()
	tw.tween_interval(seconds)
	tw.tween_property(card, "modulate:a", 0.0, 0.6)
	tw.tween_callback(card.queue_free)
