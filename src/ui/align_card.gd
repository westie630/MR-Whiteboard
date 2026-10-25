class_name AlignCard
extends FloatPanel
## Lining up with the session: the card that stands on the dock while the stylus tip touches the two real places that everybody in the
## room lines up on (Session.align_begin). Which point is next, what makes a good pair, and Cancel.

var _dots: StepDots
var _line: Label
var _tip: Label
var _sub: Label


func _init() -> void:
	super()
	id = "align"
	kind = "compose"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(620, 380)
	add_theme_stylebox_override("panel", UITheme.glass(26, 16.0))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(520, 0)
	add_child(v)
	var head := UiKit.hrow(v, 12)
	var icon := Btn.new("align", "")
	icon.variant = "tool"
	icon.accent = UITheme.DESK
	icon.on = true
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(46, 46)
	head.add_child(icon)
	var titles := UiKit.vcol(head, 0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UiKit.label("Line up with the session", false, UITheme.FONT, 600))
	_sub = UiKit.label("", true, UITheme.FONT_TINY)
	titles.add_child(_sub)
	_dots = StepDots.new()
	v.add_child(_dots)
	_line = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	_line.custom_minimum_size = Vector2(0, 56)
	v.add_child(_line)
	_tip = UiKit.label("Pick two places that everyone can reach and that are far apart, like two corners of a table. Everyone touches the same two places, in the same order.", true, UITheme.FONT_TINY)
	v.add_child(_tip)
	var row := UiKit.hrow(v, 8)
	var no := UiKit.chip("Cancel", func(): shell.board.session.align_cancel(), "close", 52.0)
	no.variant = "ghost"
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(no)


func refresh() -> void:
	var s: Session = shell.board.session
	var st := s.align_status()
	if not bool(st.aligning):
		return
	var step := int(st.step)
	_sub.text = "You are the owner: the guests line up on your points" if s.is_host() else "Touch the same two places as the owner"
	_dots.step = step
	if str(st.note) != "":
		_line.text = str(st.note)
	elif step == 0:
		_line.text = "Press the stylus tip on the first point, or pinch your fingers on it, and hold still for a moment."
	else:
		_line.text = "Got it. Now the second point, at least %d cm from the first. The further apart, the more exact." % int(SharedSpace.MIN_SPAN * 100.0)
	_dots.queue_redraw()


## Two numbered points joined by a line: the one to touch next is ringed, the one done is filled.
class StepDots extends Control:
	var step := 0

	func _init() -> void:
		custom_minimum_size = Vector2(0, 76)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_style_box(UITheme.box(UITheme.WELL, 16), Rect2(Vector2.ZERO, size))
		var a := Vector2(size.x * 0.28, size.y * 0.5)
		var b := Vector2(size.x * 0.72, size.y * 0.5)
		draw_line(a, b, Color(UITheme.DESK.r, UITheme.DESK.g, UITheme.DESK.b, 0.35), 2.0, true)
		for i in 2:
			var p := a if i == 0 else b
			var done := i < step
			var current := i == step
			var col := UITheme.DESK if (done or current) else UITheme.TEXT_FAINT
			if done:
				draw_circle(p, 17.0, col)
			else:
				draw_circle(p, 17.0, Color(col.r, col.g, col.b, 0.14))
				draw_arc(p, 17.0, 0.0, TAU, 32, col, 2.5 if current else 1.5, true)
			draw_string(UITheme.font(700), p + Vector2(-5.5, 7.0), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SMALL, Color(0.06, 0.07, 0.1) if done else col)
