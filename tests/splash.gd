extends Control
## Renders the boot splash image (run via tests/shot.sh, saved to assets/splash.png).
const T := preload("res://scripts/ui/ui_theme.gd")
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := TextureRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var g := Gradient.new()
	g.set_color(0, Color("1d1217"))
	g.set_color(1, Color("070506"))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.75)
	gt.fill_to = Vector2(1.1, 0.0)
	bg.texture = gt
	add_child(bg)
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(cc)
	var v := VBoxContainer.new()
	cc.add_child(v)
	var t := T.title("CINDERHOLD", 92)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var s := T.label("HOLD THE LINE UNTIL DAWN", 24, T.EMBER_SOFT, true)
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(s)
	add_child(load("res://scripts/core/dev_tools.gd").new())
