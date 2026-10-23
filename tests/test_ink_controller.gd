extends Node
## Handwriting to text without the network: a stand-in recogniser answers, and the controller must replace the ink with text in the
## current text style, where the writing was, bind ink written inside a box to that box as its label, keep the ink when recognition fails, and undo it all.

class FakeInk extends InkRecognizer:
	var answers: Array = ["Hello", "Hallo", "Hell0"]
	var fail := false
	var calls := 0
	var last_strokes: Array = []
	var last_area := Vector2.ZERO

	func name_of() -> String:
		return "google"

	func recognize(strokes: Array, area: Vector2, _lang: String, done: Callable) -> void:
		last_strokes = strokes
		last_area = area
		calls += 1
		if fail:
			done.call({"ok": false, "candidates": PackedStringArray(), "error": "No internet connection for handwriting recognition."})
			return
		var cands := PackedStringArray()
		for a in answers:
			cands.append(str(a))
		done.call({"ok": true, "candidates": cands, "error": ""})


func _ready() -> void:
	var t := TestCase.new("ink_controller")
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_ink"
	App.reload()
	App.put("ink_provider", "google")
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors4.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Ink test"))
	var fake := FakeInk.new()
	board.ink._provider = fake
	var toasts: Array = []
	board.toast.connect(func(m): toasts.append(m))
	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1)))
	await get_tree().process_frame

	# 1. loose handwriting: five strokes spelling a word, 30 cm wide and 6 cm tall, left edge at x = 0.10
	var ink_items := _write_word(board, f.id, Vector2(0.10, 0.20), 0.30, 0.06, 5, Color("#ff9f43"))
	t.eq(board.ink.pending.size(), 5, "five strokes are pending")
	board.ink.convert_ink()
	await get_tree().process_frame
	await get_tree().process_frame
	t.eq(fake.calls, 1, "the recogniser was asked once for the line")
	t.eq(fake.last_strokes.size(), 5, "all five strokes went to the recogniser")
	t.check(fake.last_area.x > fake.last_area.y, "the writing area is wider than tall")
	var texts := _items(board, Item.TEXT)
	t.eq(texts.size(), 1, "one text item replaces the ink")
	t.eq(_items(board, Item.STROKE).size(), 0, "the handwriting strokes are gone")
	if not texts.is_empty():
		var tx: Item = texts[0]
		t.eq(tx.text, "Hello", "the text is the first reading")
		t.near(tx.center.x, 0.25, 0.015, "the text is centred where the writing was (x)")
		var body := TextLayout.style("body")
		t.check(is_equal_approx(tx.font_size, float(body[2])) and tx.weight == int(body[3]), "the text has the size of the text style, not of the writing (em %f)" % tx.font_size)
		t.eq(tx.alternatives.size(), 2, "other readings are kept for correcting")
		t.near(tx.color.r, Color("#ff9f43").r, 0.01, "the text keeps the ink colour")
		board.ink.cycle_alternative(tx.id)
		t.eq((board.doc.items[tx.id] as Item).text, "Hallo", "cycling picks the next reading")
		# the other readings are one-tap choices; the old text joins them
		board.ink.choose_alternative(tx.id, "Hell0")
		var chosen: Item = board.doc.items[tx.id]
		t.eq(chosen.text, "Hell0", "choosing a reading makes it the text")
		t.check(chosen.alternatives.has("Hello") or chosen.alternatives.has("Hallo"), "the previous text stays available as a reading")
		# the original handwriting is kept inside the text and can be brought back, even after a save and reload
		t.eq(chosen.ink.size(), 5, "the text keeps the five strokes it came from")
		var reloaded := Item.from_dict(chosen.to_dict())
		t.eq(reloaded.ink.size(), 5, "the handwriting survives saving")
		board.ink.revert_to_ink(tx.id)
		t.eq(_items(board, Item.STROKE).size(), 5, "back to handwriting restores the strokes")
		t.eq(_items(board, Item.TEXT).size(), 0, "back to handwriting removes the text")
		board.undo()
		t.eq(_items(board, Item.TEXT).size(), 1, "undo of back to handwriting puts the text back")
		board.undo()                                          # the reading choice
	board.undo()                                              # the cycle
	board.undo()                                              # the conversion
	t.eq(_items(board, Item.STROKE).size(), 5, "undo brings the handwriting back")
	t.eq(_items(board, Item.TEXT).size(), 0, "undo removes the text")

	# 2. ink written inside a box becomes its label
	for it in _items(board, Item.STROKE):
		board.doc.remove_item(it.id)
	board.ink.reset()
	var box := Item.make_shape(f.id, "rect", Color.WHITE, 0.004)
	box.center = Vector2(0.6, 0.6)
	box.size = Vector2(0.34, 0.2)
	board.history.do(History.op_add([box]))
	fake.answers = ["Start"]
	_write_word(board, f.id, Vector2(0.50, 0.57), 0.20, 0.06, 4, Color.WHITE)
	board.ink.convert_ink()
	await get_tree().process_frame
	await get_tree().process_frame
	t.eq(_items(board, Item.TEXT).size(), 0, "no separate text item for ink inside a box")
	var labelled: Item = board.doc.items[box.id]
	t.eq(labelled.label, "Start", "the box carries the handwriting as its label")

	# 3. failure keeps the ink
	fake.fail = true
	var kept := _write_word(board, f.id, Vector2(0.1, -0.3), 0.2, 0.05, 3, Color.WHITE)
	board.ink.convert_ink()
	await get_tree().process_frame
	await get_tree().process_frame
	t.check(board.ink.failed, "a failed reading is flagged")
	t.eq(_items(board, Item.STROKE).size(), kept.size(), "the ink stays when reading fails")
	t.check(toasts.any(func(m): return str(m).contains("internet")), "the user is told why")
	get_tree().quit(t.done())


func _items(board: Board, kind: String) -> Array:
	var out: Array = []
	for it in board.doc.items.values():
		if (it as Item).kind == kind:
			out.append(it)
	return out


## n vertical-ish strokes spread over a box (x, y = lower left; w, h in metres), registered as pending ink.
func _write_word(board: Board, frame_id: String, origin: Vector2, w: float, h: float, n: int, col: Color) -> Array:
	var items: Array = []
	for i in n:
		var x := origin.x + w * float(i) / float(n - 1)
		var pts := PackedFloat32Array()
		for k in 12:
			pts.append_array(PackedFloat32Array([x, origin.y + h * float(k) / 11.0, 0.0, 0.8]))
		var it := Item.make_stroke(frame_id, pts, col, 0.004, "pen")
		board.history.do(History.op_add([it]))
		var stored: Item = board.doc.items[it.id]
		board.ink.add(stored, PackedFloat32Array([float(i) * 0.4, float(i) * 0.4 + 0.3]))
		items.append(stored)
	return items
