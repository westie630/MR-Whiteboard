class_name Btn
extends Control
## The one button of the interface: an optional vector icon and label on a rounded, anti-aliased box. Press, or toggle on and off.
## Works with the mouse and, in the headset, with pokes and pinch rays (they arrive as mouse events).
##
## Looks (`variant`):  ""     a raised tile (lists, grids)
##                     "tool"  icon only, no box until hovered or on (the dock, bars on the canvas)
##                     "chip"  a pill with a small label (choices, readings)
##                     "ghost" text only, no box until hovered (secondary actions)

signal pressed()
signal toggled(on: bool)

var icon := "":
	set(v):
		icon = v
		queue_redraw()
var text := "":
	set(v):
		text = v
		queue_redraw()
var toggle_mode := false
var on := false:
	set(v):
		on = v
		queue_redraw()
var accent := UITheme.ACCENT
var tint := Color(0, 0, 0, 0)               # icon colour override (e.g. a colour swatch)
var swatch := Color(0, 0, 0, 0)             # a solid round colour chip instead of an icon
var small := false
var danger := false
var variant := "":
	set(v):
		variant = v
		queue_redraw()
var hint := ""                              # what it does, shown as a tooltip by the surface it is on
var disabled := false:                      # drawn faint and ignores presses
	set(v):
		disabled = v
		queue_redraw()
var badge := Color(0, 0, 0, 0)              # a small dot in the top right corner (something waiting)
var busy := false:                          # a turning arc around the icon (working)
	set(v):
		busy = v
		set_process(v)
		queue_redraw()
var marker := false                         # a small caret under the icon: this button has options (tap again)
var font_weight := 400
var font_size := 0                          # 0: chosen by the look
var align := HORIZONTAL_ALIGNMENT_CENTER    # left: list rows (icon at the left edge, then the label)

const HINT_DELAY := 0.45

var _hover := false
var _down := false
var _spin := 0.0
var _hover_t := 0.0


func _init(icon_id: String = "", label: String = "", toggle: bool = false) -> void:
	icon = icon_id
	text = label
	toggle_mode = toggle
	custom_minimum_size = Vector2(0.0, UITheme.ROW_H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	set_process(false)
	mouse_entered.connect(func():
		_hover = true
		_hover_t = 0.0
		if hint != "":
			set_process(true)
		queue_redraw())
	mouse_exited.connect(func():
		_hover = false
		_down = false
		z_index = 0
		set_process(busy)
		queue_redraw())


func is_hovered() -> bool:
	return _hover


func _process(delta: float) -> void:
	if busy:
		_spin = fmod(_spin + delta * 5.0, TAU)
		queue_redraw()
	if _hover and hint != "":
		var was := _hover_t >= HINT_DELAY
		_hover_t += delta
		if (_hover_t >= HINT_DELAY) != was:
			z_index = 10
			queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_down = not disabled
		else:
			var inside := Rect2(Vector2.ZERO, size).has_point(mb.position)
			if _down and inside and not disabled:
				if toggle_mode:
					on = not on
					toggled.emit(on)
				pressed.emit()
			_down = false
		queue_redraw()
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var fg := accent if on else UITheme.TEXT
	if danger:
		fg = UITheme.BAD
	match variant:
		"tool":
			_draw_tool_bg(r)
		"chip":
			_draw_chip_bg(r)
		"ghost":
			var gr := int(minf(size.y * 0.5, 14.0))
			if on:
				draw_style_box(UITheme.box(Color(accent.r, accent.g, accent.b, 0.14), gr), r)
			if _hover or _down:
				draw_style_box(UITheme.box(Color(1, 1, 1, 0.1 if _down else 0.06), gr), r)
			fg = accent if on else (UITheme.TEXT if _hover else UITheme.TEXT_DIM)
			if danger:
				fg = UITheme.BAD
		_:
			_draw_tile_bg(r)
	if disabled:
		fg = Color(fg.r, fg.g, fg.b, 0.3)
	var font := UITheme.font(font_weight)
	var has_icon := icon != "" or swatch.a > 0.0
	var tile := has_icon and text != "" and size.y > size.x * 0.7 and variant != "chip" and variant != "ghost"
	var fs := UITheme.FONT_SMALL if (small or variant == "chip" or variant == "ghost" or tile) else UITheme.FONT
	if tile and small:
		fs = UITheme.FONT_TINY + 1
	if font_size > 0:
		fs = font_size
	if has_icon and text == "":
		var k := 0.5 if variant == "tool" else 0.6
		var ir := Rect2(r.position + r.size * (1.0 - k) * 0.5, r.size * k)
		if marker:
			ir.position.y -= size.y * 0.04
		_draw_icon(ir, fg)
	elif not has_icon:
		_label(font, fs, r.grow_individual(-14.0, 0, -14.0, 0) if align == HORIZONTAL_ALIGNMENT_LEFT else r, fg, align)
	elif tile:
		# tile: icon above, label below
		var ih := size.y * 0.52
		_draw_icon(Rect2(Vector2((size.x - ih) * 0.5, size.y * 0.1), Vector2(ih, ih)), fg)
		_label(font, fs, Rect2(Vector2(0, size.y * 0.66), Vector2(size.x, size.y * 0.3)), fg)
	else:
		var ih2 := size.y * (0.46 if variant == "chip" or variant == "ghost" else 0.5)
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var total := ih2 + 10.0 + tw
		var x0 := 16.0 if align == HORIZONTAL_ALIGNMENT_LEFT else maxf((size.x - total) * 0.5, 8.0)
		_draw_icon(Rect2(Vector2(x0, (size.y - ih2) * 0.5), Vector2(ih2, ih2)), fg)
		_label(font, fs, Rect2(Vector2(x0 + ih2 + 10.0, 0), Vector2(minf(tw + 4.0, size.x - x0 - ih2 - 14.0), size.y)), fg, HORIZONTAL_ALIGNMENT_LEFT)
	if marker:
		var c := Vector2(size.x * 0.5, size.y * 0.86)
		var mk := size.y * 0.05
		draw_polyline(PackedVector2Array([c + Vector2(-mk, mk * 0.5), c + Vector2(0, -mk * 0.5), c + Vector2(mk, mk * 0.5)]), Color(fg.r, fg.g, fg.b, 0.55), 1.6, true)
	if badge.a > 0.0:
		var bc := Vector2(size.x - size.x * 0.22, size.y * 0.22)
		draw_circle(bc, 6.0, UITheme.GLASS)
		draw_circle(bc, 4.2, badge)
	if busy:
		var rad := minf(size.x, size.y) * 0.42
		draw_arc(r.get_center(), rad, _spin, _spin + PI * 1.2, 32, Color(accent.r, accent.g, accent.b, 0.9), 2.5, true)
	_draw_hint_if_needed()


func _draw_hint_if_needed() -> void:
	if _hover and hint != "" and _hover_t >= HINT_DELAY and not _down:
		_draw_hint()


## The tooltip: a small dark pill above the button.
func _draw_hint() -> void:
	var f := UITheme.font(500)
	var fs := UITheme.FONT_TINY + 1
	var tw := f.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var br := Rect2(Vector2((size.x - tw) * 0.5 - 12.0, -40.0), Vector2(tw + 24.0, 30.0))
	draw_style_box(UITheme.box(Color(0.02, 0.025, 0.035, 0.96), 15, Color(1, 1, 1, 0.12), 1), br)
	draw_string(f, Vector2(br.position.x + 12.0, br.position.y + 20.5), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, UITheme.TEXT)


func _draw_tile_bg(r: Rect2) -> void:
	var bg := UITheme.RAISED
	var border := Color(0, 0, 0, 0)
	var bw := 0
	if on:
		bg = UITheme.ACCENT_DIM if accent == UITheme.ACCENT else Color(accent.r, accent.g, accent.b, 0.22)
		border = accent
		bw = 2
	if _hover and not disabled:
		bg = bg.lerp(Color.WHITE, 0.07)
	if _down:
		bg = bg.lerp(accent, 0.25)
	draw_style_box(UITheme.box(bg, UITheme.RADIUS if not small else 10, border, bw), r)


func _draw_tool_bg(r: Rect2) -> void:
	var rad := int(minf(r.size.x, r.size.y) * 0.3)
	if on and swatch.a <= 0.0:
		draw_style_box(UITheme.box(Color(accent.r, accent.g, accent.b, 0.17), rad), r)
	if _hover and not disabled:
		draw_style_box(UITheme.box(Color(1, 1, 1, 0.07), rad), r)
	if _down:
		draw_style_box(UITheme.box(Color(accent.r, accent.g, accent.b, 0.25), rad), r)


func _draw_chip_bg(r: Rect2) -> void:
	var rad := int(r.size.y * 0.5)
	var bg := UITheme.WELL_HI
	var border := Color(0, 0, 0, 0)
	var bw := 0
	if on:
		bg = Color(accent.r, accent.g, accent.b, 0.18)
		border = Color(accent.r, accent.g, accent.b, 0.85)
		bw = 1
	if _hover and not disabled:
		bg = bg.lerp(Color.WHITE, 0.08)
	if _down:
		bg = bg.lerp(accent, 0.25)
	var sb := UITheme.box(bg, rad, border, bw)
	draw_style_box(sb, r)


func _draw_icon(r: Rect2, fg: Color) -> void:
	if swatch.a > 0.0:
		var c := r.get_center()
		var rad := minf(r.size.x, r.size.y) * 0.5
		if on:
			draw_arc(c, rad + 5.0, 0.0, TAU, 48, accent, 2.5, true)
		draw_circle(c, rad, swatch)
		draw_arc(c, rad, 0.0, TAU, 40, Color(1, 1, 1, 0.3 if swatch.get_luminance() < 0.2 else 0.12), 1.5, true)
	else:
		Icons.draw(self, icon, r, tint if tint.a > 0.0 else fg)


func _label(font: Font, fs: int, r: Rect2, col: Color, h_align: int = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var asc := font.get_ascent(fs)
	var desc := font.get_descent(fs)
	var y := r.position.y + (r.size.y + asc - desc) * 0.5
	draw_string(font, Vector2(r.position.x, y), fit_text(font, text, fs, r.size.x), h_align, r.size.x, fs, col)


## The text, shortened with an ellipsis when it is wider than `w`.
static func fit_text(font: Font, t: String, fs: int, w: float) -> String:
	if w <= 0.0 or font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
		return t
	var lo := 0
	var hi := t.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if font.get_string_size(t.left(mid) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= w:
			lo = mid
		else:
			hi = mid - 1
	return t.left(lo).strip_edges() + "…"
