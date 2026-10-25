class_name BatteryGauge
extends Control
## A small battery: a vector cell filled to the charge with the percentage under it (a bolt while charging). Quiet while there is
## plenty, amber at 30 % and red at 15 %. It reads the device now and then and hides itself when there is no battery to show.

const POLL_S := 30.0

var level := -1
var charging := false
var _t := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(46, UITheme.TOOL)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _ready() -> void:
	poll()


func _process(delta: float) -> void:
	_t += delta
	if _t >= POLL_S:
		poll()


func poll() -> void:
	_t = 0.0
	var b := Battery.read()
	set_state(int(b.get("level", -1)), bool(b.get("charging", false)))


func set_state(lvl: int, is_charging: bool) -> void:
	if lvl != level or is_charging != charging:
		level = lvl
		charging = is_charging
		queue_redraw()
	visible = level >= 0


func tint() -> Color:
	if charging:
		return UITheme.GOOD
	if level <= 15:
		return UITheme.BAD
	if level <= 30:
		return UITheme.WARN
	return UITheme.TEXT_DIM


func _draw() -> void:
	if level < 0:
		return
	var col := tint()
	var w := 28.0
	var h := 14.0
	var body := Rect2(Vector2((size.x - w - 3.0) * 0.5, size.y * 0.5 - h - 1.0), Vector2(w, h))
	draw_style_box(UITheme.box(Color(0, 0, 0, 0), 4, Color(col.r, col.g, col.b, 0.8), 2), body)
	draw_rect(Rect2(body.end.x + 1.0, body.position.y + 4.0, 3.0, h - 8.0), Color(col.r, col.g, col.b, 0.8))
	var inner := body.grow(-3.5)
	var fill := Rect2(inner.position, Vector2(maxf(2.0, inner.size.x * level / 100.0), inner.size.y))
	draw_rect(fill, col)
	if charging:
		var c := body.get_center()
		var bolt := PackedVector2Array([c + Vector2(1.5, -6), c + Vector2(-4, 1), c + Vector2(-0.5, 1), c + Vector2(-1.5, 6),
			c + Vector2(4, -1), c + Vector2(0.5, -1)])
		draw_colored_polygon(bolt, Color(0.02, 0.03, 0.04, 0.9))
	var f := UITheme.font(600 if level <= 15 else 500)
	var txt := "%d%%" % level
	var fs := UITheme.FONT_TINY
	var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(f, Vector2((size.x - tw) * 0.5, body.end.y + 17.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col if level <= 30 or charging else UITheme.TEXT_DIM)
