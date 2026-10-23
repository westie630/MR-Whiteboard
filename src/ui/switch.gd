class_name Switch
extends Control
## A settings row: a label (and an optional line under it) on the left, a vector toggle switch on the right. The whole row toggles.

signal toggled(on: bool)

var text := ""
var sub := ""
var on := false:
	set(v):
		if v != on:
			on = v
			queue_redraw()

var _hover := false
var _down := false
var _knob := 0.0                           # 0 off .. 1 on, eased


func _init(label: String = "", subtitle: String = "") -> void:
	text = label
	sub = subtitle
	custom_minimum_size = Vector2(0, 64 if subtitle != "" else 48)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_entered.connect(func(): _hover = true; queue_redraw())
	mouse_exited.connect(func(): _hover = false; _down = false; queue_redraw())


func _process(delta: float) -> void:
	var goal := 1.0 if on else 0.0
	if not is_equal_approx(_knob, goal):
		_knob = move_toward(_knob, goal, delta * 7.0)
		queue_redraw()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_down = true
		elif _down:
			_down = false
			if Rect2(Vector2.ZERO, size).has_point(mb.position):
				on = not on
				toggled.emit(on)
		accept_event()


func _draw() -> void:
	if _hover:
		draw_style_box(UITheme.box(Color(1, 1, 1, 0.04), 12), Rect2(Vector2.ZERO, size))
	var f := UITheme.font()
	var tw := 58.0
	var th := 32.0
	var text_w := size.x - tw - 26.0
	var y := size.y * 0.5
	if sub != "":
		draw_string(f, Vector2(8, y - 4), text, HORIZONTAL_ALIGNMENT_LEFT, text_w, UITheme.FONT_SMALL, UITheme.TEXT)
		draw_string(f, Vector2(8, y + 18), sub, HORIZONTAL_ALIGNMENT_LEFT, text_w, UITheme.FONT_TINY, UITheme.TEXT_DIM)
	else:
		draw_string(f, Vector2(8, y + 6), text, HORIZONTAL_ALIGNMENT_LEFT, text_w, UITheme.FONT_SMALL, UITheme.TEXT)
	var k := smoothstep(0.0, 1.0, _knob)
	var track := Rect2(Vector2(size.x - tw - 8.0, y - th * 0.5), Vector2(tw, th))
	var off_col := Color(1, 1, 1, 0.16)
	draw_style_box(UITheme.box(off_col.lerp(Color(UITheme.ACCENT.r, UITheme.ACCENT.g, UITheme.ACCENT.b, 0.9), k), int(th * 0.5)), track)
	var kr := th * 0.5 - 4.0
	var kx := lerpf(track.position.x + th * 0.5, track.end.x - th * 0.5, k)
	draw_circle(Vector2(kx, y), kr, Color(1, 1, 1, 0.96))
