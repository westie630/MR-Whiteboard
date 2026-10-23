class_name InkController
extends RefCounted
## Handwriting to text. In Write mode the strokes stay on the canvas as ink; once the pen has rested for a moment (or Convert is
## pressed) they are grouped into lines, sent to the recogniser, and each line is replaced by a text item in the chosen text style
## (Body, Heading 1, ...: the size of typed text, not of the handwriting), centred where the handwriting was. Ink written inside a box becomes that box's label. The original ink comes back with Undo.
##
## Predicted, so the tool rarely has to be switched (WritingDetector decides from the shape of the ink):
##  - in Write mode a line, an underline, an arrow or a box drawn among the words is kept as a drawing, not read as text;
##  - with the Pen, strokes that look like words are watched: once the pen rests, `suggestion` offers them for conversion (InkChip),
##    or converts them at once when the setting says so;
##  - right after a conversion, the new text is `recent_text()` for a few seconds, so its other readings can be offered beside it.

const PX_PER_LINE := 150.0                 # the recogniser sees a line of handwriting about this many units tall

var board: Board
var pending: Array = []                    # [{id, frame, t0, t1}]
var busy := false
var failed := false
var last_error := ""

var _idle := 0.0
var _provider: InkRecognizer

const WATCH_GAP_S := 4.0                   # a pen stroke this long after the last one starts a new group
const WATCH_REST_S := 0.6                  # the pen rests this long before a group is judged
const RECENT_S := 9.0                      # converted text offers its other readings this long

## Pen strokes that look like writing, offered for conversion: {frame, ids, rect (canvas units), score}, or {}.
var suggestion: Dictionary = {}
var _watch: Array = []                     # [{id, frame, t0, t1, at}] pen strokes drawn one after the other, close together
var _watch_idle := 0.0
var _watch_sig := ""
var _dismissed := {}                       # stroke ids the user said are a drawing
var _marks: Array = []                     # Write mode: recent strokes kept as drawings [{frame, a, b, len, at}] (m)
var _told_marks := false
var _recent_text := ""
var _recent_t := 0.0
var _clock := 0.0


func _init(b: Board) -> void:
	board = b


func provider() -> InkRecognizer:
	var want := str(App.val("ink_provider"))
	if _provider == null or _provider.name_of() != want:
		_provider = GoogleInk.new(board) if want == "google" else InkRecognizer.new()
	return _provider


## A stroke written in Write mode. False when it is not writing (a line, a box, an arrow among the words): it stays a drawing.
func add(item: Item, times: PackedFloat32Array) -> bool:
	var scale := _scale(item.frame)
	var f := WritingDetector.features(item, scale)
	if WritingDetector.is_mark(f, _letter_height(item.frame, scale)) or _after_mark(item.frame, f):
		_marks.append({"frame": item.frame, "a": f.a, "b": f.b, "len": float(f.length), "at": _clock})
		if not _told_marks:
			_told_marks = true
			board.toast.emit("Kept as a drawing: lines, boxes and arrows are not read as text")
		return false
	var t0 := times[0] if times.size() > 0 else 0.0
	var t1 := times[times.size() - 1] if times.size() > 0 else t0 + 0.2
	pending.append({"id": item.id, "frame": item.frame, "t0": t0, "t1": maxf(t1, t0 + 0.05)})
	failed = false
	_idle = 0.0
	board.changed.emit()
	return true


func _scale(frame_id: String) -> float:
	var fd: FrameData = board.doc.frames.get(frame_id) if board.doc != null else null
	return fd.scale if fd != null else 1.0


## The height of the handwriting waiting on a canvas (m), 0 with none.
func _letter_height(frame_id: String, scale: float) -> float:
	var fs: Array = []
	for p in pending:
		if p.frame == frame_id and board.doc.items.has(p.id):
			fs.append(WritingDetector.features(board.doc.items[p.id], scale))
	return WritingDetector.letter_height(fs)


func _after_mark(frame_id: String, f: Dictionary) -> bool:
	for m in _marks:
		if m.frame == frame_id and _clock - float(m.at) < 2.5 and WritingDetector.attached(f, m.a, m.b, float(m.len)):
			return true
	return false


# ------------------------------------------------------------------------------------------------ the pen notices writing

## A stroke drawn with the Pen tool: watched, in case it is part of words.
func observe(item: Item, times: PackedFloat32Array) -> void:
	if str(App.val("smart_ink")) == "off" or str(App.val("ink_provider")) == "none" or item.kind != Item.STROKE:
		return
	if not _watch.is_empty():
		var last: Dictionary = _watch[_watch.size() - 1]
		if last.frame != item.frame or _clock - float(last.at) > WATCH_GAP_S or not _near_watch(item):
			_watch.clear()
	var t0 := times[0] if times.size() > 0 else 0.0
	var t1 := times[times.size() - 1] if times.size() > 0 else t0 + 0.2
	_watch.append({"id": item.id, "frame": item.frame, "t0": t0, "t1": maxf(t1, t0 + 0.05), "at": _clock})
	if _watch.size() > 80:
		_watch.pop_front()
	_watch_idle = 0.0
	if not suggestion.is_empty():
		suggestion = {}
		board.changed.emit()


func _watched_items() -> Array:
	var out: Array = []
	for w in _watch:
		var it: Item = board.doc.items.get(w.id) if board.doc != null else null
		if it != null and it.kind == Item.STROKE and not _dismissed.has(w.id):
			out.append(it)
	return out


## Is a new stroke next to the group being watched (on its line, or the line under it)?
func _near_watch(item: Item) -> bool:
	var items := _watched_items()
	if items.is_empty():
		return true
	var r := (items[0] as Item).bounds()
	for it in items:
		r = r.merge((it as Item).bounds())
	var fs: Array = items.map(func(x): return WritingDetector.features(x, 1.0))
	var h := maxf(WritingDetector.letter_height(fs), 0.01)
	return r.grow_individual(h * 2.5, h * 2.6, h * 2.5, h * 1.2).intersects(item.bounds())


func _update_watch(dt: float) -> void:
	if _watch.is_empty() or board.doc == null:
		return
	if board.pen_ctl.state == PenController.S.DRAWING:
		_watch_idle = 0.0
		return
	if not suggestion.is_empty():
		for id in suggestion.ids:
			if not board.doc.items.has(id):
				suggestion = {}
				_watch.clear()
				board.changed.emit()
				return
		return
	_watch_idle += dt
	if _watch_idle < WATCH_REST_S:
		return
	var items := _watched_items()
	var sig := ",".join(PackedStringArray(items.map(func(x): return (x as Item).id)))
	if sig == _watch_sig or items.is_empty():
		return
	_watch_sig = sig
	var frame_id: String = (items[0] as Item).frame
	var score := WritingDetector.group_score(items, _scale(frame_id))
	if score < WritingDetector.SUGGEST:
		return
	var r := (items[0] as Item).bounds()
	for it in items:
		r = r.merge((it as Item).bounds())
	suggestion = {"frame": frame_id, "ids": items.map(func(x): return (x as Item).id), "rect": r, "score": score}
	if str(App.val("smart_ink")) == "auto" and score >= WritingDetector.AUTO and not busy:
		accept_suggestion()
	else:
		board.changed.emit()


## Turn the strokes the pen offered into text.
func accept_suggestion() -> void:
	if suggestion.is_empty() or busy:
		return
	var ids: Array = suggestion.ids
	var fid: String = suggestion.frame
	pending = pending.filter(func(p): return p.frame == fid)
	for w in _watch:
		if ids.has(w.id):
			pending.append({"id": w.id, "frame": w.frame, "t0": w.t0, "t1": w.t1})
	_watch.clear()
	suggestion = {}
	failed = false
	convert_ink()


## The strokes the pen offered are a drawing after all: they are not offered again.
func dismiss_suggestion() -> void:
	for id in suggestion.get("ids", []):
		_dismissed[id] = true
	_watch.clear()
	suggestion = {}
	board.changed.emit()


## Text made from handwriting a moment ago (its other readings are offered beside it), or null.
func recent_text() -> Item:
	if _recent_text == "" or board.doc == null:
		return null
	return board.doc.items.get(_recent_text)


func clear_recent() -> void:
	if _recent_text != "":
		_recent_text = ""
		board.changed.emit()


func forget(id: String) -> void:
	for i in range(pending.size() - 1, -1, -1):
		if pending[i].id == id:
			pending.remove_at(i)


func reset() -> void:
	pending.clear()
	busy = false
	failed = false
	suggestion = {}
	_watch.clear()
	_marks.clear()
	_dismissed.clear()
	_recent_text = ""


func has_pending() -> bool:
	return not pending.is_empty()


func update(dt: float) -> void:
	_clock += dt
	if _recent_text != "":
		_recent_t += dt
		if _recent_t > RECENT_S or board.pen_ctl.state == PenController.S.DRAWING:
			clear_recent()
	_update_watch(dt)
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
		var st := TextLayout.style(str(App.val("text_style")))
		var t := Item.make_text(frame_id, text, Color(col.r, col.g, col.b, 1.0), float(st[2]), int(st[3]))
		t.center = bb.get_center()
		for src in items:
			t.ink.append((src as Item).to_dict())
		var alts := PackedStringArray()
		for i in range(1, mini(cands.size(), 6)):
			if cands[i] != text:
				alts.append(cands[i])
		t.alternatives = alts
		h.do(History.op_add([t]))
		_recent_text = t.id
		_recent_t = 0.0
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
