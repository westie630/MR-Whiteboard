class_name PenController
extends RefCounted
## Everything the pen does to the board: draw (with hold-to-snap shape recognition), write (handwriting to text), erase, select
## (tap, lasso, drag, resize / rotate handles), place stencil shapes, undo with the back button (with the front button held: redo).
## Works the same for the MX Ink stylus, the mouse and a pinch. Grabbing (moving and resizing canvases, dragging items with the front
## button) is the pointer's job, shared with the hands: see HandController.

enum S { IDLE, DRAWING, ERASING, LASSO, DRAG_ITEMS, DRAG_HANDLE, SHAPE_DRAG, DRAG_MARKER }

const MIN_STEP := InputTuning.MIN_STEP     # metres between stroke samples
const HOLD_MOVE := InputTuning.HOLD_MOVE   # the pen counts as still while it stays within this
const UNSNAP_MOVE := InputTuning.UNSNAP_MOVE
const ERASE_R := InputTuning.ERASE_R
const PICK_R := InputTuning.PICK_R
const HANDLE_R := 0.016                    # drawn radius of a handle (world metres)
const HANDLE_HIT := InputTuning.HANDLE_HIT
const HANDLE_INSIDE := InputTuning.HANDLE_INSIDE
const HANDLE_INSIDE_MIN := InputTuning.HANDLE_INSIDE_MIN
const HANDLE_BODY_FRAC := InputTuning.HANDLE_BODY_FRAC
const BTN_R := 0.019                       # drawn radius of an undo / redo / delete button beside the selection
const BTN_GAP := 0.052                     # distance between button centres
const BTN_SIDE := 0.075                    # distance of the button column from the selection box (clear of the corner handles)
const BTN_HIT := InputTuning.BTN_HIT
const HOVER_REACH := 0.25

var board: Board
var state := S.IDLE
## A hand pointing with a ray (HandController) drives its own PenController in this mode: only the Select tool's moves exist (tap,
## drag, handles; a tap on empty canvas just clears the selection, there is no lasso unless `lasso_ok`) and every pick radius is `reach`
## times larger, because a ray at arm's length is not a nib.
var hand_mode := false
var reach := 1.0
## Set by HandController for the press it hands over: empty canvas pointed at from a distance with the Select tool chosen draws a lasso.
var lasso_ok := false
## Set by the board while the front-button pointer is holding something: a new press must not start a stroke under it.
var blocked := false
var cursor_frame := ""
var cursor_pos := Vector2.ZERO
var cursor_dist := 0.0
var lasso := PackedVector2Array()
var snapped_shape := ""                    # id of the shape the stroke has snapped to (for the toast / UI)
var live_id := ""                          # the id the item of the stroke being drawn will get: what the others of a session see it by meanwhile

var _live: LiveStroke
var _live_fn: FrameNode
var _live_volume := false
var _write_mode := false
var _filter := OneEuro3.new(InputTuning.STYLUS_FILTER.x, InputTuning.STYLUS_FILTER.y)
var _pressure := 0.5
var _prev_down := false
var _prev_back := false
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
var _drag_delta := Vector2.ZERO
var _drag3_start := Vector3.ZERO
var _handle: Dictionary = {}
var _work: Item
var _orig: Item
var _group_before := Rect2()
var _shape_fn: FrameNode
var _shape_a := Vector2.ZERO
var _lasso_fn: FrameNode
var _on_key := ""                          # what the undo / redo buttons' enabled state was computed for
var _on_undo := false
var _on_redo := false
var _lasso_tap_item: Item                  # the box under the pen when a selection loop started: a plain tap selects it
var _marker := ""                          # the marker of a curved desk being moved ("d" distance, "r" radius); the frame is `_drag_fn`
var _hot_fn: FrameNode                     # the curved desk whose marker the nib is on


func _init(b: Board) -> void:
	board = b


# ------------------------------------------------------------------------------------------------ per frame

func update(pen: PenState, dt: float) -> void:
	_handle_back(pen)
	if not pen.tracked or pen.docked:
		if state != S.IDLE:
			_finish(pen)
		cursor_frame = ""
		_prev_down = false
		return
	var down_edge := pen.down and not _prev_down
	if state == S.IDLE:
		_update_cursor(pen)
		if down_edge and not blocked:
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
			S.DRAG_MARKER:
				_step_marker(pen)
		if not pen.down:
			_finish(pen)
	_prev_down = pen.down


## What this pointer is in the middle of, as plain data for a session to show to the others (LiveOut): {} when it is idle. Keys:
##   stroke  the stroke being drawn: {id, frame, brush, color, width, pts, n, vis}
##   drag    items being carried or resized as a group: {f, ids, t: the transform they are shown with}
##   work    one shape being reshaped, or a stencil being dragged out: {f, item (a dictionary), ghost}
##   erase   what the eraser has touched: {ids}
func live_view() -> Dictionary:
	var out := {}
	match state:
		S.DRAWING:
			if _live != null and not _live_volume and is_instance_valid(_live_fn) and live_id != "":
				out["stroke"] = {"id": live_id, "frame": _live_fn.data.id, "brush": _live.brush, "color": _live.color.to_html(), "width": _live.width,
					"pts": _live.pts, "n": _live.point_count(), "vis": _live.visible}
				if _ghost_item != null:
					out["work"] = {"f": _live_fn.data.id, "item": _ghost_item.to_dict(), "ghost": true}
		S.DRAG_ITEMS:
			if is_instance_valid(_drag_fn) and _drag_fn.is_canvas:
				out["drag"] = {"f": _drag_fn.data.id, "ids": _drag_ids.duplicate(), "t": Transform3D(Basis.IDENTITY, Vector3(_drag_delta.x, _drag_delta.y, 0.0))}
		S.DRAG_HANDLE:
			if is_instance_valid(_drag_fn) and _drag_fn.is_canvas:
				if _work != null:
					out["work"] = {"f": _drag_fn.data.id, "item": _work.to_dict(), "ghost": false}
				else:
					var xf := _drag_xf
					out["drag"] = {"f": _drag_fn.data.id, "ids": _drag_ids.duplicate(),
						"t": Transform3D(Basis(Vector3(xf.x.x, xf.x.y, 0), Vector3(xf.y.x, xf.y.y, 0), Vector3(0, 0, 1)), Vector3(xf.origin.x, xf.origin.y, 0))}
		S.SHAPE_DRAG:
			if is_instance_valid(_shape_fn) and _ghost_item != null:
				out["work"] = {"f": _shape_fn.data.id, "item": _ghost_item.to_dict(), "ghost": true}
		S.ERASING:
			if not _erase_set.is_empty():
				out["erase"] = {"ids": _erase_set.keys()}
	return out


## The frame an item or handle drag is working on (a hand keeps pointing at its plane while the drag lasts), or null.
func working_frame() -> FrameNode:
	if state == S.DRAG_ITEMS or state == S.DRAG_HANDLE or state == S.DRAG_MARKER:
		return _drag_fn if is_instance_valid(_drag_fn) else null
	if state == S.LASSO:
		return _lasso_fn if is_instance_valid(_lasso_fn) else null
	return null


func flush_live() -> void:
	if _live != null:
		_live.flush()


## The back button: undo, at once. With the front button held: redo.
func _handle_back(pen: PenState) -> void:
	var edge := pen.back and not _prev_back
	_prev_back = pen.back
	if not edge:
		return
	if pen.front:
		if state == S.IDLE and not blocked:
			board.redo()
			board.toast.emit("Redo")
	else:
		board.undo()
		board.toast.emit("Undo")


func _update_cursor(pen: PenState) -> void:
	var t := board.pen_target(pen.tip, HOVER_REACH, 0.3)
	if t.is_empty():
		cursor_frame = ""
		_light_marker(null, "")
		return
	var fn := t.fn as FrameNode
	cursor_frame = fn.data.id
	cursor_pos = Vector2(t.local.x, t.local.y)
	cursor_dist = float(t.dist)
	_light_marker(fn, hit_marker(fn, cursor_pos) if cursor_dist < Board.CAPTURE else "")


## The marker of a curved desk the nib is on lights up and says its number.
func _light_marker(fn: FrameNode, which: String) -> void:
	if hand_mode:
		return
	if _hot_fn != null and _hot_fn != fn and is_instance_valid(_hot_fn):
		_hot_fn.set_marker_hot("")
	_hot_fn = fn if which != "" else null
	if fn != null:
		fn.set_marker_hot(which)


# ------------------------------------------------------------------------------------------------ beginnings

func _begin_down(pen: PenState) -> void:
	if not board.can_edit():
		board.deny_edit()
		return
	_filter.reset()
	_pressure = maxf(pen.pressure, 0.2)
	if _begin_on_button(pen):
		return
	if _begin_on_marker(pen):
		return
	if hand_mode:
		_begin_select(pen)
		return
	# the handles of a selection (corners scale, the top one turns) work with every tool: touching one grabs it
	if _begin_on_handle(pen):
		return
	print("[pen] down with the %s tool (%s)" % [str(App.val("tool")), pen.source])
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


## A press whose nib is on one of the buttons beside the selection (undo, redo, delete) presses it, whatever the tool is.
func _begin_on_button(pen: PenState) -> bool:
	if board.selection.is_empty() and board.bar_ghost.is_empty():
		return false
	var t := board.pen_target(pen.tip, Board.CAPTURE, 0.3)
	if t.is_empty():
		return false
	var fn := t.fn as FrameNode
	var id := hit_button(fn, Vector2(t.local.x, t.local.y))
	if id == "":
		return false
	board.bar_action(id)
	pen.tick(0.4, 0.02)
	return true


## A press whose nib is on a marker of a curved desk takes hold of it, whatever the tool is: its distance and its radius slide with the nib.
func _begin_on_marker(pen: PenState) -> bool:
	var t := board.pen_target(pen.tip, Board.CAPTURE, 0.3)
	if t.is_empty() or (t.fn as FrameNode).bend == null:
		return false
	var fn := t.fn as FrameNode
	var which := hit_marker(fn, Vector2(t.local.x, t.local.y))
	if which == "":
		return false
	board.begin_grab(fn.data)
	if not board.grabs.has(fn.data.id):
		return true                                    # (a guest who may not edit: the press is consumed all the same)
	_drag_fn = fn
	_marker = which
	fn.set_marker_hot(which)
	state = S.DRAG_MARKER
	pen.tick(0.3, 0.02)
	return true


## Which marker ("d" or "r") of a curved desk is on this point of its canvas, or "".
func hit_marker(fn: FrameNode, l: Vector2) -> String:
	if fn.bend == null:
		return ""
	var best := ""
	var bd := InputTuning.MARKER_HIT * sqrt(reach) / fn.bend.zoom      # (in canvas metres: the markers keep their size when the contents are zoomed)
	for which: String in ["d", "r"]:
		var d := fn.marker_pos(which).distance_to(l)
		if d < bd:
			bd = d
			best = which
	return best


## The marker that is being moved ("d", "r"), or "" when none.
func marker_drag() -> String:
	return _marker if state == S.DRAG_MARKER else ""


## The nib moves a marker: the distance marker slides on the desk (the flat part ends under it), the radius marker slides up the diagonal that
## runs from the start of the bend to the corner of the wall (the bend is a quarter circle round the point radius above and radius short of it).
func _step_marker(pen: PenState) -> void:
	var fn := _drag_fn
	if fn == null or not is_instance_valid(fn) or not board.grabs.has(fn.data.id):
		state = S.IDLE
		return
	var g: Dictionary = board.grabs[fn.data.id]
	var p := fn.global_transform.affine_inverse() * pen.tip
	var at := float(g.get("bend_at", fn.data.bend_at))
	var radius := float(g.get("bend_radius", fn.data.bend_radius))
	if _marker == "d":
		at = DeskBend.clamp_at(p.y)
	else:
		radius = DeskBend.clamp_radius(((p.y - at) + p.z) * 0.5)
	if roundi(at * 100.0) != roundi(float(g.get("bend_at", at)) * 100.0) or roundi(radius * 100.0) != roundi(float(g.get("bend_radius", radius)) * 100.0):
		pen.tick(0.1, 0.006)
	g.bend_at = at
	g.bend_radius = radius
	fn.set_marker_hot(_marker)
	cursor_frame = fn.data.id
	cursor_pos = fn.marker_pos(_marker)
	cursor_dist = 0.0


func _finish_marker() -> void:
	state = S.IDLE
	_marker = ""
	var fn := _drag_fn
	if fn != null and is_instance_valid(fn):
		fn.set_marker_hot("")
		board.end_grab(fn.data)
	_drag_fn = null


## A press whose nib is on a handle of the current selection starts dragging that handle, whatever the tool is.
func _begin_on_handle(pen: PenState) -> bool:
	if board.selection.is_empty() or board.sel_frame == "":
		return false
	var t := board.pen_target(pen.tip, Board.CAPTURE, 0.3)
	if t.is_empty() or (t.fn as FrameNode).data.id != board.sel_frame:
		return false
	var fn := t.fn as FrameNode
	var l := Vector2(t.local.x, t.local.y)
	var h := hit_handle(fn, l)
	if h.is_empty():
		return false
	_start_handle(fn, h, l)
	return true


func _brush_width(fn: FrameNode) -> float:
	return float(App.val("width")) / fn.data.scale


func _begin_draw(pen: PenState, write: bool) -> void:
	var t := board.pen_target(pen.tip, Board.CAPTURE)
	if t.is_empty():
		# everything is drawn on a canvas (drawing in the air is switched off)
		board.toast.emit("Draw on a canvas: bring the stylus to one, or place one with Add (+) on the toolbar.")
		return
	var fn: FrameNode = t.fn
	var volume := false
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
	live_id = U.uid("i")
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
		if not hand_mode:
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
	var it := board.doc.pick(fn.data.id, l, PICK_R * reach / s)
	if it != null:
		if not board.selection.has(it.id):
			board.select_items([it.id], fn.data.id)
		_start_drag_items(fn, l)
		return
	# inside a box (not on its outline): dragging an already selected box moves it; otherwise a tap selects the box and a drag draws a loop
	var inside := board.doc.shape_containing(fn.data.id, l)
	if inside != null and board.selection.has(inside.id):
		_start_drag_items(fn, l)
		return
	if hand_mode and not (lasso_ok and inside == null):
		# no lasso with a hand (unless it was handed one): the box under the ray is picked up, empty canvas lets go of the selection
		if inside != null:
			board.select_items([inside.id], fn.data.id)
			_start_drag_items(fn, l)
		else:
			board.clear_selection()
		return
	_lasso_tap_item = inside
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
		_drag_delta = Vector2.ZERO
		state = S.DRAG_ITEMS
	else:
		board.clear_selection()


func _start_drag_items(fn: FrameNode, l: Vector2) -> void:
	_drag_fn = fn
	_drag_start = l
	_drag_ids = board.selection.duplicate()
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
	_ghost_item.id = live_id
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
	if live_id != "":
		item.id = live_id                           # a stroke, a recognised shape or a snapped one: the others have been watching this id
	var times := _live.times.duplicate()
	var write := _write_mode
	_clear_live()
	board.history.do(History.op_add([item]))
	var stored: Item = doc.items.get(item.id)
	if stored != null and stored.kind == Item.STROKE and not hand_mode:
		if write:
			board.ink.add(stored, times)             # (a line or a box among the words stays a drawing)
		elif not _live_volume:
			board.ink.observe(stored, times)         # the pen notices when it is writing words
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
		if _lasso_tap_item != null and board.doc.items.has(_lasso_tap_item.id):
			board.select_items([_lasso_tap_item.id], fn.data.id)
		_lasso_tap_item = null
		return
	_lasso_tap_item = null
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
		Item.TEXT, Item.IMAGE:
			samples = item.text_corners()
			samples.append(item.center)
	if samples.is_empty():
		return false
	var inside := 0
	for p in samples:
		if Geometry2D.is_point_in_polygon(p, poly):
			inside += 1
	return float(inside) / float(samples.size()) >= InputTuning.LASSO_INSIDE


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
		if d.length() * s < InputTuning.SHAPE_TAP:
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
	if item.is_line() and item.a.distance_to(item.b) < InputTuning.MIN_LINE:
		return
	board.history.do(History.op_add([item]))


# ------------------------------------------------------------------------------------------------ handles

## The handles of the current selection on a frame node: [{id, pos (frame coords), kind}].
## `override`: the copy of the single selected shape that is being reshaped right now (its handles follow it).
func handles(fn: FrameNode, override: Item = null) -> Array:
	var out: Array = []
	var items := board.selected_items()
	if items.is_empty() or not fn.is_canvas:
		return out
	var s := fn.data.scale
	if items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly":
		var it: Item = override if override != null else items[0]
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


## The buttons beside the selection box on a frame node: [{id: "undo" | "redo" | "delete", pos (frame coords), on}], a column to the
## right of the box (top to bottom). With the selection gone after a delete only undo and redo remain, where the box was.
func bar_buttons(fn: FrameNode) -> Array:
	var out: Array = []
	if not fn.is_canvas:
		return out
	var items := board.selected_items()
	var r: Rect2
	var ids := ["undo", "redo", "delete"]
	if not items.is_empty() and fn.data.id == board.sel_frame:
		r = group_bounds(items)
	else:
		var gh := board.ghost_bar(fn.data.id)
		if gh.is_empty():
			return out
		r = gh.rect
		ids = ["undo", "redo"]
	var s := fn.data.scale
	var x := r.end.x + BTN_SIDE / s
	var top := r.get_center().y + BTN_GAP / s * float(ids.size() - 1) * 0.5
	var h := board.history
	var key := "%d/%d/%d/%s" % [h.undo_stack.size(), h.redo_stack.size(), h.serial, str(board.bar_ids())]
	if key != _on_key:                         # scanning the history is not cheap: only when something changed
		_on_key = key
		_on_undo = h.can_undo_local(board.bar_ids())
		_on_redo = h.can_redo_local(board.bar_ids())
	for i in ids.size():
		var id: String = ids[i]
		var on := _on_undo if id == "undo" else _on_redo if id == "redo" else true
		out.append({"id": id, "pos": Vector2(x, top - BTN_GAP / s * i), "on": on})
	return out


## The id of the button a point of the frame is on (the nearest one), or "".
func hit_button(fn: FrameNode, l: Vector2) -> String:
	var s := fn.data.scale
	var best := ""
	var bd := BTN_HIT * sqrt(reach) / s
	for b in bar_buttons(fn):
		var d := (b.pos as Vector2).distance_to(l)
		if d < bd:
			bd = d
			best = str(b.id)
	return best


func group_bounds(items: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for it in items:
		var b: Rect2 = (it as Item).bounds()
		r = b if first else r.merge(b)
		first = false
	return r.grow(0.008)


## The handle of the selection a point of the frame is on, or {}. Moving the selection and reshaping it must not fight over a press: the handles
## stand on the selection's own corners, so a full-size grab zone would cover much of its body. On the body (inside the shape, along a line,
## inside the box round a group) a handle is only grabbed at its very centre, as far as `HANDLE_INSIDE` and at most `HANDLE_BODY_FRAC` of the
## shape's smaller side; just outside it the zone is the full `HANDLE_HIT`. So: inside = move, just outside a corner = reshape.
func hit_handle(fn: FrameNode, l: Vector2) -> Dictionary:
	var s := fn.data.scale
	var best := {}
	var bd := HANDLE_HIT * reach / s
	var body := _body_at(l)
	if bool(body.inside):
		bd = minf(bd, maxf(minf(HANDLE_INSIDE * sqrt(reach) / s, HANDLE_BODY_FRAC * float(body.span)), HANDLE_INSIDE_MIN / s))
	for h in handles(fn):
		var d := (h.pos as Vector2).distance_to(l)
		if d < bd:
			bd = d
			best = h
	return best


## Is a point of the frame on the body of the selection? {inside: bool, span: the smaller side of it (a line's length)}, frame coordinates.
func _body_at(l: Vector2) -> Dictionary:
	var items := board.selected_items()
	if items.is_empty():
		return {"inside": false, "span": 0.0}
	if items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly":
		var it := items[0] as Item
		if it.is_line():
			var ab := it.b - it.a
			var t := (l - it.a).dot(ab) / maxf(ab.length_squared(), 1e-9)
			return {"inside": t > 0.0 and t < 1.0, "span": ab.length()}
		var hw := it.size * 0.5
		var loc := Geom2D.rot(l - it.center, -it.rot)
		return {"inside": absf(loc.x) <= hw.x and absf(loc.y) <= hw.y, "span": minf(it.size.x, it.size.y)}
	var r := group_bounds(items)
	return {"inside": r.grow(1e-4).has_point(l), "span": minf(r.size.x, r.size.y)}


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
		S.DRAG_MARKER:
			_finish_marker()


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

## The loop being drawn on `fn`, if it is (the board draws the hands' loops with this too).
func draw_lasso(od: OverlayDraw, fn: FrameNode) -> void:
	if state == S.LASSO and _lasso_fn == fn and lasso.size() > 1:
		if lasso.size() > 2:
			od.polygon(lasso, Color(0.5, 0.9, 1.0, 0.12))
		od.line(lasso, 0.0025 / fn.data.scale, Color(0.7, 0.95, 1.0, 0.95), false)


func draw_overlay(od: OverlayDraw, fn: FrameNode) -> void:
	var s := fn.data.scale
	var fid := fn.data.id
	od.z = 0.002
	if fid == board.sel_frame and not board.selection.is_empty() and fn.is_canvas:
		_draw_selection(od, fn)
	else:
		_draw_bar(od, fn, Transform2D.IDENTITY)
	draw_lasso(od, fn)
	if state == S.SHAPE_DRAG and _ghost_item != null and _ghost_item.is_line():
		_draw_glue_marks(od, s, _ghost_item)
	if cursor_frame == fid:
		_draw_cursor(od, fn)


## How the selection is shown on a frame while it is being dragged or reshaped (by this controller): {xf: the transform the stored
## selection is drawn with, offset: its translation, work: the shape copy being reshaped or null, handles: [{id, kind, pos}] where they
## are drawn now}. Outside a drag it is the stored selection.
func selection_view(fn: FrameNode) -> Dictionary:
	var xf := Transform2D.IDENTITY
	var work: Item = null
	if state == S.DRAG_ITEMS and _drag_fn == fn and fn.is_canvas:
		xf = Transform2D(0.0, _drag_delta)
	elif state == S.DRAG_HANDLE and _drag_fn == fn:
		if _work != null:
			work = _work
		else:
			xf = _drag_xf
	var hs: Array = []
	for h in handles(fn, work):
		hs.append({"id": h.id, "kind": h.kind, "pos": xf * (h.pos as Vector2)})
	return {"xf": xf, "offset": xf.origin, "work": work, "handles": hs}


func _box_points(r: Rect2, xf: Transform2D) -> PackedVector2Array:
	return PackedVector2Array([xf * r.position, xf * Vector2(r.end.x, r.position.y), xf * r.end, xf * Vector2(r.position.x, r.end.y)])


func _draw_selection(od: OverlayDraw, fn: FrameNode) -> void:
	# whoever is dragging (the stylus, or a hand) decides how the selection looks: it follows the drag
	var d: PenController = board.drag_driver()
	var v := d.selection_view(fn)
	var xf: Transform2D = v.xf
	var work: Item = v.work
	var s := fn.data.scale
	var items := board.selected_items()
	var col := Color(0.45, 0.95, 1.0, 0.9)
	var w := 0.0022 / s
	var single_shape := items.size() == 1 and (items[0] as Item).kind == Item.SHAPE and (items[0] as Item).shape != "poly"
	if single_shape and not (items[0] as Item).is_line():
		var it: Item = items[0] if work == null else work
		var hw := it.size * 0.5
		var pts := PackedVector2Array()
		for c in [Vector2(-1, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			pts.append(xf * (it.center + Geom2D.rot(c * hw, it.rot)))
		od.line(pts, w, col, true)
		od.segment(xf * (it.center + Geom2D.rot(Vector2(0, hw.y), it.rot)), xf * (it.center + Geom2D.rot(Vector2(0, hw.y + 0.055 / s), it.rot)), w, col)
	elif single_shape:
		var ln: Item = items[0] if work == null else work
		var lp := Shapes.line_points(ln)
		var mapped := PackedVector2Array()
		for p in lp:
			mapped.append(xf * p)
		od.line(mapped, w * 3.0, Color(col.r, col.g, col.b, 0.35), false)
	else:
		var r := group_bounds(items)
		for it2 in items:
			if (it2 as Item).kind != Item.STROKE:
				od.line(_box_points((it2 as Item).bounds().grow(0.004), xf), w * 0.7, Color(col.r, col.g, col.b, 0.4), true)
		od.line(_box_points(r, xf), w, col, true)
		od.segment(xf * Vector2(r.get_center().x, r.end.y), xf * Vector2(r.get_center().x, r.end.y + 0.055 / s), w, col)
	for h in v.handles:
		var hid := str(h.id)
		var active: bool = d.state == S.DRAG_HANDLE and str(d._handle.get("id", "")) == hid
		var fill := Color(1, 1, 1, 0.95) if active else Color(0.1, 0.16, 0.2, 0.9)
		var r2 := HANDLE_R / s
		od.disc(h.pos, r2 * 1.25, Color(col.r, col.g, col.b, 0.95))
		od.disc(h.pos, r2 * 0.8, fill)
		if str(h.kind) == "rot":
			od.ring(h.pos, r2 * 0.45, 0.0012 / s, Color(col.r, col.g, col.b, 1.0), 12)
	_draw_bar(od, fn, xf)


## The undo / redo / delete buttons beside the selection (`xf`: how far the selection has been dragged, they go with it).
func _draw_bar(od: OverlayDraw, fn: FrameNode, xf: Transform2D) -> void:
	var s := fn.data.scale
	var k := BTN_R / s
	for b in bar_buttons(fn):
		var id := str(b.id)
		var a := 1.0 if b.on else 0.35
		var tint := Color(1.0, 0.45, 0.4) if id == "delete" else Color(0.45, 0.95, 1.0)
		var c: Vector2 = xf * (b.pos as Vector2)
		od.disc(c, k * 1.2, Color(tint.r, tint.g, tint.b, 0.9 * a))
		od.disc(c, k * 0.95, Color(0.08, 0.13, 0.17, 0.95))
		var white := Color(1, 1, 1, a)
		var lw := 0.0016 / s
		if id == "trash" or id == "delete":
			od.line(PackedVector2Array([c + Vector2(-0.4, 0.3) * k, c + Vector2(-0.3, -0.5) * k, c + Vector2(0.3, -0.5) * k, c + Vector2(0.4, 0.3) * k]), lw, white, false)
			od.segment(c + Vector2(-0.55, 0.3) * k, c + Vector2(0.55, 0.3) * k, lw, white)
			od.line(PackedVector2Array([c + Vector2(-0.18, 0.3) * k, c + Vector2(-0.14, 0.55) * k, c + Vector2(0.14, 0.55) * k, c + Vector2(0.18, 0.3) * k]), lw, white, false)
		else:
			# an arc over the top with an arrowhead at its end; redo is the mirror image
			var m := -1.0 if id == "redo" else 1.0
			var arc := PackedVector2Array()
			for i in 13:
				var ang := deg_to_rad(15.0 + 185.0 * float(i) / 12.0)
				arc.append(c + Vector2(m * cos(ang) * 0.5, sin(ang) * 0.42 - 0.12) * k)
			od.line(arc, lw, white, false)
			var tip: Vector2 = arc[arc.size() - 1]
			od.polygon(PackedVector2Array([tip + Vector2(-0.26, 0.06) * k, tip + Vector2(0.26, 0.06) * k, tip + Vector2(0, -0.3) * k]), white)


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
