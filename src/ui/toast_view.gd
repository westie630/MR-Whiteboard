class_name ToastView
extends FloatPanel
## A short message from the board ("Snapped to circle", "Reading handwriting...", what went wrong), as a pill near the middle of the
## view that fades away by itself. Messages that warn are marked in the warning colour.

const SHOW_S := 3.6

var max_width := 620.0                     # the host narrows it when side panels leave less room
var _label: Label
var _dot: ColorRect
var _t := 0.0


func _init() -> void:
	super()
	id = "toast"
	kind = "toast"
	pivot = Vector2(0.5, 0.5)
	max_size = Vector2(760, 140)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := UITheme.glass(26, 10.0)
	sb.content_margin_left = 20
	sb.content_margin_right = 22
	add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_dot = ColorRect.new()
	_dot.custom_minimum_size = Vector2(8, 8)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_dot)
	_label = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(0, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_label)


func show_text(text: String) -> void:
	_label.text = text
	var low := text.to_lower()
	var warn := low.contains("could not") or low.contains("no ") or low.contains("failed") or low.contains("not ") or low.contains("error")
	_dot.color = UITheme.WARN if warn else UITheme.ACCENT
	# wrap long messages at a comfortable width
	var w := UITheme.font(500).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SMALL).x
	_label.custom_minimum_size.x = minf(w + 4.0, minf(max_width - 60.0, 560.0))
	_t = SHOW_S + minf(text.length() * 0.03, 3.0)
	wanted = true
	size = Vector2.ZERO


func text() -> String:
	return _label.text


func tick(delta: float) -> void:
	if _t > 0.0:
		_t -= delta
		if _t <= 0.0:
			wanted = false
