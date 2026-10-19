class_name InkController
extends RefCounted
## Handwriting to text. In Write mode the strokes stay on the canvas as ink; once the pen has rested for a moment (or Convert is
## pressed) they are grouped into lines, sent to the recogniser, and each line is replaced by a text item with the same size and
## position as the handwriting. Ink written inside a box becomes that box's label. The original ink comes back with Undo.

const PX_PER_LINE := 150.0                 # the recogniser sees a line of handwriting about this many units tall

var board: Board
var pending: Array = []                    # [{id, frame, t0, t1}]
var busy := false
var failed := false
var last_error := ""

var _idle := 0.0
var _provider: InkRecognizer


func _init(b: Board) -> void:
	board = b


func provider() -> InkRecognizer:
	var want := str(App.val("ink_provider"))
	if _provider == null or _provider.name_of() != want:
		_provider = GoogleInk.new(board) if want == "google" else InkRecognizer.new()
	return _provider


func add(item: Item, times: PackedFloat32Array) -> void:
	var t0 := times[0] if times.size() > 0 else 0.0
	var t1 := times[times.size() - 1] if times.size() > 0 else t0 + 0.2
	pending.append({"id": item.id, "frame": item.frame, "t0": t0, "t1": maxf(t1, t0 + 0.05)})
	failed = false
	_idle = 0.0
	board.changed.emit()


func forget(id: String) -> void:
	for i in range(pending.size() - 1, -1, -1):
		if pending[i].id == id:
			pending.remove_at(i)


func reset() -> void:
	pending.clear()
	busy = false
	failed = false


func has_pending() -> bool:
	return not pending.is_empty()


func update(dt: float) -> void:
	if pending.is_empty() or busy or failed or not bool(App.val("ink_auto")):
		_idle = 0.0
		return
	if board.pen_ctl.state == PenController.S.DRAWING:
		_idle = 0.0
		return
	_idle += dt
	if _idle >= float(App.val("ink_pause")):
		_idle = 0.0
		convert_ink()


## Convert the pending ink (or, with `items`, those strokes) to text.
func convert_ink(items: Array = []) -> void:
	if busy or board.doc == null:
		return
	var group: Array = []
	if items.is_empty():
		if pending.is_empty():
			return
		var frame_id: String = pending[0].frame
		for p in pending:
			if p.frame == frame_id and board.doc.items.has(p.id):
				group.append({"item": board.doc.items[p.id], "t0": p.t0, "t1": p.t1})
	else:
		var k := 0.0
		for it in items:
			if (it as Item).kind == Item.STROKE:
				group.append({"item": it, "t0": k, "t1": k + 0.3})
				k += 0.45
	if group.is_empty():
		pending.clear()
		return
	busy = true
	failed = false
	var lines := _segment_lines(group)
	_run_lines(lines, 0)


func _run_lines(lines: Array, idx: int) -> void:
	if idx >= lines.size():
		busy = false
		board.changed.emit()
		return
	var line: Dictionary = lines[idx]
	var strokes: Array = []
	var bb: Rect2 = line.bbox
	var k := clampf(PX_PER_LINE / maxf(bb.size.y, 0.012), 1500.0, 20000.0)
	var t_origin: float = line.t_min
	for e in line.entries:
		var it: Item = e.item
		var xs := PackedFloat32Array()
		var ys := PackedFloat32Array()
		var ts := PackedFloat32Array()
		var total := 0.0
		for i in range(1, it.point_count()):
			total += it.pt(i).distance_to(it.pt(i - 1))
		var run := 0.0
		for i in it.point_count():
			if i > 0:
				run += it.pt(i).distance_to(it.pt(i - 1))
			xs.append((it.pts[i * 4] - bb.position.x) * k + 20.0)
			ys.append((bb.end.y - it.pts[i * 4 + 1]) * k + 20.0)
			var f := run / maxf(total, 1e-6)
			ts.append((float(e.t0) - t_origin + f * (float(e.t1) - float(e.t0))) * 1000.0)
		strokes.append({"x": xs, "y": ys, "t": ts})
	var area := Vector2(bb.size.x * k + 40.0, bb.size.y * k + 40.0)
	board.toast.emit("Reading handwriting..." if idx == 0 else "Reading line %d..." % (idx + 1))
	provider().recognize(strokes, area, str(App.val("ink_language")), func(res: Dictionary):
		_on_line_result(lines, idx, res))


func _on_line_result(lines: Array, idx: int, res: Dictionary) -> void:
	if board.doc == null:
		busy = false
		return
	var line: Dictionary = lines[idx]
	if not bool(res.ok):
		last_error = str(res.error)
		failed = true
		busy = false
		board.toast.emit(last_error + " The ink stays on the canvas; press Convert to try again.")
		board.changed.emit()
		return
	var cands: PackedStringArray = res.candidates
	var text := cands[0].strip_edges()
	var items: Array = []
	for e in line.entries:
		if board.doc.items.has((e.item as Item).id):
			items.append(board.doc.items[(e.item as Item).id])
	if items.is_empty():
		_run_lines(lines, idx + 1)                  # the ink was erased or undone while the request was out
		return
	if text == "":
		board.toast.emit("Could not read that line.")
		_run_lines(lines, idx + 1)
		return
	var frame_id: String = (items[0] as Item).frame
	var bb: Rect2 = line.bbox
	var col: Color = (items[0] as Item).color
	var doc := board.doc
	var h := board.history
	var container := doc.shape_containing(frame_id, bb.get_center())
	h.begin_group()
	h.do(History.op_remove(items))
	if container != null and container.label == "" and bb.size.x < container.bounds().size.x * 1.1:
		var upd := container.duplicate_item(false)
		upd.label = text
		h.do(History.op_modify([container], [upd]))
	else:
		var fit := TextLayout.fit_ink(text, bb)
		var t := Item.make_text(frame_id, text, Color(col.r, col.g, col.b, 1.0), fit.em)
		t.center = fit.center
		for src in items:
			t.ink.append((src as Item).to_dict())
		var alts := PackedStringArray()
		for i in range(1, mini(cands.size(), 6)):
			if cands[i] != text:
				alts.append(cands[i])
		t.alternatives = alts
		h.do(History.op_add([t]))
	h.end_group()
	for e in line.entries:
		forget((e.item as Item).id)
	_run_lines(lines, idx + 1)


## Group strokes into lines of writing: top to bottom, each line left to right in writing order.
func _segment_lines(group: Array) -> Array:
	var sorted := group.duplicate()
	sorted.sort_custom(func(a, b): return (a.item as Item).bounds().get_center().y > (b.item as Item).bounds().get_center().y)
	var lines: Array = []
	for e in sorted:
		var bb := (e.item as Item).bounds()
		var placed := false
		for ln in lines:
			var band: Rect2 = ln.bbox
			var slack := maxf(band.size.y, 0.02) * 0.45
			var top := band.position.y - slack
			var bottom := band.end.y + slack
			var c := bb.get_center().y
			if c >= top and c <= bottom:
				ln.entries.append(e)
				ln.bbox = band.merge(bb)
				placed = true
				break
		if not placed:
			lines.append({"entries": [e], "bbox": bb})
	for ln in lines:
		(ln.entries as Array).sort_custom(func(a, b): return float(a.t0) < float(b.t0))
		var t_min := INF
		var bb2 := Rect2()
		var first := true
		for e in ln.entries:
			t_min = minf(t_min, float(e.t0))
			var b: Rect2 = (e.item as Item).bounds().grow(-(e.item as Item).width * 0.5)
			bb2 = b if first else bb2.merge(b)
			first = false
		ln.t_min = t_min
		ln.bbox = bb2
	lines.sort_custom(func(a, b): return a.bbox.get_center().y > b.bbox.get_center().y)
	return lines


## Text item whose handwriting was misread: swap in the next alternative reading.
func cycle_alternative(item_id: String) -> void:
	var it: Item = board.doc.items.get(item_id)
	if it == null or it.kind != Item.TEXT or it.alternatives.is_empty():
		return
	var upd := it.duplicate_item(false)
	var alts := PackedStringArray(it.alternatives)
	var next := alts[0]
	alts.remove_at(0)
	alts.append(it.text)
	upd.text = next
	upd.alternatives = alts
	upd.refit_text()
	board.history.do(History.op_modify([it], [upd]))


## Pick one of the other readings: it becomes the text and the old text joins the alternatives.
func choose_alternative(item_id: String, reading: String) -> void:
	var it: Item = board.doc.items.get(item_id)
	if it == null or it.kind != Item.TEXT or reading == it.text:
		return
	var upd := it.duplicate_item(false)
	var alts := PackedStringArray()
	for a in it.alternatives:
		if a != reading:
			alts.append(a)
	alts.append(it.text)
	upd.text = reading
	upd.alternatives = alts
	upd.refit_text()
	board.history.do(History.op_modify([it], [upd]))


## Swap converted text back for the handwriting it came from (works after the document was closed and reopened too).
func revert_to_ink(item_id: String) -> void:
	var it: Item = board.doc.items.get(item_id)
	if it == null or it.kind != Item.TEXT or it.ink.is_empty():
		board.toast.emit("This text has no handwriting to go back to.")
		return
	var strokes: Array = []
	var ids: Array = []
	for d in it.ink:
		var s := Item.from_dict(d)
		if not board.doc.items.has(s.id):
			strokes.append(s)
			ids.append(s.id)
	board.history.begin_group()
	board.history.do(History.op_remove([it]))
	if not strokes.is_empty():
		board.history.do(History.op_add(strokes))
	board.history.end_group()
	board.select_items(ids, it.frame)
	board.toast.emit("Back to your handwriting. Press To text to read it again.")


func set_text(item_id: String, new_text: String) -> void:
	var it: Item = board.doc.items.get(item_id)
	if it == null or it.kind != Item.TEXT or new_text == "":
		return
	var upd := it.duplicate_item(false)
	upd.text = new_text
	upd.refit_text()
	board.history.do(History.op_modify([it], [upd]))
