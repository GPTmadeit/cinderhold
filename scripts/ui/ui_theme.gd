## The shared look: soot-black panels, ember accents, Bungee headings.

const EMBER := Color("ff8a3a")
const EMBER_SOFT := Color("ffc58a")
const TEXT := Color("efe4d6")
const MUTED := Color("a89a8e")
const PANEL := Color(0.07, 0.055, 0.06, 0.92)
const DISPLAY_FONT := preload("res://assets/fonts/Bungee-Regular.ttf")
const BODY_FONT := preload("res://assets/fonts/Rajdhani-SemiBold.ttf")
const BOLD_FONT := preload("res://assets/fonts/Rajdhani-Bold.ttf")

static var _theme: Theme


static func box(bg: Color, border := Color(0, 0, 0, 0), bw := 0, radius := 6, margin := 12.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	s.anti_aliasing = true
	return s


static func get_theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = BODY_FONT
	t.default_font_size = 22

	# Buttons: a left ember bar slides in on hover.
	var normal := box(Color(0.1, 0.08, 0.085, 0.88), Color(1, 0.55, 0.25, 0.18), 1, 4, 18)
	var hover := box(Color(0.18, 0.1, 0.07, 0.95), EMBER, 1, 4, 18)
	hover.border_width_left = 5
	var pressed := box(Color(0.3, 0.13, 0.06, 1.0), EMBER, 2, 4, 18)
	var disabled := box(Color(0.08, 0.07, 0.07, 0.6), Color(1, 1, 1, 0.05), 1, 4, 18)
	var focus := box(Color(0, 0, 0, 0), EMBER_SOFT, 2, 4, 18)
	for cls in ["Button", "OptionButton", "CheckButton", "CheckBox"]:
		t.set_stylebox("normal", cls, normal)
		t.set_stylebox("hover", cls, hover)
		t.set_stylebox("pressed", cls, pressed)
		t.set_stylebox("hover_pressed", cls, pressed)
		t.set_stylebox("disabled", cls, disabled)
		t.set_stylebox("focus", cls, focus)
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, EMBER_SOFT)
		t.set_color("font_pressed_color", cls, Color.WHITE)
		t.set_color("font_focus_color", cls, EMBER_SOFT)
		t.set_color("font_disabled_color", cls, Color(1, 1, 1, 0.3))
		t.set_font("font", cls, BOLD_FONT)
		t.set_font_size("font_size", cls, 24)
	for cls in ["CheckButton", "CheckBox"]:
		t.set_stylebox("normal", cls, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 6))
		t.set_stylebox("hover", cls, box(Color(1, 0.55, 0.25, 0.08), Color(0, 0, 0, 0), 0, 4, 6))
		t.set_stylebox("pressed", cls, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 6))
		t.set_stylebox("hover_pressed", cls, box(Color(1, 0.55, 0.25, 0.08), Color(0, 0, 0, 0), 0, 4, 6))
		t.set_font_size("font_size", cls, 21)

	var panel := box(PANEL, Color(1, 0.55, 0.25, 0.22), 1, 10, 22)
	panel.shadow_color = Color(0, 0, 0, 0.5)
	panel.shadow_size = 18
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)

	var field := box(Color(0.03, 0.025, 0.03, 0.9), Color(1, 0.55, 0.25, 0.25), 1, 4, 10)
	var field_focus := box(Color(0.05, 0.035, 0.035, 0.95), EMBER, 1, 4, 10)
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", field_focus)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", EMBER)
	t.set_color("selection_color", "LineEdit", Color(1, 0.5, 0.2, 0.35))
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.3))

	var track := box(Color(1, 1, 1, 0.08), Color(0, 0, 0, 0), 0, 3, 0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := box(EMBER, Color(0, 0, 0, 0), 0, 3, 0)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_icon("grabber", "HSlider", _dot(18, EMBER_SOFT))
	t.set_icon("grabber_highlight", "HSlider", _dot(20, Color.WHITE))

	var bar_bg := box(Color(0, 0, 0, 0.55), Color(1, 1, 1, 0.08), 1, 3, 0)
	var bar_fill := box(EMBER, Color(0, 0, 0, 0), 0, 3, 0)
	t.set_stylebox("background", "ProgressBar", bar_bg)
	t.set_stylebox("fill", "ProgressBar", bar_fill)
	t.set_color("font_color", "ProgressBar", TEXT)

	var tab_sel := box(Color(0.2, 0.1, 0.06, 1.0), EMBER, 0, 4, 16)
	tab_sel.border_width_bottom = 3
	var tab_un := box(Color(0.08, 0.065, 0.07, 0.9), Color(0, 0, 0, 0), 0, 4, 16)
	var tab_hover := box(Color(0.14, 0.09, 0.07, 0.95), Color(0, 0, 0, 0), 0, 4, 16)
	t.set_stylebox("tab_selected", "TabContainer", tab_sel)
	t.set_stylebox("tab_unselected", "TabContainer", tab_un)
	t.set_stylebox("tab_hovered", "TabContainer", tab_hover)
	t.set_stylebox("panel", "TabContainer", box(Color(0.05, 0.04, 0.045, 0.6), Color(1, 0.55, 0.25, 0.12), 1, 6, 18))
	t.set_font("font", "TabContainer", BOLD_FONT)
	t.set_font_size("font_size", "TabContainer", 22)
	t.set_color("font_selected_color", "TabContainer", EMBER_SOFT)
	t.set_color("font_unselected_color", "TabContainer", MUTED)
	t.set_color("font_hovered_color", "TabContainer", TEXT)

	var popup := box(Color(0.08, 0.06, 0.065, 0.98), Color(1, 0.55, 0.25, 0.3), 1, 6, 8)
	t.set_stylebox("panel", "PopupMenu", popup)
	t.set_stylebox("hover", "PopupMenu", box(Color(0.3, 0.13, 0.06, 1.0), Color(0, 0, 0, 0), 0, 4, 8))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", EMBER_SOFT)
	t.set_font("font", "PopupMenu", BOLD_FONT)
	t.set_font_size("font_size", "PopupMenu", 22)

	t.set_stylebox("panel", "TooltipPanel", popup)
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("scroll", "VScrollBar", box(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 0, 3, 2))
	t.set_stylebox("grabber", "VScrollBar", box(Color(1, 0.55, 0.25, 0.35), Color(0, 0, 0, 0), 0, 3, 2))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(EMBER, Color(0, 0, 0, 0), 0, 3, 2))
	t.set_constant("separation", "VBoxContainer", 10)
	t.set_constant("separation", "HBoxContainer", 10)
	_theme = t
	return t


static func _dot(size: int, c: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var r := size / 2.0
	for x in size:
		for y in size:
			var d := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			img.set_pixel(x, y, Color(c.r, c.g, c.b, clampf(r - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func title(text: String, size := 64, color := EMBER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("shadow_offset_y", 4)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_outline_size", 8)
	return l


static func label(text: String, size := 22, color := TEXT, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if bold:
		l.add_theme_font_override("font", BOLD_FONT)
	return l


static func button(text: String, cb: Callable, min_w := 320.0) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(min_w, 52)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(func(): Sfx.play("ui_click", -4.0, 0.0))
	b.pressed.connect(cb)
	b.mouse_entered.connect(func(): if not b.disabled: Sfx.play("ui_hover", -14.0, 0.0))
	return b


## A centred dark scrim behind modal panels.
static func scrim(alpha := 0.55) -> ColorRect:
	var c := ColorRect.new()
	c.color = Color(0.02, 0.01, 0.015, alpha)
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	return c
