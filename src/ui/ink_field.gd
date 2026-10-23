class_name InkField
extends Control
## A small writing pad for the headset, where there is no keyboard: write a name with the stylus (or a finger poke, or the mouse),
## pause, and the handwriting recogniser turns it into text. Used for naming documents, canvases and rooms.

signal text_ready(text: String)

const IDLE_S := 0.9

var recognize_fn := Callable()              # (strokes, area, language, done) like InkRecognizer.recognize
var language := "en"
var status := "Write here"

var _strokes: Array = []                    # [{pts: PackedVector2Array, t: PackedFloat32Array}]
var _cur: PackedVector2Array
var _cur_t: PackedFloat32Array
var _down := false
var _idle := 0.0
var _busy := false


func _init() -> void:
	custom_minimum_size = Vector2(360, 120)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_meta("drag_ctrl", true)


func clear() -> void:
	_strokes.clear()
	_cur = PackedVector2Array()
	status = "Write here"
	queue_redraw()


func _process(delta: float) -> void:
	if _strokes.is_empty() or _down or _busy:
		return
	_idle += delta
	if _idle >= IDLE_S:
		_idle = 0.0
		_recognize()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		_down = mb.pressed
		if mb.pressed:
			_cur = PackedVector2Array([mb.position])
			_cur_t = PackedFloat32Array([Time.get_ticks_msec()])
			_idle = 0.0
		elif _cur.size() > 0:
			_strokes.append({"pts": _cur, "t": _cur_t})
			_cur = PackedVector2Array()
			_cur_t = PackedFloat32Array()
		queue_redraw()
		accept_event()
	elif e is InputEventMouseMotion and _down:
		var p := (e as InputEventMouseMotion).position
		if _cur.is_empty() or _cur[_cur.size() - 1].distance_to(p) > 2.0:
			_cur.append(p)
			_cur_t.append(Time.get_ticks_msec())
			queue_redraw()
		accept_event()


func _recognize() -> void:
	if not recognize_fn.is_valid() or _strokes.is_empty():
		return
	_busy = true
	status = "Reading..."
	queue_redraw()
	var strokes: Array = []
	var t0 := float((_strokes[0].t as PackedFloat32Array)[0])
	var all := PackedVector2Array()
	for s in _strokes:
		all.append_array(s.pts)
	var lo := all[0]
	var hi := all[0]
	for p in all:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var k := 150.0 / maxf(hi.y - lo.y, 24.0)
	for s in _strokes:
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var ts := PackedFloat32Array()
		for i in (s.pts as PackedVector2Array).size():
			xs.append((s.pts[i].x - lo.x) * k + 20.0)
			ys.append((s.pts[i].y - lo.y) * k + 20.0)
			ts.append(float(s.t[i]) - t0)
		strokes.append({"x": xs, "y": ys, "t": ts})
	var area := Vector2((hi.x - lo.x) * k + 40.0, (hi.y - lo.y) * k + 40.0)
	recognize_fn.call(strokes, area, language, func(res: Dictionary):
		_busy = false
		if bool(res.ok):
			status = "Write here"
			var txt := str(res.candidates[0]).strip_edges()
			_strokes.clear()
			queue_redraw()
			if txt != "":
				text_ready.emit(txt)
		else:
			status = str(res.error)
			_strokes.clear()
			queue_redraw())


func _draw() -> void:
	draw_style_box(UITheme.box(Color(0.03, 0.04, 0.07, 1.0), 12, Color(1, 1, 1, 0.14), 1), Rect2(Vector2.ZERO, size))
	var base_y := size.y * 0.72
	draw_line(Vector2(16, base_y), Vector2(size.x - 16, base_y), Color(1, 1, 1, 0.12), 1.5, true)
	if _strokes.is_empty() and _cur.is_empty():
		var font := TextLayout.font()
		draw_string(font, Vector2(18, size.y * 0.5 + 8), status, HORIZONTAL_ALIGNMENT_LEFT, size.x - 36, UITheme.FONT_SMALL, UITheme.TEXT_DIM)
	for s in _strokes:
		draw_polyline(s.pts, UITheme.WARN, 4.0, true)
	if _cur.size() > 1:
		draw_polyline(_cur, UITheme.WARN, 4.0, true)
