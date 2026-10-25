class_name LivePreview
extends Node3D
## What the others of a session are in the middle of doing, shown while they do it (LiveOut sends it): their stroke growing, items
## following their hand, a shape being resized, a stencil being dragged out, things the eraser has touched, a canvas being carried.
## Nothing here is in the document. When the real edit arrives it takes over: a stroke preview goes the moment the item with its id
## exists, a drag preview is reset by the item being rebuilt, a carried canvas is held where it was put until the document says so.
## Previews that stop being updated (the other headset lost its link, was taken off) go by themselves after a moment, and everything
## of a person goes when they leave. Everything that arrives is somebody else's data: it is checked, bounded and never trusted.

const STROKE_IDLE_S := 8.0                 # a pen can rest on the canvas this long without a point
const IDLE_S := 1.5                        # anything else goes if it is not repeated for this long
const KEEP_S := 1.0                        # an ended stroke waits this long for its item
const SETTLE_S := 1.0                      # a canvas that was put down waits this long for the document to say where
const MAX_POINTS := 1024                   # per message
const MAX_IDS := 2000
const MAX_ID_LEN := 64

var session: Session

var _now := 0.0
var _strokes: Dictionary = {}              # "from/source" -> {ls, fn, id, n, seen, ended, end_t, keep, ghost}
var _drags: Dictionary = {}                # -> {fn, ids, t, seen}
var _works: Dictionary = {}                # -> {fn, id, ghost, view, seen}
var _erases: Dictionary = {}               # -> {ids, seen}
var _grabs: Dictionary = {}                # frame id -> {from, seen, ended, end_t, xf, scale}


func _ready() -> void:
	name = "LivePreview"


func count() -> int:
	return _strokes.size() + _drags.size() + _works.size() + _erases.size() + _grabs.size()


func stroke_count() -> int:
	return _strokes.size()


func stroke_points(key_prefix: String = "") -> int:
	var n := 0
	for k in _strokes:
		if str(k).begins_with(key_prefix):
			n += int((_strokes[k] as Dictionary).n)
	return n


# ------------------------------------------------------------------------------------------------ what arrives

## One message from `from` (see LiveOut for the kinds).
func apply(from: int, m: Dictionary) -> void:
	var board := _board()
	if board == null or board.doc == null:
		return
	var key := "%d/%s" % [from, str(m.get("key", "")).left(16)]
	match str(m.get("k", "")):
		"s":
			_on_stroke(board, key, m)
		"e":
			_on_stroke_end(key, m)
		"d":
			_on_drag(board, key, m)
		"w":
			_on_work(board, key, m)
		"x":
			_on_erase(board, key, m)
		"g":
			_on_grab(board, from, m)


func _board() -> Board:
	return session.board if session != null else null


func _canvas(board: Board, frame_id: Variant) -> FrameNode:
	var fn: FrameNode = board.frame_nodes.get(str(frame_id).left(MAX_ID_LEN))
	return fn if fn != null and fn.is_canvas else null


func _on_stroke(board: Board, key: String, m: Dictionary) -> void:
	var p: Variant = m.get("p")
	if not (p is PackedFloat32Array) or (p as PackedFloat32Array).size() % 4 != 0 or (p as PackedFloat32Array).size() > MAX_POINTS * 4:
		return
	var pts: PackedFloat32Array = p
	var i := int(m.get("i", 0))
	var rec: Dictionary = _strokes.get(key, {})
	if i == 0:
		_free_stroke(key)
		var fn := _canvas(board, m.get("f"))
		if fn == null:
			return
		var brush := str(Brushes.get_def(str(m.get("b", ""))).id)
		var ls := LiveStroke.new()
		fn.add_live(ls)
		ls.begin(false, brush, U.color_from(str(m.get("c", ""))), clampf(float(m.get("w", 0.004)), 0.0002, 0.5), Brushes.priority(brush, board.doc.next_z))
		rec = {"ls": ls, "fn": fn, "id": str(m.get("id", "")).left(MAX_ID_LEN), "n": 0, "seen": _now, "ended": false, "end_t": 0.0, "keep": false}
		_strokes[key] = rec
	elif rec.is_empty() or int(rec.n) != i or str(m.get("id", "")) != str(rec.id):
		return                                       # not the stroke we have been following (we joined half way): wait for the next one
	var ls2: LiveStroke = rec.ls
	for k in pts.size() / 4:
		var x := pts[k * 4]
		var y := pts[k * 4 + 1]
		if is_finite(x + y) and absf(x) < 1000.0 and absf(y) < 1000.0:
			ls2.add_point(x, y, 0.0, clampf(pts[k * 4 + 3], 0.0, 1.0))
	rec.n = int(rec.n) + pts.size() / 4
	rec.seen = _now
	ls2.visible = bool(m.get("vis", true))


func _on_stroke_end(key: String, m: Dictionary) -> void:
	var rec: Dictionary = _strokes.get(key, {})
	if rec.is_empty() or str(m.get("id", "")) != str(rec.id):
		return
	if bool(m.get("keep", false)):
		rec.ended = true                             # its item is on its way: the preview stays until it is here
		rec.end_t = _now
		rec.keep = true
	else:
		_free_stroke(key)                            # thrown away, or replaced by something else that comes as its own edit


func _on_drag(board: Board, key: String, m: Dictionary) -> void:
	if bool(m.get("end", false)):
		_free_drag(key)
		return
	var fn := _canvas(board, m.get("f"))
	var ids_v: Variant = m.get("ids")
	var t: Variant = m.get("t")
	if fn == null or not (ids_v is Array) or not (t is Transform3D) or (ids_v as Array).size() > MAX_IDS:
		return
	if not (t as Transform3D).origin.is_finite() or not (t as Transform3D).basis.x.is_finite():
		return
	var ids: Array = []
	for id in ids_v:
		ids.append(str(id).left(MAX_ID_LEN))
	var rec: Dictionary = _drags.get(key, {})
	var objs := {}                                   # the item each id was when its preview began: once the document replaces it, the real move is here
	for id in ids:
		objs[id] = rec.objs[id] if (not rec.is_empty() and rec.objs.has(id)) else board.doc.items.get(id)
	if not rec.is_empty():
		for old in rec.ids:
			if not ids.has(old):
				_reset_view(rec.fn, old)
	_drags[key] = {"fn": fn, "ids": ids, "objs": objs, "t": t, "seen": _now}
	_show_drag(board, _drags[key])


func _on_work(board: Board, key: String, m: Dictionary) -> void:
	if bool(m.get("end", false)):
		var w: Dictionary = _works.get(key, {})
		var stroke_going: bool = _strokes.has(key) and not bool((_strokes[key] as Dictionary).ended)
		if not w.is_empty() and bool(w.ghost) and bool(m.get("keep", false)) and not stroke_going:
			w.ended = true                           # it becomes the item with this id: shown until that is here
			w.end_t = _now
		else:
			_free_work(key)                          # cancelled, or a snap the pen moved away from
		return
	var fn := _canvas(board, m.get("f"))
	var d: Variant = m.get("item")
	if fn == null or not (d is Dictionary) or str((d as Dictionary).get("id", "")) == "" or str((d as Dictionary).get("id", "")).length() > MAX_ID_LEN:
		return
	var it := Item.from_dict(d)
	if it.kind != Item.SHAPE:
		return
	it.frame = str(fn.data.id)
	var ghost := bool(m.get("ghost", false))
	var rec: Dictionary = _works.get(key, {})
	if not rec.is_empty() and (str(rec.id) != it.id or rec.fn != fn):
		_free_work(key)
		rec = {}
	if rec.is_empty():
		rec = {"fn": fn, "id": it.id, "ghost": ghost, "view": null, "seen": _now, "ended": false, "end_t": 0.0, "obj": board.doc.items.get(it.id)}
		_works[key] = rec
	elif not ghost and board.doc.items.get(it.id) != rec.obj:
		return                                       # the real edit has landed; a late preview must not undo it
	rec.seen = _now
	if ghost:
		var v: ItemView = rec.view
		if v == null or not is_instance_valid(v):
			v = ItemView.new()
			fn.add_live(v)
			v.setup(it, false)
			rec.view = v
		else:
			v.item = it
			v.rebuild()
	else:
		var v2 := fn.view_of(it.id)                  # the shape that is being reshaped: its own view shows the new shape
		if v2 != null:
			v2.item = it
			v2.rebuild()
			rec.view = v2


func _on_erase(board: Board, key: String, m: Dictionary) -> void:
	if bool(m.get("end", false)):
		_free_erase(key)
		return
	var ids_v: Variant = m.get("ids")
	if not (ids_v is Array) or (ids_v as Array).size() > MAX_IDS:
		return
	var ids: Array = []
	for id in ids_v:
		var sid := str(id).left(MAX_ID_LEN)
		var it: Item = board.doc.items.get(sid)
		var fn: FrameNode = board.frame_nodes.get(it.frame) if it != null else null
		var v: ItemView = fn.view_of(sid) if fn != null else null
		if v != null:
			v.visible = false
			ids.append(sid)
	_erases[key] = {"ids": ids, "seen": _now}


func _on_grab(board: Board, from: int, m: Dictionary) -> void:
	var fid := str(m.get("f", "")).left(MAX_ID_LEN)
	if not board.frame_nodes.has(fid):
		return
	if bool(m.get("end", false)):
		var g: Dictionary = _grabs.get(fid, {})
		if not g.is_empty() and int(g.from) == from:
			g.ended = true
			g.end_t = _now
		return
	var xf: Variant = m.get("xf")
	if not (xf is Transform3D) or not (xf as Transform3D).origin.is_finite() or not (xf as Transform3D).basis.x.is_finite():
		return
	if board.grabs.has(fid):
		return                                       # this headset is carrying it itself
	var sc := clampf(float(m.get("s", 1.0)), 0.15, 8.0)
	var had: Dictionary = _grabs.get(fid, {})
	var frame_then: FrameData = had.frame if not had.is_empty() else board.doc.frames.get(fid)
	_grabs[fid] = {"from": from, "seen": _now, "ended": false, "end_t": 0.0, "frame": frame_then}
	board.remote_grabs[fid] = {"xf": xf, "scale": sc}


# ------------------------------------------------------------------------------------------------ every frame

func _process(delta: float) -> void:
	_now += delta
	var board := _board()
	if board == null or board.doc == null:
		return
	for key in _strokes.keys():
		var r: Dictionary = _strokes[key]
		if not is_instance_valid(r.ls) or not is_instance_valid(r.fn):
			_free_stroke(key)
			continue
		(r.ls as LiveStroke).flush()
		var arrived := board.doc.items.has(str(r.id))
		if arrived or (bool(r.ended) and _now - float(r.end_t) > KEEP_S) or (not bool(r.ended) and _now - float(r.seen) > STROKE_IDLE_S):
			_free_stroke(key)
			_free_work_with_id(str(r.id))
	for key in _drags.keys():
		var d: Dictionary = _drags[key]
		if not is_instance_valid(d.fn) or _now - float(d.seen) > IDLE_S:
			_free_drag(key)
		else:
			_show_drag(board, d)                     # views are rebuilt by other edits meanwhile: keep them where the hand has them
	for key in _works.keys():
		var w: Dictionary = _works[key]
		var gone: bool = not is_instance_valid(w.fn) or (not bool(w.ended) and _now - float(w.seen) > IDLE_S)
		if bool(w.ghost) and (board.doc.items.has(str(w.id)) or (bool(w.ended) and _now - float(w.end_t) > KEEP_S)):
			gone = true                              # the real item has arrived, or is not coming
		if gone:
			_free_work(key)
	for key in _erases.keys():
		if _now - float((_erases[key] as Dictionary).seen) > IDLE_S:
			_free_erase(key)
	for fid in _grabs.keys():
		var g2: Dictionary = _grabs[fid]
		var f: FrameData = board.doc.frames.get(fid)
		var drop := f == null
		if not drop and bool(g2.ended):
			drop = f != g2.frame or _now - float(g2.end_t) > SETTLE_S     # the document has the canvas as it was put down (a new FrameData), or it never will
		elif not drop and _now - float(g2.seen) > IDLE_S:
			drop = true
		if drop:
			_grabs.erase(fid)
			board.remote_grabs.erase(fid)


# ------------------------------------------------------------------------------------------------ taking things away

func _show_drag(board: Board, d: Dictionary) -> void:
	for id in (d.ids as Array).duplicate():
		if board.doc.items.get(id) != d.objs.get(id):
			(d.ids as Array).erase(id)               # replaced by the real edit: its view is already where it belongs
			continue
		var v: ItemView = (d.fn as FrameNode).view_of(id)
		if v != null:
			v.set_preview(d.t)


func _reset_view(fn: FrameNode, id: String) -> void:
	if is_instance_valid(fn):
		var v := fn.view_of(id)
		if v != null:
			v.set_preview(Transform3D.IDENTITY)


func _free_stroke(key: String) -> void:
	var r: Dictionary = _strokes.get(key, {})
	if r.is_empty():
		return
	if is_instance_valid(r.ls):
		(r.ls as Node).queue_free()
	_strokes.erase(key)


func _free_drag(key: String) -> void:
	var d: Dictionary = _drags.get(key, {})
	if d.is_empty():
		return
	for id in d.ids:
		_reset_view(d.fn, id)
	_drags.erase(key)


func _free_work(key: String) -> void:
	var w: Dictionary = _works.get(key, {})
	if w.is_empty():
		return
	_works.erase(key)
	var board := _board()
	if bool(w.ghost):
		if w.view != null and is_instance_valid(w.view):
			(w.view as Node).queue_free()
	elif board != null and board.doc != null and is_instance_valid(w.fn):
		var it: Item = board.doc.items.get(str(w.id))
		if it != null:
			(w.fn as FrameNode).refresh_view(it)     # the shape as the document has it


func _free_work_with_id(id: String) -> void:
	for key in _works.keys():
		if str((_works[key] as Dictionary).id) == id and bool((_works[key] as Dictionary).ghost):
			_free_work(key)


func _free_erase(key: String) -> void:
	var e: Dictionary = _erases.get(key, {})
	if e.is_empty():
		return
	var board := _board()
	if board != null and board.doc != null:
		for id in e.ids:
			var it: Item = board.doc.items.get(id)
			var fn: FrameNode = board.frame_nodes.get(it.frame) if it != null else null
			var v: ItemView = fn.view_of(id) if fn != null else null
			if v != null:
				v.visible = true
	_erases.erase(key)


## Everything one person was doing (they left, or their link broke).
func clear_peer(id: int) -> void:
	var prefix := "%d/" % id
	for key in _strokes.keys():
		if str(key).begins_with(prefix):
			_free_stroke(key)
	for key in _drags.keys():
		if str(key).begins_with(prefix):
			_free_drag(key)
	for key in _works.keys():
		if str(key).begins_with(prefix):
			_free_work(key)
	for key in _erases.keys():
		if str(key).begins_with(prefix):
			_free_erase(key)
	var board := _board()
	for fid in _grabs.keys():
		if int((_grabs[fid] as Dictionary).from) == id:
			_grabs.erase(fid)
			if board != null:
				board.remote_grabs.erase(fid)


func clear_all() -> void:
	for key in _strokes.keys():
		_free_stroke(key)
	for key in _drags.keys():
		_free_drag(key)
	for key in _works.keys():
		_free_work(key)
	for key in _erases.keys():
		_free_erase(key)
	_grabs.clear()
	var board := _board()
	if board != null:
		board.remote_grabs.clear()
