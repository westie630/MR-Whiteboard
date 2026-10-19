class_name Btn
extends Control
## The one button of the interface: an optional vector icon and label on a rounded, anti-aliased box. Press, or toggle on and off.
## Works with the mouse and, in the headset, with pokes and pinch rays (they arrive as mouse events).

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

var _hover := false
var _down := false


func _init(icon_id: String = "", label: String = "", toggle: bool = false) -> void:
	icon = icon_id
	text = label
	toggle_mode = toggle
	custom_minimum_size = Vector2(0.0, UITheme.ROW_H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_entered.connect(func(): _hover = true; queue_redraw())
	mouse_exited.connect(func(): _hover = false; _down = false; queue_redraw())


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_down = true
		else:
			var inside := Rect2(Vector2.ZERO, size).has_point(mb.position)
			if _down and inside:
				if toggle_mode:
					on = not on
					toggled.emit(on)
				pressed.emit()
			_down = false
		queue_redraw()
		accept_event()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	var bg := UITheme.RAISED
	var border := Color(0, 0, 0, 0)
	var bw := 0
	if on:
		bg = UITheme.ACCENT_DIM if accent == UITheme.ACCENT else Color(accent.r, accent.g, accent.b, 0.22)
		border = accent
		bw = 2
	if _hover:
		bg = bg.lerp(Color.WHITE, 0.07)
	if _down:
		bg = bg.lerp(accent, 0.25)
	draw_style_box(UITheme.box(bg, UITheme.RADIUS if not small else 10, border, bw), r)
	var fg := accent if on else UITheme.TEXT
	if danger:
		fg = UITheme.BAD
	var font := ThemeDB.fallback_font
	if UITheme.theme().default_font != null:
		font = UITheme.theme().default_font
	var fs := UITheme.FONT_SMALL if (small or (text != "" and (icon != "" or swatch.a > 0.0) and size.y > size.x * 0.7)) else UITheme.FONT
	var has_icon := icon != "" or swatch.a > 0.0
	if has_icon and text == "":
		_draw_icon(Rect2(r.position + r.size * 0.2, r.size * 0.6), fg)
	elif not has_icon:
		_label(font, fs, r, fg)
	elif size.y > size.x * 0.7:
		# tile: icon above, label below
		var ih := size.y * 0.52
		_draw_icon(Rect2(Vector2((size.x - ih) * 0.5, size.y * 0.1), Vector2(ih, ih)), fg)
		_label(font, fs, Rect2(Vector2(0, size.y * 0.66), Vector2(size.x, size.y * 0.3)), fg)
	else:
		var ih2 := size.y * 0.56
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var total := ih2 + 10.0 + tw
		var x0 := (size.x - total) * 0.5
		_draw_icon(Rect2(Vector2(x0, (size.y - ih2) * 0.5), Vector2(ih2, ih2)), fg)
		_label(font, fs, Rect2(Vector2(x0 + ih2 + 10.0, 0), Vector2(tw + 4.0, size.y)), fg, HORIZONTAL_ALIGNMENT_LEFT)


func _draw_icon(r: Rect2, fg: Color) -> void:
	if swatch.a > 0.0:
		var c := r.get_center()
		var rad := minf(r.size.x, r.size.y) * 0.5
		draw_circle(c, rad, swatch)
		draw_arc(c, rad, 0.0, TAU, 40, Color(1, 1, 1, 0.55 if on else 0.2), 2.5 if on else 1.5, true)
	else:
		Icons.draw(self, icon, r, tint if tint.a > 0.0 else fg)


func _label(font: Font, fs: int, r: Rect2, col: Color, align: int = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var asc := font.get_ascent(fs)
	var desc := font.get_descent(fs)
	var y := r.position.y + (r.size.y + asc - desc) * 0.5
	draw_string(font, Vector2(r.position.x, y), text, align, r.size.x, fs, col)
