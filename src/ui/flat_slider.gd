class_name FlatSlider
extends Control
## A slider drawn entirely in vector graphics: slim rounded track, accent fill, round handle. Drag anywhere on it.

signal value_changed(value: float)

var min_value := 0.0
var max_value := 1.0
var step := 0.0
var value := 0.5:
	set(v):
		value = clampf(snappedf(v, step) if step > 0.0 else v, min_value, max_value)
		queue_redraw()
var accent := UITheme.ACCENT

var _drag := false


func _init(lo: float = 0.0, hi: float = 1.0, initial: float = 0.5, step_size: float = 0.0) -> void:
	min_value = lo
	max_value = hi
	step = step_size
	value = initial
	custom_minimum_size = Vector2(120, 44)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_meta("drag_ctrl", true)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_drag = (e as InputEventMouseButton).pressed
		if _drag:
			_set_from(e.position.x)
		accept_event()
	elif e is InputEventMouseMotion and _drag:
		_set_from((e as InputEventMouseMotion).position.x)
		accept_event()


func _set_from(x: float) -> void:
	var pad := 16.0
	var t := clampf((x - pad) / maxf(size.x - pad * 2.0, 1.0), 0.0, 1.0)
	var v := lerpf(min_value, max_value, t)
	var before := value
	value = v
	if not is_equal_approx(before, value):
		value_changed.emit(value)


func _draw() -> void:
	var pad := 16.0
	var y := size.y * 0.5
	var t := inverse_lerp(min_value, max_value, value)
	var x := pad + (size.x - pad * 2.0) * t
	var track := Rect2(Vector2(pad - 6.0, y - 5.0), Vector2(size.x - pad * 2.0 + 12.0, 10.0))
	draw_style_box(UITheme.box(Color(0.03, 0.04, 0.07, 1.0), 5), track)
	var fill := Rect2(track.position, Vector2(x - track.position.x + 2.0, 10.0))
	draw_style_box(UITheme.box(accent, 5), fill)
	draw_circle(Vector2(x, y), 15.0, Color(0, 0, 0, 0.35))
	draw_circle(Vector2(x, y), 13.0, Color.WHITE)
	draw_circle(Vector2(x, y), 6.5, accent)
