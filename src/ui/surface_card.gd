class_name SurfaceCard
extends FloatPanel
## Finding the desk: the card that stands on the dock while the stylus nib feels for a surface (SurfaceController). A plan of the points
## felt so far, one sentence on what is still needed (or how flat and level the desk is), and Done / Start over / Cancel.
## Lining a curved desk up with the real desk (SurfaceController.begin_align) shows on it too: which of the two touches is next, and Not now.

var _plot: SurfacePlot
var _line: Label
var _done: Btn
var _sub: Label
var _find: VBoxContainer
var _align: VBoxContainer
var _adots: AlignCard.StepDots
var _aline: Label


func _init() -> void:
	super()
	id = "surface"
	kind = "compose"
	pivot = Vector2(0.5, 1.0)
	max_size = Vector2(620, 420)
	add_theme_stylebox_override("panel", UITheme.glass(26, 16.0))
	var outer := VBoxContainer.new()
	add_child(outer)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(520, 0)
	outer.add_child(v)
	_find = v
	_build_align(outer)
	var head := UiKit.hrow(v, 12)
	var icon := Btn.new("desk", "")
	icon.variant = "tool"
	icon.accent = UITheme.DESK
	icon.on = true
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(46, 46)
	head.add_child(icon)
	var titles := UiKit.vcol(head, 0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UiKit.label("Find the desk", false, UITheme.FONT, 600))
	_sub = UiKit.label("", true, UITheme.FONT_TINY)
	titles.add_child(_sub)
	_plot = SurfacePlot.new()
	v.add_child(_plot)
	_line = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	_line.custom_minimum_size = Vector2(0, 52)
	v.add_child(_line)
	var row := UiKit.hrow(v, 8)
	_done = UiKit.chip("Done", func(): shell.board.surface.finish(), "check", 52.0)
	_done.accent = UITheme.DESK
	_done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_done)
	var again := UiKit.chip("Start over", func(): shell.board.surface.restart(), "undo", 52.0)
	again.variant = "ghost"
	row.add_child(again)
	var no := UiKit.chip("Cancel", func(): shell.board.surface.cancel(), "close", 52.0)
	no.variant = "ghost"
	row.add_child(no)


func _build_align(parent: Control) -> void:
	_align = VBoxContainer.new()
	_align.add_theme_constant_override("separation", 12)
	_align.custom_minimum_size = Vector2(520, 0)
	parent.add_child(_align)
	var head := UiKit.hrow(_align, 12)
	var icon := Btn.new("curve", "")
	icon.variant = "tool"
	icon.accent = UITheme.DESK
	icon.on = true
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.custom_minimum_size = Vector2(46, 46)
	head.add_child(icon)
	var titles := UiKit.vcol(head, 0)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(UiKit.label("Line it up with your desk", false, UITheme.FONT, 600))
	titles.add_child(UiKit.label("Two touches with the stylus tip", true, UITheme.FONT_TINY))
	_adots = AlignCard.StepDots.new()
	_align.add_child(_adots)
	_aline = UiKit.label("", false, UITheme.FONT_SMALL, 500)
	_aline.custom_minimum_size = Vector2(0, 56)
	_align.add_child(_aline)
	_align.add_child(UiKit.label("The canvas then starts at the edge, faces away from you along the desk and bends up so that it climbs the wall. The markers on its left edge still fine-tune the bend.", true, UITheme.FONT_TINY))
	var row := UiKit.hrow(_align, 8)
	var no := UiKit.chip("Not now", func(): shell.board.surface.cancel_align(), "close", 52.0)
	no.variant = "ghost"
	no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(no)


func refresh() -> void:
	var b: Board = shell.board
	var al := b.surface.align_status()
	_align.visible = bool(al.aligning)
	_find.visible = not bool(al.aligning)
	if bool(al.aligning):
		_adots.step = int(al.step)
		_adots.queue_redraw()
		if str(al.note) != "":
			_aline.text = str(al.note)
		elif int(al.step) == 0:
			_aline.text = "1. Touch the front edge of your desk with the stylus tip, right in front of you."
		else:
			_aline.text = "2. Now touch the wall behind the desk, low down. No wall? Touch the desk's far edge."
		return
	var st := b.surface.status()
	if not bool(st.finding):
		return
	var n := int(st.points)
	var target: FrameData = b.doc.frames.get(str(b.surface.calib.get("target", ""))) if b.doc != null else null
	_sub.text = ("Pins \"%s\" to it" % target.name) if target != null else "A new canvas will lie on it"
	_done.text = "Pin canvas here" if target != null else "Done"
	_done.disabled = not bool(st.ok)
	_done.on = bool(st.ok)
	if bool(st.ok):
		_line.text = "Desk found: %s, flat to %.1f mm from %d points. More points make it more exact." % [_level_text(float(st.tilt_deg)), float(st.rms_mm), n]
	elif n == 0:
		_line.text = "Press the stylus tip on your desk. It feels the surface when it touches."
	elif n < PlaneFit.MIN_POINTS:
		_line.text = "%d point%s. Press it in %d more place%s, a hand's width apart." % [n, "" if n == 1 else "s", PlaneFit.MIN_POINTS - n, "" if PlaneFit.MIN_POINTS - n == 1 else "s"]
	else:
		_line.text = SurfaceController.reason_text(str(st.reason))
	_plot.set_state(st)


func _level_text(tilt_deg: float) -> String:
	if tilt_deg < 1.0:
		return "level"
	if tilt_deg > 75.0:
		return "upright, like a wall"
	return "tilted %.1f° from level" % tilt_deg


## A plan of the surface: the points felt so far in the surface's own directions, with the area they span.
class SurfacePlot extends Control:
	var _st := {}

	func _init() -> void:
		custom_minimum_size = Vector2(0, 150)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_state(st: Dictionary) -> void:
		_st = st
		queue_redraw()

	func _draw() -> void:
		draw_style_box(UITheme.box(UITheme.WELL, 16), Rect2(Vector2.ZERO, size))
		var pts: PackedVector2Array = _st.get("plot", PackedVector2Array())
		var ok := bool(_st.get("ok", false))
		var col := UITheme.DESK if ok else UITheme.TEXT_DIM
		var pad := 22.0
		var inner := Rect2(Vector2(pad, pad), size - Vector2(pad, pad) * 2.0)
		# a faint desk-top outline in perspective, so an empty plot still says what is wanted
		var c := size * 0.5
		var top := PackedVector2Array([c + Vector2(-150, 34), c + Vector2(-96, -34), c + Vector2(96, -34), c + Vector2(150, 34)])
		draw_colored_polygon(top, Color(col.r, col.g, col.b, 0.07 if pts.size() > 0 else 0.1))
		draw_polyline(PackedVector2Array([top[0], top[1], top[2], top[3], top[0]]), Color(col.r, col.g, col.b, 0.35), 1.5, true)
		if pts.is_empty():
			draw_circle(c + Vector2(0, 4), 5.0, Color(col.r, col.g, col.b, 0.55))
			draw_arc(c + Vector2(0, 4), 12.0, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.3), 1.5, true)
			return
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in pts:
			lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
			hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
		var span := hi - lo
		var k := minf(inner.size.x / maxf(span.x, 0.12), inner.size.y / maxf(span.y, 0.12))
		k = minf(k, 1800.0)
		var mid := (lo + hi) * 0.5
		var map := func(p: Vector2) -> Vector2: return c + Vector2(p.x - mid.x, -(p.y - mid.y)) * k
		if ok:
			var a: Vector2 = map.call(lo)
			var b: Vector2 = map.call(hi)
			draw_rect(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs()).grow(8.0), Color(col.r, col.g, col.b, 0.1))
			draw_rect(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (b - a).abs()).grow(8.0), Color(col.r, col.g, col.b, 0.5), false, 1.5)
		for p in pts:
			var q: Vector2 = map.call(p)
			draw_circle(q, 7.0, Color(col.r, col.g, col.b, 0.22))
			draw_circle(q, 3.8, col)
		var tag := "%.0f x %.0f cm" % [span.x * 100.0, span.y * 100.0]
		draw_string(UITheme.font(500), Vector2(14, size.y - 12), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_TINY, Color(col.r, col.g, col.b, 0.8))
