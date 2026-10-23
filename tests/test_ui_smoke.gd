extends Node
## The interface's surfaces with a document that has content: every button of every popover, Home tab, the assistant and the bar
## beside each kind of selection is pressed (twice for toggles, the arm-then-confirm bins once), every slider and colour picker moved;
## the run fails on any script error. Then the rules of the flow: the surfaces step back while you draw, a popover closes when drawing
## starts, the bar beside the selection offers what fits it and its edits are one undo step each.

## A language model that answers when told to (or at once): words, or a drawing.
class FakeModel extends RefCounted:
	var hold := false
	var waiting := Callable()
	var draw := false

	func list_models(_p: String, _k: String, done: Callable) -> void:
		done.call({"ok": true, "error": "", "models": [{"id": "m", "name": "Model M", "vision": true, "modes": [["default", "Model default"]]}]})

	func chat(_p: String, _k: String, _m: String, _mode: String, _s: String, _h: Array, _prompt: String, _png: PackedByteArray, done: Callable) -> void:
		var ans := {"say": "Because the arrow loops back.", "add": [], "change": [], "remove": []}
		if draw:
			ans = {"say": "Added a review step.", "add": [{"type": "shape", "shape": "rect", "id": "n1", "x": 5, "y": 5, "w": 20, "h": 10, "label": "Review"}], "change": [], "remove": []}
		var res := {"ok": true, "text": JSON.stringify(ans), "error": "", "left_out": PackedStringArray()}
		if hold:
			waiting = func(): done.call(res)
		else:
			done.call(res)


var t: TestCase
var ui: UiShell
var board: Board
var pen := PenState.new()


func _ready() -> void:
	t = TestCase.new("ui_smoke")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_ui"
	App.reload()
	board = Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors3.json")
	add_child(anchors)
	board.setup(anchors)
	var doc := DemoDoc.build()
	doc.id = "ui-smoke"
	doc.save()
	board.open(doc)
	ui = UiShell.new()
	add_child(ui)
	ui.setup(board)
	var root := Control.new()
	add_child(root)
	for p in ui.panels:
		root.add_child(p)
	await _frames(120)
	t.eq(board.room_state, "found", "the demo room is found")
	t.check(ui.dock.visible and not ui.popover.visible and not ui.home.visible and not ui.context.visible, "only the dock shows at first")

	# every popover
	var pressed := 0
	for id in ["brush", "shapes", "write", "add"]:
		ui.open_popover(id)
		await _frames(3)
		t.check(ui.popover.visible and ui.popover.mode == id, "the %s popover opens" % id)
		pressed += await _press_all(ui.popover, func():
			if ui.popover_id != id:
				ui.open_popover(id)
				ui.popover.snap_fade())
		ui.open_popover(id)                               # a button may have closed it (a stencil, Type text ...)
		await _frames(2)
		_move_sliders(ui.popover)
		board.cancel_place()
		board.speech.cancel()
	ui.close_popover()
	# every Home tab
	ui.open_side("home")
	for tab in ["docs", "canvas", "rooms", "share", "settings"]:
		ui.home.select_tab(tab)
		await _frames(4)
		pressed += await _press_all(ui.home, func():
			if board.doc == null or board.doc.id != "ui-smoke":
				board.open(DocStore.open("ui-smoke"))
			if not ui.is_side_open("home"):
				ui.open_side("home")
			if ui.home.tab != tab:
				ui.home.select_tab(tab)
			ui.home.snap_fade())
		_move_sliders(ui.home)
		board.cancel_place()
		if board.share.is_running():
			board.share.stop()
		if board.doc == null or board.doc.id != "ui-smoke":
			board.open(DocStore.open("ui-smoke"))
			await _frames(4)
	ui.close_side("home")
	# the assistant (no key, no network: its requests only say so)
	ui.open_side("assistant")
	await _frames(4)
	pressed += await _press_all(ui.assistant)
	ui.close_side("assistant")
	t.check(pressed > 90, "pressed %d buttons on the surfaces" % pressed)
	t.check(board.doc != null, "the board still has a document after all that")
	var fresh := DemoDoc.build()                           # the buttons cleared and deleted things: start the rest from the demo again
	fresh.id = "ui-smoke"
	fresh.save()
	board.open(fresh)
	await _frames(20)

	await _selection_bar()
	await _flow_rules()
	await _chat()

	# Quit needs a second press: the first only arms it (and times out again)
	ui.home.quit_btn.pressed.emit()
	t.eq(ui.home.quit_btn.text, "Sure?", "the first press of Quit asks again")
	ui.home.tick_quit(3.5)
	t.eq(ui.home.quit_btn.text, "Quit", "...and gives up after a few seconds")
	t.check(DocStore.list().size() >= 1, "documents are listed")
	for s in DocStore.list():
		DocStore.delete(s.id)
	get_tree().quit(t.done())


## The bar above the selection: what it offers for text, ink and a box, and its edits.
func _selection_bar() -> void:
	var doc := board.doc
	var txt_id := _first(Item.TEXT)
	var box_id := ""
	for it in doc.items.values():
		if (it as Item).kind == Item.SHAPE and not (it as Item).is_line():
			box_id = (it as Item).id
			break
	var ink_id := _first(Item.STROKE)
	# text
	var txt: Item = doc.items[txt_id]
	var old_size := txt.font_size
	board.select_items([txt_id], txt.frame)
	await _frames(int(UiShell.CALM_S * 60.0) + 4)
	t.check(ui.context.visible, "the bar shows above selected text")
	t.check(_btn(ui.context, "H1") != null and _btn(ui.context, "To text") == null, "...with the text styles and without To text")
	_btn(ui.context, "H1").pressed.emit()
	await _frames(2)
	txt = doc.items[txt_id]
	t.check(is_equal_approx(txt.font_size, 0.09) and txt.weight == 700 and _btn(ui.context, "H1").on, "Heading 1 gives exactly its size and weight and lights its chip")
	_btn(ui.context, "Body").pressed.emit()
	await _frames(2)
	txt = doc.items[txt_id]
	t.check(is_equal_approx(txt.font_size, 0.045) and txt.weight == 400, "Body gives its size and weight")
	var old_w := txt.size.x
	for i in 4:                                            # Regular -> Medium -> SemiBold -> Bold -> ExtraBold
		ui.context._weight_chip.pressed.emit()
		await _frames(1)
	txt = doc.items[txt_id]
	t.check(txt.weight == 800 and txt.size.x > old_w and ui.context._weight_chip.text == "ExtraBold", "the weight chip steps up to ExtraBold and widens the box (%d %s)" % [txt.weight, ui.context._weight_chip.text])
	_tool(ui.context, "italic").pressed.emit()
	await _frames(1)
	t.check((doc.items[txt_id] as Item).italic and _tool(ui.context, "italic").on, "Italic switches italic on")
	_tool(ui.context, "italic").pressed.emit()
	t.check(not (doc.items[txt_id] as Item).italic, "Italic again switches it off")
	_tool(ui.context, "bold").pressed.emit()
	t.eq((doc.items[txt_id] as Item).weight, 400, "Bold on bold text makes it regular")
	for _i in 9:
		board.undo()
	txt = doc.items[txt_id]
	t.check(txt.weight == 400 and not txt.italic and is_equal_approx(txt.font_size, old_size), "undo restores the original style")
	# recolour (only the colour), one undo step
	var col_before := (doc.items[txt_id] as Item).color
	var serial := board.history.serial
	ui.set_color(Color("#ef476f"))
	t.check((doc.items[txt_id] as Item).color.is_equal_approx(Color("#ef476f")), "a palette colour recolours the selection")
	t.eq(board.history.serial, serial + 1, "...in one undo step")
	board.undo()
	t.check((doc.items[txt_id] as Item).color.is_equal_approx(col_before), "undo brings the colour back")
	# ink
	board.select_items([ink_id], (doc.items[ink_id] as Item).frame)
	await _frames(3)
	t.check(_btn(ui.context, "To text") != null and _btn(ui.context, "H1") == null, "selected ink offers To text, not text styles")
	# a box: label and fill
	var box: Item = doc.items[box_id]
	var filled := box.fill.a > 0.0
	board.select_items([box_id], box.frame)
	await _frames(3)
	t.check(_tool(ui.context, "shapes") != null and _tool(ui.context, "text") != null, "a selected box offers a label and a fill")
	_tool(ui.context, "shapes").pressed.emit()
	t.eq((doc.items[box_id] as Item).fill.a > 0.0, not filled, "Filled switches its fill")
	board.undo()
	t.eq((doc.items[box_id] as Item).fill.a > 0.0, filled, "...and undo switches it back")
	# every button of the bar, for each kind of selection
	var pressed := 0
	for id in [txt_id, ink_id, box_id]:
		if not doc.items.has(id):
			continue
		board.select_items([id], (doc.items[id] as Item).frame)
		await _frames(3)
		pressed += await _press_all(ui.context)
		ui.close_entry()
	t.check(pressed > 10, "pressed %d buttons on the selection bar" % pressed)
	board.clear_selection()
	await _frames(3)
	t.check(not ui.context.wanted, "the bar goes away with the selection")


## While the pen draws: a popover closes, the dock steps back, the bar on the canvas steps away; all of it comes back after.
func _flow_rules() -> void:
	App.put("ui_fade", true)
	var fid: String = board.doc.frames.keys()[0]
	var fn: FrameNode = board.frame_nodes[fid]
	board.select_items([_first(Item.SHAPE)], fid)
	ui.open_popover("brush")
	await _frames(int(UiShell.CALM_S * 60.0) + 6)
	t.check(ui.popover.visible and ui.context.visible, "(a popover and the selection bar are showing)")
	App.put("tool", "draw")
	board.clear_selection()
	pen.tracked = true
	pen.pressure = 0.8
	pen.tip = fn.to_world_point(Vector3(-0.3, -0.2, 0.0))
	pen.down = true
	board.tick(pen, [], 0.016)
	for i in 6:
		pen.tip = fn.to_world_point(Vector3(-0.3 + i * 0.02, -0.2, 0.0))
		board.tick(pen, [], 0.016)
		await _frames(1)
	t.eq(board.pen_ctl.state, PenController.S.DRAWING, "(the pen is drawing)")
	t.eq(ui.popover_id, "", "drawing on a canvas closes the popover")
	await _frames(10)
	t.check(ui.dock.modulate.a < 0.5, "the dock steps back while the pen draws (%f)" % ui.dock.modulate.a)
	pen.down = false
	board.tick(pen, [], 0.016)
	pen.tracked = false
	await _frames(int(UiShell.CALM_S * 60.0) + 20)
	t.check(ui.dock.modulate.a > 0.95, "...and comes back when it is done (%f)" % ui.dock.modulate.a)
	# tool buttons: the active tool again opens its options; Shapes opens the shapes at once
	ui.tool_pressed("draw")
	t.eq(ui.popover_id, "brush", "the Pen again opens the brush")
	ui.tool_pressed("draw")
	t.eq(ui.popover_id, "", "...and again closes it")
	ui.tool_pressed("shape")
	t.check(ui.popover_id == "shapes" and App.val("tool") == "shape", "Shapes picks the tool and opens the stencils")
	ui.pick_stencil("diamond")
	t.check(ui.popover_id == "" and board.stencil == "diamond", "picking a stencil closes them, ready to place it")
	ui.tool_pressed("select")
	# Esc closes what is open, the topmost first
	ui.open_side("home")
	ui.open_popover("add")
	t.check(ui.back() and ui.popover_id == "" and ui.is_side_open("home"), "back closes the popover first")
	t.check(ui.back() and not ui.is_side_open("home"), "...then the side panel")
	App.put("tool", "draw")


## The assistant as a conversation: the setup card without a key, a message typed in the box and sent, the typing indicator, the
## answer as a bubble, a drawn suggestion as a card in the answer, a new conversation.
func _chat() -> void:
	var ai := board.ai
	var fid: String = board.doc.frames.keys()[0]
	board.active_frame = fid
	board.clear_selection()
	App.put("ai_note", false)
	ai.set_provider("anthropic")                          # (the buttons above left another provider picked)
	ai.set_key("anthropic", "")
	ai.forget(fid)
	ui.open_side("assistant")
	await _frames(6)
	var a := ui.assistant
	t.check(_btn(a._thread, "Set the API key") != null, "without a key the conversation starts with setting it up")
	var fake := FakeModel.new()
	ai.client = fake
	ai.set_key("anthropic", "sk-test-1234")
	await _frames(3)
	t.check(_btn(a._thread, "Set the API key") == null, "with a key that card goes")
	# typed in the box and sent with Enter
	fake.hold = true
	a.composer.grab_focus()
	await _frames(1)
	t.check(ui.is_typing(), "while the box has the keyboard, keys are not shortcuts")
	a.composer.text = "Why does it loop?"
	a.composer.text_submitted.emit(a.composer.text)
	await _frames(3)
	t.check(ai.busy and a.composer.text == "", "the message is sent and the box empties")
	t.check(_label(a._thread, "Why does it loop?") != null, "your message shows at once")
	t.check(_typing_shown(a), "...with the assistant typing under it")
	fake.waiting.call()
	await _frames(3)
	t.check(_label(a._thread, "Because the arrow loops back.") != null, "the answer comes in as a message")
	t.check(not _typing_shown(a), "...and the typing stops")
	t.check(_label(a._thread, "Model M") != null or _label(a._thread, ai.model_name()) != null, "...signed with the model's name")
	# a quick request that draws: its suggestion is a card in the answer
	fake.hold = false
	fake.draw = true
	_btn(a, "Improve it").pressed.emit()
	await _frames(3)
	t.check(ai.has_layer(fid), "(the answer is a suggestion)")
	t.check(_label(a._thread, "Improve it") != null, "the request shows as your message")
	var accept := _btn(a._thread, "Accept")
	t.check(accept != null, "the suggestion is a card in the answer, with Accept")
	var before := board.doc.items_of(fid).size()
	accept.pressed.emit()
	await _frames(3)
	t.eq(board.doc.items_of(fid).size(), before + 1, "Accept there puts it on the canvas")
	t.check(_btn(a._thread, "Accept") == null, "...and the card is done")
	board.undo()
	t.eq((ai.chat.get(fid, []) as Array).size(), 4, "the conversation has both questions and both answers")
	_tool(a, "plus").pressed.emit()
	await _frames(3)
	t.check((ai.chat.get(fid, []) as Array).is_empty() and _label(a._thread, "Ask about this canvas") != null, "a new conversation starts empty")
	a.composer.release_focus()
	ui.close_side("assistant")
	ai.set_key("anthropic", "")


func _typing_shown(a: AssistantPanel) -> bool:
	return a._thread.find_children("*", "Control", true, false).any(func(n): return n is AssistantPanel.Dots)


func _label(root: Node, text: String) -> Label:
	for n in root.find_children("*", "Label", true, false):
		if (n as Label).text == text:
			return n
	return null


func _first(kind: String) -> String:
	for it in board.doc.items.values():
		if (it as Item).kind == kind:
			return (it as Item).id
	return ""


func _btn(root: Node, text: String) -> Btn:
	for n in root.find_children("*", "Btn", true, false):
		if (n as Btn).text == text and (n as Btn).is_visible_in_tree():
			return n
	return null


func _tool(root: Node, icon: String) -> Btn:
	for n in root.find_children("*", "Btn", true, false):
		if (n as Btn).icon == icon and (n as Btn).text == "" and (n as Btn).is_visible_in_tree():
			return n
	return null


## Press every button showing on a surface, in order. `reopen` puts the surface back after a button closed or rebuilt it.
func _press_all(root: Node, reopen: Callable = Callable()) -> int:
	var n := 0
	var i := 0
	while i < 300:
		var list: Array = root.find_children("*", "Btn", true, false).filter(func(x): return is_instance_valid(x) and (x as Btn).is_visible_in_tree())
		if i >= list.size():
			break
		var btn := list[i] as Btn
		i += 1
		if btn == ui.home.quit_btn or btn.hint == "Close" or btn.text in ["SVG", "3D .glb", "File .mrw"]:
			continue                                   # Quit really quits (checked on its own); Close is pressed by the flow rules; exports
			                                           # write into Documents (tests/test_export.gd covers them)
		btn.pressed.emit()
		if btn.toggle_mode:
			btn.toggled.emit(not btn.on)
		n += 1
		await _frames(1)
		if ui.entry_open():                            # Type, Rename ... open the typing card: close it again
			ui.close_entry()
		if reopen.is_valid():
			reopen.call()
	for s in root.find_children("*", "Switch", true, false):
		var sw := s as Switch
		if is_instance_valid(sw) and sw.is_visible_in_tree():
			sw.toggled.emit(not sw.on)
			sw.toggled.emit(sw.on)
			n += 1
	return n


func _move_sliders(root: Node) -> void:
	for s in root.find_children("*", "FlatSlider", true, false):
		var sl := s as FlatSlider
		if is_instance_valid(sl) and sl.is_visible_in_tree():
			sl.value = lerpf(sl.min_value, sl.max_value, 0.7)
			sl.value_changed.emit(sl.value)
	for p in root.find_children("*", "HsvPicker", true, false):
		(p as HsvPicker).color_changed.emit(Color.from_hsv(0.3, 0.8, 0.9))


## Frames at a fixed 60 Hz for the board, the shell and the fades (headless frames come as fast as they can).
func _frames(n: int) -> void:
	for i in n:
		board.tick(pen, [], 0.016)
		ui.update(0.016)
		for p in ui.panels:
			(p as FloatPanel)._process(0.016)
		await get_tree().process_frame
