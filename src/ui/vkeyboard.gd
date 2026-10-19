class_name VKeyboard
extends Control
## The on-screen keyboard: vector-drawn keys that send real InputEventKey events to the text field that has focus, exactly like a
## physical keyboard would, so LineEdit and TextEdit need no special code. Keys fire on press (like a keyboard), backspace and the
## arrows repeat while held. Letters, symbols, shift (tap: one capital, double tap: caps lock), caret arrows and enter.

signal hide_requested()

const GAP := 6.0
const KEY_H := 58.0
const REPEAT_DELAY := 0.42
const REPEAT_EVERY := 0.055
const DOUBLE_TAP_S := 0.4

const NUMBERS := "1234567890"
const LETTERS := ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
const SYMBOLS := ["@#$%&-+()/", "*\"':;!?\\^|", "=<>[]{}"]

var target: Control                          # the field that receives the keys (the focused one is used when this has lost focus)

var _symbols := false
var _shift := 0                              # 0 off, 1 one capital, 2 caps lock
var _last_shift_tap := -10.0
var _keys: Array = []                        # [{rect, kind, ch, label, code}]
var _layout_sig := ""
var _hover := -1
var _down := -1
var _held := -1
var _held_t := 0.0
var _repeating := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(0, KEY_H * 5.0 + GAP * 4.0)
	set_meta("drag_ctrl", true)             # the headset panel must not wait to tell a tap from a scroll here
	mouse_exited.connect(func():
		_hover = -1
		_down = -1
		_held = -1
		queue_redraw())


# ------------------------------------------------------------------------------------------------ layout

func _rows() -> Array:
	var rows: Array = []
	var nums: Array = []
	for ch in NUMBERS:
		nums.append({"kind": "char", "ch": ch, "w": 1.0})
	rows.append(nums)
	var src: Array = SYMBOLS if _symbols else LETTERS
	var r1: Array = []
	for ch in (SYMBOLS[0] if _symbols else LETTERS[0]):
		r1.append({"kind": "char", "ch": ch, "w": 1.0})
	rows.append(r1)
	var r2: Array = []
	if not _symbols:
		r2.append({"kind": "pad", "w": 0.5})
	for ch in (SYMBOLS[1] if _symbols else LETTERS[1]):
		r2.append({"kind": "char", "ch": ch, "w": 1.0})
	if not _symbols:
		r2.append({"kind": "pad", "w": 0.5})
	rows.append(r2)
	var r3: Array = []
	r3.append({"kind": "shift", "w": 1.5} if not _symbols else {"kind": "char", "ch": "_", "w": 1.5})
	for ch in src[2]:
		r3.append({"kind": "char", "ch": ch, "w": 1.0})
	r3.append({"kind": "back", "w": 1.5})
	rows.append(r3)
	rows.append([
		{"kind": "mode", "w": 1.5}, {"kind": "char", "ch": ",", "w": 1.0}, {"kind": "left", "w": 1.0}, {"kind": "char", "ch": " ", "w": 3.0, "space": true},
		{"kind": "right", "w": 1.0}, {"kind": "char", "ch": ".", "w": 1.0}, {"kind": "enter", "w": 1.5},
	])
	return rows


func _build_layout() -> void:
	var sig := "%s|%s|%d" % [str(size), _symbols, _shift]
	if sig == _layout_sig:
		return
	_layout_sig = sig
	_keys.clear()
	var rows := _rows()
	var kh := (size.y - GAP * float(rows.size() - 1)) / float(rows.size())
	for ri in rows.size():
		var row: Array = rows[ri]
		var units := 0.0
		for k in row:
			units += float(k.w)
		var unit := (size.x - GAP * float(row.size() - 1)) / units
		var x := 0.0
		for k in row:
			var w := float(k.w) * unit
			if k.kind != "pad":
				var key: Dictionary = (k as Dictionary).duplicate()
				key.rect = Rect2(x, float(ri) * (kh + GAP), w, kh)
				_keys.append(key)
			x += w + GAP


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout_sig = ""
		queue_redraw()


func _key_at(p: Vector2) -> int:
	_build_layout()
	for i in _keys.size():
		if (_keys[i].rect as Rect2).grow(GAP * 0.5).has_point(p):
			return i
	return -1


# ------------------------------------------------------------------------------------------------ input

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var h := _key_at((e as InputEventMouseMotion).position)
		if h != _hover:
			_hover = h
			queue_redraw()
		accept_event()
	elif e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_down = _key_at(mb.position)
			if _down >= 0:
				_press(_down)
				var kind: String = _keys[_down].kind
				if kind in ["back", "left", "right"]:
					_held = _down
					_held_t = 0.0
					_repeating = false
		else:
			_down = -1
			_held = -1
		queue_redraw()
		accept_event()


func _process(delta: float) -> void:
	if _held < 0 or _held >= _keys.size():
		return
	_held_t += delta
	if not _repeating:
		if _held_t >= REPEAT_DELAY:
			_repeating = true
			_held_t = 0.0
	elif _held_t >= REPEAT_EVERY:
		_held_t = 0.0
		_press(_held, true)


func _press(i: int, echo: bool = false) -> void:
	var k: Dictionary = _keys[i]
	match str(k.kind):
		"char":
			var ch := str(k.ch)
			if not _symbols and _shift > 0:
				ch = ch.to_upper()
			send_char(ch)
			if _shift == 1:
				_shift = 0
				_layout_sig = ""
		"back":
			send_key(KEY_BACKSPACE, echo)
		"enter":
			send_key(KEY_ENTER)
		"left":
			send_key(KEY_LEFT, echo)
		"right":
			send_key(KEY_RIGHT, echo)
		"shift":
			var now := Time.get_ticks_msec() / 1000.0
			if _shift == 2:
				_shift = 0
			elif _shift == 1 and now - _last_shift_tap < DOUBLE_TAP_S:
				_shift = 2
			elif _shift == 1:
				_shift = 0
			else:
				_shift = 1
			_last_shift_tap = now
			_layout_sig = ""
		"mode":
			_symbols = not _symbols
			_layout_sig = ""
	queue_redraw()


## Type one character (any unicode character works, the layout is only a convenience).
func send_char(ch: String) -> void:
	var e := InputEventKey.new()
	var code := ch.unicode_at(0)
	e.pressed = true
	e.unicode = code
	e.keycode = _keycode_for(ch)
	e.physical_keycode = e.keycode
	e.key_label = e.keycode
	_deliver(e)
	var up := e.duplicate() as InputEventKey
	up.pressed = false
	_deliver(up)


func send_key(code: int, echo: bool = false) -> void:
	var e := InputEventKey.new()
	e.pressed = true
	e.echo = echo
	e.keycode = code as Key
	e.physical_keycode = code as Key
	e.key_label = code as Key
	_deliver(e)
	var up := e.duplicate() as InputEventKey
	up.pressed = false
	up.echo = false
	_deliver(up)


static func _keycode_for(ch: String) -> Key:
	if ch == " ":
		return KEY_SPACE
	var code := OS.find_keycode_from_string(ch.to_upper())
	return code if code != KEY_NONE else (ch.unicode_at(0) as Key)


func _deliver(e: InputEventKey) -> void:
	var f := _field()
	if f == null:
		return
	if not f.has_focus():
		f.grab_focus()
	get_viewport().push_input(e, false)


func _field() -> Control:
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null and (focus is LineEdit or focus is TextEdit):
		return focus
	if is_instance_valid(target):
		return target
	return null


# ------------------------------------------------------------------------------------------------ drawing

func _draw() -> void:
	_build_layout()
	var font := UITheme.theme().default_font
	for i in _keys.size():
		var k: Dictionary = _keys[i]
		var r: Rect2 = k.rect
		var kind: String = k.kind
		var special := kind != "char" or str(k.ch) == " "
		var bg := UITheme.RAISED if not special else Color(0.105, 0.135, 0.19, 1.0)
		var fg := UITheme.TEXT
		if kind == "shift" and _shift > 0:
			bg = UITheme.ACCENT_DIM
			fg = UITheme.ACCENT
		if kind == "mode" and _symbols:
			fg = UITheme.ACCENT
		if i == _hover:
			bg = bg.lerp(Color.WHITE, 0.07)
		if i == _down:
			bg = bg.lerp(UITheme.ACCENT, 0.4)
		draw_style_box(UITheme.box(bg, 10, UITheme.ACCENT if (kind == "shift" and _shift == 2) else Color(0, 0, 0, 0), 2 if (kind == "shift" and _shift == 2) else 0), r)
		match kind:
			"char":
				if bool(k.get("space", false)):
					draw_line(r.get_center() + Vector2(-r.size.x * 0.18, 0), r.get_center() + Vector2(r.size.x * 0.18, 0), Color(fg.r, fg.g, fg.b, 0.35), 2.0, true)
				else:
					var ch := str(k.ch)
					if not _symbols and _shift > 0:
						ch = ch.to_upper()
					_text(font, ch, r, fg, 28)
			"mode":
				_text(font, "abc" if _symbols else "123", r, fg, 22)
			"shift":
				Icons.draw(self, "shift", r.grow_individual(-r.size.x * 0.28, -r.size.y * 0.2, -r.size.x * 0.28, -r.size.y * 0.2), fg)
			"back":
				Icons.draw(self, "backspace", r.grow_individual(-r.size.x * 0.3, -r.size.y * 0.2, -r.size.x * 0.3, -r.size.y * 0.2), fg)
			"enter":
				Icons.draw(self, "enter", r.grow_individual(-r.size.x * 0.3, -r.size.y * 0.2, -r.size.x * 0.3, -r.size.y * 0.2), UITheme.ACCENT)
			"left":
				Icons.draw(self, "left", r.grow_individual(-r.size.x * 0.25, -r.size.y * 0.2, -r.size.x * 0.25, -r.size.y * 0.2), fg)
			"right":
				Icons.draw(self, "right", r.grow_individual(-r.size.x * 0.25, -r.size.y * 0.2, -r.size.x * 0.25, -r.size.y * 0.2), fg)


func _text(font: Font, s: String, r: Rect2, col: Color, fs: int) -> void:
	var asc := font.get_ascent(fs)
	var desc := font.get_descent(fs)
	draw_string(font, Vector2(r.position.x, r.position.y + (r.size.y + asc - desc) * 0.5), s, HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, col)


# ------------------------------------------------------------------------------------------------ test hooks

## The centre of the key that types `ch` (or of a special key by its kind), in this control's coordinates; (-1,-1) when there is none.
func key_centre(what: String) -> Vector2:
	_build_layout()
	for k in _keys:
		if str(k.kind) == what or (str(k.kind) == "char" and str(k.ch) == what):
			return (k.rect as Rect2).get_center()
	return Vector2(-1, -1)


func is_symbols() -> bool:
	return _symbols


func shift_state() -> int:
	return _shift
