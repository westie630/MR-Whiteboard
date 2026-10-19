class_name PenController
extends RefCounted
## Everything the pen does to the board: draw (with hold-to-snap shape recognition), write (handwriting to text), erase, select
## (tap, lasso, drag, resize / rotate handles), place stencil shapes, grab with the front button, undo with the back button.
## Works the same for the MX Ink stylus, the mouse and a pinch.

enum S { IDLE, DRAWING, ERASING, LASSO, DRAG_ITEMS, DRAG_HANDLE, SHAPE_DRAG, GRAB_FRAME }

const MIN_STEP := 0.0009                   # metres between stroke samples
const HOLD_MOVE := 0.004                   # the pen counts as still while it stays within this
const UNSNAP_MOVE := 0.012
const ERASE_R := 0.014
const PICK_R := 0.013
const HANDLE_R := 0.011                    # drawn radius of a handle (world metres)
const HANDLE_HIT := 0.024
const BACK_DOUBLE_S := 0.32
const HOVER_REACH := 0.25

var board: Board
var state := S.IDLE
var cursor_frame := ""
var cursor_pos := Vector2.ZERO
var cursor_dist := 0.0
var lasso := PackedVector2Array()
var snapped_shape := ""                    # id of the shape the stroke has snapped to (for the toast / UI)

var _live: LiveStroke
var _live_fn: FrameNode
var _live_volume := false
var _write_mode := false
var _filter := OneEuro3.new(2.2, 45.0)
var _pressure := 0.5
var _prev_down := false
var _prev_front := false
var _prev_back := false
var _back_wait := -1.0
var _hold_t := 0.0
var _hold_anchor := Vector3.ZERO
var _snap: Dictionary = {}
var _snap_anchor := Vector3.ZERO
var _ghost_item: Item
var _ghost_view: ItemView
var _erase_set: Dictionary = {}
var _drag_fn: FrameNode
var _drag_start := Vector2.ZERO
var _drag_ids: Array = []
var _drag_btn_front := false
var _drag_delta := Vector2.ZERO
var _drag3_start := Vector3.ZERO
var _handle: Dictionary = {}
var _work: Item
var _orig: Item
var _group_before := Rect2()
var _shape_fn: FrameNode
var _shape_a := Vector2.ZERO
var _grab_f: FrameData
var _grab_tip0 := Vector3.ZERO
var _grab_origin0 := Vector3.ZERO
var _lasso_fn: FrameNode


func _init(b: Board) -> void:
	board = b


# ------------------------------------------------------------------------------------------------ per frame

func update(pen: PenState, dt: float) -> void:
	_handle_back(pen, dt)
	if not pen.tracked or pen.docked:
		if state != S.IDLE:
			_finish(pen)
		cursor_frame = ""
		_prev_down = false
		_prev_front = false
		return
	var down_edge := pen.down and not _prev_down
	var front_edge := pen.front and not _prev_front
	if state == S.IDLE:
		_update_cursor(pen)
		if front_edge:
			_begin_front(pen)
		elif down_edge:
			_begin_down(pen)
	else:
		match state:
			S.DRAWING:
				_step_draw(pen, dt)
			S.ERASING:
				_step_erase(pen)
			S.LASSO:
				_step_lasso(pen)
			S.DRAG_ITEMS:
				_step_drag_items(pen)
			S.DRAG_HANDLE:
				_step_handle(pen)
			S.SHAPE_DRAG:
				_step_shape(pen)
			S.GRAB_FRAME:
				_step_grab(pen)
		var released := (not pen.down) if state in [S.DRAWING, S.ERASING, S.LASSO, S.SHAPE_DRAG, S.DRAG_HANDLE] else false
		if state == S.DRAG_ITEMS or state == S.GRAB_FRAME:
			released = (not pen.front) if _drag_btn_front else (not pen.down)
		if released:
			_finish(pen)
	_prev_down = pen.down
	_prev_front = pen.front


func flush_live() -> void:
	if _live != null:
		_live.flush()


func _handle_back(pen: PenState, dt: float) -> void:
	var edge := pen.back and not _prev_back
	_prev_back = pen.back
	if edge:
		if _back_wait > 0.0:
			_back_wait = -1.0
			board.redo()
			board.toast.emit("Redo")
		else:
			_back_wait = BACK_DOUBLE_S
	elif _back_wait > 0.0:
		_back_wait -= dt
		if _back_wait <= 0.0:
			_back_wait = -1.0
			board.undo()
			board.toast.emit("Undo")


func _update_cursor(pen: PenState) -> void:
	var t := board.pen_target(pen.tip, HOVER_REACH, 0.3)
	if t.is_empty():
		cursor_frame = ""
		return
	var fn := t.fn as FrameNode
	cursor_frame = fn.data.id
	cursor_pos = Vector2(t.local.x, t.local.y)
	cursor_dist = float(t.dist)


# ------------------------------------------------------------------------------------------------ beginnings

func _begin_down(pen: PenState) -> void:
	_filter.reset()
	_pressure = maxf(pen.pressure, 0.2)
	match str(App.val("tool")):
		"draw":
			_begin_draw(pen, false)
		"write":
			_begin_draw(pen, true)
		"erase":
			_begin_erase(pen)
		"select":
			_begin_select(pen)
		"shape":
			_begin_shape(pen)


func _brush_width(fn: FrameNode) -> float:
	return float(App.val("width")) / fn.data.scale


func _begin_draw(pen: PenState, write: bool) -> void:
	var t := board.pen_target(pen.tip, Board.CAPTURE)
	var fn: FrameNode
	var volume := false
	if not t.is_empty():
		fn = t.fn
	else:
		if write:
			board.toast.emit("Handwriting goes on a canvas: bring the stylus to a canvas first.")
			return
		fn = board.active_volume()
		if fn == null:
			fn = board.new_volume_at(pen.tip)
		volume = true
	if fn == null:
		return
	_live_fn = fn
	_live_volume = volume
	_write_mode = write
	var brush := str(App.val("brush"))
	_live = LiveStroke.new()
	fn.add_live(_live)
	var col: Color = App.val("color")
	if write:
		brush = "pen"
	_live.begin(volume, brush, col, _brush_width(fn), Brushes.priority(brush, board.doc.next_z))
	_add_sample(pen, fn, 0.011, true)
	_snap = {}
	_hold_t = 0.0
	_hold_anchor = _live.last_point()
	state = S.DRAWING
	if not volume:
		board.active_frame = fn.data.id
	pen.tick(0.15, 0.01)


func _begin_erase(pen: PenState) -> void:
	_erase_set.clear()
	state = S.ERASING
	_step_erase(pen)


func _begin_shape(pen: PenState) -> void:
	var t := board.pen_target(pen.tip, Board.CAPTURE)
	if t.is_empty():
		board.toast.emit("Stencil shapes go on a canvas: bring the stylus to a canvas first.")
		return
	_shape_fn = t.fn
	_shape_a = Vector2(t.local.x, t.local.y)
	var id := board.stencil
	var rec := {"shape": id}
	if Shapes.is_line(id):
		rec.a = _shape_a
		rec.b = _shape_a + Vector2(0.05, 0)
	else:
		rec.center = _shape_a
		rec.size = Shapes.default_size(id)
	_ghost_item = board.make_shape(_shape_fn.data.id, rec)
	_ghost_view = ItemView.new()
	_shape_fn.add_live(_ghost_view)
	_ghost_view.setup(_ghost_item, false)
	state = S.SHAPE_DRAG


func _begin_select(pen: PenState) -> void:
	var t := board.pen_target(pen.tip, Board.CAPTURE, 0.3)
	if t.is_empty():
		_begin_select_volume(pen)
		return
	var fn := t.fn as FrameNode
	var s := fn.data.scale
	var l := Vector2(t.local.x, t.local.y)
	# a handle of the current selection?
	if board.sel_frame == fn.data.id and not board.selection.is_empty():
		var h := hit_handle(fn, l)
		if not h.is_empty():
			_start_handle(fn, h, l)
			return
	var it := board.doc.pick(fn.data.id, l, PICK_R / s)
	if it != null:
		if not board.selection.has(it.id):
			board.select_items([it.id], fn.data.id)
		_start_drag_items(fn, l, false)
		return
	board.clear_selection()
	lasso = PackedVector2Array([l])
	_lasso_fn = fn
	state = S.LASSO


func _begin_select_volume(pen: PenState) -> void:
	var best: Item = null
	var best_d := 0.03
	var best_fn: FrameNode
	for fn in board.visible_frames(FrameData.VOLUME):
		var n := fn as FrameNode
		var lp := n.to_local_point(pen.tip)
		for it in board.doc.items_of(n.data.id):
			var item: Item = it
			for i in item.point_count() - 1:
				var a := item.pt(i)
				var b := item.pt(i + 1)
				var d := Geometry3D.get_closest_point_to_segment(lp, a, b).distance_to(lp) * n.data.scale
				if d < best_d:
					best_d = d
					best = item
					best_fn = n
	if best != null:
		board.select_items([best.id], best_fn.data.id)
		_drag_fn = best_fn
		_drag_ids = [best.id]
		_drag3_start = best_fn.to_local_point(pen.tip)
		_drag_btn_front = false
		_drag_delta = Vector2.ZERO
		state = S.DRAG_ITEMS
	else:
		board.clear_selection()


func _begin_front(pen: PenState) -> void:
	# front button: grab what is under the tip (an item, or else the whole canvas / 3D sketch)
	var t := board.pen_target(pen.tip, 0.14, 0.2)
	if not t.is_empty():
		var fn := t.fn as FrameNode
		var l := Vector2(t.local.x, t.local.y)
		var it := board.doc.pick(fn.data.id, l, PICK_R * 1.6 / fn.data.scale)
		if it != null:
			if not board.selection.has(it.id):
				board.select_items([it.id], fn.data.id)
			_start_drag_items(fn, l, true)
			return
	var p := board.pick_frame(pen.tip)
	if not p.is_empty() and not (p.fn as FrameNode).data.locked:
		_grab_f = (p.fn as FrameNode).data
		board.begin_grab(_grab_f)
		if board.grabs.has(_grab_f.id):
			_grab_tip0 = pen.tip
			_grab_origin0 = ((board.grabs[_grab_f.id] as Dictionary).xf as Transform3D).origin
			_drag_btn_front = true
			state = S.GRAB_FRAME
			pen.tick(0.3, 0.02)


func _start_drag_items(fn: FrameNode, l: Vector2, front: bool) -> void:
	_drag_fn = fn
	_drag_start = l
	_drag_ids = board.selection.duplicate()
	_drag_btn_front = front
	_drag_delta = Vector2.ZERO
	state = S.DRAG_ITEMS


# ------------------------------------------------------------------------------------------------ drawing

func _add_sample(pen: PenState, fn: FrameNode, dt: float, first: bool = false) -> bool:
	var tip := pen.tip
	if pen.source == "stylus":
		tip = _filter.filter(tip, dt)
	_pressure = lerpf(_pressure, maxf(pen.pressure, 0.08), 0.45)
	var l := fn.to_local_point(tip)
	if not _live_volume:
		l.z = 0.0
	var s := fn.data.scale
	if not first and _live.point_count() > 0 and l.distance_to(_live.last_point()) < MIN_STEP / s:
		return false
	_live.add_point(l.x, l.y, l.z, _pressure)
	return true


func _step_draw(pen: PenState, dt: float) -> void:
	var fn := _live_fn
	if fn == null or not is_instance_valid(fn):
		_abort()
		return
	_add_sample(pen, fn, dt)
	var cur := _live.last_point()
	var s := fn.data.scale
	if cur.distance_to(_hold_anchor) * s > HOLD_MOVE:
		_hold_anchor = cur
		_hold_t = 0.0
	else:
		_hold_t += dt
	var mode := str(App.val("recognize"))
	if mode == "hold" and not _live_volume and not _write_mode and _snap.is_empty() and _live.point_count() >= 6 and _hold_t >= float(App.val("hold_seconds")):
		_try_snap(pen)
	if not _snap.is_empty() and cur.distance_to(_snap_anchor) * s > UNSNAP_MOVE * 2.0:
		_unsnap()
	if not _live_volume:
		cursor_frame = fn.data.id
		cursor_pos = Vector2(cur.x, cur.y)
		cursor_dist = 0.0


func _try_snap(pen: PenState) -> void:
	var pts := PackedVector2Array()
	for i in _live.point_count():
		pts.append(Vector2(_live.pts[i * 4], _live.pts[i * 4 + 1]))
	var rec := ShapeRecognizer.recognize(pts)
	_hold_t = -1000.0 if rec.is_empty() else _hold_t           # no shape in this stroke: do not retry until the pen moves again
	if rec.is_empty():
		return
	_snap = rec
	_snap_anchor = _live.last_point()
	_ghost_item = board.make_shape(_live_fn.data.id, rec)
	_ghost_view = ItemView.new()
	_live_fn.add_live(_ghost_view)
	_ghost_view.setup(_ghost_item, false)
	_live.visible = false
	snapped_shape = str(rec.shape)
	pen.tick(0.6, 0.03)
	board.toast.emit("Snapped to %s" % Shapes.name_of(str(rec.shape)).to_lower())


func _unsnap() -> void:
	_snap = {}
	if _ghost_view != null:
		_ghost_view.queue_free()
		_ghost_view = null
	_ghost_item = null
	if _live != null:
		_live.visible = true
	_hold_t = 0.0
	snapped_shape = ""


func _finish_draw() -> void:
	var fn := _live_fn
	var doc := board.doc
	if _live == null or fn == null or not is_instance_valid(fn):
		_abort()
		return
	var s := fn.data.scale
	var item: Item
	if not _snap.is_empty() and _ghost_item != null:
		item = _ghost_item
	else:
		var pts := StrokeMesher.decimate(_live.pts, 0.0015 / s)
		pts = StrokeMesher.smooth(pts, 1)
		var mode := str(App.val("recognize"))
		var rec := {}
		if not _live_volume and mode == "auto" and not _write_mode:
			var p2 := PackedVector2Array()
			for i in pts.size() / 4:
				p2.append(Vector2(pts[i * 4], pts[i * 4 + 1]))
			rec = ShapeRecognizer.recognize(p2)
		if not rec.is_empty():
			item = board.make_shape(fn.data.id, rec)
			board.toast.emit("Recognised %s" % Shapes.name_of(str(rec.shape)).to_lower())
		else:
			if _live_volume and (mode == "auto" or (mode == "hold" and _hold_t >= float(App.val("hold_seconds")))):
				pts = _straighten_3d(pts)
			var brush := _live.brush
			item = Item.make_stroke(fn.data.id, pts, _live.color, _live.width, brush)
	var times := _live.times.duplicate()
	var write := _write_mode
	_clear_live()
	board.history.do(History.op_add([item]))
	var stored: Item = doc.items.get(item.id)
	if write and stored != null and stored.kind == Item.STROKE:
		board.ink.add(stored, times)
	state = S.IDLE


## A 3D stroke that is a straight line (within a few percent of its length) becomes two points.
func _straighten_3d(pts: PackedFloat32Array) -> PackedFloat32Array:
	var n := pts.size() / 4
	if n < 4:
		return pts
	var a := Vector3(pts[0], pts[1], pts[2])
	var b := Vector3(pts[(n - 1) * 4], pts[(n - 1) * 4 + 1], pts[(n - 1) * 4 + 2])
	var chord := a.distance_to(b)
	var length := 0.0
	var worst := 0.0
	var prev := a
	for i in n:
		var p := Vector3(pts[i * 4], pts[i * 4 + 1], pts[i * 4 + 2])
		length += prev.distance_to(p)
		prev = p
		worst = maxf(worst, Geometry3D.get_closest_point_to_segment(p, a, b).distance_to(p))
	if length < 0.03 or chord / length < 0.9 or worst > 0.06 * length:
		return pts
	var pr := pts[3]
	var pe := pts[(n - 1) * 4 + 3]
	return PackedFloat32Array([a.x, a.y, a.z, pr, b.x, b.y, b.z, pe])


# ------------------------------------------------------------------------------------------------ erasing

func _step_erase(pen: PenState) -> void:
	var doc := board.doc
	for fnn in board.visible_frames():
		var fn := fnn as FrameNode
		var s := fn.data.scale
		var l := fn.to_local_point(pen.tip)
		var r := ERASE_R / s
		if fn.is_canvas:
			if absf(l.z) * s > 0.2 or not fn.bounds().grow(0.2).has_point(Vector2(l.x, l.y)):
				continue
			for it in doc.items_of(fn.data.id):
				if not _erase_set.has(it.id) and (it as Item).hit(Vector2(l.x, l.y), r):
					_erase_set[it.id] = it
					var v := fn.view_of(it.id)
					if v != null:
						v.visible = false
					pen.tick(0.2, 0.01)
		else:
			for it in doc.items_of(fn.data.id):
				var item: Item = it
				if _erase_set.has(item.id):
					continue
				for i in item.point_count() - 1:
					if Geometry3D.get_closest_point_to_segment(l, item.pt(i), item.pt(i + 1)).distance_to(l) * s < ERASE_R * 1.4:
						_erase_set[item.id] = item
						var v2 := fn.view_of(item.id)
						if v2 != null:
							v2.visible = false
						pen.tick(0.2, 0.01)
						break
	var t := board.pen_target(pen.tip, HOVER_REACH, 0.3)
	if not t.is_empty():
		cursor_frame = (t.fn as FrameNode).data.id
		cursor_pos = Vector2(t.local.x, t.local.y)
		cursor_dist = float(t.dist)


func _finish_erase() -> void:
	var items: Array = _erase_set.values()
	_erase_set.clear()
	state = S.IDLE
	if items.is_empty():
		return
	board.history.begin_group()
	board._release_glue_to(items)
	board.history.do(History.op_remove(items))
	board.history.end_group()


# ------------------------------------------------------------------------------------------------ lasso / drag

func _step_lasso(pen: PenState) -> void:
	var t := board.pen_target(pen.tip, 0.25, 0.4)
	if t.is_empty() or t.fn != _lasso_fn:
		return
	var l := Vector2(t.local.x, t.local.y)
	if lasso.is_empty() or lasso[lasso.size() - 1].distance_to(l) * _lasso_fn.data.scale > 0.005:
		lasso.append(l)
	cursor_frame = _lasso_fn.data.id
	cursor_pos = l
	cursor_dist = float(t.dist)


func _finish_lasso() -> void:
	state = S.IDLE
	var fn := _lasso_fn
	var poly := lasso
	lasso = PackedVector2Array()
	if fn == null or not is_instance_valid(fn):
		return
	if poly.size() < 4 or Geom2D.polygon_area(poly) * fn.data.scale * fn.data.scale < 0.0004:
		return
	var ids: Array = []
	for it in board.doc.items_of(fn.data.id):
		var item: Item = it
		if _mostly_inside(item, poly):
			ids.append(item.id)
	board.select_items(ids, fn.data.id)
	if ids.is_empty():
		board.toast.emit("Nothing inside the loop")
	else:
		board.toast.emit("%d selected" % ids.size())


func _mostly_inside(item: Item, poly: PackedVector2Array) -> bool:
	var samples := PackedVector2Array()
	match item.kind:
		Item.STROKE:
			var step := maxi(item.point_count() / 12, 1)
			for i in range(0, item.point_count(), step):
				samples.append(Vector2(item.pts[i * 4], item.pts[i * 4 + 1]))
		Item.SHAPE:
			for o in Shapes.world_outlines(item):
				var pts: PackedVector2Array = o.pts
				var step2 := maxi(pts.size() / 10, 1)
				for i in range(0, pts.size(), step2):
					samples.append(pts[i])
			if item.shape == "poly":
				samples.append_array(item.poly)
		Item.TEXT:
			samples = item.text_corners()
			samples.append(item.center)
	if samples.is_empty():
		return false
	var inside := 0
	for p in samples:
		if Geometry2D.is_point_in_polygon(p, poly):
			inside += 1
	return float(inside) / float(samples.size()) >= 0.6


func _step_drag_items(pen: PenState) -> void:
	var fn := _drag_fn
	if fn == null or not is_instance_valid(fn):
		return
	if not fn.is_canvas:
		var l3 := fn.to_local_point(pen.tip)
		var d3 := l3 - _drag3_start
		for id in _drag_ids:
			var v := fn.view_of(id)
			if v != null:
				v.set_preview(Transform3D(Basis.IDENTITY, d3))
		_drag_delta = Vector2(d3.x, d3.y)
		_drag3_last = d3
		return
	var l := fn.to_local_point(pen.tip)
	_drag_delta = Vector2(l.x, l.y) - _drag_start
	for id in _drag_ids:
		var v2 := fn.view_of(id)
		if v2 != null:
			v2.set_preview(Transform3D(Basis.IDENTITY, Vector3(_drag_delta.x, _drag_delta.y, 0.0)))
	cursor_frame = fn.data.id
	cursor_pos = Vector2(l.x, l.y)


var _drag3_last := Vector3.ZERO


func _finish_drag_items() -> void:
	var fn := _drag_fn
	state = S.IDLE
	if fn == null or not is_instance_valid(fn):
		return
	var s := fn.data.scale
	var moved := (_drag_delta.length() * s) > 0.004
	if not moved:
		for id in _drag_ids:
			var v := fn.view_of(id)
			if v != null:
				v.set_preview(Transform3D.IDENTITY)
		return
	var h := board.history
	h.begin_group()
	if fn.is_canvas:
		h.do(History.op_xform2(_drag_ids, Transform2D(0.0, _drag_delta)))
		_after_move(fn, _drag_ids)
	else:
		h.do(History.op_xform3(_drag_ids, Transform3D(Basis.IDENTITY, _drag3_last)))
	h.end_group()


## After items were moved: connectors follow shapes that moved; a connector moved on its own lets go of the shapes it was glued to.
func _after_move(fn: FrameNode, ids: Array) -> void:
	var doc := board.doc
	var moved_shapes: Array = []
	var loose_before: Array = []
	var loose_after: Array = []
	for id in ids:
		var it: Item = doc.items.get(id)
		if it == null:
			continue
		if it.kind == Item.SHAPE and not it.is_line():
			moved_shapes.append(id)
		elif it.is_line():
			var c := it.duplicate_item(false)
			var changed := false
			for end in ["a", "b"]:
				var g: Dictionary = c.get("glue_" + end)
				if not g.is_empty() and not ids.has(g.item):
					c.set("glue_" + end, {})
					c.set("n" + end, Vector2.ZERO)
					changed = true
			if changed:
				loose_before.append(it.duplicate_item(false))
				loose_after.append(c)
	if not loose_before.is_empty():
		board.history.do(History.op_modify(loose_before, loose_after))
	if not moved_shapes.is_empty():
		# glued lines that were not moved themselves follow; those that moved with their shapes keep their (already moved) ends
		var follow: Array = []
		for id in moved_shapes:
			follow.append(id)
		board.follow_connectors(follow, fn.data.id)


func _step_grab(pen: PenState) -> void:
	if _grab_f == null or not board.grabs.has(_grab_f.id):
		return
	var g: Dictionary = board.grabs[_grab_f.id]
	var xf := g.xf as Transform3D
	xf.origin = _grab_origin0 + (pen.tip - _grab_tip0)
	g.xf = xf


# ------------------------------------------------------------------------------------------------ shape stencils

func _step_shape(pen: PenState) -> void:
	var fn := _shape_fn
	if fn == null or not is_instance_valid(fn) or _ghost_item == null:
		return
	var l := fn.to_local_point(pen.tip)
	var b := Vector2(l.x, l.y)
	var s := fn.data.scale
	var id := _ghost_item.shape
	if Shapes.is_line(id):
		var snapped := ShapeRecognizer.snap_line(_shape_a, b)
		_ghost_item.a = snapped[0]
		_ghost_item.b = snapped[1]
		board.snap_line_ends(_ghost_item)
	else:
		var d := b - _shape_a
		if d.length() * s < 0.025:
			_ghost_item.center = _shape_a
			_ghost_item.size = Shapes.default_size(id)
		else:
			var size := Vector2(absf(d.x), absf(d.y))
			if pen.front:
				var m := maxf(size.x, size.y)
				size = Vector2(m, m)
			size = Vector2(maxf(size.x, 0.02), maxf(size.y, 0.02))
			_ghost_item.size = size
			_ghost_item.center = _shape_a + d * 0.5
	_ghost_view.rebuild()
	cursor_frame = fn.data.id
	cursor_pos = b
	cursor_dist = 0.0


func _finish_shape() -> void:
	state = S.IDLE
	var item := _ghost_item
	var view := _ghost_view
	_ghost_item = null
	_ghost_view = null
	if view != null:
		view.queue_free()
	if item == null:
		return
	if item.is_line() and item.a.distance_to(item.b) < 0.02:
		return
	board.history.do(History.op_add([item]))


# ------------------------------------------------------------------------------------------------ handles

## The handles of the current selection on a frame node: [{id, pos (frame coords), kind}].
func handles(fn: FrameNode) -> Array:
	var out: Array = []
	var items := board.selected_items()
	if items.is_empty() or not fn.is_canvas:
		return out
	var s := fn.data.scale
	if items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly":
		var it: Item = items[0]
		if it.is_line():
			out.append({"id": "end_a", "pos": it.a, "kind": "end"})
			out.append({"id": "end_b", "pos": it.b, "kind": "end"})
			return out
		var hw := it.size * 0.5
		var dirs := [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]
		for i in 4:
			out.append({"id": "corner%d" % i, "pos": it.center + Geom2D.rot(dirs[i] * hw, it.rot), "kind": "corner"})
		var edges := [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]
		for i in 4:
			out.append({"id": "edge%d" % i, "pos": it.center + Geom2D.rot(edges[i] * hw, it.rot), "kind": "edge"})
		out.append({"id": "rot", "pos": it.center + Geom2D.rot(Vector2(0, hw.y + 0.055 / s), it.rot), "kind": "rot"})
		return out
	var r := group_bounds(items)
	var cs := [r.position + Vector2(0, r.size.y), r.end, r.position + Vector2(r.size.x, 0), r.position]
	for i in 4:
		out.append({"id": "gcorner%d" % i, "pos": cs[i], "kind": "gcorner"})
	out.append({"id": "grot", "pos": Vector2(r.get_center().x, r.end.y + 0.055 / s), "kind": "rot"})
	return out


func group_bounds(items: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for it in items:
		var b: Rect2 = (it as Item).bounds()
		r = b if first else r.merge(b)
		first = false
	return r.grow(0.008)


func hit_handle(fn: FrameNode, l: Vector2) -> Dictionary:
	var s := fn.data.scale
	var best := {}
	var bd := HANDLE_HIT / s
	for h in handles(fn):
		var d := (h.pos as Vector2).distance_to(l)
		if d < bd:
			bd = d
			best = h
	return best


func _start_handle(fn: FrameNode, h: Dictionary, l: Vector2) -> void:
	_drag_fn = fn
	_handle = h
	_drag_start = l
	_drag_ids = board.selection.duplicate()
	var items := board.selected_items()
	_work = null
	_orig = null
	if items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly":
		_orig = items[0]
		_work = _orig.duplicate_item(false)
	_group_before = group_bounds(items)
	_drag_delta = Vector2.ZERO
	state = S.DRAG_HANDLE


func _step_handle(pen: PenState) -> void:
	var fn := _drag_fn
	if fn == null or not is_instance_valid(fn):
		return
	var l3 := fn.to_local_point(pen.tip)
	var p := Vector2(l3.x, l3.y)
	cursor_frame = fn.data.id
	cursor_pos = p
	if _work != null:
		_apply_shape_handle(p, pen.front)
		var v := fn.view_of(_work.id)
		if v != null:
			v.item = _work
			v.rebuild()
		_preview_connectors(fn)
		return
	# group transform: scale about the opposite corner or rotate about the centre
	var xf := _group_xform(p)
	_drag_xf = xf
	var t3 := Transform3D(Basis(Vector3(xf.x.x, xf.x.y, 0), Vector3(xf.y.x, xf.y.y, 0), Vector3(0, 0, 1)), Vector3(xf.origin.x, xf.origin.y, 0))
	for id in _drag_ids:
		var v2 := fn.view_of(id)
		if v2 != null:
			v2.set_preview(t3)


var _drag_xf := Transform2D.IDENTITY


func _group_xform(p: Vector2) -> Transform2D:
	var r := _group_before
	var c := r.get_center()
	var hid := str(_handle.id)
	if hid == "grot":
		var a0 := (_drag_start - c).angle()
		var a1 := (p - c).angle()
		var d := angle_difference(a0, a1)
		if absf(fposmod(rad_to_deg(d) + 7.5, 15.0) - 7.5) < 3.0:
			d = deg_to_rad(roundf(rad_to_deg(d) / 15.0) * 15.0)
		return _rotate_about(d, c)
	var idx := int(hid.trim_prefix("gcorner"))
	var corners := [r.position + Vector2(0, r.size.y), r.end, r.position + Vector2(r.size.x, 0), r.position]
	var anchor: Vector2 = corners[(idx + 2) % 4]
	var orig: Vector2 = corners[idx]
	var diag := orig - anchor
	var k := clampf((p - anchor).dot(diag) / maxf(diag.length_squared(), 1e-6), 0.1, 12.0)
	return _scale_about(k, anchor)


func _rotate_about(a: float, c: Vector2) -> Transform2D:
	return Transform2D(a, c - Geom2D.rot(c, a))


func _scale_about(k: float, c: Vector2) -> Transform2D:
	return Transform2D(Vector2(k, 0), Vector2(0, k), c - c * k)


func _apply_shape_handle(p: Vector2, keep_aspect: bool) -> void:
	var w := _work
	var o := _orig
	var hid := str(_handle.id)
	if hid == "end_a" or hid == "end_b":
		var other: Vector2 = o.b if hid == "end_a" else o.a
		var snapped := ShapeRecognizer.snap_line(other, p) if hid == "end_b" else ShapeRecognizer.snap_line(p, other)
		w.a = snapped[0]
		w.b = snapped[1]
		w.glue_a = o.glue_a if hid == "end_b" else {}
		w.glue_b = o.glue_b if hid == "end_a" else {}
		w.na = o.na if hid == "end_b" else Vector2.ZERO
		w.nb = o.nb if hid == "end_a" else Vector2.ZERO
		board.snap_line_ends(w, "")
		return
	if hid == "rot":
		var ang := (p - o.center).angle() - PI * 0.5
		if absf(fposmod(rad_to_deg(ang) + 7.5, 15.0) - 7.5) < 3.0:
			ang = deg_to_rad(roundf(rad_to_deg(ang) / 15.0) * 15.0)
		w.rot = ang
		return
	var q := Geom2D.rot(p - o.center, -o.rot)
	var hw := o.size * 0.5
	if hid.begins_with("corner"):
		var dirs := [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]
		var c: Vector2 = dirs[int(hid.trim_prefix("corner"))]
		var opp := -c * hw
		var size := Vector2(maxf(absf(q.x - opp.x), 0.02), maxf(absf(q.y - opp.y), 0.02))
		if keep_aspect:
			var ratio := o.size.x / maxf(o.size.y, 1e-4)
			var m := maxf(size.x / ratio, size.y)
			size = Vector2(m * ratio, m)
		var corner_pos := opp + Vector2(signf(c.x) * size.x, signf(c.y) * size.y)
		w.size = size
		w.center = o.center + Geom2D.rot((opp + corner_pos) * 0.5, o.rot)
	else:
		var edges := [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]
		var e: Vector2 = edges[int(hid.trim_prefix("edge"))]
		var opp2 := -e * hw
		var along := q.x if absf(e.x) > 0.5 else q.y
		var o_along := opp2.x if absf(e.x) > 0.5 else opp2.y
		var len := maxf(absf(along - o_along), 0.02)
		var sgn := signf(e.x) if absf(e.x) > 0.5 else signf(e.y)
		var new_edge := o_along + sgn * len
		var mid := (o_along + new_edge) * 0.5
		if absf(e.x) > 0.5:
			w.size = Vector2(len, o.size.y)
			w.center = o.center + Geom2D.rot(Vector2(mid, 0), o.rot)
		else:
			w.size = Vector2(o.size.x, len)
			w.center = o.center + Geom2D.rot(Vector2(0, mid), o.rot)


## While a shape is being reshaped its glued connectors follow on screen.
func _preview_connectors(fn: FrameNode) -> void:
	for it in board.doc.items_of(fn.data.id):
		var line: Item = it
		if not line.is_line():
			continue
		var c := line.duplicate_item(false)
		var touched := false
		for end in ["a", "b"]:
			var g: Dictionary = c.get("glue_" + end)
			if not g.is_empty() and g.item == _work.id:
				var pw := Shapes.port_world(_work, int(g.port))
				c.set(end, pw.pos)
				c.set("n" + end, pw.n)
				touched = true
		if touched:
			var v := fn.view_of(line.id)
			if v != null:
				v.item = c
				v.rebuild()


func _finish_handle() -> void:
	state = S.IDLE
	var fn := _drag_fn
	if fn == null or not is_instance_valid(fn):
		return
	if _work != null:
		var changed_enough := not (_work.to_dict() == _orig.to_dict())
		if changed_enough:
			board.history.begin_group()
			board.history.do(History.op_modify([_orig], [_work]))
			if not _orig.is_line():
				board.follow_connectors([_orig.id], fn.data.id)
			board.history.end_group()
		else:
			board.doc.item_touched(board.doc.items[_orig.id])
		# put every connector view back to the stored state (a preview may have changed them)
		for it in board.doc.items_of(fn.data.id):
			if (it as Item).is_line():
				fn.refresh_view(it)
	else:
		board.history.begin_group()
		board.history.do(History.op_xform2(_drag_ids, _drag_xf))
		_after_move(fn, _drag_ids)
		board.history.end_group()
	_work = null
	_orig = null
	_drag_xf = Transform2D.IDENTITY


# ------------------------------------------------------------------------------------------------ finishing

func _finish(_pen: PenState) -> void:
	match state:
		S.DRAWING:
			_finish_draw()
		S.ERASING:
			_finish_erase()
		S.LASSO:
			_finish_lasso()
		S.DRAG_ITEMS:
			_finish_drag_items()
		S.DRAG_HANDLE:
			_finish_handle()
		S.SHAPE_DRAG:
			_finish_shape()
		S.GRAB_FRAME:
			if _grab_f != null:
				board.end_grab(_grab_f)
				_grab_f = null
			state = S.IDLE
	_drag_btn_front = false


func _abort() -> void:
	_clear_live()
	state = S.IDLE


func _clear_live() -> void:
	if _live != null:
		_live.queue_free()
		_live = null
	if _ghost_view != null:
		_ghost_view.queue_free()
		_ghost_view = null
	_ghost_item = null
	_snap = {}
	_live_fn = null
	snapped_shape = ""


# ------------------------------------------------------------------------------------------------ overlay

func draw_overlay(od: OverlayDraw, fn: FrameNode) -> void:
	var s := fn.data.scale
	var fid := fn.data.id
	od.z = 0.002
	if fid == board.sel_frame and not board.selection.is_empty() and fn.is_canvas:
		_draw_selection(od, fn)
	if state == S.LASSO and _lasso_fn == fn and lasso.size() > 1:
		if lasso.size() > 2:
			od.polygon(lasso, Color(0.5, 0.9, 1.0, 0.12))
		od.line(lasso, 0.0025 / s, Color(0.7, 0.95, 1.0, 0.95), false)
	if state == S.SHAPE_DRAG and _ghost_item != null and _ghost_item.is_line():
		_draw_glue_marks(od, s, _ghost_item)
	if cursor_frame == fid:
		_draw_cursor(od, fn)


func _draw_selection(od: OverlayDraw, fn: FrameNode) -> void:
	var s := fn.data.scale
	var items := board.selected_items()
	var col := Color(0.45, 0.95, 1.0, 0.9)
	var w := 0.0022 / s
	var single_shape := items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly"
	if single_shape and not (items[0] as Item).is_line():
		var it: Item = items[0] if _work == null else _work
		var hw := it.size * 0.5
		var pts := PackedVector2Array()
		for c in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			pts.append(it.center + Geom2D.rot(c * hw, it.rot))
		od.line(pts, w, col, true)
		od.segment(it.center + Geom2D.rot(Vector2(0, hw.y), it.rot), it.center + Geom2D.rot(Vector2(0, hw.y + 0.055 / s), it.rot), w, col)
	elif single_shape:
		var ln: Item = items[0] if _work == null else _work
		od.line(Shapes.line_points(ln), w * 3.0, Color(col.r, col.g, col.b, 0.35), false)
	else:
		var r := group_bounds(items)
		for it2 in items:
			if (it2 as Item).kind != Item.STROKE:
				od.rect((it2 as Item).bounds().grow(0.004), w * 0.7, Color(col.r, col.g, col.b, 0.4))
		od.rect(r, w, col)
		od.segment(Vector2(r.get_center().x, r.end.y), Vector2(r.get_center().x, r.end.y + 0.055 / s), w, col)
	for h in handles(fn):
		var hid := str(h.id)
		var active := state == S.DRAG_HANDLE and str(_handle.get("id", "")) == hid
		var fill := Color(1, 1, 1, 0.95) if active else Color(0.1, 0.16, 0.2, 0.9)
		var r2 := HANDLE_R / s
		od.disc(h.pos, r2 * 1.25, Color(col.r, col.g, col.b, 0.95))
		od.disc(h.pos, r2 * 0.8, fill)
		if str(h.kind) == "rot":
			od.ring(h.pos, r2 * 0.45, 0.0012 / s, Color(col.r, col.g, col.b, 1.0), 12)


func _draw_glue_marks(od: OverlayDraw, s: float, line: Item) -> void:
	for end in ["glue_a", "glue_b"]:
		var g: Dictionary = line.get(end)
		if g.is_empty() or not board.doc.items.has(g.item):
			continue
		var pw := Shapes.port_world(board.doc.items[g.item], int(g.port))
		od.ring(pw.pos, 0.016 / s, 0.003 / s, Color(0.4, 1.0, 0.7, 0.95), 20)


func _draw_cursor(od: OverlayDraw, fn: FrameNode) -> void:
	var s := fn.data.scale
	var tool := str(App.val("tool"))
	var col: Color = App.val("color")
	var near := 1.0 - clampf(cursor_dist / HOVER_REACH, 0.0, 1.0)
	var a := 0.25 + 0.7 * near
	od.z = 0.003
	if state == S.DRAWING and not _live_volume and not _write_mode and _snap.is_empty() and str(App.val("recognize")) == "hold":
		# hold still and this ring fills: when it closes the stroke snaps to a clean shape
		var frac := clampf(_hold_t / float(App.val("hold_seconds")), 0.0, 1.0)
		if _hold_t > 0.12 and frac < 1.0:
			var arc := PackedVector2Array()
			var steps := 28
			for i in range(0, int(steps * frac) + 1):
				var ang := -PI * 0.5 + TAU * frac * float(i) / float(maxi(int(steps * frac), 1))
				arc.append(cursor_pos + Vector2(cos(ang), sin(ang)) * (0.016 / s))
			od.line(arc, 0.003 / s, Color(0.4, 1.0, 0.8, 0.95), false)
	match tool:
		"erase":
			od.ring(cursor_pos, ERASE_R / s, 0.002 / s, Color(1.0, 0.45, 0.4, a), 24)
		"select":
			od.disc(cursor_pos, 0.0035 / s, Color(1, 1, 1, a))
			od.ring(cursor_pos, 0.01 / s, 0.0015 / s, Color(0.7, 0.95, 1.0, a * 0.8), 20)
		"shape":
			var arm := 0.014 / s
			od.segment(cursor_pos - Vector2(arm, 0), cursor_pos + Vector2(arm, 0), 0.0018 / s, Color(1, 1, 1, a))
			od.segment(cursor_pos - Vector2(0, arm), cursor_pos + Vector2(0, arm), 0.0018 / s, Color(1, 1, 1, a))
		_:
			var bw := Brushes.width_at(str(App.val("brush")), float(App.val("width")), 0.6)
			od.disc(cursor_pos, maxf(bw * 0.5, 0.0022) / s, Color(col.r, col.g, col.b, a))
			od.ring(cursor_pos, (maxf(bw * 0.5, 0.0022) + 0.004 + cursor_dist * 0.06) / s, 0.0013 / s, Color(1, 1, 1, a * 0.7), 24)
