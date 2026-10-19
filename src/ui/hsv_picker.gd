class_name HsvPicker
extends Control
## Colour picker: a saturation / brightness square and a hue strip, drawn as vector gradients.

signal color_changed(color: Color)

var hue := 0.12
var sat := 0.6
var val := 1.0

var _drag := ""                             # "sv" | "hue"


func _init() -> void:
	custom_minimum_size = Vector2(300, 200)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_meta("drag_ctrl", true)


func set_color(c: Color) -> void:
	hue = c.h
	sat = c.s
	val = c.v
	queue_redraw()


func current() -> Color:
	return Color.from_hsv(hue, sat, val, 1.0)


func _sv_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(size.x - 56.0, size.y))


func _hue_rect() -> Rect2:
	return Rect2(Vector2(size.x - 40.0, 0.0), Vector2(40.0, size.y))


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_drag = "hue" if _hue_rect().grow(8.0).has_point(mb.position) else ("sv" if _sv_rect().has_point(mb.position) else "")
			_apply(mb.position)
		else:
			_drag = ""
		accept_event()
	elif e is InputEventMouseMotion and _drag != "":
		_apply((e as InputEventMouseMotion).position)
		accept_event()


func _apply(p: Vector2) -> void:
	if _drag == "sv":
		var r := _sv_rect()
		sat = clampf((p.x - r.position.x) / r.size.x, 0.0, 1.0)
		val = 1.0 - clampf((p.y - r.position.y) / r.size.y, 0.0, 1.0)
	elif _drag == "hue":
		var r2 := _hue_rect()
		hue = clampf((p.y - r2.position.y) / r2.size.y, 0.0, 0.999)
	else:
		return
	queue_redraw()
	color_changed.emit(current())


func _draw() -> void:
	var r := _sv_rect()
	var pure := Color.from_hsv(hue, 1.0, 1.0)
	draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]),
		PackedColorArray([Color.WHITE, pure, Color.BLACK, Color.BLACK]))
	draw_rect(r, Color(1, 1, 1, 0.18), false, 1.5)
	var h := _hue_rect()
	var n := 24
	for i in n:
		var y0 := h.position.y + h.size.y * float(i) / n
		var y1 := h.position.y + h.size.y * float(i + 1) / n
		var c0 := Color.from_hsv(float(i) / n, 1, 1)
		var c1 := Color.from_hsv(float(i + 1) / n, 1, 1)
		draw_polygon(PackedVector2Array([Vector2(h.position.x, y0), Vector2(h.end.x, y0), Vector2(h.end.x, y1 + 0.5), Vector2(h.position.x, y1 + 0.5)]),
			PackedColorArray([c0, c0, c1, c1]))
	draw_rect(h, Color(1, 1, 1, 0.18), false, 1.5)
	var sp := Vector2(r.position.x + sat * r.size.x, r.position.y + (1.0 - val) * r.size.y)
	draw_circle(sp, 13.0, Color(0, 0, 0, 0.5))
	draw_circle(sp, 11.0, Color.WHITE)
	draw_circle(sp, 8.0, current())
	var hp := Vector2(h.get_center().x, h.position.y + hue * h.size.y)
	draw_circle(hp, 15.0, Color(0, 0, 0, 0.5))
	draw_circle(hp, 13.0, Color.WHITE)
	draw_circle(hp, 9.0, pure)
