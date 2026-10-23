extends Node
## Handwriting, predicted (WritingDetector, InkController, InkChip), without the network: synthetic handwritten words score as
## writing and drawings do not; in Write mode a line, an underline, a box or an arrow among the words stays a drawing; with the Pen,
## words are offered for conversion once the pen rests (and only those), accepting converts them, the other readings are offered
## right after, a "keep as drawing" is remembered; "convert" converts clear writing by itself, "off" leaves the pen alone.

class FakeInk extends InkRecognizer:
	var calls := 0

	func name_of() -> String:
		return "google"

	func recognize(_strokes: Array, _area: Vector2, _lang: String, done: Callable) -> void:
		calls += 1
		done.call({"ok": true, "candidates": PackedStringArray(["hello", "hallo", "hells"]), "error": ""})


var t: TestCase
var rng := RandomNumberGenerator.new()


func _ready() -> void:
	t = TestCase.new("writing")
	rng.seed = 11
	App.settings_path = "user://test_settings.cfg"
	App.docs_dir = "user://test_docs_writing"
	App.reload()
	App.put("ink_provider", "google")
	App.put("smart_ink", "suggest")
	App.put("ink_auto", true)
	_detector()
	await _controller()
	get_tree().quit(t.done())


# ------------------------------------------------------------------------------------------------ the detector on its own

func _detector() -> void:
	for h in [0.02, 0.04, 0.08]:
		for word in ["hello", "cat", "hello cat"]:
			var s := WritingDetector.score_features(_feats(_word(word, Vector2(0.1, 0.2), h)))
			_say("%-10s %d cm  %.2f" % [word, int(h * 100), s])
			t.check(s >= WritingDetector.SUGGEST, "\"%s\" written %d cm tall reads as writing (%.2f)" % [word, int(h * 100), s])
	var cur := WritingDetector.score_features(_feats([_cursive(Vector2(0.1, 0.2), 0.04, 7)]))
	_say("joined-up  %.2f" % cur)
	t.check(cur >= WritingDetector.SUGGEST, "a joined-up word in one stroke reads as writing (%.2f)" % cur)
	var drawings := {
		"a house": _house(Vector2(0.2, 0.1), 0.3),
		"a wave": [_wave(Vector2(0.0, 0.3), 0.4, 0.05)],
		"hatching": _hatching(Vector2(0.2, 0.2), 6, 0.05),
		"a star": [_star(Vector2(0.3, 0.3), 0.08)],
		"a smiley": _smiley(Vector2(0.3, 0.3), 0.1),
		"an arrow": _arrow(Vector2(0.1, 0.3), Vector2(0.45, 0.32)),
		"a box": [_rect_stroke(Rect2(0.1, 0.1, 0.3, 0.2))],
		"one letter-sized loop": [_circle(Vector2(0.2, 0.2), 0.02)],
	}
	for k in drawings:
		var s2 := WritingDetector.score_features(_feats(drawings[k]))
		_say("%-22s %.2f" % [k, s2])
		t.check(s2 < WritingDetector.SUGGEST, "%s does not read as writing (%.2f)" % [k, s2])
	# single marks among writing 4 cm tall
	var h4 := 0.04
	t.check(WritingDetector.is_mark(WritingDetector.features_of(_line(Vector2(0.1, 0.18), Vector2(0.4, 0.18))), h4), "an underline is a mark")
	t.check(WritingDetector.is_mark(WritingDetector.features_of(_rect_stroke(Rect2(0.08, 0.15, 0.36, 0.1))), h4), "a box round the words is a mark")
	t.check(not WritingDetector.is_mark(WritingDetector.features_of(_line(Vector2(0.2, 0.2), Vector2(0.2, 0.28))), h4), "an l is not")
	t.check(not WritingDetector.is_mark(WritingDetector.features_of(_circle(Vector2(0.2, 0.2), 0.02)), h4), "an o is not")
	t.check(not WritingDetector.is_mark(WritingDetector.features_of(_line(Vector2(0.2, 0.2), Vector2(0.23, 0.2))), h4), "a dash is not")
	t.check(WritingDetector.is_mark(WritingDetector.features_of(_line(Vector2(0.1, 0.1), Vector2(0.4, 0.1))), 0.0), "with nothing written yet, a long line is a mark")
	t.check(not WritingDetector.is_mark(WritingDetector.features_of(_line(Vector2(0.1, 0.1), Vector2(0.1, 0.16))), 0.0), "...a short one is not")


# ------------------------------------------------------------------------------------------------ the ink controller and the chip

func _controller() -> void:
	var board := Board.new()
	add_child(board)
	var anchors := SimAnchors.new("user://test_sim_anchors_writing.json")
	add_child(anchors)
	board.setup(anchors)
	board.open(Document.create("Writing test"))
	var fake := FakeInk.new()
	board.ink._provider = fake
	var f := board.add_frame(FrameData.CANVAS, Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1)))
	await get_tree().process_frame
	var ink := board.ink
	var ui := UiShell.new()
	add_child(ui)
	ui.setup(board)

	# Write mode: the words wait for conversion, the marks among them stay drawings
	var line_first := _add(board, f.id, [_line(Vector2(-0.4, 0.3), Vector2(-0.1, 0.3))])
	t.check(not ink.add(line_first[0], PackedFloat32Array([0.0, 0.3])), "Write mode: a long line drawn first stays a drawing")
	var words := _add(board, f.id, _word("hello", Vector2(-0.4, 0.0), 0.04))
	var k := 0.0
	for w in words:
		t.check(ink.add(w, PackedFloat32Array([k, k + 0.3])), "a letter waits to be read")
		k += 0.4
	t.eq(ink.pending.size(), words.size(), "every letter is pending")
	var under := _add(board, f.id, [_line(Vector2(-0.41, -0.02), Vector2(-0.12, -0.02))])
	t.check(not ink.add(under[0], PackedFloat32Array([3.0, 3.3])), "an underline stays a drawing")
	var ring := _add(board, f.id, [_rect_stroke(Rect2(-0.43, -0.04, 0.34, 0.17))])
	t.check(not ink.add(ring[0], PackedFloat32Array([4.0, 4.6])), "a box round the words stays a drawing")
	var arrow := _add(board, f.id, _arrow(Vector2(-0.05, 0.03), Vector2(0.3, 0.03)))
	t.check(not ink.add(arrow[0], PackedFloat32Array([5.0, 5.3])) and not ink.add(arrow[1], PackedFloat32Array([5.4, 5.6])), "an arrow (shaft and head) stays a drawing")
	t.eq(ink.pending.size(), words.size(), "only the letters are pending")
	ink.convert_ink()
	await get_tree().process_frame
	t.eq(_count(board, Item.TEXT), 1, "the letters became one text")
	t.eq(_count(board, Item.STROKE), 1 + 1 + 1 + 2, "the line, the underline, the box and the arrow are still ink")
	var conv := ink.recent_text()
	t.check(conv != null and conv.text == "hello", "the new text is the one just converted")
	ui.update(1.0)
	t.check(ui.ink_chip.place_for(board) and ui.ink_chip.mode == "readings", "the chip offers the other readings")
	ui.ink_chip.refresh()
	t.check(_btn(ui.ink_chip, "hallo") != null and _btn(ui.ink_chip, "Handwriting") != null, "...each one a tap away, and the way back to the ink")
	_btn(ui.ink_chip, "hallo").pressed.emit()
	t.eq((board.doc.items[conv.id] as Item).text, "hallo", "a tap on a reading fixes the text")
	ink.update(InkController.RECENT_S + 1.0)
	t.check(ink.recent_text() == null, "the readings go away by themselves after a while")
	board.undo()
	board.undo()
	for it in board.doc.items.values():
		board.history.do(History.op_remove([it]))
	ink.reset()

	# the Pen: words are watched, and offered once the pen rests
	var calls := fake.calls
	var pen_words := _add(board, f.id, _word("cat", Vector2(-0.3, -0.2), 0.05))
	for w in pen_words:
		ink.observe(w, PackedFloat32Array([0.0, 0.2]))
		ink.update(0.1)
	t.check(ink.suggestion.is_empty(), "nothing is offered while the pen is still writing")
	ink.update(1.0)
	t.eq(ink.suggestion.get("ids", []).size(), pen_words.size(), "once the pen rests the word is offered")
	ui.update(1.0)
	t.check(ui.ink_chip.place_for(board) and ui.ink_chip.mode == "suggest", "the chip shows beside it")
	var r: Rect2 = ink.suggestion.rect
	t.check((ui.ink_chip.anchor.pos as Vector2).x > r.end.x, "...on its right")
	ui.ink_chip.refresh()
	t.eq(fake.calls, calls, "nothing was sent before the tap")
	_btn(ui.ink_chip, "Convert to text").pressed.emit()
	await get_tree().process_frame
	t.eq(fake.calls, calls + 1, "Convert to text reads it")
	t.eq(_count(board, Item.TEXT), 1, "...and puts text in its place")
	t.eq(_count(board, Item.STROKE), 0, "...instead of the strokes")
	t.check(ink.suggestion.is_empty(), "the offer is gone")
	for it in board.doc.items.values():
		board.history.do(History.op_remove([it]))
	ink.reset()

	# a drawing drawn with the pen is not offered
	for s in _add(board, f.id, _house(Vector2(-0.3, -0.3), 0.25)):
		ink.observe(s, PackedFloat32Array([0.0, 0.3]))
		ink.update(0.2)
	ink.update(1.0)
	t.check(ink.suggestion.is_empty(), "a house drawn with the pen is not offered as text")
	ink.reset()

	# "keep as drawing" is remembered
	var doodle := _add(board, f.id, _word("hello", Vector2(0.0, 0.2), 0.03))
	for w in doodle:
		ink.observe(w, PackedFloat32Array([0.0, 0.2]))
	ink.update(1.0)
	t.check(not ink.suggestion.is_empty(), "(offered)")
	ink.dismiss_suggestion()
	ink.update(1.0)
	t.check(ink.suggestion.is_empty(), "after Keep as drawing it is not offered again")
	for w in doodle:
		ink.observe(w, PackedFloat32Array([0.0, 0.2]))
	ink.update(1.0)
	t.check(ink.suggestion.is_empty(), "...not even when it is looked at again")
	ink.reset()

	# convert by itself
	App.put("smart_ink", "auto")
	calls = fake.calls
	var auto_words := _add(board, f.id, _word("hello", Vector2(-0.4, -0.35), 0.05))
	for w in auto_words:
		ink.observe(w, PackedFloat32Array([0.0, 0.2]))
	ink.update(1.0)
	await get_tree().process_frame
	t.eq(fake.calls, calls + 1, "\"Convert\": clear writing is read without asking")
	ink.reset()
	# off
	App.put("smart_ink", "off")
	for w in _add(board, f.id, _word("cat", Vector2(0.1, -0.35), 0.05)):
		ink.observe(w, PackedFloat32Array([0.0, 0.2]))
	ink.update(1.0)
	t.check(ink.suggestion.is_empty(), "\"Off\": the pen leaves writing alone")
	App.put("smart_ink", "suggest")
	DocStore.delete(board.doc.id)


## The scores, for tuning: VERBOSE_TESTS=1 when running this test.
func _say(line: String) -> void:
	if OS.has_environment("VERBOSE_TESTS"):
		print("  score ", line)


# ------------------------------------------------------------------------------------------------ synthetic ink

func _feats(strokes: Array) -> Array:
	var out: Array = []
	for s in strokes:
		out.append(WritingDetector.features_of(s))
	return out


func _add(board: Board, frame_id: String, strokes: Array) -> Array:
	var items: Array = []
	for s in strokes:
		var pts := PackedFloat32Array()
		for p in s:
			pts.append_array(PackedFloat32Array([p.x, p.y, 0.0, 0.8]))
		var it := Item.make_stroke(frame_id, pts, Color.WHITE, 0.003, "pen")
		board.history.do(History.op_add([it]))
		items.append(board.doc.items[it.id])
	return items


func _jit(p: Vector2, amp: float) -> Vector2:
	return p + Vector2(rng.randfn(0.0, amp), rng.randfn(0.0, amp))


func _poly(pts: Array, at: Vector2, h: float, step: float = 0.06) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var n := maxi(int(a.distance_to(b) / step), 1)
		for k in n:
			out.append(_jit(at + a.lerp(b, float(k) / n) * h, h * 0.005))
	out.append(_jit(at + (pts[pts.size() - 1] as Vector2) * h, h * 0.005))
	return out


func _arc_pts(c: Vector2, r: Vector2, a0: float, a1: float, n: int = 20) -> Array:
	var out: Array = []
	for i in n + 1:
		var a := lerpf(a0, a1, float(i) / n)
		out.append(c + Vector2(cos(a) * r.x, sin(a) * r.y))
	return out


## Strokes of a word in a simple print hand, x-height h (letters 2h tall where they rise), y up, starting at `at`.
func _word(word: String, at: Vector2, h: float) -> Array:
	var strokes: Array = []
	var x := 0.0
	for ch in word:
		var o := at + Vector2(x, 0.0)
		match ch:
			"h":
				strokes.append(_poly([Vector2(0, 2), Vector2(0, 0), Vector2(0, 0.7)] + _arc_pts(Vector2(0.35, 0.65), Vector2(0.35, 0.35), PI, 0.0) + [Vector2(0.7, 0)], o, h))
				x += 0.95 * h
			"e":
				strokes.append(_poly([Vector2(0, 0.5), Vector2(0.8, 0.5)] + _arc_pts(Vector2(0.4, 0.5), Vector2(0.4, 0.5), 0.0, PI * 1.75), o, h))
				x += 1.05 * h
			"l":
				strokes.append(_poly([Vector2(0.1, 2), Vector2(0.1, 0)], o, h))
				x += 0.45 * h
			"o":
				strokes.append(_poly(_arc_pts(Vector2(0.45, 0.5), Vector2(0.45, 0.5), PI * 0.5, PI * 2.5), o, h))
				x += 1.1 * h
			"c":
				strokes.append(_poly(_arc_pts(Vector2(0.45, 0.5), Vector2(0.45, 0.5), PI * 0.25, PI * 1.75), o, h))
				x += 1.0 * h
			"a":
				strokes.append(_poly(_arc_pts(Vector2(0.4, 0.5), Vector2(0.4, 0.5), PI * 0.3, PI * 2.3), o, h))
				strokes.append(_poly([Vector2(0.8, 1), Vector2(0.8, 0)], o, h))
				x += 1.1 * h
			"t":
				strokes.append(_poly([Vector2(0.3, 1.7), Vector2(0.3, 0.1), Vector2(0.5, 0)], o, h))
				strokes.append(_poly([Vector2(0, 1), Vector2(0.65, 1)], o, h))
				x += 0.85 * h
			" ":
				x += 0.9 * h
	return strokes


## A joined-up word: loops along the line (a trochoid), one stroke.
func _cursive(at: Vector2, h: float, loops: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := loops * 24
	for i in n + 1:
		var u := float(i) / 24.0
		out.append(_jit(at + Vector2(u * 0.7 * h - 0.32 * h * sin(u * TAU), 0.5 * h * (1.0 - cos(u * TAU))), h * 0.01))
	return out


func _line(a: Vector2, b: Vector2) -> PackedVector2Array:
	return _poly([Vector2.ZERO, (b - a) / 0.1], a, 0.1, 0.05)


func _rect_stroke(r: Rect2) -> PackedVector2Array:
	var c := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), r.position + Vector2(0.004, 0.0)]
	var out := PackedVector2Array()
	for i in range(c.size() - 1):
		out.append_array(_line(c[i], c[i + 1]))
	return out


func _circle(c: Vector2, r: float) -> PackedVector2Array:
	return _poly(_arc_pts(Vector2.ZERO, Vector2(r, r) / 0.1, 0.0, TAU * 0.98, 32), c, 0.1)


func _house(at: Vector2, s: float) -> Array:
	return [_rect_stroke(Rect2(at, Vector2(s, s * 0.8))), _line(at + Vector2(0, s * 0.8), at + Vector2(s * 0.5, s * 1.3)), _line(at + Vector2(s * 0.5, s * 1.3), at + Vector2(s, s * 0.8))]


func _wave(at: Vector2, w: float, amp: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 81:
		var u := float(i) / 80.0
		out.append(_jit(at + Vector2(u * w, sin(u * TAU * 3.0) * amp), 0.0005))
	return out


func _hatching(at: Vector2, n: int, len_m: float) -> Array:
	var out: Array = []
	for i in n:
		var a := at + Vector2(i * 0.015, 0.0)
		out.append(_line(a, a + Vector2(len_m * 0.6, len_m * 0.8)))
	return out


func _star(c: Vector2, r: float) -> PackedVector2Array:
	var pts: Array = []
	for i in 6:
		var a := PI * 0.5 + TAU * float(i * 2 % 5) / 5.0
		pts.append(Vector2(cos(a), sin(a)) * r / 0.1)
	return _poly(pts, c, 0.1, 0.05)


func _smiley(c: Vector2, r: float) -> Array:
	return [_circle(c, r), _circle(c + Vector2(-r * 0.35, r * 0.3), r * 0.08), _circle(c + Vector2(r * 0.35, r * 0.3), r * 0.08),
		_poly(_arc_pts(Vector2.ZERO, Vector2(r * 0.5, r * 0.4) / 0.1, PI * 1.15, PI * 1.85), c, 0.1)]


func _arrow(a: Vector2, b: Vector2) -> Array:
	var d := (b - a).normalized()
	var n := Vector2(-d.y, d.x)
	var head := PackedVector2Array()
	head.append_array(_line(b - d * 0.03 + n * 0.02, b))
	head.append_array(_line(b, b - d * 0.03 - n * 0.02))
	return [_line(a, b), head]


func _count(board: Board, kind: String) -> int:
	var n := 0
	for it in board.doc.items.values():
		if (it as Item).kind == kind:
			n += 1
	return n


func _btn(root: Node, text: String) -> Btn:
	for n in root.find_children("*", "Btn", true, false):
		if (n as Btn).text == text:
			return n
	return null
