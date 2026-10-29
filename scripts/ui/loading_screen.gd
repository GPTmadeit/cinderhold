extends CanvasLayer
## Full-screen loading overlay with a progress bar. It lives directly under
## the window root, so it survives scene changes: the menu opens it, the match
## keeps filling it, and it fades out once everything is built and warmed up.

const T := preload("res://scripts/ui/ui_theme.gd")
const NODE_NAME := "LoadingScreen"
const TIPS := [
	"Headshots are worth more points. Aim for the embers in their eyes.",
	"Doors open new ground, and new vents for the Husks to crawl out of.",
	"The Ember Forge doubles a weapon's bite. It costs 5000 points.",
	"Downed allies bleed out in 35 seconds. Hold Interact to revive them.",
	"Brutes enrage when wounded. Keep your distance.",
	"The Relic Cache can grant the Cinderbolt. Feeling lucky?",
	"Second Wind lets you get back up on your own when playing solo.",
	"Runners don't shamble. Clear an escape route before round three.",
]

var _bar: ProgressBar
var _stage: Label
var _pct: Label
var _tip: Label
var _note: Label
var _root: Control
var _target := 0.0
var _shown := 0.0
var _tip_t := 0.0
var _closing := false


## The open loading screen, creating it if needed.
static func open(tree: SceneTree, stage := "") -> Node:
	var ls: Node = tree.root.get_node_or_null(NODE_NAME)
	if ls == null or ls.is_queued_for_deletion():
		ls = load("res://scripts/ui/loading_screen.gd").new()
		ls.name = NODE_NAME
		tree.root.add_child(ls)
	if stage != "":
		ls.set_progress(ls._target, stage)
	return ls


static func find(tree: SceneTree) -> Node:
	var ls: Node = tree.root.get_node_or_null(NODE_NAME)
	return ls if ls and not ls.is_queued_for_deletion() else null


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.theme = T.get_theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	var g := Gradient.new()
	g.set_color(0, Color("1d1217"))
	g.set_color(1, Color("070506"))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.75)
	gt.fill_to = Vector2(1.1, 0.0)
	bg.texture = gt
	_root.add_child(bg)
	_root.add_child(_embers())

	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(cc)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	cc.add_child(v)
	var title := T.title("CINDERHOLD", 92)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size.y = 26
	v.add_child(gap)

	var row := HBoxContainer.new()
	_stage = T.label("Lighting the braziers…", 22, T.EMBER_SOFT, true)
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pct = T.label("0%", 22, T.MUTED, true)
	row.add_child(_stage)
	row.add_child(_pct)
	v.add_child(row)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(620, 12)
	_bar.max_value = 1.0
	_bar.show_percentage = false
	var fill := T.box(T.EMBER, Color(0, 0, 0, 0), 0, 4, 0)
	fill.shadow_color = Color(1.0, 0.45, 0.1, 0.55)
	fill.shadow_size = 8
	_bar.add_theme_stylebox_override("fill", fill)
	_bar.add_theme_stylebox_override("background", T.box(Color(1, 1, 1, 0.06), Color(1, 0.55, 0.25, 0.2), 1, 4, 0))
	v.add_child(_bar)
	var gap2 := Control.new()
	gap2.custom_minimum_size.y = 18
	v.add_child(gap2)
	_tip = T.label(TIPS[randi() % TIPS.size()], 20, T.MUTED)
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.custom_minimum_size.x = 620
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_tip)
	_note = T.label("", 15, Color(1, 1, 1, 0.4))
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_note)


## A small line under the tips (the map's data credit).
func set_note(text: String) -> void:
	if _note:
		_note.text = text


func _embers() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = 70
	p.lifetime = 7.0
	p.preprocess = 7.0
	p.position = Vector2(800, 960)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(900, 10)
	p.direction = Vector2(0.15, -1)
	p.spread = 18.0
	p.gravity = Vector2(6, -12)
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 110.0
	p.scale_amount_min = 2.0
	p.scale_amount_max = 5.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.75, 0.3, 0.0))
	ramp.add_point(0.15, Color(1.0, 0.6, 0.2, 0.9))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.9, 0.2, 0.05, 0.0))
	p.color_ramp = ramp
	return p


## Progress never moves backwards, so stages can report rough fractions.
func set_progress(f: float, stage := "") -> void:
	_target = clampf(maxf(f, _target), 0.0, 1.0)
	if stage != "" and _stage:
		_stage.text = stage


func close() -> void:
	if _closing:
		return
	_closing = true
	_target = 1.0
	var tw := create_tween()
	tw.tween_interval(0.15)
	tw.tween_property(_root, "modulate:a", 0.0, 0.45)
	tw.tween_callback(queue_free)


func _process(dt: float) -> void:
	_shown = move_toward(_shown, _target, dt * maxf(1.5, (_target - _shown) * 6.0))
	_bar.value = _shown
	_pct.text = "%d%%" % roundi(_shown * 100.0)
	_tip_t += dt
	if _tip_t > 4.5:
		_tip_t = 0.0
		_tip.text = TIPS[randi() % TIPS.size()]
