extends Control
## On-screen controls for phones and tablets: a floating move stick on the
## left (push to the rim to sprint), drag-to-look on the right, and action
## buttons. Buttons drive the regular input actions so gameplay code is shared.

const T := preload("res://scripts/ui/ui_theme.gd")

var hud: Node

const BUTTONS := [
	# action, label, anchor offset from bottom-right, radius
	["fire", "FIRE", Vector2(-150, -170), 74.0],
	["aim", "AIM", Vector2(-310, -110), 50.0],
	["jump", "JUMP", Vector2(-120, -330), 46.0],
	["reload", "R", Vector2(-280, -260), 42.0],
	["interact", "USE", Vector2(-420, -190), 46.0],
	["melee", "MELEE", Vector2(-410, -70), 40.0],
	["next_weapon", "SWAP", Vector2(-240, -400), 40.0],
	["crouch", "DUCK", Vector2(-100, -470), 36.0],
]

var _move_finger := -1
var _move_origin := Vector2.ZERO
var _move_pos := Vector2.ZERO
var _look_finger := -1
var _look_last := Vector2.ZERO
var _btn_fingers := {}       # finger -> action
var _aim_toggled := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pause := T.button("II", func(): hud.set_paused(true), 64)
	pause.alignment = HORIZONTAL_ALIGNMENT_CENTER
	pause.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pause.position = Vector2(-90, 20)
	add_child(pause)


func _button_center(i: int) -> Vector2:
	return size + BUTTONS[i][2]


func _button_at(p: Vector2) -> int:
	for i in BUTTONS.size():
		if p.distance_to(_button_center(i)) <= BUTTONS[i][3] * 1.15:
			return i
	return -1


func _input(event: InputEvent) -> void:
	if hud.menu_open():
		_release_all()
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			var b := _button_at(event.position)
			if b >= 0:
				var action: String = BUTTONS[b][0]
				if action == "aim":
					_aim_toggled = not _aim_toggled
					if _aim_toggled:
						Input.action_press("aim")
					else:
						Input.action_release("aim")
				else:
					_btn_fingers[event.index] = action
					_press(action)
				# firing also steers the camera with the same finger
				if action == "fire" and _look_finger == -1:
					_look_finger = event.index
					_look_last = event.position
			elif event.position.x < size.x * 0.42 and _move_finger == -1:
				_move_finger = event.index
				_move_origin = event.position
				_move_pos = event.position
			elif _look_finger == -1:
				_look_finger = event.index
				_look_last = event.position
		else:
			if _btn_fingers.has(event.index):
				Input.action_release(_btn_fingers[event.index])
				_btn_fingers.erase(event.index)
			if event.index == _move_finger:
				_move_finger = -1
				_set_move(Vector2.ZERO)
			if event.index == _look_finger:
				_look_finger = -1
		queue_redraw()
	elif event is InputEventScreenDrag:
		if event.index == _move_finger:
			_move_pos = event.position
			var v: Vector2 = (_move_pos - _move_origin) / 90.0
			_set_move(v.limit_length(1.4))
			queue_redraw()
		elif event.index == _look_finger and hud.player:
			var d: Vector2 = event.position - _look_last
			_look_last = event.position
			hud.player.add_look(d * 0.0045 * float(Settings.get_v("gameplay", "touch_look")))


func _press(action: String) -> void:
	# just_pressed-style actions need a real event so _unhandled_input sees them
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	if action in ["reload", "interact", "melee", "next_weapon", "jump"]:
		var up := InputEventAction.new()
		up.action = action
		up.pressed = false
		# keep interact held for revives; others release next frame
		if action != "interact":
			get_tree().create_timer(0.08).timeout.connect(func(): Input.parse_input_event(up))


func _set_move(v: Vector2) -> void:
	var sprint := v.length() > 1.15
	var n := v.limit_length(1.0)
	_axis("move_right", "move_left", n.x)
	_axis("move_back", "move_forward", n.y)
	if sprint:
		Input.action_press("sprint")
	else:
		Input.action_release("sprint")


func _axis(pos: String, neg: String, value: float) -> void:
	if value > 0.05:
		Input.action_press(pos, value)
		Input.action_release(neg)
	elif value < -0.05:
		Input.action_press(neg, -value)
		Input.action_release(pos)
	else:
		Input.action_release(pos)
		Input.action_release(neg)


func _release_all() -> void:
	for f in _btn_fingers:
		Input.action_release(_btn_fingers[f])
	_btn_fingers.clear()
	_move_finger = -1
	_look_finger = -1
	_set_move(Vector2.ZERO)


func _process(_dt: float) -> void:
	_assist()
	queue_redraw()


## Gentle aim assist: while firing or aiming, ease toward the nearest head
## that is already close to the crosshair.
func _assist() -> void:
	if not bool(Settings.get_v("gameplay", "aim_assist")) or hud.player == null or hud.game == null:
		return
	var p = hud.player
	if not (Input.is_action_pressed("fire") or _aim_toggled) or p.camera == null:
		return
	var cam: Camera3D = p.camera
	var fwd := -cam.global_basis.z
	var best = null
	var best_dot := cos(deg_to_rad(7.0))
	for e in hud.game.enemies.values():
		if e.dying:
			continue
		var to: Vector3 = (e.global_position + Vector3.UP * 1.65) - cam.global_position
		if to.length() > 30.0:
			continue
		var d := fwd.dot(to.normalized())
		if d > best_dot:
			best_dot = d
			best = to
	if best == null:
		return
	var want_yaw := atan2(-best.x, -best.z)
	var want_pitch := atan2(best.y, Vector2(best.x, best.z).length())
	var dy := wrapf(want_yaw - p.yaw, -PI, PI)
	var dp: float = want_pitch - p.pitch
	var k := 0.06
	p.yaw += dy * k
	p.pitch += dp * k


func _draw() -> void:
	var faint := Color(1, 1, 1, 0.12)
	var ring := Color(1, 0.6, 0.3, 0.35)
	if _move_finger != -1:
		draw_circle(_move_origin, 90.0, faint)
		draw_arc(_move_origin, 90.0, 0, TAU, 48, ring, 3.0)
		var knob := _move_origin + (_move_pos - _move_origin).limit_length(110.0)
		draw_circle(knob, 38.0, Color(1, 0.6, 0.3, 0.5 if (_move_pos - _move_origin).length() > 103.0 else 0.3))
	else:
		var hint := Vector2(200, size.y - 200)
		draw_arc(hint, 80.0, 0, TAU, 48, Color(1, 1, 1, 0.08), 2.0)
	var font := T.BOLD_FONT
	for i in BUTTONS.size():
		var c := _button_center(i)
		var r: float = BUTTONS[i][3]
		var action: String = BUTTONS[i][0]
		var held := action in _btn_fingers.values() or (action == "aim" and _aim_toggled)
		draw_circle(c, r, Color(1, 0.5, 0.2, 0.35) if held else Color(0.05, 0.04, 0.04, 0.45))
		draw_arc(c, r, 0, TAU, 40, ring, 2.5)
		var label: String = BUTTONS[i][1]
		var fs := 22 if r > 45.0 else 17
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, c + Vector2(-w / 2.0, fs * 0.35), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.85))
