class_name TextEntry
extends PanelContainer
## The box for typing: new text for the canvas, correcting a text item, naming a document / canvas / room. Keys come from a physical
## (Bluetooth) keyboard or the on-screen one (VKeyboard, shown by the menu while this box is open); without a keyboard the pad lets
## you write the words with the stylus instead. One line for names (Enter accepts), several lines for text (Ctrl+Enter accepts).

signal accepted(text: String)
signal cancelled()
signal keyboard_toggled()

var title: Label
var mic_btn: Btn
var keyboard_btn: Btn
var pad: InkField

var _line: LineEdit
var _area: TextEdit
var allow_empty := false                   # OK with nothing typed is accepted (clearing a label) instead of cancelling

var _multiline := false
var _ok: Btn


func _init() -> void:
	add_theme_stylebox_override("panel", UITheme.box(UITheme.PANEL, 16, UITheme.ACCENT, 2))
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	title = Label.new()
	title.add_theme_font_size_override("font_size", UITheme.FONT)
	title.clip_text = true
	v.add_child(title)
	_line = LineEdit.new()
	_line.custom_minimum_size = Vector2(0, 56)
	_setup_field(_line)
	_line.text_submitted.connect(func(_t: String): _accept())
	v.add_child(_line)
	_area = TextEdit.new()
	_area.custom_minimum_size = Vector2(0, 120)
	_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_area.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_area.drag_and_drop_selection_enabled = false
	_setup_field(_area)
	v.add_child(_area)
	pad = InkField.new()
	pad.custom_minimum_size = Vector2(0, 120)
	pad.text_ready.connect(insert)
	pad.visible = false
	v.add_child(pad)
	var h := HBoxContainer.new()
	v.add_child(h)
	_ok = Btn.new("check", "OK")
	_ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ok.pressed.connect(_accept)
	h.add_child(_ok)
	mic_btn = Btn.new("mic", "Dictate")
	mic_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(mic_btn)
	keyboard_btn = Btn.new("keyboard", "", true)
	keyboard_btn.custom_minimum_size = Vector2(70, UITheme.ROW_H)
	keyboard_btn.pressed.connect(func(): keyboard_toggled.emit())
	h.add_child(keyboard_btn)
	var cancel := Btn.new("close", "")
	cancel.custom_minimum_size = Vector2(70, UITheme.ROW_H)
	cancel.pressed.connect(func(): cancelled.emit())
	h.add_child(cancel)
	visible = false


func _setup_field(f: Control) -> void:
	f.set("virtual_keyboard_enabled", false)          # our own keyboard is the on-screen one; never the system's
	f.set("context_menu_enabled", false)
	f.gui_input.connect(_field_key)


## Show the box. `multiline` is for text (several lines), otherwise for a name (one line).
func open(heading: String, text: String, multiline: bool, recognize: Callable, language: String, empty_ok: bool = false) -> void:
	title.text = heading
	allow_empty = empty_ok
	_multiline = multiline
	_line.visible = not multiline
	_area.visible = multiline
	_ok.text = "OK"
	pad.clear()
	pad.recognize_fn = recognize
	pad.language = language
	visible = true
	field().text = text
	field().grab_focus()
	_place_caret()


func _place_caret() -> void:
	if _multiline:
		_area.set_caret_line(_area.get_line_count() - 1)
		_area.set_caret_column(_area.get_line(_area.get_line_count() - 1).length())
	else:
		_line.caret_column = _line.text.length()
		if _line.text != "":
			_line.select_all()


func close() -> void:
	visible = false
	pad.clear()
	field().release_focus()


func is_open() -> bool:
	return visible


## The field being edited (also what the on-screen keyboard types into).
func field() -> Control:
	return _area if _multiline else _line


func text() -> String:
	return _area.text if _multiline else _line.text


## The pad: show it (write with the stylus) instead of the on-screen keyboard.
func show_pad(on: bool) -> void:
	pad.visible = on
	keyboard_btn.on = not on


## Words from the pad or from dictation: added at the caret, with a space between words.
func insert(words: String) -> void:
	words = words.strip_edges()
	if words == "":
		return
	if _multiline:
		var before := _area.get_line(_area.get_caret_line()).left(_area.get_caret_column())
		_area.insert_text_at_caret((" " if before != "" and not before.ends_with(" ") else "") + words)
	else:
		if _line.text == "" or _line.has_selection():
			_line.text = words
			_line.caret_column = words.length()
		else:
			_line.insert_text_at_caret((" " if not _line.text.ends_with(" ") else "") + words)


func _accept() -> void:
	var t := text().strip_edges()
	if t == "" and not allow_empty:
		cancelled.emit()
	else:
		accepted.emit(t)


func _field_key(e: InputEvent) -> void:
	if not (e is InputEventKey) or not (e as InputEventKey).pressed:
		return
	var k := e as InputEventKey
	if k.keycode == KEY_ESCAPE:
		cancelled.emit()
		get_viewport().set_input_as_handled()
	elif _multiline and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and (k.ctrl_pressed or k.meta_pressed):
		_accept()
		get_viewport().set_input_as_handled()

