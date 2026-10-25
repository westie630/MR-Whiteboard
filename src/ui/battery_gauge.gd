class_name BatteryGauge
extends Control
## A small battery: a vector cell filled to the charge with the percentage under it (a bolt while charging). Quiet while there is
## plenty, amber at 30 % and red at 15 %. It reads the device now and then and hides itself when there is no battery to show.

const POLL_S := 30.0
const HINT_DELAY := 0.45

var level := -1
var charging := false
var status := Callable()                   # -> String, shown as a tooltip while hovered: the stylus's state (the headset knows no stylus charge)
var _t := 0.0
var _hover := false
var _hover_t := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(46, UITheme.TOOL)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	mouse_entered.connect(func():
		_hover = true
		_hover_t = 0.0
		z_index = 10
		queue_redraw())
	mouse_exited.connect(func():
		_hover = false
		z_index = 0
		queue_redraw())


func _ready() -> void:
	poll()


func _process(delta: float) -> void:
	_t += delta
	if _t >= POLL_S:
		poll()
	if _hover:
		_hover_t += delta
		queue_redraw()                       # the stylus's state can change under the pointer


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


## What the stylus is doing, in a few words, from the pen of the latest frame.
static func stylus_text(pen: PenState) -> String:
	if pen == null:
		return ""
	match pen.source:
		"stylus":
			if pen.docked:
				return "Stylus: in its dock"
			return "Stylus: connected" + (", pen down" if pen.down else "")
		"mouse":
			return "Pen: mouse or tablet"
	return "Stylus: not found. Is it on?"


## The tooltip, like Btn's: a dark pill above, lined up with the gauge's right edge since the gauge ends the dock.
func _draw_status() -> void:
	if not _hover or _hover_t < HINT_DELAY or not status.is_valid():
		return
	var txt := str(status.call())
	if txt == "":
		return
	var f := UITheme.font(500)
	var fs := UITheme.FONT_TINY + 1
	var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var br := Rect2(Vector2(size.x + 6.0 - tw - 24.0, -40.0), Vector2(tw + 24.0, 30.0))
	draw_style_box(UITheme.box(Color(0.02, 0.025, 0.035, 0.96), 15, Color(1, 1, 1, 0.12), 1), br)
	draw_string(f, Vector2(br.position.x + 12.0, br.position.y + 20.5), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.TEXT)


func _draw() -> void:
	if level < 0:
		return
	_draw_status()
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
