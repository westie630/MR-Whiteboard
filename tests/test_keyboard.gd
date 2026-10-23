extends Node
## Typing: the on-screen keyboard (pressed with synthetic pointer events, like a poke in the headset) and a physical keyboard (key
## events) both fill the text box; the box places new text, edits text, labels a shape and names things; wrapping keeps line breaks.

var _t: TestCase


func _ready() -> void:
	_t = TestCase.new("keyboard")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_keyboard"
	App.reload()
	App.put("vkeyboard", true)

	_t.eq(TextController.wrap_text("one two three four five", 9), "one two\nthree\nfour five", "words wrap at the limit")
	_t.eq(TextController.wrap_text("first line\nsecond line", 30), "first line\nsecond line", "typed line breaks stay")
	_t.eq(TextController.wrap_text("a\n\nb", 30), "a\n\nb", "blank lines stay")

	# the keyboard types into a LineEdit and a TextEdit through real key events, in a SubViewport like the headset menu
	var vp := SubViewport.new()
	vp.size = Vector2i(560, 520)
	vp.handle_input_locally = true
	add_child(vp)
	var line := LineEdit.new()
	line.virtual_keyboard_enabled = false
	line.size = Vector2(500, 50)
	vp.add_child(line)
	var area := TextEdit.new()
	area.virtual_keyboard_enabled = false
	area.position = Vector2(0, 60)
	area.size = Vector2(500, 100)
	vp.add_child(area)
	var kb := VKeyboard.new()
	kb.position = Vector2(0, 170)
	kb.size = Vector2(560, 330)
	vp.add_child(kb)
	await get_tree().process_frame
	await get_tree().process_frame
	line.grab_focus()
	for ch in "hello":
		await _tap(vp, kb, ch)
	_t.eq(line.text, "hello", "letters are typed")
	await _tap(vp, kb, "shift")
	_t.eq(kb.shift_state(), 1, "shift arms one capital")
	await _tap(vp, kb, "w")
	_t.eq(line.text, "helloW", "one capital")
	_t.eq(kb.shift_state(), 0, "shift releases itself")
	await _tap(vp, kb, "back")
	await _tap(vp, kb, "back")
	_t.eq(line.text, "hell", "backspace deletes")
	await _tap(vp, kb, "left")
	await _tap(vp, kb, "x")
	_t.eq(line.text, "helxl", "the arrow moves the caret")
	await _tap(vp, kb, "mode")
	_t.check(kb.is_symbols(), "the symbol layer opens")
	await _tap(vp, kb, "7")
	await _tap(vp, kb, "@")
	_t.eq(line.text, "helx7@l", "digits and symbols are typed at the caret")
	await _tap(vp, kb, "mode")
	_t.check(not kb.is_symbols(), "back to letters")

	area.grab_focus()
	await _tap(vp, kb, "a")
	await _tap(vp, kb, "enter")
	await _tap(vp, kb, "b")
	_t.eq(area.text, "a\nb", "enter makes a new line in a text box")
	_t.check(area.has_focus(), "the keys do not take the focus away from the field")

	# the menu and the board
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors_keyboard.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Keyboard test"))
	board.head_provider = func(): return Transform3D(Basis.IDENTITY, Vector3(0.0, 1.4, 0.0))
	var pen := PenState.new()
	var ui := UiShell.new()
	add_child(ui)
	ui.setup(board)
	var mvp := SubViewport.new()                           # the typing card on its own, as on its headset panel
	mvp.size = Vector2i(ui.compose.max_size)
	mvp.handle_input_locally = true
	add_child(mvp)
	mvp.add_child(ui.compose)
	for _i in 100:
		board.tick(pen, [], 0.016)
		await get_tree().process_frame
	_t.check(not ui.open_text_entry(), "no canvas: the box does not open")
	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1)))
	for _i in 60:
		board.tick(pen, [], 0.016)
		await get_tree().process_frame

	ui.open_popover("brush")
	_t.check(ui.open_text_entry(), "with a canvas the box opens")
	await get_tree().process_frame
	await get_tree().process_frame
	var entry := ui.compose.entry
	_t.check(ui.entry_open() and ui.is_typing() and entry.field().has_focus(), "the box has the keyboard focus")
	_t.check(ui.compose.visible and ui.compose.keyboard.visible, "the typing card shows with the on-screen keyboard")
	_t.eq(ui.popover_id, "", "typing closes the popover that was open")
	_t.check(ui.compose.get_combined_minimum_size().y <= ui.compose.max_size.y and ui.compose.get_combined_minimum_size().x <= ui.compose.max_size.x,
		"the typing card fits its panel (%s)" % str(ui.compose.get_combined_minimum_size()))
	# a physical keyboard: key events pushed to the card's viewport
	for ch in "Hi there":
		_physical(mvp, ch)
	_t.eq(entry.text(), "Hi there", "a physical keyboard types into the box")
	# and the on-screen one, pressed through the card
	var mkb := ui.compose.keyboard
	await get_tree().process_frame
	await _tap(mvp, mkb, ".")
	_t.eq(entry.text(), "Hi there.", "the on-screen keyboard types into the box")
	await _tap(mvp, mkb, "enter")
	_t.eq(entry.text(), "Hi there.\n", "enter is a new line in the text box")
	await _tap(mvp, mkb, "back")
	_t.eq(entry.text(), "Hi there.", "backspace removes it again")
	entry.accepted.emit(entry.text())
	await get_tree().process_frame
	var texts := _texts(board)
	_t.eq(texts.size(), 1, "OK puts the text on the canvas")
	if texts.size() == 1:
		var a: Item = texts[0]
		_t.eq(a.text, "Hi there.", "the text is what was typed")
		_t.eq(a.frame, f.id, "on the canvas in front of the head")
		_t.eq(board.selection, [a.id], "and selected")
	await get_tree().process_frame
	_t.check(not ui.entry_open() and not ui.compose.wanted, "the typing card goes away")

	# edit the selected text (one undo step)
	_t.check(ui.open_text_entry(), "the box opens for the selected text")
	_t.eq(entry.text(), "Hi there.", "it holds the current text")
	entry.accepted.emit("Changed words")
	texts = _texts(board)
	_t.eq(texts.size(), 1, "still one text")
	_t.eq((texts[0] as Item).text, "Changed words", "the text was edited")
	board.undo()
	_t.eq((_texts(board)[0] as Item).text, "Hi there.", "undo brings the old words back")
	_t.check(not board.texts.edit((_texts(board)[0] as Item).id, "   "), "empty text does not replace the words")

	# label a shape
	var box := _make_rect(f.id)
	board.history.do(History.op_add([box]))
	board.select_items([box.id], f.id)
	_t.check(ui.open_text_entry(), "the box opens for a selected shape")
	entry.accepted.emit("Start")
	_t.eq((board.doc.items[box.id] as Item).label, "Start", "typed words become the label of the shape")
	board.undo()
	_t.eq((board.doc.items[box.id] as Item).label, "", "undo removes the label")

	# names go through the same box, on one line
	var named: Array = []
	ui.ask_name("Rename", "Old", func(s: String): named.append(s))
	await get_tree().process_frame
	_t.check(ui.entry_open(), "the name box opens")
	_t.eq(entry.text(), "Old", "it holds the current name")
	_physical(mvp, "N")
	_t.eq(entry.text(), "N", "typing replaces the selected name")
	_physical_key(mvp, KEY_ENTER)
	_t.eq(named, ["N"], "Enter accepts a one-line name")
	_t.check(not ui.entry_open(), "the box closed")

	# a key (the Wit.ai token, an API key) is typed in the same card, hidden, with the keyboard
	var keys: Array = []
	ui.ask_secret("Wit.ai server access token", func(s: String): keys.append(s))
	await get_tree().process_frame
	await get_tree().process_frame
	_t.check(ui.compose.keyboard.visible and (entry.field() as LineEdit).secret, "the keyboard shows for a key, and the key is hidden")
	_t.check(ui.compose.get_combined_minimum_size().y <= ui.compose.max_size.y, "the card with the keyboard fits its panel (%s)" % str(ui.compose.get_combined_minimum_size()))
	for ch in "Abc":
		_physical(mvp, ch)
	_physical_key(mvp, KEY_ENTER)
	_t.eq(keys, ["Abc"], "the key is handed over on Enter")
	await get_tree().process_frame
	_t.check(not ui.compose.wanted, "and the card goes away")
	ui.ask_name("Name", "", func(_s: String): pass)
	_t.check(not (entry.field() as LineEdit).secret, "a name is not hidden")
	ui.close_entry()

	# with the keyboard switched off the writing pad is offered instead
	App.put("vkeyboard", false)
	ui.open_text_entry()
	await get_tree().process_frame
	await get_tree().process_frame
	_t.check(not ui.compose.keyboard.visible and entry.pad.visible, "without the keyboard the pad is shown")
	ui.close_entry()
	App.put("vkeyboard", true)

	get_tree().quit(_t.done())


func _make_rect(frame_id: String) -> Item:
	var it := Item.new()
	it.id = U.uid("i")
	it.kind = Item.SHAPE
	it.shape = "rect"
	it.frame = frame_id
	it.center = Vector2(0.3, 0.5)
	it.size = Vector2(0.4, 0.25)
	return it


func _texts(board: Board) -> Array:
	var out: Array = []
	for it in board.doc.items.values():
		if (it as Item).kind == Item.TEXT:
			out.append(it)
	return out


## Press a key of the on-screen keyboard with pointer events (what a poke becomes in the headset).
func _tap(vp: Viewport, kb: VKeyboard, what: String) -> void:
	var local := kb.key_centre(what)
	_t.check(local.x >= 0.0, "the keyboard has a '%s' key" % what)
	var pos := kb.global_position + local
	var m := InputEventMouseMotion.new()
	m.position = pos
	m.global_position = pos
	vp.push_input(m, true)
	for down in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = down
		b.position = pos
		b.global_position = pos
		b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		vp.push_input(b, true)
	await get_tree().process_frame


## A physical key: press and release of a character, as a Bluetooth keyboard delivers it.
func _physical(vp: Viewport, ch: String) -> void:
	var k := InputEventKey.new()
	k.unicode = ch.unicode_at(0)
	k.keycode = OS.find_keycode_from_string(ch.to_upper())
	k.physical_keycode = k.keycode
	k.shift_pressed = ch != ch.to_lower()
	k.pressed = true
	vp.push_input(k, false)
	var up := k.duplicate() as InputEventKey
	up.pressed = false
	vp.push_input(up, false)


func _physical_key(vp: Viewport, code: Key) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	vp.push_input(k, false)
