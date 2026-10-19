class_name UITheme
extends RefCounted
## Colours, metrics and the Godot Theme for every panel. Everything is vector: rounded boxes are anti-aliased StyleBoxFlat,
## icons are drawn in code (Icons), so the interface stays sharp at any size and in the headset.

const BG := Color(0.055, 0.07, 0.1, 0.96)
const PANEL := Color(0.09, 0.115, 0.16, 1.0)
const RAISED := Color(0.13, 0.165, 0.225, 1.0)
const HOVER := Color(0.18, 0.23, 0.31, 1.0)
const ACCENT := Color("#3fe0c8")
const ACCENT_DIM := Color(0.25, 0.88, 0.78, 0.22)
const TEXT := Color(0.92, 0.95, 1.0)
const TEXT_DIM := Color(0.62, 0.69, 0.8)
const WARN := Color("#ffd166")
const BAD := Color("#ef476f")
const GOOD := Color("#06d6a0")

const FONT := 22
const FONT_SMALL := 17
const FONT_BIG := 28
const ROW_H := 56.0
const GAP := 10
const RADIUS := 14

const PALETTE := [
	"#ffffff", "#ffd166", "#ff9f43", "#ef476f", "#ff5d8f", "#c77dff", "#7b6cff", "#4ea8ff",
	"#3fe0c8", "#06d6a0", "#a3e635", "#9aa5b8", "#4b5563", "#111827",
]

static var _theme: Theme


static func box(color: Color, radius: int = RADIUS, border: Color = Color(0, 0, 0, 0), border_w: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	s.anti_aliasing_size = 1.0
	s.corner_detail = 12
	if border_w > 0:
		s.border_color = border
		s.set_border_width_all(border_w)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	return s


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = TextLayout.font()
	t.default_font_size = FONT
	for cls in ["Button", "CheckButton", "OptionButton", "MenuButton"]:
		t.set_stylebox("normal", cls, box(RAISED))
		t.set_stylebox("hover", cls, box(HOVER))
		t.set_stylebox("pressed", cls, box(ACCENT_DIM, RADIUS, ACCENT, 2))
		t.set_stylebox("disabled", cls, box(Color(RAISED.r, RAISED.g, RAISED.b, 0.5)))
		t.set_stylebox("focus", cls, StyleBoxEmpty.new())
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, Color.WHITE)
		t.set_color("font_pressed_color", cls, ACCENT)
		t.set_color("font_disabled_color", cls, TEXT_DIM)
		t.set_font_size("font_size", cls, FONT)
	t.set_color("font_color", "Label", TEXT)
	t.set_font_size("font_size", "Label", FONT)
	t.set_stylebox("panel", "PanelContainer", box(BG, 22))
	t.set_stylebox("normal", "LineEdit", box(Color(0.04, 0.05, 0.08, 1.0), 10, Color(1, 1, 1, 0.12), 1))
	t.set_stylebox("focus", "LineEdit", box(Color(0.04, 0.05, 0.08, 1.0), 10, ACCENT, 2))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_font_size("font_size", "LineEdit", FONT)
	t.set_constant("separation", "VBoxContainer", GAP)
	t.set_constant("separation", "HBoxContainer", GAP)
	t.set_constant("h_separation", "GridContainer", GAP)
	t.set_constant("v_separation", "GridContainer", GAP)
	t.set_stylebox("scroll", "VScrollBar", box(Color(1, 1, 1, 0.05), 6))
	t.set_stylebox("grabber", "VScrollBar", box(Color(1, 1, 1, 0.3), 6))
	t.set_stylebox("grabber_highlight", "VScrollBar", box(Color(1, 1, 1, 0.45), 6))
	t.set_stylebox("grabber_pressed", "VScrollBar", box(ACCENT, 6))
	_theme = t
	return t
